#!/bin/bash
# =============================================================================
# bastion OS 기준선 (Debian 11 bullseye, SSH 점프 서버)
#
#  목적  : 같은 AMI(ami-0f68da0073476cce5) + os/bastion/user_data.tpl 로 만든 새 인스턴스를
#          2026-10-06 운영 상태로 맞춘다. (README.md 의 근거 [A]~[G] 참고)
#  적용분: ① 9/28~29 팀 이행조치 - 근거 [E] wf_result_v2.json(9/30 실서버 조회), [C] 10/2 사전 확인 로그
#          ② 10/2 취약점 조치    - 근거 [A] 조치명령_서버별_20261002.md, [C] apply_scripts·실행 로그
#  제외  : U-64 Debian 11 -> 12/13 업그레이드(사용자가 10/2 조치에서 제외 [B]) - 하지 않는다.
#  실행  : root, user_data(cloud-init) 완료 뒤 SSM 세션에서  bash baseline.sh
#          (적용 후 SSH 는 <ADMIN_IP> 과 EC2 Instance Connect 대역만 허용 - SSH 세션에서 돌리면 새 접속이 막힐 수 있음)
#          여러 번 실행해도 결과가 같도록 작성했다.
#  비밀값: 필요 없음 (root/team 비밀번호는 user_data 템플릿이 처리)
#  표기  : '# TODO(확인필요)' = 근거 자료로 확정하지 못한 부분. 값을 지어내지 않고 표시만 했다.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$HERE/files"
BAK=/root/baseline_bak            # 최초 원본 보관(재실행 시 덮어쓰지 않음)
REGION=ap-northeast-2

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[WARN] $*" >&2; }

# ---- 공통 함수 ---------------------------------------------------------------
backup() {                       # 파일 최초본 1회 백업
  local f
  for f in "$@"; do
    [ -e "$f" ] || continue
    mkdir -p "$BAK$(dirname "$f")"
    [ -e "$BAK$f" ] || cp -p "$f" "$BAK$f"
  done
}
ensure_line() {                  # 정확히 같은 줄이 없으면 파일 끝에 추가
  grep -qxF -- "$2" "$1" 2>/dev/null || echo "$2" >> "$1"
}
set_kv() {                       # 'KEY<공백>VALUE' (login.defs)
  local f=$1 k=$2 v=$3
  if grep -qE "^[[:space:]]*${k}[[:space:]]" "$f"; then
    sed -i -E "s|^[[:space:]]*${k}[[:space:]].*|${k}\t${v}|" "$f"
  else
    printf '%s\t%s\n' "$k" "$v" >> "$f"
  fi
}
set_eq() {                       # 'key = value' (pwquality.conf, faillock.conf)
  local f=$1 k=$2 v=$3
  if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f"; then
    sed -i -E "s|^[[:space:]]*${k}[[:space:]]*=.*|${k} = ${v}|" "$f"
  else
    echo "${k} = ${v}" >> "$f"
  fi
}
statov() {                       # dpkg-statoverride 를 원하는 값으로 (owner group mode path)
  local cur
  cur=$(dpkg-statoverride --list "$4" 2>/dev/null || true)
  if [ "$cur" != "$1 $2 ${3#0} $4" ]; then
    if [ -n "$cur" ]; then dpkg-statoverride --remove "$4"; fi
    dpkg-statoverride --update --add "$1" "$2" "$3" "$4"
  fi
  # 목록이 이미 같아도 실제 파일 모드는 앞 단계(9/29 chmod 등)에서 바뀌었을 수 있어 항상 맞춘다
  chown "$1:$2" "$4"; chmod "$3" "$4"
}
install_deb_url() {              # $1=패키지명 $2=URL (설치돼 있으면 건너뜀)
  dpkg -s "$1" >/dev/null 2>&1 && return 0
  command -v curl >/dev/null 2>&1 || apt-get install -y curl
  local t; t=$(mktemp -d)
  curl -fsSL -o "$t/pkg.deb" "$2"
  dpkg -i "$t/pkg.deb"
  rm -rf "$t"
}

# ---- 0. 사전 확인 -------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "root 로 실행해야 한다"; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
{ [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = "11" ]; } || { echo "Debian 11 전용"; exit 1; }
[ -d "$FILES" ] || { echo "files/ 폴더가 없다: $FILES"; exit 1; }
if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait >/dev/null 2>&1 || true; fi
# user_data.tpl 은 운영과 같게 CRLF 라 cloud-init 이 실행하지 못할 수 있다(#!/bin/bash).
# team 계정까지 없으면 반쯤 적용된 상태를 막기 위해 여기서 멈춘다 (수동 실행 방법: README 10장)
if [ ! -f /var/log/bootstrap.log ]; then
  id team >/dev/null 2>&1 || { echo "user_data 미실행(bootstrap.log·team 계정 없음) - README 10장대로 user_data 를 CR 제거 후 먼저 실행"; exit 1; }
  warn "user_data 로그(/var/log/bootstrap.log) 없음 - team 계정은 있어 계속 진행"
fi
mkdir -p "$BAK"

# ---- 1. 패키지 -------------------------------------------------------------------
log "1. 패키지"
apt-get update -q
# [9/28] apt history: libpam-pwquality, nftables 설치 [E U-64]
#        nftables 는 설치만 돼 있고 룰셋은 비어 있음(9/30, 서비스 미기동으로 판단) [E U-28]
apt-get install -y -o Dpkg::Options::=--force-confold libpam-pwquality nftables
# U-64(Debian 11 EOL)는 의도적으로 미조치: 배포판 업그레이드·dist-upgrade 를 하지 않는다 [B]

# SSM Agent: 실서버는 deb 패키지 서비스 amazon-ssm-agent=active (snap 아님) [C 99_postcheck]
# TODO(확인필요) 원래 설치 방법·버전 미확보 - AWS 공식 리전 배포 경로로 설치
install_deb_url amazon-ssm-agent \
  "https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/debian_amd64/amazon-ssm-agent.deb"
systemctl enable --now amazon-ssm-agent >/dev/null 2>&1

# CloudWatch Agent: 실서버 active, /etc/systemd/system/amazon-cloudwatch-agent.service, 계정 cwagent(997) [C U-20·U-32]
# TODO(확인필요) 원래 설치 방법·버전·에이전트 설정(json) 미확보 - 설치만 하고 설정 적용·기동은 하지 않는다
install_deb_url amazon-cloudwatch-agent \
  "https://amazoncloudwatch-agent-${REGION}.s3.${REGION}.amazonaws.com/debian/amd64/latest/amazon-cloudwatch-agent.deb"

# TODO(확인필요) /opt/jdk, /opt/maven(+ team 의 .bashrc PATH, ~/.m2) 이 실서버에 있음 [E U-14·U-15·U-33]
#                버전·설치 출처 미확보로 재현하지 않음

# ---- 2. 계정·PAM ---------------------------------------------------------------
log "2. 계정 / PAM"
backup /etc/login.defs /etc/security/pwquality.conf /etc/security/faillock.conf /etc/pam.d/common-password \
       /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/su

# [9/28] U-02 login.defs 90/1/8, root·team 1/90 [E U-02, D U-02 'WARN=7']
set_kv /etc/login.defs PASS_MAX_DAYS 90
set_kv /etc/login.defs PASS_MIN_DAYS 1
set_kv /etc/login.defs PASS_WARN_AGE 7
set_kv /etc/login.defs PASS_MIN_LEN 8
chage -m 1 -M 90 root
chage -m 1 -M 90 team
# [9/28] pwquality.conf (주석 아닌 줄 = 아래 6개) [C 00_precheck 출력]
set_eq /etc/security/pwquality.conf minlen 8
set_eq /etc/security/pwquality.conf dcredit -1
set_eq /etc/security/pwquality.conf ucredit -1
set_eq /etc/security/pwquality.conf lcredit -1
set_eq /etc/security/pwquality.conf ocredit -1
ensure_line /etc/security/pwquality.conf 'enforce_for_root'

# common-password: 10/2 조치 직후와 같은 3줄 순서로 맞춘다 [C U-02 실행 로그 after]
#   25: password    requisite    pam_pwquality.so retry=3
#   26: password<TAB>required<TAB><TAB><TAB>pam_pwhistory.so remember=4 use_authtok enforce_for_root
#   27: password<TAB>[success=1 default=ignore]<TAB>pam_unix.so obscure use_authtok try_first_pass yescrypt
CP=/etc/pam.d/common-password
# (a) 9/28 상태로 정규화: libpam-pwquality 설치 시 pam-auth-update 가 넣는 pwquality 줄을 빼고 pwhistory 를 pam_unix 앞에
sed -i '/^password.*pam_pwquality\.so/d' "$CP"
sed -i 's/^\(password.*pam_unix\.so obscure\) use_authtok try_first_pass yescrypt$/\1 yescrypt/' "$CP"
grep -q '^password.*pam_pwhistory\.so' "$CP" || \
  sed -i '/^password.*pam_unix\.so obscure yescrypt$/i password\trequired\t\t\tpam_pwhistory.so remember=4 use_authtok enforce_for_root' "$CP"
# (b) 10/2 U-02 명령 그대로 [A bastion U-02]
sed -i '/^password.*pam_pwhistory\.so/i password    requisite    pam_pwquality.so retry=3' "$CP"
sed -i 's/^\(password.*pam_unix\.so obscure\) yescrypt$/\1 use_authtok try_first_pass yescrypt/' "$CP"
ORDER=$(grep '^password' "$CP" | grep -oE 'pam_(pwquality|pwhistory|unix)\.so' | tr '\n' ' ')
[ "$ORDER" = "pam_pwquality.so pam_pwhistory.so pam_unix.so " ] || warn "common-password 순서 이상: $ORDER"
# 주의: pam-auth-update --force 는 수동 줄을 지우므로 쓰지 않는다 [A]

# [9/28] U-03 pam_faillock: faillock.conf deny=5·unlock_time=600·fail_interval=900, common-account 1행 [E U-03]
set_eq /etc/security/faillock.conf deny 5
set_eq /etc/security/faillock.conf unlock_time 600
set_eq /etc/security/faillock.conf fail_interval 900
grep -qE '^account[[:space:]]+required[[:space:]]+pam_faillock\.so' /etc/pam.d/common-account || \
  sed -i '1i account required pam_faillock.so' /etc/pam.d/common-account
# TODO(확인필요) common-auth 의 faillock 4줄은 정확한 제어 문자열이 확보되지 않아 자동 적용하지 않는다.
#   근거 [E U-03] 원문(순서만 확인):
#     'auth required pam_faillock.so preauth' -> 'pam_unix.so nullok [success=2]'
#     -> '[default=die] pam_faillock.so authfail' -> 'sufficient pam_faillock.so authsucc'
#   실서버 /etc/pam.d/common-auth 를 확인한 뒤 같은 줄을 넣는다(잘못 넣으면 비밀번호 인증이 모두 실패할 수 있음).
grep -q 'pam_faillock.so preauth' /etc/pam.d/common-auth || warn "U-03: common-auth faillock 줄 미적용(TODO 확인필요)"

# [9/28] U-06 su 제한: wheel 그룹(구성원 admin, 실서버 GID 1002) + pam_wheel group=wheel + su 4750 [E U-06·U-08·U-09]
getent group wheel >/dev/null || groupadd wheel
if id admin >/dev/null 2>&1; then usermod -aG wheel admin; fi
if ! grep -qE '^[[:space:]]*auth[[:space:]].*pam_wheel\.so' /etc/pam.d/su; then
  # TODO(확인필요) 'pam_wheel group=wheel' 사용만 확인됨 - 제어 플래그(required 등) 원문 미확보
  sed -i '/^auth[[:space:]]\+sufficient[[:space:]]\+pam_rootok\.so/a auth       required   pam_wheel.so group=wheel' /etc/pam.d/su
fi
chgrp wheel /usr/bin/su; chmod 4750 /usr/bin/su

# ---- 3. 파일 권한 ----------------------------------------------------------------
log "3. 파일 권한"
# [9/28] U-18 /etc/shadow root:shadow 400 [E U-04·U-18]
chown root:shadow /etc/shadow; chmod 400 /etc/shadow
# [9/28] U-21 rsyslog 설정 root 640 (rsyslog.conf, rsyslog.d/21-cloudinit.conf) [E U-21, D U-21]
chown root:root /etc/rsyslog.conf /etc/rsyslog.d/*.conf
chmod 640 /etc/rsyslog.conf /etc/rsyslog.d/*.conf
# [9/28] U-23 제거권고 SUID/SGID 해제: unix_chkpwd·wall·write.ul·newgrp -> 755 [E U-23]
for f in /usr/sbin/unix_chkpwd /usr/bin/wall /usr/bin/write.ul /usr/bin/newgrp; do
  if [ -e "$f" ]; then chmod 755 "$f"; fi
done
# [9/28] U-37 crontab root:root 750 (chmod 방식 - statoverride 'root crontab 2755' 는 실서버처럼 그대로 둠) [E U-37]
chown root:root /usr/bin/crontab; chmod 750 /usr/bin/crontab
chmod 640 /etc/crontab
[ "$(cat /etc/cron.allow 2>/dev/null || true)" = root ] || echo root > /etc/cron.allow
chown root:root /etc/cron.allow; chmod 640 /etc/cron.allow
find /etc/cron.d -maxdepth 1 -type f ! -name '.*' -exec chmod 640 {} +
# 실서버는 cron.daily·cron.weekly 안의 파일도 640 (과잉조치, run-parts 대상 0개 - 해당 작업은 systemd timer 가 대신함) [E U-37, C U-37]
find /etc/cron.daily /etc/cron.weekly -maxdepth 1 -type f -exec chmod 640 {} +

# [10/2] U-37 cron.* 디렉터리 640 (statoverride) [A bastion U-37, C U-37]
for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do statov root root 0640 "$d"; done

# [10/2] U-32 홈 디렉터리 존재 (irc 홈 /run/ircd -> /var/lib/irc) [A bastion U-32, C U-32]
if [ "$(getent passwd irc | cut -d: -f6 || true)" = /run/ircd ]; then usermod -d /var/lib/irc irc; fi
for u in lp news uucp www-data list irc gnats nobody _apt messagebus tcpdump cwagent; do
  h=$(getent passwd "$u" | cut -d: -f6 || true)
  { [ -n "$h" ] && [ ! -d "$h" ]; } || continue
  mkdir -p "$h"
  case "$h" in
    /nonexist*) chown root:root "$h"; chmod 755 "$h" ;;
    *)          chown "$u": "$h";     chmod 750 "$h" ;;
  esac
done

# ---- 4. 세션·배너·접속 제한 ------------------------------------------------------
log "4. 세션 / 배너 / TCP Wrapper"
backup /etc/profile /etc/profile.d/tmout.sh /etc/ssh/sshd_config /etc/hosts.allow /etc/hosts.deny /etc/issue /etc/issue.net /etc/motd
# [9/28 06:20] U-12 TMOUT=600: /etc/profile.d/tmout.sh(readonly) + /etc/profile 35~36행 [E U-12, D U-12 'tmout.sh:1,readonly']
# TODO(확인필요) tmout.sh 는 'TMOUT=600 / readonly TMOUT / export TMOUT' 세 문장만 확인됨(줄 형식 미확보)
printf 'TMOUT=600\nreadonly TMOUT\nexport TMOUT\n' > /etc/profile.d/tmout.sh.new
if cmp -s /etc/profile.d/tmout.sh.new /etc/profile.d/tmout.sh; then rm -f /etc/profile.d/tmout.sh.new
else mv -f /etc/profile.d/tmout.sh.new /etc/profile.d/tmout.sh; fi
chown root:root /etc/profile.d/tmout.sh; chmod 644 /etc/profile.d/tmout.sh
# /etc/profile 에도 중복 대입이 있음(로그인 때 'TMOUT: readonly variable' 경고, 실서버와 동일) [E U-12]
ensure_line /etc/profile 'TMOUT=600'
ensure_line /etc/profile 'export TMOUT'

# [9/28 06:30] U-62 경고문 /etc/issue, /etc/issue.net, /etc/motd + sshd Banner [E U-62]
if [ -f "$FILES/banner.txt" ]; then
  BANNER_SRC="$FILES/banner.txt"
else
  # TODO(확인필요) 경고문 전문 미확보 - 근거에 인용된 조각만 배포한다(files/banner.FRAGMENT.txt)
  BANNER_SRC=$(mktemp); grep -v '^#' "$FILES/banner.FRAGMENT.txt" > "$BANNER_SRC"
  warn "경고문 전문 없음 - 조각(banner.FRAGMENT.txt)으로 배포"
fi
for f in /etc/issue /etc/issue.net /etc/motd; do
  cmp -s "$BANNER_SRC" "$f" || install -o root -g root -m 644 "$BANNER_SRC" "$f"
done
SC=/etc/ssh/sshd_config
if ! grep -qE '^[[:space:]]*Banner[[:space:]]+/etc/issue\.net' "$SC"; then
  if grep -qE '^#?[[:space:]]*Banner[[:space:]]' "$SC"; then
    sed -i -E 's|^#?[[:space:]]*Banner[[:space:]].*|Banner /etc/issue.net|' "$SC"
  else
    echo 'Banner /etc/issue.net' >> "$SC"
  fi
fi
# sshd 실효값 ClientAliveInterval 120 / ClientAliveCountMax 3, PrintMotd no [E U-12·U-62]
# TODO(확인필요) 설정 위치(AMI 기본값인지 9/28 수정인지) 미확보 - 실효값이 다를 때만 sshd_config 에 넣는다
if ! sshd -T 2>/dev/null | grep -qx 'clientaliveinterval 120'; then
  if grep -qE '^#?[[:space:]]*ClientAliveInterval[[:space:]]' "$SC"; then
    sed -i -E 's|^#?[[:space:]]*ClientAliveInterval[[:space:]].*|ClientAliveInterval 120|' "$SC"
  else echo 'ClientAliveInterval 120' >> "$SC"; fi
fi
if ! sshd -T 2>/dev/null | grep -qx 'clientalivecountmax 3'; then
  if grep -qE '^#?[[:space:]]*ClientAliveCountMax[[:space:]]' "$SC"; then
    sed -i -E 's|^#?[[:space:]]*ClientAliveCountMax[[:space:]].*|ClientAliveCountMax 3|' "$SC"
  else echo 'ClientAliveCountMax 3' >> "$SC"; fi
fi
sshd -t
systemctl reload ssh

# [9/29 + 10/2] U-28 TCP Wrapper
#   hosts.allow = files/hosts.allow (10/2 조치 후 전문. 조치 전 46바이트 크기로 내용 검증) [C U-28·U-28-check, E U-28]
#   hosts.deny  = 'ALL: ALL' (9/29 04:43) - TODO(확인필요) 주석 등 나머지 내용 미확보, 규칙 줄만 맞춘다
[ "$(ldd /usr/sbin/sshd | grep -c libwrap || true)" -ge 1 ] || warn "sshd 가 libwrap 과 연결돼 있지 않다 - TCP Wrapper 무효"
cmp -s "$FILES/hosts.allow" /etc/hosts.allow || install -o root -g root -m 644 "$FILES/hosts.allow" /etc/hosts.allow
ensure_line /etc/hosts.deny 'ALL: ALL'

# ---- 5. 로그 파일 권한 -------------------------------------------------------------
log "5. 로그(tmpfiles / logrotate)"
backup /etc/tmpfiles.d/var.conf /etc/logrotate.d/wtmp /etc/logrotate.d/btmp
# [9/28 06:32] /etc/tmpfiles.d/var.conf = 패키지 var.conf 복사본 + wtmp 0644 / btmp 0600 [E U-67, C U-67 백업 파일 시각]
# [10/2]       lastlog 0644 [A bastion U-67, C U-67]
cp -p /usr/lib/tmpfiles.d/var.conf /etc/tmpfiles.d/var.conf
sed -i -e 's#^f /var/log/wtmp 0664#f /var/log/wtmp 0644#' -e 's#^f /var/log/btmp 0660#f /var/log/btmp 0600#' \
       -e 's#^f /var/log/lastlog 0664 root utmp -#f /var/log/lastlog 0644 root utmp -#' /etc/tmpfiles.d/var.conf
chmod 644 /var/log/wtmp /var/log/lastlog
chmod 600 /var/log/btmp
systemd-tmpfiles --create --prefix=/var/log/lastlog
# [9/28] logrotate wtmp/btmp 생성 권한 0644/0600 [E U-67]
# TODO(확인필요) 바꾼 파일 위치는 미기재(값만 확인) - Debian 11 기본 위치(logrotate.d)에 적용
if [ -f /etc/logrotate.d/wtmp ]; then sed -i 's/create 0664 root utmp/create 0644 root utmp/' /etc/logrotate.d/wtmp; fi
if [ -f /etc/logrotate.d/btmp ]; then sed -i 's/create 0660 root utmp/create 0600 root utmp/' /etc/logrotate.d/btmp; fi

# ---- 6. /etc/systemd 권한 (10/2 U-20, bastion 은 유지 유닛 없음) -------------------------
log "6. U-20 /etc/systemd 600"
find /etc/systemd -xdev -type f -exec chown root {} + -exec chmod 600 {} +
systemctl daemon-reload

# ---- 7. 확인 (읽기 전용 출력) -----------------------------------------------------------
log "7. 확인"
echo "  os/kernel      : $(cat /etc/debian_version) / $(uname -r)"
echo "  hosts.allow    : $(grep -vE '^[[:space:]]*(#|$)' /etc/hosts.allow | xargs)"
echo "  hosts.deny     : $(grep -vE '^[[:space:]]*(#|$)' /etc/hosts.deny | xargs)"
echo "  PAM password   : $ORDER"
echo "  sudo(team)     : $(sudo -u team sudo -n true 2>/dev/null && echo OK || echo FAIL)"
echo "  /var/log 비적합: $(find /var/log -xdev -maxdepth 4 -type f \( ! -user root -o -perm /7133 \) | wc -l)"
echo "  U-20 비적합    : $(find /etc/systemd -xdev -type f \( ! -user root -o -perm /177 \) | wc -l)"
echo "  cron 디렉터리  : $(stat -c '%a' /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly | xargs)"
echo "  chrony         : $(systemctl is-active chrony)  ssm=$(systemctl is-active amazon-ssm-agent)"
echo "  failed units   : [$(systemctl --failed --no-legend --plain | awk '{print $1}' | xargs)]"
log "완료"
