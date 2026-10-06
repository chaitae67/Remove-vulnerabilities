#!/bin/bash
# =============================================================================
# was-adm1 OS 기준선 재현 (Rocky Linux 8.10, 관리자 WAS - Spring Boot 내장 Tomcat 8080)
#
# 대상 : 같은 AMI(ami-015dc263f405fc73c, Rocky-8-EC2-Base-8.10-20260625) 와
#        os/was-adm1/user_data.tpl 로 처음 부팅을 마친 새 인스턴스
# 결과 : 2026-10-02 취약점 조치 후 운영 상태(재진단 rfix4 기준, 남은 취약 WEB-25 만)
# 실행 : os/was-adm1 디렉터리를 통째로 서버에 올린 뒤 root 로  bash baseline.sh
#        여러 번 실행해도 결과가 같다(idempotent). 서버에서 직접 실행할 것(이 저장소에서는 실행 금지).
#
# 비밀값은 리터럴로 두지 않는다. 환경변수 또는 SSM Parameter Store(SecureString)에서만 읽는다.
#   DB_PASSWORD                  | DB_PASSWORD_SSM_PARAM                  -> /etc/clinic/db.env (필수: 앱 기동)
#   ROTATE_ADMIN_PASSWORD        | ROTATE_ADMIN_PASSWORD_SSM_PARAM        -> /etc/clinic/admin-rotate.env (선택)
#   ROTATE_USER_PASSWORD         | ROTATE_USER_PASSWORD_SSM_PARAM         -> /etc/clinic/admin-rotate.env (선택)
# 그 밖의 입력(선택)
#   DB_URL (기본: 운영값 jdbc:oracle:thin:@10.0.20.184:1521/XEPDB1), DB_USERNAME (기본: oraadmin)
#   ROTATE_PASSWORDS_ON_STARTUP  admin-rotate.env 값(운영값 미확보)
#   ADMIN_APP_JAR_SRC            운영 jar 경로 또는 s3:// URI (jar 는 저장소에 없음)
#   HOSTS_ALLOW_LINE             /etc/hosts.allow 의 허용 1줄(운영 원문 미확보)
#   LOGIN_BANNER_FILE            /etc/issue, /etc/issue.net 경고문 파일(운영 원문 미확보)
#   SKIP_PATCH=1                 U-64 보안 업데이트 생략
#   INSTALL_SSM_AGENT=1, INSTALL_CW_AGENT=1, CW_AGENT_CONFIG_SSM_PARAM   에이전트 설치(운영 설치 방법 미확보)
#   AUTO_REBOOT=1                커널 갱신 시 1분 뒤 재부팅(10/2 운영도 승인 후 재부팅)
#   AWS_REGION (기본 ap-northeast-2)
#
# 근거(경로는 C:\claude_work\infra_diag_0929 기준)
#   [CMD]   report_1001/조치명령_서버별_20261002.md  §3 was-adm1
#   [APPLY] apply_scripts/was-adm1/*.sh, results/apply/was-adm1/*.log  (10/2 실제 적용 명령과 출력)
#   [RES]   report_1002/조치결과_보고_20261002.md
#   [DIAG]  results/base_infra_was-adm1.out.txt(9/29), results/rfix4_was-adm1/scan.out(10/2 조치 후)
# =============================================================================
set -euo pipefail
umask 022
export LC_ALL=C
export PATH=$PATH:/usr/local/bin

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES=$HERE/files
D=$(date +%Y%m%d)
AWS_REGION=${AWS_REGION:-ap-northeast-2}
DB_URL=${DB_URL:-jdbc:oracle:thin:@10.0.20.184:1521/XEPDB1}
DB_USERNAME=${DB_USERNAME:-oraadmin}
LIVE_JAVA=/usr/lib/jvm/java-21-openjdk-21.0.12.1.1-1.1.el8_10.x86_64/bin/java   # 운영 ExecStart 의 JVM
JAR=/opt/clinic/admin-app.jar
SD=/etc/systemd/system
WARNS=0; FAILS=0; APP_CHANGED=0

# 비밀값이 로그에 남지 않도록 set -x 는 쓰지 않는다
LOG=/var/log/baseline-was-adm1.log
exec > >(tee -a "$LOG") 2>&1

log()  { printf '\n== %s\n' "$*"; }
warn() { printf '  [경고] %s\n' "$*"; WARNS=$((WARNS+1)); }
die()  { printf '  [중단] %s\n' "$*" >&2; exit 1; }

# 원본이 있고 백업이 없을 때만 백업
backup_once() {
  if [ -e "$1" ] && [ ! -e "$2" ]; then cp -p "$1" "$2"; fi
  return 0
}

# 내용이 다를 때만 설치. 바뀌었으면 0, 그대로면 1 반환 (소유자·모드는 항상 맞춘다)
install_file() {
  local src=$1 dst=$2 mode=$3 og=${4:-root:root}
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    chown "$og" "$dst"; chmod "$mode" "$dst"
    return 1
  fi
  install -D -m "$mode" -o "${og%%:*}" -g "${og##*:}" "$src" "$dst"
  echo "  배포: $dst ($mode $og)"
  return 0
}

# 비밀값: 환경변수 $1 → 없으면 환경변수 $2 에 적힌 SSM 파라미터를 복호화해 읽는다
get_secret() {
  local v=${!1:-} p=${!2:-}
  if [ -z "$v" ] && [ -n "$p" ]; then
    command -v aws >/dev/null 2>&1 || die "aws CLI 가 없어 SSM 파라미터($2)를 읽을 수 없다"
    v=$(aws ssm get-parameter --region "$AWS_REGION" --name "$p" --with-decryption \
          --query Parameter.Value --output text)
  fi
  printf '%s' "$v"
}

# "키 = 값" 형식 설정(pwquality.conf, faillock.conf) 강제
set_conf_eq() {
  local f=$1 k=$2 v=$3
  if grep -qE "^[[:space:]]*$k[[:space:]]*=" "$f"; then
    sed -i -E "s/^[[:space:]]*$k[[:space:]]*=.*/$k = $v/" "$f"
  else
    echo "$k = $v" >> "$f"
  fi
}

# sshd_config 키 강제(활성 줄 → 주석 줄 첫 번째 → 끝에 추가 순)
set_sshd() {
  local k=$1 v=$2 f=/etc/ssh/sshd_config
  if grep -qE "^[[:space:]]*$k[[:space:]]" "$f"; then
    sed -i -E "s|^[[:space:]]*$k[[:space:]].*|$k $v|" "$f"
  elif grep -qE "^#[[:space:]]*$k[[:space:]]" "$f"; then
    sed -i -E "0,/^#[[:space:]]*$k[[:space:]].*/s||$k $v|" "$f"
  else
    echo "$k $v" >> "$f"
  fi
}

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# -----------------------------------------------------------------------------
log "0. 사전 확인"
[ "$(id -u)" = 0 ] || die "root 로 실행해야 한다"
. /etc/os-release
if [ "${ID:-}" != rocky ] || [[ "${VERSION_ID:-}" != 8* ]]; then die "Rocky Linux 8 전용 (현재: ${PRETTY_NAME:-?})"; fi
[ -d "$FILES" ] || die "files/ 디렉터리 없음: $FILES"
id team >/dev/null 2>&1 || die "team 계정 없음 - user_data(첫 부팅) 완료 후 실행. CRLF 로 user_data 가 미실행됐다면 README 10장대로 CR 제거 후 먼저 실행"
echo "  host=$(hostname) kernel=$(uname -r) selinux=$(getenforce 2>/dev/null || echo '?')"
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
if [ "${IP:-}" != 10.0.10.52 ]; then
  # 10/2 장애 원인: db-active sqlnet.ora tcp.invited_nodes 에 앱 서버 IP 가 없으면 DB 연결 거부 [RES §3]
  warn "사설 IP 가 운영값(10.0.10.52)과 다름(${IP:-?}) - db-active sqlnet.ora tcp.invited_nodes 에 이 IP 추가 필요"
fi

# -----------------------------------------------------------------------------
log "1. U-64 보안 업데이트 [CMD §3 U-64, APPLY U-64.sh] - 권한 조치보다 먼저(패키지 갱신이 권한을 되돌림)"
if [ "${SKIP_PATCH:-0}" = 1 ]; then
  warn "SKIP_PATCH=1 - 보안 업데이트 생략"
else
  dnf -y update --security
  # 운영(10/2): expat-2.5.0-4.el8_10, kernel*-4.18.0-553.170.1.el8_10 갱신 후 재부팅.
  # TODO(확인필요): 새 인스턴스는 실행 시점 저장소 기준으로 갱신되므로 운영과 패키지 버전이 같다는 보장은 없다.
fi
# user_data 는 java-21 실패 시 java-17 로 대체 설치한다. 운영은 java-21 (ExecStart 경로)
rpm -q java-21-openjdk >/dev/null 2>&1 || dnf install -y java-21-openjdk

# -----------------------------------------------------------------------------
log "2. 에이전트 (운영에 설치돼 있음 - 설치 방법 미확보, 선택 실행)"
# 근거: precheck.log 의 /etc/systemd/system/amazon-ssm-agent.service, amazon-cloudwatch-agent.service,
#       cwagent 계정(uid 991), /etc/sudoers.d/ssm-agent-users(2026-09-30 01:26 생성), U-32 로그 cloudwatch-agent active
# TODO(확인필요): 운영의 설치 경로(RPM URL)·버전·CloudWatch Agent 설정 원문은 자료에 없다. 아래 URL 은 AWS 공식 배포 위치.
if [ "${INSTALL_SSM_AGENT:-0}" = 1 ]; then
  rpm -q amazon-ssm-agent >/dev/null 2>&1 || \
    dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
  systemctl enable --now amazon-ssm-agent
else
  rpm -q amazon-ssm-agent >/dev/null 2>&1 || warn "amazon-ssm-agent 미설치 (INSTALL_SSM_AGENT=1 로 설치)"
fi
if [ "${INSTALL_CW_AGENT:-0}" = 1 ]; then
  rpm -q amazon-cloudwatch-agent >/dev/null 2>&1 || \
    dnf install -y https://amazoncloudwatch-agent.s3.amazonaws.com/redhat/amd64/latest/amazon-cloudwatch-agent.rpm
  if [ -n "${CW_AGENT_CONFIG_SSM_PARAM:-}" ]; then
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
      -c "ssm:${CW_AGENT_CONFIG_SSM_PARAM}"
  else
    warn "CW_AGENT_CONFIG_SSM_PARAM 미지정 - CloudWatch Agent 설정 미적용 (TODO(확인필요): 운영 설정 원문 미확보)"
  fi
else
  rpm -q amazon-cloudwatch-agent >/dev/null 2>&1 || warn "amazon-cloudwatch-agent 미설치 (INSTALL_CW_AGENT=1 로 설치)"
fi

# -----------------------------------------------------------------------------
log "3. 10/2 이전부터 적용돼 있던 하드닝 (진단 증거의 결과 상태만 재현)"
# TODO(확인필요): 아래 3-x 는 2026-09-17~09-29 사이 적용된 설정이다. 적용 명령과 파일 원문은 자료에 없고,
#   값은 [DIAG] base(9/29)·rfix4(10/2) 진단 결과와 precheck.log 에 나온 상태다.

# 3-1 login.defs 사용기간 (U-02 증거: login.defs MAX=90 MIN=1 WARN=7, PASS_MIN_LEN=5 는 기본값 유지)
backup_once /etc/login.defs "/etc/login.defs.bak_baseline_$D"
for kv in "PASS_MAX_DAYS 90" "PASS_MIN_DAYS 1" "PASS_WARN_AGE 7"; do
  k=${kv%% *}; v=${kv##* }
  if grep -qE "^[[:space:]]*$k[[:space:]]" /etc/login.defs; then
    sed -i -E "s/^[[:space:]]*$k[[:space:]].*/$k\t$v/" /etc/login.defs
  else
    printf '%s\t%s\n' "$k" "$v" >> /etc/login.defs
  fi
done

# 3-2 pwquality minlen, faillock 임계값 (precheck.log: pwquality "minlen = 8", faillock "deny = 5" "unlock_time = 600")
backup_once /etc/security/pwquality.conf "/etc/security/pwquality.conf.bak_baseline_$D"
backup_once /etc/security/faillock.conf "/etc/security/faillock.conf.bak_baseline_$D"
set_conf_eq /etc/security/pwquality.conf minlen 8
set_conf_eq /etc/security/faillock.conf deny 5
set_conf_eq /etc/security/faillock.conf unlock_time 600

# 3-3 su 제한 (U-06 증거: /etc/pam.d/su "auth required pam_wheel.so use_uid", /usr/bin/su root:root 4750)
if ! grep -qE '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so[[:space:]]+use_uid' /etc/pam.d/su; then
  backup_once /etc/pam.d/su "/etc/pam.d/su.bak_baseline_$D"
  if grep -qE '^#[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so[[:space:]]+use_uid' /etc/pam.d/su; then
    sed -i -E 's/^#[[:space:]]*(auth[[:space:]]+required[[:space:]]+pam_wheel\.so[[:space:]]+use_uid)/\1/' /etc/pam.d/su
  else
    warn "/etc/pam.d/su 에 pam_wheel 주석 줄이 없어 적용하지 않음 (TODO(확인필요))"
  fi
fi
chown root:root /usr/bin/su
chmod 4750 /usr/bin/su

# 3-4 세션 타임아웃 (U-12 증거: TMOUT=600 readonly, 설정 위치 /etc/profile.d/tmout.sh:1 과 /etc/profile:86)
# TODO(확인필요): tmout.sh 원문과 /etc/profile 86행 원문 미확보. 86행은 readonly 오류만 내는 중복이라 재현하지 않는다.
TMOUT_LINE='readonly TMOUT=600; export TMOUT'
if [ "$(cat /etc/profile.d/tmout.sh 2>/dev/null || true)" != "$TMOUT_LINE" ]; then
  printf '%s\n' "$TMOUT_LINE" > /etc/profile.d/tmout.sh
fi
chown root:root /etc/profile.d/tmout.sh; chmod 644 /etc/profile.d/tmout.sh

# 3-5 sshd (U-01·U-12·U-62 증거: PermitRootLogin=no, ClientAliveInterval=300/CountMax=2, Banner /etc/issue.net)
#   PermitRootLogin no / PasswordAuthentication no / UsePAM yes 는 user_data 가 이미 설정
# TODO(확인필요): 운영에서 이 값들이 sshd_config 본문에 있는지(drop-in 여부) 미확보
backup_once /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak_baseline_$D"
set_sshd ClientAliveInterval 300
set_sshd ClientAliveCountMax 2
set_sshd Banner /etc/issue.net

# 3-6 로그인 경고문 /etc/issue, /etc/issue.net (U-62 증거: issue=1, SSH Banner=1 → 경고 문구 있음)
# TODO(확인필요): 운영 원문 미확보. LOGIN_BANNER_FILE 이 없으면 10/2 motd 문구를, 경고 문구가 없을 때만 쓴다.
WARN_RE='(경고|허가|무단|승인|비인가|unauthorized|authorized (users|personnel|access)|prohibited|monitored|warning)'
BANNER_SRC=${LOGIN_BANNER_FILE:-$FILES/etc/motd}
for f in /etc/issue /etc/issue.net; do
  if ! grep -qiE "$WARN_RE" "$f" 2>/dev/null; then
    backup_once "$f" "$f.bak_baseline_$D"
    install -m 644 -o root -g root "$BANNER_SRC" "$f"
    warn "$f 에 경고문 기록(운영 원문 미확보, 원본: $BANNER_SRC)"
  fi
done
sshd -t || die "sshd 설정 오류 - $LOG 확인, /etc/ssh/sshd_config.bak_baseline_$D 로 복원"
systemctl reload sshd

# 3-7 TCP Wrapper (U-28 증거: hosts.deny ALL:ALL + hosts.allow 1줄(특정 호스트만 허용), sshd 는 libwrap 미연동)
# TODO(확인필요): 운영 hosts.allow 허용 줄 원문 미확보 → HOSTS_ALLOW_LINE 으로 받는다
if [ -n "${HOSTS_ALLOW_LINE:-}" ]; then
  backup_once /etc/hosts.allow "/etc/hosts.allow.bak_baseline_$D"
  backup_once /etc/hosts.deny "/etc/hosts.deny.bak_baseline_$D"
  { grep -E '^[[:space:]]*(#|$)' /etc/hosts.allow 2>/dev/null || true; printf '%s\n' "$HOSTS_ALLOW_LINE"; } > "$TMPD/hosts.allow"
  install -m 644 -o root -g root "$TMPD/hosts.allow" /etc/hosts.allow
  grep -qE '^[[:space:]]*ALL[[:space:]]*:[[:space:]]*ALL' /etc/hosts.deny || echo 'ALL: ALL' >> /etc/hosts.deny
else
  warn "HOSTS_ALLOW_LINE 미지정 - hosts.allow/hosts.deny 생략 (TODO(확인필요))"
fi

# 3-8 syslog 설정 권한 (U-21 증거: rsyslog.conf(root,640) 21-cloudinit.conf(root,640))
for f in /etc/rsyslog.conf /etc/rsyslog.d/21-cloudinit.conf; do
  if [ -f "$f" ]; then chown root:root "$f"; chmod 640 "$f"; fi
done

# 3-9 cron 허용목록·설정 파일 (base 진단 "cron.allow 존재(허용목록 방식)", remediation_plan.md "cron.allow 가 root 뿐",
#     rfix3b 진단에서 /etc/crontab·cron.d 미검출 = root, 640 이하)
# TODO(확인필요): 파일별 정확한 모드 미확보 → 640 을 넘을 때만 640 이하로 낮춘다
if [ ! -e /etc/cron.allow ]; then install -m 600 -o root -g root /dev/null /etc/cron.allow; fi
grep -qx root /etc/cron.allow || echo root >> /etc/cron.allow
for f in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/cron.d/*; do
  if [ -f "$f" ]; then chown root "$f"; chmod u-x,g-wx,o-rwx "$f"; fi
done

# 3-10 user_data 의 placeholder(8080) 중지 (precheck2.log: placeholder.service disabled / inactive)
if systemctl is-enabled --quiet placeholder.service 2>/dev/null || systemctl is-active --quiet placeholder.service 2>/dev/null; then
  systemctl disable --now placeholder.service
fi

# -----------------------------------------------------------------------------
log "4. 관리자 앱 clinic-admin 배포 + WEB-09/WEB-13/WEB-26/WEB-07 [CMD §3, APPLY WEB-09_13_26.sh, WEB-07.sh]"

# 4-1 WEB-09 실행 전용 계정(관리자 권한 없음, 로그인 불가). 운영 uid=990 gid=987 (APPLY 로그)
if ! id clinicapp >/dev/null 2>&1; then
  if ! getent group clinicapp >/dev/null && ! getent group 987 >/dev/null && ! getent passwd 990 >/dev/null; then
    groupadd -r -g 987 clinicapp
    useradd -r -M -u 990 -g clinicapp -d /opt/clinic -s /sbin/nologin clinicapp
  else
    useradd -r -M -d /opt/clinic -s /sbin/nologin clinicapp
    warn "uid 990/gid 987 사용 중 - clinicapp 을 자동 번호로 생성"
  fi
fi

# 4-2 배포 경로 (precheck.log /opt/clinic team:team 755 · WEB-09 로그 uploads·records clinicapp 700)
install -d -m 755 -o team -g team /opt/clinic
install -d -m 700 -o clinicapp -g clinicapp /opt/clinic/uploads /opt/clinic/records
# TODO(확인필요): uploads/qna, uploads/reviews 의 모드 미확보(소유자는 10/2 chown -R 로 clinicapp)
install -d -m 700 -o clinicapp -g clinicapp /opt/clinic/uploads/qna /opt/clinic/uploads/reviews
chown -R clinicapp:clinicapp /opt/clinic/uploads /opt/clinic/records

# 4-3 WEB-07 배포 경로 밖 백업 보관소 + 백업 jar 이동
install -d -m 700 -o root -g root /var/backups/clinic-admin
for f in /opt/clinic/admin-app.jar.bak /opt/clinic/admin-app.jar.*.bak /opt/clinic/admin-app.jar.backup-*; do
  if [ -f "$f" ]; then mv -v "$f" /var/backups/clinic-admin/; fi
done

# 4-4 WEB-13 jar (clinicapp 600). jar 자체는 저장소에 없으므로 ADMIN_APP_JAR_SRC 로 받는다
if [ -n "${ADMIN_APP_JAR_SRC:-}" ]; then
  case "$ADMIN_APP_JAR_SRC" in
    s3://*) command -v aws >/dev/null 2>&1 || die "aws CLI 없음 - s3 에서 jar 를 받을 수 없다"
            aws s3 cp --region "$AWS_REGION" "$ADMIN_APP_JAR_SRC" "$TMPD/admin-app.jar" ;;
    *)      cp "$ADMIN_APP_JAR_SRC" "$TMPD/admin-app.jar" ;;
  esac
  if [ -f "$JAR" ] && cmp -s "$TMPD/admin-app.jar" "$JAR"; then
    echo "  jar 동일 - 교체 안 함"
  else
    if [ -f "$JAR" ]; then cp -p "$JAR" "/var/backups/clinic-admin/admin-app.jar.$(date +%Y%m%d-%H%M)"; fi
    install -m 600 -o clinicapp -g clinicapp "$TMPD/admin-app.jar" "$JAR"
    APP_CHANGED=1; echo "  배포: $JAR"
  fi
fi
if [ -f "$JAR" ]; then
  chown clinicapp:clinicapp "$JAR"; chmod 600 "$JAR"
else
  warn "$JAR 없음 - 서비스는 등록만 하고 기동하지 않는다 (ADMIN_APP_JAR_SRC 지정)"
fi

# 4-5 DB 연결·비밀번호 회전 환경파일 (systemd 가 root 로 읽어 앱에 넘김)
# TODO(확인필요): /etc/clinic 디렉터리 모드 미확보
install -d -m 755 -o root -g root /etc/clinic
# db.env: 운영 600 root:root 328 bytes. 키 3개는 앱 프로세스 환경변수 목록(precheck2.log)으로 확인,
# URL·계정은 원래 ExecStart 값. TODO(확인필요): 운영 db.env 원문(키 순서·추가 줄) 미확보
DBP=$(get_secret DB_PASSWORD DB_PASSWORD_SSM_PARAM)
if [ -n "$DBP" ]; then
  printf 'SPRING_DATASOURCE_URL=%s\nSPRING_DATASOURCE_USERNAME=%s\nSPRING_DATASOURCE_PASSWORD=%s\n' \
    "$DB_URL" "$DB_USERNAME" "$DBP" > "$TMPD/db.env"
  if install_file "$TMPD/db.env" /etc/clinic/db.env 600 root:root; then APP_CHANGED=1; fi
  rm -f "$TMPD/db.env"
elif [ ! -s /etc/clinic/db.env ]; then
  warn "DB_PASSWORD / DB_PASSWORD_SSM_PARAM 미지정 - /etc/clinic/db.env 없음, 앱 기동 불가"
fi
unset DBP
# admin-rotate.env: 운영 640 root:team 102 bytes, 키 ROTATE_ADMIN_PASSWORD·ROTATE_USER_PASSWORD·ROTATE_PASSWORDS_ON_STARTUP
# (precheck2.log). override.conf 가 EnvironmentFile=- 로 읽으므로 없어도 기동된다.
# TODO(확인필요): ROTATE_PASSWORDS_ON_STARTUP 운영값·키 순서 미확보
RAP=$(get_secret ROTATE_ADMIN_PASSWORD ROTATE_ADMIN_PASSWORD_SSM_PARAM)
RUP=$(get_secret ROTATE_USER_PASSWORD ROTATE_USER_PASSWORD_SSM_PARAM)
if [ -n "$RAP" ] && [ -n "$RUP" ] && [ -n "${ROTATE_PASSWORDS_ON_STARTUP:-}" ]; then
  printf 'ROTATE_PASSWORDS_ON_STARTUP=%s\nROTATE_ADMIN_PASSWORD=%s\nROTATE_USER_PASSWORD=%s\n' \
    "$ROTATE_PASSWORDS_ON_STARTUP" "$RAP" "$RUP" > "$TMPD/admin-rotate.env"
  if install_file "$TMPD/admin-rotate.env" /etc/clinic/admin-rotate.env 640 root:team; then APP_CHANGED=1; fi
  rm -f "$TMPD/admin-rotate.env"
elif [ ! -e /etc/clinic/admin-rotate.env ]; then
  warn "admin-rotate.env 입력 미지정 - 생략(선택 사항)"
fi
unset RAP RUP

# 4-6 systemd 유닛 + drop-in (files/ 원문. JVM 경로만 설치된 java-21 로 맞춤)
if [ -x "$LIVE_JAVA" ]; then
  JAVA_BIN=$LIVE_JAVA
else
  JAVA_BIN=$(ls -d /usr/lib/jvm/java-21-openjdk-21*/bin/java 2>/dev/null | sort -V | tail -n1 || true)
  [ -n "$JAVA_BIN" ] || die "java-21-openjdk 를 찾을 수 없다"
  warn "운영 JVM 경로 없음 → $JAVA_BIN 로 바꿔 배포"
fi
sed "s|$LIVE_JAVA|$JAVA_BIN|g" "$FILES/etc/systemd/system/clinic-admin.service" > "$TMPD/clinic-admin.service"
sed "s|$LIVE_JAVA|$JAVA_BIN|g" "$FILES/etc/systemd/system/clinic-admin.service.d/db-creds.conf" > "$TMPD/db-creds.conf"
install -d -m 755 -o root -g root "$SD/clinic-admin.service.d"
if install_file "$TMPD/clinic-admin.service" "$SD/clinic-admin.service" 600; then APP_CHANGED=1; fi
if install_file "$TMPD/db-creds.conf" "$SD/clinic-admin.service.d/db-creds.conf" 600; then APP_CHANGED=1; fi
for n in override security runas; do   # runas.conf = 10/2 WEB-09(User/Group)·WEB-26(로그 경로)
  if install_file "$FILES/etc/systemd/system/clinic-admin.service.d/$n.conf" "$SD/clinic-admin.service.d/$n.conf" 600; then APP_CHANGED=1; fi
done

# 4-7 WEB-26 로그 디렉터리 750 root, 파일 640 root (systemd file: 로 기록)
install -d -m 750 -o root -g root /var/log/clinic-admin
for f in admin-app.log admin-app-err.log; do
  if [ ! -e "/var/log/clinic-admin/$f" ]; then install -m 640 -o root -g root /dev/null "/var/log/clinic-admin/$f"; fi
  chown root:root "/var/log/clinic-admin/$f"; chmod 640 "/var/log/clinic-admin/$f"
done

# -----------------------------------------------------------------------------
log "5. 2026-10-02 조치 U-02 U-03 U-23 U-30 U-32 U-37 U-62 U-65 U-67 [CMD §3, APPLY 같은 이름 스크립트]"

# 5-1 U-02 비밀번호 정책 + U-03 계정 잠금 (같은 PAM 파일) [APPLY U-02_U-03.sh]
SA=/etc/pam.d/system-auth; PA=/etc/pam.d/password-auth; PQ=/etc/security/pwquality.conf
ls -l /usr/lib64/security/pam_faillock.so /usr/lib64/security/pam_pwhistory.so >/dev/null || die "PAM 모듈 없음"
for f in $SA $PA; do
  if [ -L "$f" ]; then die "$f 가 심볼릭 링크(authselect 관리) - 수동 확인 필요"; fi
  for re in '^password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so' '^auth[[:space:]]+sufficient[[:space:]]+pam_unix\.so' '^account[[:space:]]+required[[:space:]]+pam_unix\.so'; do
    n=$(grep -cE "$re" "$f" || true); [ "$n" = 1 ] || die "$f 기준 줄 '$re' 개수=$n"
  done
done
for f in $PQ $SA $PA; do backup_once "$f" "$f.bak_u02_$D"; done
for k in dcredit ucredit lcredit ocredit; do
  grep -qE "^[[:space:]]*$k[[:space:]]*=" $PQ || echo "$k = -1" >> $PQ
done
grep -qE '^[[:space:]]*enforce_for_root' $PQ || echo 'enforce_for_root' >> $PQ
for f in $SA $PA; do
  grep -qE '^password[[:space:]]+requisite[[:space:]]+pam_pwhistory\.so' "$f" || \
    sed -i '/^password[[:space:]]\+requisite[[:space:]]\+pam_pwquality\.so/a password    requisite     pam_pwhistory.so use_authtok remember=4 enforce_for_root' "$f"
  grep -qE '^auth[[:space:]]+required[[:space:]]+pam_faillock\.so[[:space:]]+preauth' "$f" || \
    sed -i '/^auth[[:space:]]\+sufficient[[:space:]]\+pam_unix\.so/i auth        required      pam_faillock.so preauth silent audit' "$f"
  grep -qE '^auth[[:space:]]+\[default=die\][[:space:]]+pam_faillock\.so[[:space:]]+authfail' "$f" || \
    sed -i '/^auth[[:space:]]\+sufficient[[:space:]]\+pam_unix\.so/a auth        [default=die] pam_faillock.so authfail audit' "$f"
  grep -qE '^account[[:space:]]+required[[:space:]]+pam_faillock\.so' "$f" || \
    sed -i '/^account[[:space:]]\+required[[:space:]]\+pam_unix\.so/i account     required      pam_faillock.so' "$f"
done
# 기존 계정 사용기간(운영: 2026-12-16 만료. 새 인스턴스는 첫 부팅 비밀번호 설정일 + 90일)
chage -m 1 -M 90 -W 7 root
chage -m 1 -M 90 -W 7 team
sshd -t || die "sshd -t 실패(PAM 변경 후)"

# 5-2 U-23 unix_chkpwd SUID 제거 [APPLY U-23.sh]
if [ ! -e "/root/u23_perm_before_$D.txt" ]; then stat -c '%a %U:%G %n' /usr/sbin/unix_chkpwd > "/root/u23_perm_before_$D.txt"; fi
chmod u-s /usr/sbin/unix_chkpwd

# 5-3 U-30 /etc/profile umask 002 → 022 [APPLY U-30.sh]
backup_once /etc/profile "/etc/profile.bak_u30_$D"
sed -i 's/^\([[:space:]]*\)umask 002[[:space:]]*$/\1umask 022/' /etc/profile

# 5-4 U-32 홈 디렉터리 없는 계정 [APPLY U-32.sh]
L="cockpit-ws cockpit-wsinstance cwagent"
if [ ! -e "/root/u32_passwd_before_$D.txt" ]; then getent passwd $L > "/root/u32_passwd_before_$D.txt" || true; fi
for u in $L; do
  h=$(getent passwd "$u" | cut -d: -f6 || true)
  if [ -n "$h" ] && [ ! -d "$h" ]; then
    mkdir -p "$h"; echo "  생성: $h ($u)"
    case "$h" in
      /nonexist*) chown root:root "$h"; chmod 755 "$h" ;;
      *)          chown "$u": "$h"; chmod 750 "$h" ;;
    esac
  fi
done

# 5-5 U-37 crontab SUID 제거 + cron 디렉터리 640 [APPLY U-37.sh]
T="/usr/bin/crontab /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly"
if [ ! -e "/root/u37_perm_before_$D.txt" ]; then stat -c '%a %U:%G %n' $T > "/root/u37_perm_before_$D.txt"; fi
chmod 0750 /usr/bin/crontab
chmod 0640 /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly

# 5-6 U-62 /etc/motd 경고문 [APPLY U-62.sh, files/etc/motd 원문]
backup_once /etc/motd "/etc/motd.bak_u62_$D"
install_file "$FILES/etc/motd" /etc/motd 644 root:root || true

# 5-7 U-65 chrony → AWS Time Sync 169.254.169.123 [APPLY U-65.sh]
backup_once /etc/chrony.conf "/etc/chrony.conf.bak_$D"
CH0=$(md5sum /etc/chrony.conf)
sed -i 's/^pool 2.rocky.pool.ntp.org iburst/#&/' /etc/chrony.conf
grep -q '^server 169.254.169.123 ' /etc/chrony.conf || \
  sed -i '/^#pool 2.rocky.pool.ntp.org iburst/a server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' /etc/chrony.conf
grep -q '^server 169.254.169.123 ' /etc/chrony.conf || warn "chrony.conf 에 기준 줄(pool 2.rocky.pool.ntp.org)이 없어 server 줄을 넣지 못함"
if [ "$CH0" != "$(md5sum /etc/chrony.conf)" ] || ! systemctl is-active --quiet chronyd; then
  systemctl restart chronyd
fi
systemctl enable chronyd >/dev/null 2>&1 || true

# 5-8 U-67 로그 파일 권한 + 재부팅·로테이트 후 유지 [APPLY U-67.sh]
mkdir -p /root/u67_bak
for f in /etc/logrotate.d/wtmp /etc/logrotate.d/btmp; do
  if [ ! -e "/root/u67_bak/$(basename "$f")" ]; then cp -p "$f" /root/u67_bak/; fi
done
if [ -e /etc/tmpfiles.d/zz-kisa-logperm.conf ]; then mv -v /etc/tmpfiles.d/zz-kisa-logperm.conf /root/u67_bak/; fi   # 이름이 달라 무시되던 파일
[ -e /etc/tmpfiles.d/var.conf ] || cp -p /usr/lib/tmpfiles.d/var.conf /etc/tmpfiles.d/var.conf
sed -i -e 's#^f /var/log/wtmp 0664#f /var/log/wtmp 0644#' -e 's#^f /var/log/btmp 0660#f /var/log/btmp 0600#' \
       -e 's#^f /var/log/lastlog 0664#f /var/log/lastlog 0644#' /etc/tmpfiles.d/var.conf
sed -i 's/create 0664 root utmp/create 0644 root utmp/' /etc/logrotate.d/wtmp
sed -i 's/create 0660 root utmp/create 0600 root utmp/' /etc/logrotate.d/btmp
for f in /var/log/wtmp /var/log/lastlog; do if [ -e "$f" ]; then chmod 644 "$f"; fi; done
for f in /var/log/btmp /var/log/btmp-*; do if [ -e "$f" ]; then chmod 600 "$f"; fi; done

# -----------------------------------------------------------------------------
log "6. U-20 /etc/systemd 파일 root 600 (systemd 파일 배포가 모두 끝난 뒤) [CMD §1 U-20, APPLY U-20.sh]"
# 운영에는 web-adm1 같은 유지 유닛(kisa-u20-perm.path)이 없다. systemd 패키지 갱신 뒤 이 스크립트를 다시 실행한다.
if [ ! -e "/root/u20_perm_before_$D.txt" ]; then find /etc/systemd -xdev -type f -printf '%m %u %p\n' > "/root/u20_perm_before_$D.txt"; fi
chown root /etc/systemd/system.conf && chmod 600 /etc/systemd/system.conf
find /etc/systemd -xdev -type f -exec chown root {} + -exec chmod 600 {} +
systemctl daemon-reload

# -----------------------------------------------------------------------------
log "7. clinic-admin 기동"
systemctl enable clinic-admin.service
HC=skip
if [ -f "$JAR" ] && [ -s /etc/clinic/db.env ]; then
  if [ "$APP_CHANGED" = 1 ] || ! systemctl is-active --quiet clinic-admin; then
    systemctl restart clinic-admin
  fi
  HC=000
  for i in $(seq 1 24); do
    HC=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:8080/login || true)
    if [ "$HC" = 200 ] || [ "$HC" = 302 ]; then break; fi
    sleep 5
  done
  echo "  /login HTTP $HC"
else
  warn "jar 또는 db.env 가 없어 기동 생략"
fi

# -----------------------------------------------------------------------------
log "8. 확인 (읽기 전용, 운영 rfix4 재진단·U-64_post.sh 기준)"
chk() { if eval "$2" >/dev/null 2>&1; then echo "  OK   $1"; else echo "  FAIL $1"; FAILS=$((FAILS+1)); fi; }
chk "U-01 PermitRootLogin no"            'sshd -T | grep -x "permitrootlogin no"'
chk "U-02 pwquality 복잡성 4개+enforce_for_root" '[ "$(grep -cE "^(d|u|l|o)credit = -1|^enforce_for_root" /etc/security/pwquality.conf)" = 5 ]'
chk "U-02/03 faillock 3+3, pwhistory 1+1" '[ "$(grep -c pam_faillock $SA)$(grep -c pam_faillock $PA)$(grep -c pam_pwhistory $SA)$(grep -c pam_pwhistory $PA)" = 3311 ]'
chk "U-03 faillock.conf deny=5"          'grep -qE "^deny = 5" /etc/security/faillock.conf'
chk "U-12 ClientAliveInterval 300"       'sshd -T | grep -x "clientaliveinterval 300"'
chk "U-20 /etc/systemd 전부 root 600"    '[ -z "$(find /etc/systemd -xdev -type f \( ! -user root -o -perm /177 \))" ]'
chk "U-23 unix_chkpwd SUID 없음"         '[ ! -u /usr/sbin/unix_chkpwd ]'
chk "U-30 su - team umask 0022"          '[ "$(su - team -c umask 2>/dev/null | tail -n1)" = 0022 ]'
chk "U-32 모든 홈 디렉터리 존재"         '[ -z "$(awk -F: "{print \$6}" /etc/passwd | while read -r h; do [ -d "$h" ] || echo x; done)" ]'
chk "U-37 crontab 750, cron 디렉터리 640" '[ "$(stat -c %a /usr/bin/crontab /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly | tr "\n" " ")" = "750 640 640 640 640 " ]'
chk "U-37 team crontab 거부"             '! sudo -u team crontab -l'
chk "U-62 motd 경고문"                   'cmp -s "$FILES/etc/motd" /etc/motd'
chk "U-65 chrony 169.254.169.123 설정"   'grep -q "^server 169.254.169.123 " /etc/chrony.conf'
chk "U-67 /var/log root·644 이하"        '[ -z "$(find /var/log -xdev -maxdepth 4 -type f \( ! -user root -o -perm /7133 \))" ]'
chk "placeholder.service 비활성"         '! systemctl is-enabled --quiet placeholder.service'
chk "WEB-07 배포 경로 정리"              '[ -z "$(ls -A /opt/clinic | grep -vxE "admin-app.jar|records|uploads")" ]'
chk "WEB-26 로그 750 root / 640 root"    '[ "$(stat -c "%a %U" /var/log/clinic-admin)" = "750 root" ] && [ -z "$(find /var/log/clinic-admin -type f ! -perm 640)" ]'
chk "WEB-09 clinicapp sudo 없음"         'sudo -l -U clinicapp 2>&1 | grep "not allowed"'
if [ -f "$JAR" ]; then
  chk "WEB-13 jar 600 clinicapp"         '[ "$(stat -c "%a %U" "$JAR")" = "600 clinicapp" ]'
fi
if [ "$HC" != skip ]; then
  PID=$(systemctl show -p MainPID --value clinic-admin)
  chk "WEB-09 앱 프로세스 계정 clinicapp" '[ "$(ps -o user= -p "$PID" | tr -d " ")" = clinicapp ]'
  chk "WEB-26 fd 1/2 → /var/log/clinic-admin" '[ "$(readlink /proc/$PID/fd/1)" = /var/log/clinic-admin/admin-app.log ]'
  chk "앱 /login 200/302 (HTTP $HC)"      '[ "$HC" = 200 ] || [ "$HC" = 302 ]'
fi
echo "  참고: SELinux=$(getenforce 2>/dev/null || echo '?') (user_data 가 permissive 로 설정), 남은 취약 WEB-25(내장 Tomcat 10.1.55) 는 의도적으로 미조치"

# U-64 재부팅 필요 여부 (10/2 운영은 승인 후 shutdown -r +1)
if command -v needs-restarting >/dev/null 2>&1 || dnf needs-restarting --help >/dev/null 2>&1; then
  if ! dnf needs-restarting -r >/dev/null 2>&1; then
    if [ "${AUTO_REBOOT:-0}" = 1 ]; then
      shutdown -r +1 "baseline: U-64 kernel update reboot"
      echo "  1분 뒤 재부팅 예약됨 - 재부팅 후 이 스크립트를 한 번 더 실행해 확인"
    else
      warn "커널 등 갱신으로 재부팅 필요 (AUTO_REBOOT=1 또는 수동 재부팅 후 재실행)"
    fi
  fi
fi

log "완료: 경고 $WARNS 건, 확인 실패 $FAILS 건 (로그 $LOG)"
[ "$FAILS" -eq 0 ] || exit 2
