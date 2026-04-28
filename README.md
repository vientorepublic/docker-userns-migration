# docker-userns-migration

Docker의 **userns-remap** 기능을 활성화하고, 기존 named volume과 bind mount 데이터를 새 네임스페이스로 자동 마이그레이션하는 Bash 스크립트입니다.

---

## 목차

- [배경 — userns-remap이란](#배경--userns-remap이란)
- [이 스크립트가 해결하는 문제](#이-스크립트가-해결하는-문제)
- [사전 요구사항](#사전-요구사항)
- [빠른 시작](#빠른-시작)
- [환경 변수 (동작 제어)](#환경-변수-동작-제어)
- [실행 흐름 (단계별 설명)](#실행-흐름-단계별-설명)
- [FORCE_MIGRATE 모드 — 실수 복구](#force_migrate-모드--실수-복구)
- [마이그레이션 완료 후 작업](#마이그레이션-완료-후-작업)
- [롤백 방법](#롤백-방법)
- [주의사항 및 제한](#주의사항-및-제한)

---

## 배경 — userns-remap이란

Docker는 기본적으로 컨테이너 내부의 `root(UID 0)`를 호스트의 `root(UID 0)`와 동일하게 취급합니다. 컨테이너 탈출 취약점이 발생하면 호스트 전체가 위험해질 수 있습니다.

**userns-remap**은 컨테이너 내부의 UID/GID를 호스트의 비특권 UID/GID 범위로 매핑하는 Linux User Namespace 기능입니다.

```
컨테이너 내부 UID 0  →  호스트 UID 100000
컨테이너 내부 UID 1  →  호스트 UID 100001
…
```

이렇게 하면 컨테이너가 호스트의 root 권한 없이 동작하므로 보안이 크게 향상됩니다.

### 활성화 시 생기는 데이터 문제

userns-remap을 활성화하면 Docker는 데이터 루트를 변경합니다.

```
활성화 전:  /var/lib/docker/volumes/<volume>/_data
활성화 후:  /var/lib/docker/100000.100000/volumes/<volume>/_data
                                  ↑ offset.offset 디렉토리
```

기존에 `UID 0`이 소유하던 파일들이 이제 `UID 100000`으로 보여야 하기 때문에, **마이그레이션 없이 userns-remap만 활성화하면 컨테이너가 자신의 볼륨 데이터를 읽지 못합니다.**

---

## 이 스크립트가 해결하는 문제

| 시나리오                                                                            | 해결책                         |
| ----------------------------------------------------------------------------------- | ------------------------------ |
| userns-remap을 아직 활성화하지 않았고, 기존 데이터를 안전하게 마이그레이션하고 싶다 | 기본 모드 실행                 |
| userns-remap을 **먼저 활성화해버렸고** 볼륨 데이터가 없어진 것처럼 보인다           | `FORCE_MIGRATE=true` 모드 실행 |
| 실제 변경 없이 어떤 작업이 일어날지 미리 확인하고 싶다                              | `DRY_RUN=true` 모드 실행       |

---

## 사전 요구사항

- Linux 호스트 (Ubuntu, Debian, RHEL, CentOS 등)
- Bash 4.0 이상
- `root` 권한으로 실행
- 다음 명령어가 PATH에 존재해야 함:
  - `docker`
  - `jq` (`apt-get install -y jq` 또는 `yum install -y jq`)
  - `find`, `cp`, `chown` (대부분의 배포판에 기본 포함)

---

## 빠른 시작

```bash
# 1. 스크립트에 실행 권한 부여
chmod +x userns_migration.sh

# 2. (권장) 먼저 dry-run으로 실행 계획 확인
sudo DRY_RUN=true ./userns_migration.sh

# 3. 실제 마이그레이션 실행
sudo ./userns_migration.sh
```

실행 중 마이그레이션 계획 요약이 출력되며, `y`를 입력해야 진행됩니다.

---

## 환경 변수 (동작 제어)

| 변수            | 기본값                                   | 설명                                                                                                                                                                                   |
| --------------- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DOCKER_ROOT`   | `docker info`로 자동 감지                | Docker 데이터 루트 경로                                                                                                                                                                |
| `DAEMON_JSON`   | `/etc/docker/daemon.json`                | Docker 데몬 설정 파일 경로                                                                                                                                                             |
| `BACKUP_DIR`    | `/root/docker-userns-backup-<timestamp>` | 백업 저장 디렉토리                                                                                                                                                                     |
| `DRY_RUN`       | `false`                                  | `true`로 설정하면 실제 변경 없이 수행될 작업만 출력                                                                                                                                    |
| `SKIP_BACKUP`   | `false`                                  | `true`로 설정하면 볼륨 백업 단계를 건너뜀                                                                                                                                              |
| `FORCE_MIGRATE` | `false`                                  | `true`로 설정하면 daemon.json 수정과 Docker 재시작을 생략하고 데이터 복사와 소유권 수정만 수행. **userns-remap이 이미 활성화된 상태에서 데이터가 새 경로로 옮겨지지 않은 경우에 사용** |

### 사용 예시

```bash
# 백업 없이 마이그레이션 (이미 외부 백업이 있는 경우)
sudo SKIP_BACKUP=true ./userns_migration.sh

# 커스텀 백업 경로 지정
sudo BACKUP_DIR=/mnt/backup/docker-migration ./userns_migration.sh

# 데이터만 마이그레이션 (userns-remap이 이미 활성화된 경우)
sudo FORCE_MIGRATE=true ./userns_migration.sh
```

---

## 실행 흐름 (단계별 설명)

### Phase 0 — Pre-flight 검사

- `root` 권한 확인
- `docker`, `jq` 명령어 존재 여부 확인
- Docker 데몬 실행 중인지 확인
- `docker info`로 실제 데이터 루트 경로 자동 감지
  - userns-remap이 이미 활성화되어 있으면 경로에 `/<offset>.<offset>` 접미사가 붙어 있으며, 스크립트가 물리적 베이스 경로를 자동으로 분리함

### Phase 1 — 인벤토리 수집

- 현재 존재하는 모든 **named volume** 목록과 드라이버, 레이블 정보 수집
- 모든 컨테이너에서 사용 중인 **bind mount 경로** 수집 (시스템 경로 자동 제외)
- 수집된 정보는 `$BACKUP_DIR/inventory.sh`에 저장

### Phase 2 — 컨테이너 중지

- 실행 중인 모든 컨테이너를 `docker stop`으로 안전하게 중지

### Phase 3 — 볼륨 백업

- `local` 드라이버의 named volume `_data` 디렉토리를 `tar.gz`로 압축 저장
- 백업 경로: `$BACKUP_DIR/volumes/<volume_name>.tar.gz`
- 서드파티 드라이버(예: `nfs`, `rexray`) 볼륨은 건너뛰고 경고 출력
- `SKIP_BACKUP=true`로 건너뛸 수 있음

### Phase 4 — userns-remap 설정 및 Docker 재시작

- `/etc/docker/daemon.json`에 `"userns-remap": "default"` 추가 (기존 파일은 `.bak` 백업 후 `jq`로 병합)
- `systemctl restart docker` 또는 `service docker restart`로 재시작
- 재시작 후 `/etc/subuid`의 `dockremap` 항목에서 실제 UID/GID offset 값 읽기

> **FORCE_MIGRATE 모드**에서는 이 단계를 완전히 건너뜁니다. `/etc/subuid`에서 offset만 읽습니다.

### Phase 5 — Named Volume 마이그레이션

각 볼륨에 대해 다음 작업을 수행합니다.

1. `docker volume create`로 새 네임스페이스에 볼륨 등록 (레이블 포함)
2. 기존 `_data` 디렉토리의 내용을 새 네임스페이스 경로로 복사 (`cp -a`, 권한/타임스탬프 보존)
3. 복사된 파일의 UID/GID를 **+offset**만큼 일괄 이동

```
복사 경로:
  /var/lib/docker/volumes/<vol>/_data
    → /var/lib/docker/100000.100000/volumes/<vol>/_data

UID/GID 변환:
  UID 0  → UID 100000
  UID 33 → UID 100033
```

중복 실행 안전성: 목적지 디렉토리에 이미 파일이 있으면 복사를 건너뛰고 소유권 조정만 수행합니다.

### Phase 6 — Bind Mount 소유권 수정 (인터랙티브)

bind mount 경로가 발견된 경우, 각 경로에 대해 `+offset` 소유권 이동 여부를 사용자에게 확인 후 처리합니다.

거부한 경우 수동으로 적용할 수 있는 명령어를 출력합니다.

```bash
find '/data/myapp' -uid 0 -exec chown 100000 {} +
```

### Phase 7 — 검증

- 새 네임스페이스 볼륨 디렉토리 목록 출력
- `docker volume ls`로 새 네임스페이스에서 볼륨이 보이는지 확인

---

## FORCE_MIGRATE 모드 — 실수 복구

### 문제 상황

userns-remap을 **데이터 마이그레이션 없이 먼저 활성화**한 경우:

```bash
# daemon.json에 userns-remap을 추가하고 Docker를 재시작했더니
# docker volume ls 가 비어 있고, 컨테이너가 데이터를 찾지 못함
```

이 상황에서 데이터는 삭제된 것이 아닙니다. 기존 데이터는 여전히 `/var/lib/docker/volumes/`에 존재하지만, Docker는 이제 `/var/lib/docker/100000.100000/volumes/`만 바라보고 있습니다.

### 해결 방법

```bash
sudo FORCE_MIGRATE=true ./userns_migration.sh
```

FORCE_MIGRATE 모드에서는:

1. `daemon.json` 및 Docker 재시작을 **완전히 생략**합니다.
2. `docker volume ls` 대신 디스크에서 직접 `/var/lib/docker/volumes/`를 스캔하여 기존 볼륨을 찾습니다.
3. 볼륨 메타데이터(드라이버, 레이블)를 `docker volume inspect` 대신 온디스크 `config.v2.json` 파일에서 읽습니다.
4. 볼륨 데이터를 새 네임스페이스 경로로 복사하고 소유권을 조정합니다.

### 내부 동작 원리

userns-remap 활성화 상태에서 `docker info`는 다음과 같이 보고합니다.

```
DockerRootDir: /var/lib/docker/100000.100000
```

스크립트는 이 접미사(`/100000.100000`)를 정규식으로 감지하여 물리적 베이스 경로(`/var/lib/docker`)를 분리합니다. FORCE_MIGRATE 모드에서는 이 물리적 경로에서 기존 볼륨을 찾습니다.

---

## 마이그레이션 완료 후 작업

### 1. Docker 이미지 다시 pull

userns-remap 활성화 시 Docker는 **새 네임스페이스의 이미지 스토어를 비어있는 상태로 시작**합니다. 기존 이미지 레이어는 마이그레이션되지 않으므로 다시 pull해야 합니다.

```bash
docker compose pull
```

### 2. 서비스 시작

```bash
docker compose up -d
```

### 3. userns 매핑 확인

```bash
PID=$(docker inspect -f '{{.State.Pid}}' <container_name>)
cat /proc/$PID/uid_map
# 정상 출력:  0  100000  65536
```

---

## 롤백 방법

마이그레이션 후 문제가 발생한 경우:

```bash
# 1. daemon.json에서 userns-remap 설정 제거
sudo jq 'del(."userns-remap")' /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json

# 2. Docker 재시작
sudo systemctl restart docker

# 3. 백업에서 볼륨 데이터 복원
# (예시: myvolume 복원)
sudo tar xzf /root/docker-userns-backup-<timestamp>/volumes/myvolume.tar.gz \
    -C /var/lib/docker/volumes/myvolume/
```

---

## 주의사항 및 제한

- **서드파티 볼륨 드라이버** (`nfs`, `rexray` 등)를 사용하는 볼륨은 자동 마이그레이션에서 제외됩니다. 수동으로 마이그레이션해야 합니다.
- **Docker 이미지는 마이그레이션되지 않습니다.** 새 네임스페이스에서 이미지를 다시 pull해야 합니다.
- 실행 중인 **모든 컨테이너가 중지**됩니다. 프로덕션 환경에서는 유지보수 시간을 계획하고 실행하세요.
- `/etc/subuid`와 `/etc/subgid`에 `dockremap` 항목이 없으면 offset을 `100000`으로 가정합니다. 실제 값과 다를 경우 수동으로 `USERNS_OFFSET` 환경 변수를 지정하거나 스크립트 실행 전 확인하세요.
- bind mount 소유권 변경은 **되돌리기 어렵습니다.** 확인 프롬프트에서 신중하게 응답하세요.
