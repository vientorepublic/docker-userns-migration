#!/usr/bin/env bash
# ==============================================================================
# docker-userns-migrate.sh
#
# Enables Docker userns-remap and migrates ALL existing named volumes and
# host bind mounts so containers can continue to read/write their data.
#
# What it does (in order):
#   1. Pre-flight:  verify root, docker, jq; detect Docker data root
#   2. Inventory:   record all named volumes and user bind mounts
#   3. Shutdown:    stop every running container
#   4. Backup:      tar.gz each named volume's _data into BACKUP_DIR
#   5. Configure:   merge {"userns-remap":"default"} into daemon.json,
#                   restart Docker, read the actual offset from /etc/subuid
#   6. Volumes:     docker volume create each volume in the new namespace,
#                   cp -a old _data into the new location, shift UID/GID +offset
#   7. Bind mounts: prompt to shift UID/GID +offset on host paths
#   8. Verify:      list volumes and show the new uid_map format
#
# Requirements: bash 4+, docker, jq, find, cp, chown  (standard on any distro)
# Must be run as: root
#
# Usage:
#   ./docker-userns-migrate.sh
#
# Environment overrides:
#   DOCKER_ROOT=/var/lib/docker          (auto-detected from `docker info`)
#   DAEMON_JSON=/etc/docker/daemon.json
#   BACKUP_DIR=/root/docker-userns-backup-<timestamp>
#   DRY_RUN=true         print every action without executing it
#   SKIP_BACKUP=true     skip the tarball backup step
#   FORCE_MIGRATE=true   skip daemon.json edit & Docker restart; only copy data
#                        into the existing userns namespace root and fix ownership.
#                        Use this when userns-remap is already active but old
#                        volume data has not yet been moved to the new root.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Defaults (overridable via environment)
# ---------------------------------------------------------------------------
DOCKER_ROOT="${DOCKER_ROOT:-}"
DAEMON_JSON="${DAEMON_JSON:-/etc/docker/daemon.json}"
BACKUP_DIR="${BACKUP_DIR:-/root/docker-userns-backup-$(date +%Y%m%d-%H%M%S)}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_BACKUP="${SKIP_BACKUP:-false}"
FORCE_MIGRATE="${FORCE_MIGRATE:-false}"

# Populated after Docker restarts
USERNS_OFFSET=""
# Physical Docker data root — never contains the userns suffix.
# Derived in preflight() by stripping the /<offset>.<offset> suffix that
# Docker appends to DockerRootDir when userns-remap is active.
REAL_DOCKER_ROOT=""

# Inventories filled during take_inventory()
declare -a VOLUME_NAMES=()
declare -A VOLUME_DRIVER=()
declare -A VOLUME_LABELS=()
declare -a BIND_MOUNT_PATHS=()

# ---------------------------------------------------------------------------
# Terminal colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
step()  { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }
die()   { err "$*"; exit 1; }

# dry-run wrapper: print command if DRY_RUN=true, otherwise run it
drun() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} $*"
    else
        "$@"
    fi
}

# ===========================================================================
# PHASE 0 — PRE-FLIGHT
# ===========================================================================
preflight() {
    step "Pre-flight checks"

    [[ $EUID -eq 0 ]] || die "Must be run as root."
    command -v docker &>/dev/null || die "'docker' not found in PATH."
    command -v jq    &>/dev/null || die "'jq' is required.  apt-get install -y jq  |  yum install -y jq"
    docker info &>/dev/null      || die "Docker daemon is not running."

    # Detect Docker data root (honours custom --data-root)
    if [[ -z "$DOCKER_ROOT" ]]; then
        DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
    fi
    info "Docker data root (reported) : $DOCKER_ROOT"

    # When userns-remap is active, Docker appends /<offset>.<offset> to the
    # data root it reports (e.g. /var/lib/docker/100000.100000).  The physical
    # base directory — where the pre-remap volumes still live — is one level up.
    if [[ "$DOCKER_ROOT" =~ ^(.+)/[0-9]+\.[0-9]+$ ]]; then
        REAL_DOCKER_ROOT="${BASH_REMATCH[1]}"
        info "Physical Docker root (userns suffix stripped): $REAL_DOCKER_ROOT"
    else
        REAL_DOCKER_ROOT="$DOCKER_ROOT"
    fi

    # Check if userns-remap is already active
    if docker info 2>/dev/null | grep -qi "userns"; then
        if [[ "$FORCE_MIGRATE" == "true" ]]; then
            warn "userns-remap is already active — running in data-only migration mode (FORCE_MIGRATE=true)."
            warn "daemon.json and Docker daemon will NOT be modified."
        else
            die "userns-remap is already active. Use FORCE_MIGRATE=true to migrate existing data into the new namespace root."
        fi
    fi

    ok "All pre-flight checks passed."
}

# ===========================================================================
# PHASE 1 — INVENTORY  (must run while Docker is still up)
# ===========================================================================
take_inventory() {
    step "Taking inventory"
    mkdir -p "$BACKUP_DIR"

    # ---- Named volumes ----
    info "Enumerating named volumes…"

    # FORCE_MIGRATE: userns-remap is already active, so `docker volume ls`
    # only sees volumes registered in the NEW namespace root
    # (${DOCKER_ROOT}/<offset>.<offset>/volumes/).
    # The OLD data that was never migrated still lives under
    # ${DOCKER_ROOT}/volumes/.  Scan that directory on disk directly.
    #
    # Normal mode: use `docker volume ls` as usual.
    _enumerate_volumes() {
        if [[ "$FORCE_MIGRATE" == "true" ]]; then
            # Use REAL_DOCKER_ROOT (physical base, no userns suffix) so that we
            # scan /var/lib/docker/volumes/ not /var/lib/docker/100000.100000/volumes/
            local old_vol_root="${REAL_DOCKER_ROOT}/volumes"
            # Redirect info/warn to stderr — this function's stdout must only
            # contain bare volume names so the caller's `while read` loop works.
            info "  (FORCE_MIGRATE) scanning pre-userns disk root: ${old_vol_root}/" >&2
            if [[ ! -d "$old_vol_root" ]]; then
                warn "  Directory not found: $old_vol_root — no old volumes to migrate." >&2
                return
            fi
            find "${old_vol_root}" -maxdepth 1 -mindepth 1 -type d \
                -printf "%f\n" 2>/dev/null || true
        else
            docker volume ls -q
        fi
    }

    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        VOLUME_NAMES+=("$vol")

        # Determine driver:
        #   FORCE_MIGRATE — docker volume inspect only sees the NEW namespace and
        #   will fail (or return garbage) for old volumes.  Read the driver from
        #   the on-disk config.v2.json instead.
        #   Normal mode — ask Docker directly.
        local _drv
        if [[ "$FORCE_MIGRATE" == "true" ]]; then
            local _cfg="${REAL_DOCKER_ROOT}/volumes/${vol}/config.v2.json"
            if [[ -f "$_cfg" ]]; then
                _drv=$(jq -r '.Driver // "local"' "$_cfg" 2>/dev/null || echo "local")
            else
                _drv="local"
            fi
        else
            _drv=$(docker volume inspect --format '{{.Driver}}' "$vol" 2>/dev/null || echo "local")
        fi
        # Strip any stray whitespace / newlines that some Docker versions emit
        _drv="${_drv//[$'\n\r\t ']/}"
        [[ -z "$_drv" ]] && _drv="local"
        VOLUME_DRIVER["$vol"]="$_drv"

        local raw_labels
        # In FORCE_MIGRATE mode docker volume inspect sees the NEW namespace only
        # and will find nothing for old-namespace volumes.  Fall back to reading
        # the labels from the on-disk config.v2.json.
        if [[ "$FORCE_MIGRATE" == "true" ]]; then
            local _lcfg="${REAL_DOCKER_ROOT}/volumes/${vol}/config.v2.json"
            if [[ -f "$_lcfg" ]]; then
                # Build --label k=v string from the Labels object
                raw_labels=$(jq -r '
                    .Labels // {} | to_entries[] |
                    "--label " + .key + "=" + .value
                ' "$_lcfg" 2>/dev/null | tr '\n' ' ' | xargs || true)
            else
                raw_labels=""
            fi
        else
            raw_labels=$(docker volume inspect --format \
                '{{range $k,$v := .Labels}}--label {{$k}}={{$v}} {{end}}' "$vol" 2>/dev/null | xargs || true)
        fi
        VOLUME_LABELS["$vol"]="${raw_labels:-}"
    done < <(_enumerate_volumes)

    if [[ ${#VOLUME_NAMES[@]} -gt 0 ]]; then
        info "Found ${#VOLUME_NAMES[@]} volume(s):"
        for v in "${VOLUME_NAMES[@]}"; do
            printf "    %-40s  driver: %s\n" "$v" "${VOLUME_DRIVER[$v]}"
        done
    else
        info "No named volumes found."
    fi

    # ---- Bind mounts (user-space paths only) ----
    # Skip standard system mount sources that don't need ownership changes.
    local -a SKIP_PREFIXES=(
        "/etc/" "/proc/" "/sys/" "/dev/" "/run/" "/var/run/"
        "/tmp/" "/usr/" "/bin/" "/sbin/" "/lib/" "/lib64/"
    )

    info "Enumerating bind mounts across all containers…"
    declare -A _seen_paths=()

    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        local sources
        # Extract source path of every bind-type mount
        sources=$(docker inspect \
            --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' \
            "$cid" 2>/dev/null || true)

        while IFS= read -r src; do
            [[ -z "$src" ]] && continue

            local skip=false
            for prefix in "${SKIP_PREFIXES[@]}"; do
                if [[ "$src" == "$prefix"* ]]; then skip=true; break; fi
            done
            $skip && continue

            if [[ -z "${_seen_paths[$src]+_}" ]]; then
                _seen_paths["$src"]=1
                BIND_MOUNT_PATHS+=("$src")
            fi
        done <<< "$sources"
    done < <(docker ps -aq)

    if [[ ${#BIND_MOUNT_PATHS[@]} -gt 0 ]]; then
        info "Found ${#BIND_MOUNT_PATHS[@]} user bind mount path(s):"
        for p in "${BIND_MOUNT_PATHS[@]}"; do echo "    $p"; done
    else
        info "No user bind mounts found."
    fi

    # Persist inventory so it can be reviewed later
    {
        printf "VOLUME_NAMES=(%s)\n"       "${VOLUME_NAMES[*]+"${VOLUME_NAMES[*]}"}"
        printf "BIND_MOUNT_PATHS=(%s)\n"   "${BIND_MOUNT_PATHS[*]+"${BIND_MOUNT_PATHS[*]}"}"
    } > "$BACKUP_DIR/inventory.sh"

    ok "Inventory saved → $BACKUP_DIR/inventory.sh"
}

# ===========================================================================
# CONFIRM PLAN  (interactive gate before first destructive step)
# ===========================================================================
confirm_plan() {
    # DRY_RUN is non-destructive — skip prompt
    if [[ "$DRY_RUN" == "true" ]]; then return; fi

    local mode_label
    if [[ "$FORCE_MIGRATE" == "true" ]]; then
        mode_label="FORCE_MIGRATE  (data-only — daemon.json unchanged)"
    else
        mode_label="Normal  (enable userns-remap + restart Docker)"
    fi

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                   Migration Plan                         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    printf "  %-22s %s\n" "Mode:"           "$mode_label"
    printf "  %-22s %s\n" "Named volumes:"  "${#VOLUME_NAMES[@]}"
    printf "  %-22s %s\n" "Bind mounts:"    "${#BIND_MOUNT_PATHS[@]}"
    printf "  %-22s %s\n" "Backup dir:"     "$BACKUP_DIR"
    echo ""
    echo -e "${YELLOW}${BOLD}The following DESTRUCTIVE actions will be performed:${NC}"
    echo "  • Stop ALL running containers"
    if [[ "$SKIP_BACKUP" != "true" && ${#VOLUME_NAMES[@]} -gt 0 ]]; then
        echo "  • Backup named volume data → $BACKUP_DIR/volumes/"
    fi
    if [[ "$FORCE_MIGRATE" != "true" ]]; then
        echo "  • Modify  $DAEMON_JSON  (add userns-remap: default)"
        echo "  • Restart Docker daemon"
    fi
    if [[ ${#VOLUME_NAMES[@]} -gt 0 ]]; then
        echo "  • Copy each volume's _data into the new namespace root"
        echo "  • Shift all file UID/GID ownership by +<offset>"
    fi
    if [[ ${#BIND_MOUNT_PATHS[@]} -gt 0 ]]; then
        echo "  • Prompt to shift UID/GID on bind mount host paths"
    fi
    echo ""

    local answer="n"
    read -r -p "Proceed with migration? [y/N] " answer
    if [[ "${answer,,}" != "y" ]]; then
        info "Aborted by user."
        exit 0
    fi
    echo ""
}

# ===========================================================================
# PHASE 2 — STOP ALL CONTAINERS
# ===========================================================================
stop_all_containers() {
    step "Stopping all running containers"

    local running
    running=$(docker ps -q)
    if [[ -z "$running" ]]; then
        info "No running containers."
        return
    fi

    local count
    count=$(echo "$running" | wc -l | tr -d ' ')
    info "Stopping $count container(s)…"
    # shellcheck disable=SC2086
    drun docker stop $running
    ok "$count container(s) stopped."
}

# ===========================================================================
# PHASE 3 — BACKUP NAMED VOLUMES
# ===========================================================================
backup_volumes() {
    step "Backing up named volumes"

    if [[ "$SKIP_BACKUP" == "true" ]]; then
        warn "SKIP_BACKUP=true — proceeding without backup."
        return
    fi

    if [[ ${#VOLUME_NAMES[@]} -eq 0 ]]; then
        info "No volumes to back up."
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$BACKUP_DIR/volumes"
    fi

    for vol in "${VOLUME_NAMES[@]}"; do
        local driver="${VOLUME_DRIVER[$vol]:-local}"
        driver="${driver//[$'\n\r\t ']/}"   # defensive trim
        if [[ "$driver" != "local" ]]; then
            warn "  Skipping '$vol' (driver=$driver — back up manually)."
            continue
        fi

        local src="${REAL_DOCKER_ROOT}/volumes/${vol}/_data"
        if [[ ! -d "$src" ]]; then
            warn "  Skipping '$vol': _data not found at $src"
            continue
        fi

        info "  Backing up: $vol"
        drun tar czf "${BACKUP_DIR}/volumes/${vol}.tar.gz" \
            -C "${REAL_DOCKER_ROOT}/volumes/${vol}" _data
    done

    ok "Backup complete → $BACKUP_DIR/volumes/"
}

# ===========================================================================
# PHASE 4 — CONFIGURE daemon.json  +  RESTART DOCKER
# ===========================================================================
configure_and_restart() {
    # FORCE_MIGRATE: userns-remap is already active — do not touch daemon.json or
    # restart Docker.  Just resolve the current offset from /etc/subuid.
    if [[ "$FORCE_MIGRATE" == "true" ]]; then
        step "Resolving current userns offset (FORCE_MIGRATE — no daemon changes)"
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[dry-run] Would read offset from /etc/subuid"
            USERNS_OFFSET=100000
            return
        fi
        if grep -q "^dockremap:" /etc/subuid 2>/dev/null; then
            USERNS_OFFSET=$(awk -F: '/^dockremap:/{print $2}' /etc/subuid | head -1)
            ok "Detected userns offset (from /etc/subuid): +${USERNS_OFFSET}"
        else
            USERNS_OFFSET=100000
            warn "dockremap not found in /etc/subuid; assuming offset=100000"
        fi
        return
    fi

    step "Configuring userns-remap and restarting Docker"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Would merge {\"userns-remap\":\"default\"} into $DAEMON_JSON"
        info "[dry-run] Would restart Docker daemon"
        USERNS_OFFSET=100000
        return
    fi

    # Back up existing daemon.json (if any) and merge the new key
    if [[ -f "$DAEMON_JSON" ]]; then
        local bak="${DAEMON_JSON}.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$DAEMON_JSON" "$bak"
        info "Backed up $DAEMON_JSON → $bak"
        jq '. + {"userns-remap": "default"}' "$DAEMON_JSON" > "${DAEMON_JSON}.tmp"
        mv "${DAEMON_JSON}.tmp" "$DAEMON_JSON"
    else
        mkdir -p "$(dirname "$DAEMON_JSON")"
        printf '{\n  "userns-remap": "default"\n}\n' > "$DAEMON_JSON"
    fi

    info "Updated $DAEMON_JSON:"
    cat "$DAEMON_JSON"

    # Restart the Docker daemon
    info "Restarting Docker daemon…"
    if command -v systemctl &>/dev/null; then
        systemctl restart docker
    elif command -v service &>/dev/null; then
        service docker restart
    else
        die "Cannot restart Docker: neither systemctl nor service found."
    fi

    # Wait until daemon responds
    local attempts=20
    while ! docker info &>/dev/null; do
        sleep 1
        (( attempts-- ))
        [[ $attempts -le 0 ]] && die "Docker did not come back up after restart."
    done
    ok "Docker daemon is up."

    # Determine the actual UID/GID offset that Docker chose
    if grep -q "^dockremap:" /etc/subuid 2>/dev/null; then
        USERNS_OFFSET=$(awk -F: '/^dockremap:/{print $2}' /etc/subuid | head -1)
        ok "userns offset (from /etc/subuid): +${USERNS_OFFSET}"
    else
        USERNS_OFFSET=100000
        warn "dockremap not found in /etc/subuid; assuming offset=100000"
    fi
}

# ===========================================================================
# HELPER — apply UID/GID +offset to every file under a path
# ===========================================================================
apply_offset() {
    local path="$1"
    local offset="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "    [dry-run] Would shift UID/GID +${offset} under: $path"
        return
    fi

    # Collect all unique UID:GID pairs present in the tree.
    # Process in DESCENDING order so that UIDs/GIDs that are already in the
    # offset range (e.g. from a partial previous run) are shifted first;
    # this prevents freshly-shifted files from being matched again when a
    # lower source UID is processed next.
    local pairs
    pairs=$(find "$path" -printf "%U:%G\n" 2>/dev/null | sort -t: -k1 -rn -k2 -rn | uniq)

    while IFS=: read -r uid gid; do
        [[ -z "$uid" || -z "$gid" ]] && continue
        local new_uid=$(( uid + offset ))
        local new_gid=$(( gid + offset ))
        find "$path" -uid "$uid" -gid "$gid" -exec chown -h "${new_uid}:${new_gid}" {} +
    done <<< "$pairs"
}

# ===========================================================================
# PHASE 5 — MIGRATE NAMED VOLUMES
# ===========================================================================
migrate_volumes() {
    step "Migrating named volumes"

    if [[ ${#VOLUME_NAMES[@]} -eq 0 ]]; then
        info "No volumes to migrate."
        return
    fi

    local offset="${USERNS_OFFSET:-100000}"

    # old_root: physical base /var/lib/docker/volumes/  (pre-remap data lives here)
    # new_root: userns namespace /var/lib/docker/<offset>.<offset>/volumes/
    # REAL_DOCKER_ROOT is always the physical base regardless of FORCE_MIGRATE.
    local old_root="${REAL_DOCKER_ROOT}/volumes"
    local new_root="${REAL_DOCKER_ROOT}/${offset}.${offset}/volumes"

    info "Old volume root : $old_root"
    info "New volume root : $new_root"

    for vol in "${VOLUME_NAMES[@]}"; do
        local driver="${VOLUME_DRIVER[$vol]:-local}"
        driver="${driver//[$'\n\r\t ']/}"   # defensive trim
        if [[ "$driver" != "local" ]]; then
            warn "  Skipping '$vol' (driver=$driver — migrate manually)."
            continue
        fi

        local src="${old_root}/${vol}/_data"
        if [[ ! -d "$src" ]]; then
            warn "  Skipping '$vol': source _data not found at $src"
            continue
        fi

        info "  Migrating: $vol"
        info "    src : $src"

        # Register the volume in the new (userns) namespace so Docker creates
        # the metadata and the _data directory.
        local labels="${VOLUME_LABELS[$vol]:-}"
        if [[ "$DRY_RUN" == "true" ]]; then
            info "    [dry-run] docker volume create ${labels} ${vol}"
        else
            # shellcheck disable=SC2086
            docker volume create ${labels} "$vol" > /dev/null 2>&1 || true
        fi

        local dst="${new_root}/${vol}/_data"
        info "    dst : $dst"

        # Ensure destination directory exists (docker volume create should have
        # created it, but guard against edge cases).
        if [[ "$DRY_RUN" != "true" ]]; then
            if [[ ! -d "$dst" ]]; then
                warn "    dst not created by 'docker volume create'; creating manually…"
                mkdir -p "$dst"
            fi
        fi

        # Guard: do not copy if src and dst are the same path (would happen if
        # old_root == new_root, which should not occur but is a safety net).
        if [[ "$src" == "$dst" ]]; then
            warn "  src == dst for '$vol' — skipping copy, applying offset only."
            apply_offset "$dst" "$offset"
            ok "  Done (offset-only): $vol"
            continue
        fi

        # Check whether dst already has content (idempotency guard).
        if [[ "$DRY_RUN" != "true" ]] && [[ -n "$(ls -A "$dst" 2>/dev/null)" ]]; then
            warn "  dst is not empty for '$vol' — skipping copy (already migrated?)."
            warn "  Applying offset to existing dst anyway."
            apply_offset "$dst" "$offset"
            ok "  Done (offset-only, dst was non-empty): $vol"
            continue
        fi

        # Copy data preserving permissions, timestamps, symlinks
        drun cp -a "${src}/." "${dst}/"

        # Shift ownership +offset
        info "    Applying UID/GID +${offset} offset…"
        apply_offset "$dst" "$offset"

        ok "  Done: $vol"
    done
}

# ===========================================================================
# PHASE 6 — MIGRATE BIND MOUNTS  (interactive)
# ===========================================================================
migrate_bind_mounts() {
    step "Bind mount ownership migration"

    if [[ ${#BIND_MOUNT_PATHS[@]} -eq 0 ]]; then
        info "No user bind mounts detected — nothing to do."
        return
    fi

    local offset="${USERNS_OFFSET:-100000}"

    warn "The following host paths are used as bind mounts:"
    for p in "${BIND_MOUNT_PATHS[@]}"; do echo "    $p"; done
    echo ""
    warn "With userns-remap the container's UID 0 maps to host UID ${offset}."
    warn "Files owned by UID 0 on the host will NOT be writable inside the container"
    warn "unless their ownership is shifted by +${offset}."
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        for p in "${BIND_MOUNT_PATHS[@]}"; do
            info "  [dry-run] Would apply UID/GID +${offset} to: $p"
        done
        return
    fi

    local answer="n"
    read -r -p "Apply UID/GID +${offset} to all listed bind mount paths? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
        for p in "${BIND_MOUNT_PATHS[@]}"; do
            if [[ -e "$p" ]]; then
                info "  Applying offset to: $p"
                apply_offset "$p" "$offset"
                ok "  Done: $p"
            else
                warn "  Path not found, skipping: $p"
            fi
        done
    else
        warn "Skipped. Apply manually per path as needed:"
        for p in "${BIND_MOUNT_PATHS[@]}"; do
            echo "    # find '$p' -uid 0 -exec chown ${offset} {} +"
        done
    fi
}

# ===========================================================================
# PHASE 7 — VERIFY
# ===========================================================================
verify() {
    step "Verification"

    local offset="${USERNS_OFFSET:-100000}"
    local new_root="${REAL_DOCKER_ROOT}/${offset}.${offset}/volumes"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Verification skipped."
        return
    fi

    if [[ -d "$new_root" ]]; then
        info "Volumes in new namespace path ($new_root):"
        ls -la "$new_root"
    else
        warn "New volume directory not found: $new_root"
    fi

    info "docker volume ls (new namespace):"
    docker volume ls
}

# ===========================================================================
# SUMMARY
# ===========================================================================
print_summary() {
    local offset="${USERNS_OFFSET:-100000}"
    local new_root="${REAL_DOCKER_ROOT}/${offset}.${offset}/volumes"

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║                  Migration complete                      ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    printf "  %-28s +%s\n" "UID/GID offset applied:"  "$offset"
    printf "  %-28s %s\n"  "New volume root:"          "$new_root"
    printf "  %-28s %s\n"  "Backup location:"          "$BACKUP_DIR/volumes/"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo "  1. Re-pull Docker images (image layers are NOT migrated — the new"
    echo "     namespace starts with an empty image store):"
    echo "       docker compose pull"
    echo ""
    echo "  2. Start your services:"
    echo "       docker compose up -d"
    echo ""
    echo "  3. Confirm the uid_map of a running container:"
    echo "       PID=\$(docker inspect -f '{{.State.Pid}}' <container_name>)"
    echo "       cat /proc/\$PID/uid_map"
    echo "       # Expected:  0  ${offset}  65536"
    echo ""
    echo "  4. To roll back (if anything is wrong):"
    echo "       # Remove 'userns-remap' from $DAEMON_JSON"
    echo "       # systemctl restart docker"
    echo "       # Restore from $BACKUP_DIR/volumes/<name>.tar.gz"
    echo ""
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║       Docker userns-remap Migration Script               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    [[ "$DRY_RUN"       == "true" ]] && warn "DRY-RUN mode — no changes will be made." && echo ""
    [[ "$FORCE_MIGRATE" == "true" ]] && warn "FORCE_MIGRATE mode — daemon.json will NOT be modified." && echo ""

    preflight
    take_inventory
    confirm_plan
    stop_all_containers
    backup_volumes
    configure_and_restart
    migrate_volumes
    migrate_bind_mounts
    verify
    print_summary
}

main "$@"
