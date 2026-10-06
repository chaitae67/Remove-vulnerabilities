#!/usr/bin/env bash
# =============================================================================
# db-active OS 기준선(baseline) 재현 스크립트
#
#  대상  : 같은 AMI(ami-0d84f865d3f4728e2, amzn2-ami-hvm-2.0.20260914.1, Amazon Linux 2)
#          + 같은 user_data(os/db-active/user_data.tpl)로 새로 만든 인스턴스
#  목적  : 2026-10-06 기준 운영 db-active 의 OS·Docker·Oracle XE 설정 상태를 재현한다.
#          적용 순서
#            1) user_data 효과 보정 (AL2 에 dnf 가 없어 user_data 일부가 실패한 상태를 운영 실측대로 맞춤)
#            2) 9/17~9/30 운영자 수작업 (docker yum 설치, rc.local 로 dockerd 기동, 호스트 oracle 계정 등)
#            3) 9/28 팀 이행조치 (원 명령 미확보 - 조치 전/후 진단 증거로 확인된 '상태'만 재현)
#            4) 9/29~9/30 DB 조치 (원 명령 미확보 - 증거로 확인된 '상태'만 재현)
#            5) 2026-10-02 조치 (apply_scripts/db-active/*.sh 그대로) + 10/2 장애 조치(tcp.invited_nodes)
#  실행  : root, 멱등(여러 번 실행해도 같은 결과).  bash baseline.sh  (files/ 와 같은 폴더에서)
#  금지  : 운영 중인 db-active 에는 절대 실행하지 않는다(9/29·9/30 과부하 사고, 진단·변경 금지).
#          10/2 조치 흔적(/root/u02_root_aging_before_20261002.txt)이 있으면 스스로 중단한다.
#  비밀값: 환경변수 또는 SSM Parameter Store(SecureString)에서만 읽는다. 스크립트에 비밀번호 리터럴 없음.
#            DB_PASSWORD           / DB_PASSWORD_SSM_PARAM            : Oracle SYS·oraadmin 비밀번호(컨테이너 생성, /etc/environment)
#            SERVER_PASSWORD       / SERVER_PASSWORD_SSM_PARAM        : root·team 비밀번호(user_data 미실행 시에만 사용)
#            ORAADMIN_ADM_PASSWORD / ORAADMIN_ADM_PASSWORD_SSM_PARAM  : XEPDB1 ORAADMIN_ADM 비밀번호(없으면 그 단계 건너뜀)
#          *_SSM_PARAM 에는 SSM 파라미터 이름을 넣는다(예: /vuln-lab/db-active/db_password - 현재 계정에 없음, TODO 생성 필요).
#  기타 환경변수(선택)
#            ORACLE_IMAGE_TAR / ORACLE_IMAGE_TAR_S3 : 오프라인 이미지(docker save 결과) 경로 - DB 서브넷은 인터넷 없음
#            CWAGENT_CONFIG    : CloudWatch Agent 설정(ssm:<파라미터> 또는 file:<경로>)
#            SKIP_DB=1         : 컨테이너·DB 단계 건너뜀
#            ALLOW_DB_RESTART=1: audit_trail(spfile) 반영을 위해 컨테이너 재시작 허용
#
#  근거 약어 (모두 C:\claude_work\infra_diag_0929 기준 상대경로, 읽기 전용 원본)
#    [UD]      os/db-active/user_data.tpl (라이브 user_data 와 동일)
#    [CMD1002] report_1001/조치명령_서버별_20261002.md 4장(db-active)
#    [APPLY]   apply_scripts/db-active/*.sh  + results/apply/db-active/*.log (10/2 실제 적용 스크립트·출력)
#    [RES1002] report_1002/조치결과_보고_20261002.md
#    [RFIX4]   results/rfix4_db-active/{aio.out,dbms.out,db.json,server_linux_*.csv} (10/2 조치 후 재진단)
#    [WF1001]  wf_1001.json (10/1 db-active 읽기 전용 실측 검증 - 항목 코드로 인용)
#    [MANUAL]  ref/manual_reports.json linux:db-active (9/28 이행조치 이전 팀 수동 진단)
#    [G1001]   report_1001/취약항목_판단기준_조치방법_20261001.md
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"
D="$(date +%Y%m%d)"
LOG=/var/log/baseline-db-active.log
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

# ---- 근거 문서의 값 (환경변수로 덮어쓸 수 있음) ----
BASTION_IP="${BASTION_IP:-10.0.0.176}"   # hosts.allow 'sshd : 10.0.0.176' [WF1001 U-53]
INVITED_NODES="${INVITED_NODES:-127.0.0.1, 10.0.20.0/24, 10.0.10.52, 10.0.10.174, <ADMIN_IP>, <TEAM_IP_3>}"   # [RFIX4 D-10]
ORACLE_IMAGE="${ORACLE_IMAGE:-gvenzl/oracle-xe:21-slim}"   # [WF1001 D-16][G1001 U-64]
APP_USER="${APP_USER:-oraadmin}"                           # [UD] APP_USER
DB_READY_TIMEOUT="${DB_READY_TIMEOUT:-1200}"
# team 공개키(비밀값 아님) - [UD] 와 같은 값
TEAM_SSH_PUBKEY="${TEAM_SSH_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnULWloBYXMlrDnuXfT29sTrKInAAnYxspJFqCcNo6M team}"
# 로그인 경고문 - 10/2 U-62 에서 쓴 문구 [APPLY U-62.sh]. /etc/issue(.net) 원문(9/28, 195바이트)은 미확보라 이 문구로 대체
ISSUE_TEXT="${ISSUE_TEXT:-본 시스템은 인가된 사용자만 사용할 수 있으며, 무단 접근 시 관련 법령에 따라 처벌받을 수 있습니다.
Authorized users only. All activities may be monitored and recorded.}"

ORA_UID=54321; ORA_GID=54321; DBA_GID=54322            # [WF1001 U-15] id 54321=oracle, gid 54321 oinstall, 54322 dba
H_CFG=/oradata/dbconfig/XE                              # 호스트 경로 [APPLY D-15.sh]
C_CFG=/opt/oracle/oradata/dbconfig/XE                   # 컨테이너 경로
C_TNS=/opt/oracle/homes/OraDBHome21cXE/network/admin    # TNS_ADMIN [RFIX4 dbms.out]

# =============================================================================
# 공통 함수
# =============================================================================
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARN: $*"; }
todo() { log "TODO(확인필요): $*"; }
die()  { log "ERROR: $*"; exit 1; }

# 같은 날 재실행 시 최초 원본 보존
backup_once() {
  local f="$1" tag="$2"
  if [ -e "$f" ] && [ ! -e "${f}.bak_${tag}_${D}" ]; then cp -p "$f" "${f}.bak_${tag}_${D}"; fi
  return 0
}

# "키<구분자>값" 행 보장 (있으면 교체, 없으면 추가)
set_kv() {
  local f="$1" k="$2" v="$3" s="${4:- }"
  if grep -qE "^[[:space:]]*${k}([[:space:]]|=)" "$f"; then
    sed -i -E "s#^[[:space:]]*${k}([[:space:]]*=.*|[[:space:]]+.*)\$#${k}${s}${v}#" "$f"
  else
    printf '%s%s%s\n' "$k" "$s" "$v" >> "$f"
  fi
}

# 행 단위 존재 보장
ensure_line() {
  local line="$1" f="$2"
  if ! grep -qxF -- "$line" "$f" 2>/dev/null; then printf '%s\n' "$line" >> "$f"; fi
}

# 비밀값: 환경변수 → SSM Parameter Store(SecureString) 순. 값은 절대 출력하지 않는다.
get_secret() {
  local env_name="$1" param_env="$2" v p
  v="${!env_name:-}"; p="${!param_env:-}"
  if [ -z "$v" ] && [ -n "$p" ]; then
    v="$(aws ssm get-parameter --region "$AWS_REGION" --name "$p" --with-decryption \
          --query Parameter.Value --output text)"
  fi
  printf '%s' "$v"
}

ora_sql()  { docker exec -i -u oracle oracle-xe sqlplus -S / as sysdba; }   # stdin 으로 SQL 전달
ora_exec() { docker exec -u oracle oracle-xe "$@"; }

db_open() {
  local o
  o="$(printf "set heading off feedback off pagesize 0\nselect open_mode from v\$pdbs where name='XEPDB1';\nexit\n" \
        | docker exec -i -u oracle oracle-xe sqlplus -S / as sysdba 2>/dev/null || true)"
  [[ "$o" == *"READ WRITE"* ]]
}

xepdb1_ready() {
  local s
  s="$(ora_exec lsnrctl status 2>/dev/null || true)"
  grep -i -A1 'service "xepdb1"' <<<"$s" | grep -q 'READY'
}

wait_xepdb1_ready() {
  local i
  for i in $(seq 1 12); do
    if xepdb1_ready; then log "xepdb1 READY (~$((i*5))s)"; return 0; fi
    sleep 5
  done
  return 1
}

# =============================================================================
# 0. 사전 확인
# =============================================================================
preflight() {
  [ "$(id -u)" -eq 0 ] || die "root 로 실행해야 한다"
  grep -q '^Amazon Linux release 2 ' /etc/system-release 2>/dev/null \
    || die "Amazon Linux 2 전용 스크립트 (운영 db-active = Amazon Linux release 2 (Karoo) [APPLY 00_before.log])"
  # 운영 서버 보호: 10/2 조치 때 만든 기록 파일이 있으면 운영 db-active 로 보고 중단
  if [ -e /root/u02_root_aging_before_20261002.txt ] || [ -e /root/listener.ora.bak_20261002 ]; then
    die "운영 db-active(10/2 조치 흔적 있음)로 보인다. 이 서버에서는 실행 금지."
  fi
  [ -f "${FILES_DIR}/listener.ora" ] && [ -f "${FILES_DIR}/99-kisa-warning" ] || die "files/ 폴더가 없다: ${FILES_DIR}"
  touch "$LOG"; chmod 600 "$LOG"
  log "== db-active baseline 시작 (host=$(hostname), MemAvailable=$(awk '/MemAvailable/{print $2}' /proc/meminfo) kB)"
}

# =============================================================================
# 1. user_data 효과 보정
#   - [UD] 는 AL2023(dnf) 전제로 쓰였지만 실제 AMI 는 AL2 라 'dnf -y update', 'dnf -y install docker tar' 가 실패했다.
#     그 결과 user_data 의 docker 관련 단계(enable/usermod/restart/docker run)도 모두 실패했다.
#     근거: 전체·보안 업데이트 이력 없음, yum.log 9/17 docker 설치 [WF1001 U-64], docker 그룹 구성원 없음 [WF1001 D-14]
#   - 라이브 user_data 속성은 CRLF 줄바꿈이다(2026-10-06 바이트 비교). 새 인스턴스에서는 '#!/bin/bash\r' 때문에
#     user_data 자체가 실행되지 않을 수 있으므로, user_data 가 남기는 효과도 없으면 만든다(/var/log/bootstrap.log 로 판단).
# =============================================================================
phase_userdata_fix() {
  log "== 1. user_data 효과 보정"
  local ud_ran=1
  [ -s /var/log/bootstrap.log ] || ud_ran=0
  if [ "$ud_ran" -eq 0 ]; then warn "user_data 미실행으로 보임(/var/log/bootstrap.log 없음) - user_data 단계도 재현한다"; fi

  # 1-1) docker 설치: 9/17 운영자가 yum 으로 설치 [WF1001 U-64 yum.log]
  if ! rpm -q docker >/dev/null 2>&1; then
    # TODO(확인필요): 당시 설치 버전·방법(yum / amazon-linux-extras) 미확보.
    #   DB 서브넷은 인터넷이 없다(라우팅: local + S3 게이트웨이 엔드포인트). AL2 저장소(S3)에 엔드포인트 정책상 접근 가능한지 확인 필요.
    yum -y install docker tar || amazon-linux-extras install -y docker
  fi
  # docker.service 는 enabled 상태 [APPLY 20261002-105917_chk_docker.log UnitFileState=enabled]
  systemctl enable docker.service >/dev/null 2>&1 || warn "docker.service enable 실패(override.conf 로 로드 오류 상태가 정상)"

  # 1-2) team 계정·키·sudo [UD] (sudoers.d/team 28바이트·440 [APPLY 00_before.log])
  if ! id team >/dev/null 2>&1; then useradd -m -s /bin/bash team; fi
  install -d -o team -g team -m 700 /home/team/.ssh
  if ! grep -qxF "$TEAM_SSH_PUBKEY" /home/team/.ssh/authorized_keys 2>/dev/null; then
    printf '%s\n' "$TEAM_SSH_PUBKEY" > /home/team/.ssh/authorized_keys
  fi
  chown team:team /home/team/.ssh/authorized_keys; chmod 600 /home/team/.ssh/authorized_keys
  if [ ! -f /etc/sudoers.d/team ]; then
    echo 'team ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/team
  fi
  chmod 440 /etc/sudoers.d/team

  # 1-3) user_data 미실행 시에만: root/team 비밀번호, SSH 비밀번호 인증 [UD]
  if [ "$ud_ran" -eq 0 ]; then
    local spw; spw="$(get_secret SERVER_PASSWORD SERVER_PASSWORD_SSM_PARAM)"
    if [ -n "$spw" ]; then
      printf 'root:%s\nteam:%s\n' "$spw" "$spw" | chpasswd
    else
      todo "SERVER_PASSWORD(_SSM_PARAM) 미지정 - root/team 비밀번호 미설정"
    fi
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.d/*.conf
  fi
  # TODO(확인필요): 9/28 이행조치 이후 PasswordAuthentication 값은 진단 증거에 없다. user_data 값(yes)을 그대로 둔다.

  # 1-4) docker drop-in [UD] - 내용이 'ExecStart=' 뿐이라 docker.service 는 기동 불가 [APPLY chk_docker2.log]
  #      운영과 같게 그대로 둔다(고치지 않음). dockerd 는 5장의 rc.local 로 띄운다.
  if [ ! -f /etc/systemd/system/docker.service.d/override.conf ]; then
    mkdir -p /etc/systemd/system/docker.service.d
    printf '[Service]\nExecStart=\n' > /etc/systemd/system/docker.service.d/override.conf
  fi

  # 1-5) 데이터 볼륨 /oradata (20GB, xfs) [UD]
  if ! mountpoint -q /oradata; then
    local dev="" i
    for i in 1 2 3 4 5 6; do
      dev="$(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk" && $2=="20G" {print $1; exit}')"
      if [ -n "$dev" ]; then break; fi
      sleep 5
    done
    [ -n "$dev" ] || die "20GB 데이터 디스크를 찾지 못했다(aws_ebs_volume.enc_db_data /dev/sdf 연결 확인)"
    mkdir -p /oradata
    if ! blkid "$dev" >/dev/null 2>&1; then mkfs -t xfs "$dev"; fi
    mount "$dev" /oradata
    if ! grep -qE '[[:space:]]/oradata[[:space:]]' /etc/fstab; then
      echo "$dev /oradata xfs defaults,nofail 0 2" >> /etc/fstab
    fi
  fi
  # 컨테이너 oracle UID 54321 [UD]. user_data 는 chown -R 이지만 기존 DB 파일은 이미 54321 이므로 최상위만 맞춘다.
  chown "${ORA_UID}:${ORA_GID}" /oradata

  # 1-6) /etc/environment [UD][취약점 재현] - 10/1 실측에서 ORACLE_PWD 평문이 남아 있음 [WF1001 U-14 참고]
  ensure_line 'ORACLE_SID=XE' /etc/environment
  ensure_line "ORACLE_USER=${APP_USER}" /etc/environment
  if ! grep -q '^ORACLE_PWD=' /etc/environment; then
    local dpw; dpw="$(get_secret DB_PASSWORD DB_PASSWORD_SSM_PARAM)"
    if [ -n "$dpw" ]; then
      printf 'ORACLE_PWD=%s\n' "$dpw" >> /etc/environment
    else
      todo "DB_PASSWORD(_SSM_PARAM) 미지정 - /etc/environment ORACLE_PWD 미기록"
    fi
  fi
  chmod 644 /etc/environment
}

# =============================================================================
# 2. 호스트 oracle 계정 (9/28 U-15 조치로 추정: 조치 전 '/oradata 소유자 없는 파일 29건' [MANUAL U-15]
#    → 10/1 'id 54321 = oracle, gid 54321 oinstall, 54322 dba' [WF1001 U-15], nologin·홈 없음 [APPLY 00_before.log U-32])
# =============================================================================
phase_host_oracle_account() {
  log "== 2. 호스트 oracle 계정"
  # TODO(확인필요): 생성 시각·명령 미확보. UID/GID·셸·홈 경로만 근거로 확인됨.
  getent group oinstall >/dev/null || groupadd -g "$ORA_GID" oinstall
  getent group dba >/dev/null || groupadd -g "$DBA_GID" dba
  if ! id oracle >/dev/null 2>&1; then
    useradd -u "$ORA_UID" -g oinstall -G dba -M -d /home/oracle -s /sbin/nologin oracle
  fi
}

# =============================================================================
# 3. 9/28 팀 이행조치 (원 명령 미확보 - 조치 전 [MANUAL] / 조치 후 [WF1001][RFIX4] 증거로 확인된 상태만 재현)
#    10/2 조치(U-02 PAM 추가 등)보다 먼저 적용해야 한다.
# =============================================================================
phase_pre1002_os() {
  log "== 3. 9/28 팀 이행조치(상태 재현)"
  local f

  # U-01 PermitRootLogin no (조치 전 yes [MANUAL U-01] → no [RFIX4 U-01], sshd_config 9/28 04:12 수정 [WF1001 U-62])
  # U-62 Banner /etc/issue.net [WF1001 U-62 sshd -T]
  backup_once /etc/ssh/sshd_config pre1002
  if grep -qE '^#?PermitRootLogin' /etc/ssh/sshd_config; then
    sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  else
    echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
  fi
  if grep -qE '^#?Banner' /etc/ssh/sshd_config; then
    sed -i -E 's|^#?Banner.*|Banner /etc/issue.net|' /etc/ssh/sshd_config
  else
    echo 'Banner /etc/issue.net' >> /etc/ssh/sshd_config
  fi
  # TODO(확인필요): /etc/issue·/etc/issue.net 원문(둘 다 195바이트, 9/28 04:12, OS 이스케이프 없음 [WF1001 U-62]) 미확보 → ISSUE_TEXT 로 대체
  for f in /etc/issue /etc/issue.net; do
    if ! grep -q 'Authorized users only' "$f" 2>/dev/null; then
      backup_once "$f" pre1002
      printf '%s\n' "$ISSUE_TEXT" > "$f"
    fi
    chown root:root "$f"; chmod 644 "$f"
  done
  sshd -t
  systemctl reload sshd

  # U-02(9/28분) login.defs 90/1/7, PASS_MIN_LEN 8 [RFIX4 U-02], 조치 전 99999/0 [MANUAL U-02]
  #             pwquality.conf minlen=8 minclass=3 (9/28 03:45 수정) [APPLY 00_before.log][WF1001 U-02]
  backup_once /etc/login.defs pre1002
  set_kv /etc/login.defs PASS_MAX_DAYS 90 $'\t'
  set_kv /etc/login.defs PASS_MIN_DAYS 1 $'\t'
  set_kv /etc/login.defs PASS_MIN_LEN 8 $'\t'
  set_kv /etc/login.defs PASS_WARN_AGE 7 $'\t'
  backup_once /etc/security/pwquality.conf pre1002
  set_kv /etc/security/pwquality.conf minlen 8 ' = '
  set_kv /etc/security/pwquality.conf minclass 3 ' = '
  # team 사용기간: 10/2 전부터 'shadow 기존계정' 점검 통과(root 만 미흡) [WF1001 U-02] → max<=90, min>=1 로 설정돼 있었음
  # TODO(확인필요): team 의 정확한 min/max/warn 값·적용일 미확보(login.defs 정책값으로 맞춤)
  chage -m 1 -M 90 -W 7 team

  # U-03 계정 잠금: pam_faillock + deny=5(PAM 인자) [RFIX4 U-03], 조치 전 미설정 [MANUAL U-03]
  #   *-ac 파일은 authconfig 생성본('authtok_type=' 인자) [APPLY 00_before.log] → authconfig 로 활성화
  if ! grep -q 'pam_faillock' /etc/pam.d/system-auth-ac; then
    # TODO(확인필요): 9/28 적용 방법·나머지 인자(unlock_time 등) 미확보. 확인된 사실은 pam_faillock 적용 + deny=5 뿐
    authconfig --enablefaillock --faillockargs="deny=5" --update
  fi
  [ "$(readlink /etc/pam.d/system-auth)" = system-auth-ac ] || die "system-auth 링크가 깨졌다"

  # U-06 su 제한: /etc/pam.d/su pam_wheel 주석 해제 + su 4750 [RFIX4 U-06], 조치 전 주석 처리 [MANUAL U-06]
  backup_once /etc/pam.d/su pre1002
  sed -i -E 's/^#[[:space:]]*(auth[[:space:]]+required[[:space:]]+pam_wheel\.so[[:space:]]+use_uid.*)$/\1/' /etc/pam.d/su
  grep -qE '^auth[[:space:]]+required[[:space:]]+pam_wheel\.so' /etc/pam.d/su || warn "pam_wheel 행을 찾지 못했다"
  # TODO(확인필요): /usr/bin/su 소유 그룹 미확보(권한 4750 만 확인) - 가이드 사례대로 wheel 로 둔다
  chgrp wheel /usr/bin/su
  chmod 4750 /usr/bin/su

  # U-08 wheel 그룹 구성원 제거: 조치 전 ec2-user·rlagustj [MANUAL U-08] → 구성원 없음 'wheel:x:10:' [APPLY 00_before.log]
  #      (rlagustj·unused1 은 user_data 밖에서 만든 계정이라 새 인스턴스에는 없다)
  if id ec2-user >/dev/null 2>&1 && id -nG ec2-user | tr ' ' '\n' | grep -qx wheel; then
    gpasswd -d ec2-user wheel
  fi
  # TODO(확인필요): ec2-user 는 '로그인 셸 보유 일반계정' 목록에 없다 [WF1001 U-07] - 셸 변경/잠금 여부와 방법 미확보

  # U-63 sudo: NOPASSWD:ALL 대상이 ssm-user·team 뿐 [RFIX4 U-63], 90-cloud-init-users 9/28 04:24 수정(81바이트) [APPLY 00_before.log]
  f=/etc/sudoers.d/90-cloud-init-users
  if [ -f "$f" ] && grep -qE '^[[:space:]]*ec2-user[[:space:]].*NOPASSWD' "$f"; then
    # TODO(확인필요): 9/28 수정 내용 미확보 - ec2-user NOPASSWD 행을 주석 처리해 같은 결과를 만든다
    cp -p "$f" "/root/90-cloud-init-users.bak_pre1002_${D}"
    sed -i -E 's/^([[:space:]]*ec2-user[[:space:]])/#\1/' "$f"
    if ! visudo -cf "$f" >/dev/null; then cp -p "/root/90-cloud-init-users.bak_pre1002_${D}" "$f"; die "sudoers 문법 오류 - 원복함"; fi
  fi

  # U-12 TMOUT=600 (/etc/profile:77~78 'TMOUT=600' 'export TMOUT') [WF1001 U-12], 조치 전 없음 [MANUAL U-12]
  if ! grep -qE '^[[:space:]]*TMOUT=600' /etc/profile; then
    backup_once /etc/profile pre1002
    printf 'TMOUT=600\nexport TMOUT\n' >> /etc/profile
  fi

  # U-21 rsyslog 설정 640 (rsyslog.conf·21-cloudinit.conf·listen.conf) [RFIX4 U-21], 조치 전 644 [MANUAL U-21]
  chmod 640 /etc/rsyslog.conf
  for f in /etc/rsyslog.d/*.conf; do
    if [ -e "$f" ]; then chmod 640 "$f"; fi
  done

  # U-23 SUID/SGID: 도구 제거권고 목록 파일에 SUID/SGID 없음 [RFIX4 U-23]
  #      조치 전 unix_chkpwd·at·newgrp SUID, wall·write SGID [MANUAL U-23]
  #      목록 = patches/big_refactor_files/kisa_unix_check.sh KISA_SUID_RM
  local t real
  for t in /sbin/dump /sbin/restore /sbin/unix_chkpwd /usr/bin/at /usr/bin/lpq /usr/bin/lpq-lpd /usr/bin/lpr \
           /usr/bin/lpr-lpd /usr/bin/lprm /usr/bin/lprm-lpd /usr/bin/newgrp /usr/sbin/lpc /usr/sbin/lpc-lpd \
           /usr/sbin/traceroute /usr/bin/traceroute6 /usr/bin/wall /usr/bin/write; do
    [ -e "$t" ] || continue
    real="$(readlink -f "$t")"
    if [ -u "$real" ] || [ -g "$real" ]; then
      stat -c '%a %U:%G %n' "$real" >> "/root/u23_perm_before_${D}.txt"
      chmod u-s,g-s "$real"
    fi
  done

  # U-28 TCP Wrapper: hosts.allow 'sshd : 10.0.0.176'(유효 1줄), hosts.deny 'ALL : ALL' [WF1001 U-53·U-28][RFIX4 U-28]
  backup_once /etc/hosts.allow pre1002
  backup_once /etc/hosts.deny pre1002
  ensure_line "sshd : ${BASTION_IP}" /etc/hosts.allow
  if grep -vE '^[[:space:]]*(#|$)' /etc/hosts.allow | grep -vqxF "sshd : ${BASTION_IP}"; then
    warn "hosts.allow 에 다른 유효 행이 있다(운영은 1줄) - 확인 필요"
  fi
  ensure_line 'ALL : ALL' /etc/hosts.deny

  # U-30 UMASK: profile·bashrc·csh.cshrc 의 002 분기를 022 로 [WF1001 U-30], 조치 전 002 [MANUAL U-30]
  for f in /etc/profile /etc/bashrc /etc/csh.cshrc; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*umask[[:space:]]+002' "$f"; then
      backup_once "$f" pre1002
      sed -i -E 's/^([[:space:]]*umask[[:space:]]+)002([[:space:]]*)$/\1022\2/' "$f"
    fi
  done

  # U-37(9/28분) cron 관련 파일: /etc/crontab 640, anacrontab 600, cron.allow 640(root만), cron.deny 600,
  #              at.deny 640, cron.d/* 640 [G1001 U-37 현재 상태표]
  chmod 640 /etc/crontab
  if [ -e /etc/anacrontab ]; then chmod 600 /etc/anacrontab; fi
  if [ ! -e /etc/cron.allow ]; then echo root > /etc/cron.allow; fi
  chown root:root /etc/cron.allow; chmod 640 /etc/cron.allow
  if [ -e /etc/cron.deny ]; then chmod 600 /etc/cron.deny; fi
  if [ -e /etc/at.deny ]; then chmod 640 /etc/at.deny; fi
  for f in /etc/cron.d/*; do
    if [ -f "$f" ]; then chmod 640 "$f"; fi
  done

  # U-45~48 postfix: 조치 전 구동 중 [MANUAL U-45] → 설치만 되어 있고 중지·disabled [WF1001 U-45]
  if systemctl list-unit-files postfix.service >/dev/null 2>&1; then
    systemctl disable --now postfix.service >/dev/null 2>&1 || true
  fi

  # U-66 logrotate.conf: weekly·rotate 104, wtmp 'create 0644' (9/28 변경) [WF1001 U-66·U-67]
  backup_once /etc/logrotate.conf pre1002
  if ! grep -qE '^weekly' /etc/logrotate.conf; then sed -i -E 's/^(daily|monthly)$/weekly/' /etc/logrotate.conf; fi
  sed -i -E 's/^rotate[[:space:]]+[0-9]+$/rotate 104/' /etc/logrotate.conf
  sed -i -E '/^\/var\/log\/wtmp/,/^}/ s/create 0664 root utmp/create 0644 root utmp/' /etc/logrotate.conf
  return 0
}

# =============================================================================
# 4. 에이전트 (SSM: AMI 기본 + 9/30 업데이트, CloudWatch: 9/21 설치 [WF1001 U-64·U-66])
# =============================================================================
phase_agents() {
  log "== 4. SSM / CloudWatch Agent"
  systemctl enable amazon-ssm-agent >/dev/null 2>&1 || true
  systemctl start amazon-ssm-agent || warn "amazon-ssm-agent 시작 실패"
  # TODO(확인필요): 9/30 업데이트된 SSM Agent 버전 미확보(AMI 포함본 사용)
  if ! rpm -q amazon-cloudwatch-agent >/dev/null 2>&1; then
    yum -y install amazon-cloudwatch-agent || warn "amazon-cloudwatch-agent 설치 실패(저장소 접근 확인)"
  fi
  if [ -n "${CWAGENT_CONFIG:-}" ] && [ -x /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl ]; then
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c "$CWAGENT_CONFIG" -s
  else
    # TODO(확인필요): 9/21 설정 원본 미확보. 확인된 것은 /var/log/messages·/var/log/secure → 로그 그룹 aws_instance_logs [WF1001 U-66]
    #   현재 DB SG 아웃바운드(443 → SSM 엔드포인트 SG, S3 PL)와 logs 엔드포인트 부재로 실제 전송은 안 될 가능성이 있다.
    todo "CWAGENT_CONFIG 미지정 - CloudWatch Agent 설정·기동 생략"
  fi
}

# =============================================================================
# 5. Docker 기동 방식: rc.local 로 dockerd 직접 기동 (운영 실측)
#    docker.service 는 override.conf 때문에 LoadState=error, dockerd cgroup = rc-local.service,
#    /etc/rc.d/rc.local(60바이트, 9/17 10:05) 2행 'dockerd &', 4행 'docker start oracle-xe' [APPLY chk_docker*.log]
# =============================================================================
phase_docker_runtime() {
  log "== 5. Docker 기동(rc.local)"
  if ! grep -qx 'dockerd &' /etc/rc.d/rc.local 2>/dev/null; then
    backup_once /etc/rc.d/rc.local pre1002
    cat > /etc/rc.d/rc.local <<'RCL'
#!/bin/bash
dockerd &
# TODO(확인필요): 원본 3행(약 14바이트) 내용 미확보 - dockerd 준비 대기로 대체
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker start oracle-xe
RCL
  fi
  chown root:root /etc/rc.d/rc.local; chmod 755 /etc/rc.d/rc.local   # [WF1001 U-17]

  if ! docker info >/dev/null 2>&1; then
    # 이번 실행 동안만 임시 유닛으로 띄운다. 재부팅하면 운영과 같이 rc-local.service 아래에서 뜬다.
    systemd-run --unit="baseline-dockerd-$(date +%s)" /usr/bin/dockerd >/dev/null
    local i
    for i in $(seq 1 30); do
      if docker info >/dev/null 2>&1; then break; fi
      sleep 2
    done
    docker info >/dev/null 2>&1 || die "dockerd 기동 실패"
  fi
}

# =============================================================================
# 6. Oracle XE 컨테이너 (gvenzl/oracle-xe:21-slim, network=host, restart=always,
#    /oradata → /opt/oracle/oradata 바인드 마운트 [G1001 U-64(db-active) 10/1 기준], Config.User=oracle [WF1001 D-07])
# =============================================================================
phase_oracle_container() {
  log "== 6. Oracle XE 컨테이너"
  if ! docker container inspect oracle-xe >/dev/null 2>&1; then
    if ! docker image inspect "$ORACLE_IMAGE" >/dev/null 2>&1; then
      # DB 서브넷은 인터넷이 없어 Docker Hub pull 불가 [G1001 U-64] → docker save 결과를 받아 load
      # TODO(확인필요): 운영 이미지 다이제스트(RepoDigests) 미확보 - 같은 이미지인지 확인 필요
      if [ -n "${ORACLE_IMAGE_TAR:-}" ] && [ -f "${ORACLE_IMAGE_TAR}" ]; then
        docker load -i "$ORACLE_IMAGE_TAR"
      elif [ -n "${ORACLE_IMAGE_TAR_S3:-}" ]; then
        aws s3 cp "$ORACLE_IMAGE_TAR_S3" - --region "$AWS_REGION" | docker load
      else
        docker pull "$ORACLE_IMAGE" || die "이미지 없음: ORACLE_IMAGE_TAR 또는 ORACLE_IMAGE_TAR_S3 지정 필요"
      fi
    fi
    local dpw envf
    dpw="$(get_secret DB_PASSWORD DB_PASSWORD_SSM_PARAM)"
    [ -n "$dpw" ] || die "DB_PASSWORD(_SSM_PARAM) 필요(컨테이너 최초 생성)"
    envf="$(mktemp)"; chmod 600 "$envf"
    printf 'ORACLE_PASSWORD=%s\nAPP_USER=%s\nAPP_USER_PASSWORD=%s\n' "$dpw" "$APP_USER" "$dpw" > "$envf"
    # [UD] 의 docker run 옵션 그대로. --privileged 는 [UD] 의도이며 운영 컨테이너에서 직접 확인하지는 못했다.
    # TODO(확인필요): 운영 컨테이너의 --privileged 여부(docker inspect HostConfig.Privileged) 미확보
    docker run -d --name oracle-xe \
      --restart always \
      --privileged \
      --network host \
      --env-file "$envf" \
      -v /oradata:/opt/oracle/oradata \
      "$ORACLE_IMAGE" >/dev/null
    rm -f "$envf"
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' oracle-xe)" != true ]; then docker start oracle-xe >/dev/null; fi

  log "DB 기동 대기(최대 ${DB_READY_TIMEOUT}s)"
  local t=0
  until db_open; do
    t=$((t+10)); [ "$t" -le "$DB_READY_TIMEOUT" ] || die "XEPDB1 이 READ WRITE 로 열리지 않았다"
    sleep 10
  done
  log "XEPDB1 READ WRITE"
}

# =============================================================================
# 7. Oracle 네트워크 설정
#    - listener.ora: files/listener.ora = 원본(214바이트, [APPLY 00_before.log]) + 10/2 D-15 추가 2행 [APPLY D-15.sh/.log]
#    - sqlnet.ora  : 9/30 01:27 설정(validnode, 12a) [WF1001 D-08·D-10] + 10/2 11:16 앱 서버 2대 추가 [APPLY fix_invited_nodes.sh][RES1002 3장]
# =============================================================================
phase_oracle_netconf() {
  log "== 7. listener.ora / sqlnet.ora"
  local i changed=0
  for i in $(seq 1 30); do
    if [ -f "${H_CFG}/listener.ora" ]; then break; fi
    sleep 5
  done
  [ -f "${H_CFG}/listener.ora" ] || die "${H_CFG}/listener.ora 가 없다(컨테이너 최초 기동 확인)"

  # D-15 리스너 파라미터 변경 제한 (ADMIN_RESTRICTIONS_LISTENER = ON) - 결과 파일 전체를 배포
  if ! cmp -s "${FILES_DIR}/listener.ora" "${H_CFG}/listener.ora"; then
    [ -e "/root/listener.ora.bak_${D}" ] || cp -p "${H_CFG}/listener.ora" "/root/listener.ora.bak_${D}"
    install -o "$ORA_UID" -g "$ORA_GID" -m 644 "${FILES_DIR}/listener.ora" "${H_CFG}/listener.ora"
    changed=1
  fi

  # sqlnet.ora - 파일 전체 내용은 미확보(files/sqlnet.ora.fragment). 확인된 3개 설정만 보장한다.
  local sq="${H_CFG}/sqlnet.ora" tmp
  if [ -f "$sq" ]; then
    [ -e "/root/sqlnet.ora.bak_${D}" ] || cp -p "$sq" "/root/sqlnet.ora.bak_${D}"
  else
    # TODO(확인필요): 원본 sqlnet.ora 의 나머지(주석 등) 내용 미확보
    : > "$sq"
  fi
  tmp="$(mktemp)"
  awk -v nodes="$INVITED_NODES" '
    BEGIN { v=0; n=0; a=0 }
    tolower($0) ~ /^[[:space:]]*tcp\.validnode_checking[[:space:]]*=/ { print "tcp.validnode_checking = yes"; v=1; next }
    tolower($0) ~ /^[[:space:]]*tcp\.invited_nodes[[:space:]]*=/      { print "tcp.invited_nodes = (" nodes ")"; n=1; next }
    toupper($0) ~ /^[[:space:]]*SQLNET\.ALLOWED_LOGON_VERSION_SERVER[[:space:]]*=/ { print "SQLNET.ALLOWED_LOGON_VERSION_SERVER = 12a"; a=1; next }
    { print }
    END {
      if (!v) print "tcp.validnode_checking = yes"
      if (!n) print "tcp.invited_nodes = (" nodes ")"
      if (!a) print "SQLNET.ALLOWED_LOGON_VERSION_SERVER = 12a"
    }' "$sq" > "$tmp"
  if ! cmp -s "$tmp" "$sq"; then
    install -o "$ORA_UID" -g "$ORA_GID" -m 600 "$tmp" "$sq"
    changed=1
  fi
  rm -f "$tmp"
  chown "${ORA_UID}:${ORA_GID}" "$sq"; chmod 600 "$sq"   # 600 oracle:oinstall [WF1001 D-10][APPLY 00_before.log]
  # network/admin/sqlnet.ora → dbconfig 링크 [WF1001 D-08]
  if ! ora_exec test -L "${C_TNS}/sqlnet.ora"; then
    ora_exec ln -sf "${C_CFG}/sqlnet.ora" "${C_TNS}/sqlnet.ora"
    changed=1
  fi

  if [ "$changed" -eq 1 ]; then
    # 10/2 D-15·장애 조치와 같은 순서: reload → alter system register → xepdb1 READY 확인
    ora_exec lsnrctl reload | tail -n 2
    ora_sql <<'EOS'
alter system register;
exit
EOS
    wait_xepdb1_ready || die "xepdb1 서비스가 60초 안에 READY 가 되지 않았다"
  fi
  grep -n 'ADMIN_RESTRICTIONS_LISTENER' "${H_CFG}/listener.ora"
  grep -n 'invited_nodes' "$sq"
}

# =============================================================================
# 8. DB 내부 설정 (9/29~9/30 팀 조치) - 원 명령 미확보, 증거로 확인된 '상태'만 재현
#    데이터 볼륨을 9/19 스냅샷(snap-0acbe6991b5c6159c, 2026-09-19 04:45 UTC)에서 만들면 9/19 이후 DB 변경이 없으므로 필요하다.
# =============================================================================
phase_db_pre1002() {
  log "== 8. DB 내부 설정(9/29~9/30 상태 재현)"
  # CDB$ROOT: SYS/SYSTEM LOCKED [WF1001 D-01·D-03]. 9/30 ALTER USER 5건(SYS, 로컬 sqlplus) 기록 [WF1001 D-06]
  # TODO(확인필요): 9/30 ALTER USER 5건의 실제 문장 미확보
  ora_sql <<'EOS'
whenever sqlerror exit failure
set feedback off
alter user SYSTEM account lock;
alter user SYS account lock;
exit
EOS

  # XEPDB1: ORA_CIS_PROFILE(LIFE_TIME 90, GRACE 5, VERIFY ORA12C_VERIFY_FUNCTION, FAILED_LOGIN 5, LOCK_TIME 1) [WF1001 D-03·D-09]
  #         ORAADMIN 프로파일 = ORA_CIS_PROFILE [WF1001 D-03]
  ora_sql <<'EOS'
whenever sqlerror exit failure
set feedback off
alter session set container=XEPDB1;
alter profile ORA_CIS_PROFILE limit password_life_time 90 password_grace_time 5 failed_login_attempts 5 password_lock_time 1 password_verify_function ORA12C_VERIFY_FUNCTION;
alter user ORAADMIN profile ORA_CIS_PROFILE;
exit
EOS

  # XEPDB1 에서 SYS/SYSTEM 이 ORA_CIS_PROFILE 로 보임 [WF1001 D-03] (공통 사용자 - 실제 적용은 루트 프로파일)
  # TODO(확인필요): 같은 결과를 만든 실제 명령 미확보. 실패해도 계속 진행
  local out
  out="$(ora_sql <<'EOS'
set feedback off
alter session set container=XEPDB1;
alter user SYS profile ORA_CIS_PROFILE;
alter user SYSTEM profile ORA_CIS_PROFILE;
exit
EOS
)"
  if grep -q 'ORA-' <<<"$out"; then warn "XEPDB1 SYS/SYSTEM 프로파일 지정 실패: $(grep 'ORA-' <<<"$out" | head -n 2 | tr '\n' ' ')"; fi

  # ORAADMIN_ADM (9/29 생성): ORA_CIS_PROFILE, CONNECT+RESOURCE, ORAADMIN 테이블 전부에 대한 S/I/U/D(grantable=NO) +
  #   같은 이름의 private SYNONYM [WF1001 D-02·D-04·D-20]
  #   새 DB 에서는 ORAADMIN 테이블이 앱 기동(JPA ddl-auto=update) 후에 생기므로 앱 배포 뒤 다시 실행해야 권한·시노님이 생긴다.
  local apw
  apw="$(get_secret ORAADMIN_ADM_PASSWORD ORAADMIN_ADM_PASSWORD_SSM_PARAM)"
  if [ -z "$apw" ]; then
    todo "ORAADMIN_ADM_PASSWORD(_SSM_PARAM) 미지정 - ORAADMIN_ADM 생성 생략"
  else
    case "$apw" in *'"'*|*$'\n'*) die "ORAADMIN_ADM 비밀번호에 큰따옴표/줄바꿈은 쓸 수 없다";; esac
    local apw_sql="${apw//\'/\'\'}"
    ora_sql <<EOS
whenever sqlerror exit failure
set feedback off
alter session set container=XEPDB1;
declare
  n number;
begin
  select count(*) into n from dba_users where username = 'ORAADMIN_ADM';
  if n = 0 then
    execute immediate 'create user ORAADMIN_ADM identified by "${apw_sql}" profile ORA_CIS_PROFILE';
  end if;
  execute immediate 'alter user ORAADMIN_ADM profile ORA_CIS_PROFILE';
  execute immediate 'grant connect, resource to ORAADMIN_ADM';
  for t in (select table_name from dba_tables where owner = 'ORAADMIN') loop
    execute immediate 'grant select, insert, update, delete on ORAADMIN."' || t.table_name || '" to ORAADMIN_ADM';
    execute immediate 'create or replace synonym ORAADMIN_ADM."' || t.table_name || '" for ORAADMIN."' || t.table_name || '"';
  end loop;
end;
/
exit
EOS
  fi

  # audit_trail=DB,EXTENDED [RFIX4 D-26] (spfile 파라미터 - 재시작해야 반영)
  # TODO(확인필요): 설정 명령·시각 미확보. XEPDB1 전통 감사 옵션 16개 목록도 미확보(재현 안 함)
  local at
  at="$(ora_sql <<'EOS'
set heading off feedback off pagesize 0
select value from v$parameter where name='audit_trail';
exit
EOS
)"
  at="$(tr -d '[:space:]' <<<"$at")"
  if [ "$at" != "DB,EXTENDED" ]; then
    ora_sql <<'EOS'
whenever sqlerror exit failure
alter system set audit_trail=DB,EXTENDED scope=spfile;
exit
EOS
    if [ "${ALLOW_DB_RESTART:-0}" = 1 ]; then
      docker stop -t 300 oracle-xe >/dev/null    # 기본 10초는 Oracle 정상 종료 전 강제 종료될 수 있음 [G1001 U-64]
      docker start oracle-xe >/dev/null
      local t=0
      until db_open; do t=$((t+10)); [ "$t" -le "$DB_READY_TIMEOUT" ] || die "재시작 후 DB 미기동"; sleep 10; done
    else
      warn "audit_trail 은 spfile 에만 기록됨 - 컨테이너 재시작(ALLOW_DB_RESTART=1) 후 반영"
    fi
  fi
  # TODO(확인필요): 리스너에 등록된 서비스 'FREE', 'freepdb1' [APPLY 00_before.log lsnrctl] 의 생성 방법 미확보(재현 안 함)
  return 0
}

# =============================================================================
# 9. 2026-10-02 조치 - OS [CMD1002 4장][APPLY]
# =============================================================================
# U-02 비밀번호 관리정책 [APPLY U-02.sh] - *-ac 실제 파일만 수정(링크 유지)
fix1002_u02() {
  log "== 9-1. U-02 (10/2)"
  local SA=/etc/pam.d/system-auth-ac PA=/etc/pam.d/password-auth-ac PQ=/etc/security/pwquality.conf f m seq
  [ "$(readlink /etc/pam.d/system-auth)" = system-auth-ac ] && [ "$(readlink /etc/pam.d/password-auth)" = password-auth-ac ] \
    || die "system-auth/password-auth 링크 대상이 다르다"
  for m in pam_pwhistory.so pam_pwquality.so; do [ -f "/usr/lib64/security/$m" ] || die "$m 없음"; done
  for f in "$SA" "$PA" "$PQ"; do backup_once "$f" u02; done
  if [ ! -e "/root/u02_root_aging_before_${D}.txt" ]; then
    getent shadow root | awk -F: '{print ($4==""?-1:$4), ($5==""?-1:$5), ($6==""?-1:$6)}' > "/root/u02_root_aging_before_${D}.txt"
  fi
  for f in "$SA" "$PA"; do
    grep -q '^password.*pam_pwhistory\.so' "$f" || \
      sed -i '/^password[[:space:]]\+sufficient[[:space:]]\+pam_unix\.so/i password    requisite     pam_pwhistory.so use_authtok remember=4 enforce_for_root' "$f"
  done
  sed -i '/^password.*pam_pwquality\.so/{/enforce_for_root/!s/$/ enforce_for_root/}' "$SA" "$PA"
  if [ -n "$(tail -c1 "$PQ")" ]; then echo >> "$PQ"; fi
  for m in dcredit ucredit lcredit ocredit; do
    grep -qE "^[[:space:]]*$m[[:space:]]*=" "$PQ" || printf '%s = -1\n' "$m" >> "$PQ"
  done
  chage -m 1 -M 90 -W 7 root
  # 확인: pam_pwquality → pam_pwhistory → pam_unix → pam_deny
  for f in "$SA" "$PA"; do
    seq="$(grep '^password' "$f" | awk '{printf "%s ", $3}')"
    [ "$seq" = "pam_pwquality.so pam_pwhistory.so pam_unix.so pam_deny.so " ] || die "U-02 순서 확인 실패($f): $seq"
  done
  sshd -t
}

# U-32 홈 디렉토리 존재 관리 [APPLY U-32.sh]
fix1002_u32() {
  log "== 9-2. U-32 (10/2)"
  local L="ftp ec2-instance-connect rngd cwagent oracle" u h
  [ -e "/root/u32_passwd_before_${D}.txt" ] || getent passwd $L > "/root/u32_passwd_before_${D}.txt" || true
  for u in $L; do
    h="$(getent passwd "$u" | cut -d: -f6 || true)"
    if [ -n "$h" ] && [ ! -d "$h" ]; then
      mkdir -p "$h"; chown "$u": "$h"; chmod 750 "$h"
    fi
  done
  awk -F: '$1 !~ /^[+-]/ {print $1":"$6}' /etc/passwd | while IFS=: read -r u h; do
    [ -d "$h" ] || warn "홈 없음: $u($h)"
  done
}

# U-37 crontab·at 명령어 + cron 디렉터리 [APPLY U-37.sh]
fix1002_u37() {
  log "== 9-3. U-37 (10/2)"
  local T="/usr/bin/crontab /usr/bin/at /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly"
  [ -e "/root/u37_perm_before_${D}.txt" ] || stat -c '%a %U:%G %n' $T > "/root/u37_perm_before_${D}.txt"
  chmod 0750 /usr/bin/crontab /usr/bin/at
  chmod 0640 /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly
  stat -c '%a %U:%G %n' $T
}

# U-62 로그온 경고 메시지 [APPLY U-62.sh] - AL2 update-motd(/etc/motd → /var/lib/update-motd/motd 링크)
#   10/2 와 같이 update-motd 즉시 실행(yum check-update 포함)은 하지 않고 현재 motd 끝에 붙인다.
fix1002_u62() {
  log "== 9-4. U-62 (10/2)"
  local S=/etc/update-motd.d/99-kisa-warning TGT
  if [ -L /etc/motd ] && [ -d /etc/update-motd.d ]; then
    TGT="$(readlink -f /etc/motd)"
    [ -e "/root/motd.bak_u62_${D}" ] || cp -p "$TGT" "/root/motd.bak_u62_${D}" 2>/dev/null || true
    install -o root -g root -m 755 "${FILES_DIR}/99-kisa-warning" "$S"
    grep -q '인가된 사용자' "$TGT" 2>/dev/null || "$S" >> "$TGT"
  else
    [ -e "/etc/motd.bak_u62_${D}" ] || cp -p /etc/motd "/etc/motd.bak_u62_${D}"
    grep -q '인가된 사용자' /etc/motd || sed -n '3,4p' "${FILES_DIR}/99-kisa-warning" >> /etc/motd
  fi
  [ "$(grep -c '인가된 사용자' /etc/motd)" = 1 ] || warn "motd 경고문 개수 확인 필요"
}

# U-67 로그 파일 권한 [APPLY U-67.sh] - journald 는 재시작하지 않음(SplitMode 는 재부팅 때 반영), chronyd 만 재시작
fix1002_u67() {
  log "== 9-5. U-67 (10/2)"
  local BK=/root/u67_bak j i synced=0 tr
  mkdir -p "$BK"
  [ -e "$BK/chrony.conf" ]   || cp -p /etc/chrony.conf "$BK/"
  [ -e "$BK/journald.conf" ] || cp -p /etc/systemd/journald.conf "$BK/"
  # wtmp 664 → 644 (+ tmpfiles 로 재부팅 유지)
  [ -e /etc/tmpfiles.d/var.conf ] || cp -p /usr/lib/tmpfiles.d/var.conf /etc/tmpfiles.d/var.conf
  sed -i 's#^f /var/log/wtmp 0664#f /var/log/wtmp 0644#' /etc/tmpfiles.d/var.conf
  chmod 644 /var/log/wtmp
  # chrony 통계 로그 기록 지시어 끄기 + 재시작, 기존 파일은 보관
  if grep -qE '^log[[:space:]]' /etc/chrony.conf; then
    sed -i 's/^log[[:space:]]/#&/' /etc/chrony.conf
    systemctl restart chronyd
  fi
  for i in $(seq 1 30); do
    tr="$(chronyc -n tracking 2>/dev/null || true)"
    if grep -q '169\.254\.169\.123' <<<"$tr" && grep -qE 'Leap status[[:space:]]*:[[:space:]]*Normal' <<<"$tr"; then synced=1; break; fi
    sleep 3
  done
  [ "$synced" = 1 ] || warn "chrony 가 90초 안에 169.254.169.123 과 동기화되지 않았다"
  mkdir -p "$BK/chrony_log"
  if [ -d /var/log/chrony ] && [ -n "$(ls -A /var/log/chrony)" ]; then mv /var/log/chrony/* "$BK/chrony_log/"; fi
  # 사용자 journal 650 → 640, SplitMode=none(재부팅 때 반영)
  for j in /var/log/journal/*/user-*.journal; do
    if [ -e "$j" ]; then chmod 640 "$j"; fi
  done
  sed -i 's/^#\?SplitMode=.*/SplitMode=none/' /etc/systemd/journald.conf
  grep -q '^SplitMode=none' /etc/systemd/journald.conf || echo 'SplitMode=none' >> /etc/systemd/journald.conf
  return 0
}

# U-20 /etc/systemd 파일 소유자·권한 [APPLY U-20.sh] - /etc/systemd 를 바꾸는 단계가 모두 끝난 뒤 마지막에 실행
fix1002_u20() {
  log "== 9-6. U-20 (10/2)"
  local B="/root/u20_perm_before_${D}.txt" cg bad
  cg="$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || true)"
  [ -e "$B" ] || find /etc/systemd -xdev -type f -printf '%m %u %p\n' > "$B"
  chown root /etc/systemd/system.conf && chmod 600 /etc/systemd/system.conf
  find /etc/systemd -xdev -type f -exec chown root {} + -exec chmod 600 {} +
  bad="$(find /etc/systemd -xdev -type f \( ! -user root -o -perm /177 \) | head -n 20)"
  [ -z "$bad" ] || die "U-20 남은 파일: $bad"
  # 10/2 와 같이 docker cgroup 드라이버가 cgroupfs 이거나 docker 가 없을 때만 daemon-reload
  if [ -z "$cg" ] || [ "$cg" = cgroupfs ]; then
    systemctl daemon-reload
  else
    warn "daemon-reload 생략(docker cgroup driver '$cg')"
  fi
}

# =============================================================================
# 10. 2026-10-02 조치 - DBMS
#   D-05 비밀번호 재사용 제약 [APPLY D-05.sh] (문서 그대로)
#   D-15 는 7장(listener.ora 배포)에서 같은 결과를 만든다.
# =============================================================================
fix1002_d05() {
  log "== 10. D-05 (10/2)"
  [ -s "/root/D-05_profiles_before_${D}.txt" ] || ora_sql > "/root/D-05_profiles_before_${D}.txt" <<'EOS'
set pagesize 0 linesize 200 feedback off heading off trimspool on
select 'CDB$ROOT '||profile||' '||resource_name||' '||limit from dba_profiles where resource_name like 'PASSWORD_REUSE%' order by profile, resource_name;
alter session set container=XEPDB1;
select 'XEPDB1 '||profile||' '||resource_name||' '||limit from dba_profiles where resource_name like 'PASSWORD_REUSE%' order by profile, resource_name;
exit
EOS
  ora_sql <<'EOS'
whenever sqlerror exit failure
alter profile DEFAULT limit password_reuse_time 365 password_reuse_max 10;
alter session set container=XEPDB1;
alter profile ORA_CIS_PROFILE limit password_reuse_time 365 password_reuse_max 10;
alter profile DEFAULT limit password_reuse_time 365 password_reuse_max 10;
exit
EOS
}

# =============================================================================
# 11. 확인 (읽기 전용, [APPLY 99_after.sh] 와 같은 항목)
# =============================================================================
phase_verify() {
  log "== 11. 확인"
  echo "-- OS: $(cat /etc/system-release) / kernel $(uname -r)"
  echo "-- U-02: $(grep -c '^password.*pam_pwhistory.so use_authtok remember=4 enforce_for_root' /etc/pam.d/system-auth-ac /etc/pam.d/password-auth-ac | tr '\n' ' ')"
  chage -l root | sed -n '2p;5,7p'
  echo "-- U-20 위반 파일 수: $(find /etc/systemd -xdev -type f \( ! -user root -o -perm /177 \) | wc -l)"
  echo "-- U-37: $(stat -c '%a %n' /usr/bin/crontab /usr/bin/at /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly | tr '\n' ' ')"
  echo "-- U-62: $(grep -c '인가된 사용자' /etc/motd)"
  echo "-- U-67: $(stat -c '%a %n' /var/log/wtmp | tr '\n' ' ') SplitMode=$(grep '^SplitMode' /etc/systemd/journald.conf | cut -d= -f2)"
  echo "-- sshd: $(sshd -T 2>/dev/null | grep -E '^(permitrootlogin|banner) ' | tr '\n' ' ')"
  echo "-- hosts.allow: $(grep -vE '^[[:space:]]*(#|$)' /etc/hosts.allow | tr '\n' ' ') / hosts.deny: $(grep -vE '^[[:space:]]*(#|$)' /etc/hosts.deny | tr '\n' ' ')"
  if [ "${SKIP_DB:-0}" != 1 ]; then
    docker ps --format '{{.Names}} {{.Image}} {{.Status}}'
    ora_exec lsnrctl status | grep -iE 'Service "|status READY' | paste - - | awk '{print $2, $7, $8}' || true
    ora_sql <<'EOS'
set pagesize 0 linesize 200 feedback off heading off
select 'CDB$ROOT '||profile||' '||resource_name||' '||limit from dba_profiles where resource_name like 'PASSWORD_REUSE%' and profile in ('DEFAULT','ORA_CIS_PROFILE') order by 1;
alter session set container=XEPDB1;
select 'XEPDB1 '||profile||' '||resource_name||' '||limit from dba_profiles where resource_name like 'PASSWORD_REUSE%' and profile in ('DEFAULT','ORA_CIS_PROFILE') order by 1;
select 'XEPDB1 USER '||username||' '||account_status||' '||profile from dba_users where username in ('ORAADMIN','ORAADMIN_ADM') order by 1;
exit
EOS
  fi
  log "== 완료. 재부팅하면 rc.local 로 dockerd 가 운영과 같은 방식으로 뜨고 journald SplitMode 가 반영된다(필요 시 수동 재부팅)."
}

# =============================================================================
main() {
  preflight
  exec > >(tee -a "$LOG") 2>&1
  phase_userdata_fix
  phase_host_oracle_account
  phase_pre1002_os
  phase_agents
  phase_docker_runtime
  if [ "${SKIP_DB:-0}" != 1 ]; then
    phase_oracle_container
    phase_oracle_netconf
    phase_db_pre1002
  else
    todo "SKIP_DB=1 - 컨테이너·DB 단계 생략"
  fi
  fix1002_u02
  fix1002_u32
  fix1002_u37
  fix1002_u62
  fix1002_u67
  if [ "${SKIP_DB:-0}" != 1 ]; then fix1002_d05; fi
  fix1002_u20
  # 의도적 미조치(재현 대상 아님): U-64(AL2 지원 종료 → AL2023 이관 제외), D-25(XE 보안 패치 미제공 → 이관 제외) [RES1002 4장]
  phase_verify
}

main "$@"
