#!/bin/bash
# =============================================================================
# web-adm1 OS 기준선 (Ubuntu 20.04 + Nginx 1.18, 관리자 웹 프록시)
#
#  목적  : 같은 AMI(ami-0f8d552e06067b477) + os/web-adm1/user_data.tpl 로 만든 새 인스턴스를
#          2026-10-06 운영 상태로 맞춘다. (README.md 의 근거 [A]~[H] 참고)
#  적용분: ① 9/29 팀 이행조치  - 근거 [E] wf_result_v2.json(9/30 실서버 조회)
#          ② 10/2 취약점 조치   - 근거 [A] 조치명령_서버별_20261002.md, [C] apply_scripts·실행 로그
#          ③ 10/6 nginx 수정    - 근거 [F] (in-alb 이름을 resolver 로 주기 재조회)
#  실행  : root, user_data(cloud-init) 완료 뒤 SSM 세션에서  bash baseline.sh
#          (TCP Wrapper 가 SSH 를 bastion 10.0.0.176 으로만 제한하므로 SSM 사용 권장)
#          여러 번 실행해도 결과가 같도록 작성했다.
#  비밀값: UBUNTU_PRO_TOKEN 환경변수, 없으면 SSM /vuln-lab/ubuntu-pro-token (SecureString)
#  옵션  : REBOOT=1 이면 커널 갱신 시 1분 뒤 재부팅(10/2 U-64 와 같음). 기본은 안내만 출력.
#  표기  : '# TODO(확인필요)' = 근거 자료로 확정하지 못한 부분. 값을 지어내지 않고 표시만 했다.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$HERE/files"
D=$(date +%Y%m%d)
BAK=/root/baseline_bak            # 최초 원본 보관(재실행 시 덮어쓰지 않음)
APT_O=(-o Dpkg::Options::=--force-confold)   # 조치한 설정 파일 유지
REGION=ap-northeast-2
NG=/etc/nginx/nginx.conf
SITE=/etc/nginx/sites-available/clinic-admin

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
set_kv() {                       # 'KEY<공백>VALUE' (login.defs) - 주석 아닌 줄 교체, 없으면 추가
  local f=$1 k=$2 v=$3
  if grep -qE "^[[:space:]]*${k}[[:space:]]" "$f"; then
    sed -i -E "s|^[[:space:]]*${k}[[:space:]].*|${k}\t${v}|" "$f"
  else
    printf '%s\t%s\n' "$k" "$v" >> "$f"
  fi
}
set_eq() {                       # 'key = value' (pwquality.conf 등)
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
get_secret() {                   # $1=환경변수 이름, $2=SSM 파라미터 이름 (값은 출력만, 파일에 남기지 않음)
  local v="${!1:-}"
  if [ -z "$v" ]; then
    if command -v aws >/dev/null 2>&1; then
      v=$(aws ssm get-parameter --region "$REGION" --name "$2" --with-decryption \
            --query Parameter.Value --output text 2>/dev/null || true)
    else
      # Ubuntu 20.04 AMI/user_data 에는 aws CLI 가 없다 -> SSM 경로는 동작하지 않음
      warn "aws CLI 없음 - SSM 파라미터($2) 조회 불가. 환경변수 $1 로 넘기거나 awscli 를 먼저 설치"
    fi
  fi
  printf '%s' "$v"
}

# ---- 0. 사전 확인 -------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "root 로 실행해야 한다"; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
{ [ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = "20.04" ]; } || { echo "Ubuntu 20.04 전용"; exit 1; }
[ -d "$FILES" ] || { echo "files/ 폴더가 없다: $FILES"; exit 1; }
if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait >/dev/null 2>&1 || true; fi
# user_data.tpl 은 운영과 같게 CRLF 라 cloud-init 이 실행하지 못할 수 있다(#!/bin/bash).
# team 계정까지 없으면 반쯤 적용된 상태를 막기 위해 여기서 멈춘다 (수동 실행 방법: README 10장)
if [ ! -f /var/log/bootstrap.log ]; then
  id team >/dev/null 2>&1 || { echo "user_data 미실행(bootstrap.log·team 계정 없음) - README 10장대로 user_data 를 CR 제거 후 먼저 실행"; exit 1; }
  warn "user_data 로그(/var/log/bootstrap.log) 없음 - team 계정은 있어 계속 진행"
fi
mkdir -p "$BAK"

# ---- 1. Ubuntu Pro 연결 + 패키지 (9/29 이행조치 [E] U-64·WEB-25, 10/2 U-64 [C]) ------
log "1. Ubuntu Pro / 패키지"
if pro status --format json 2>/dev/null | grep -qE '"attached": ?true'; then
  log "  Ubuntu Pro 이미 연결됨"
else
  TOKEN=$(get_secret UBUNTU_PRO_TOKEN "${UBUNTU_PRO_TOKEN_SSM_PARAM:-/vuln-lab/ubuntu-pro-token}")
  if [ -n "$TOKEN" ]; then
    CFG=$(mktemp); chmod 600 "$CFG"
    printf 'token: %s\n' "$TOKEN" > "$CFG"          # 토큰을 명령줄(ps)에 노출하지 않음
    pro attach --attach-config "$CFG" >/dev/null
    rm -f "$CFG"; unset TOKEN
  else
    warn "Ubuntu Pro 토큰 없음(UBUNTU_PRO_TOKEN / UBUNTU_PRO_TOKEN_SSM_PARAM, 기본 /vuln-lab/ubuntu-pro-token) - ESM 미연결 상태로 진행"
  fi
fi
# 실서버: esm-infra, esm-apps, livepatch 모두 enabled [E]
if pro status --format json 2>/dev/null | grep -qE '"attached": ?true'; then
  for s in esm-infra esm-apps livepatch; do pro enable "$s" --assume-yes >/dev/null 2>&1 || true; done
fi

apt-get update -q
# 9/29 apt upgrade + 10/2 U-64 보안 업데이트(dist-upgrade)를 먼저 끝내 둔다
# (나중에 nginx-common 이 갱신되며 기본 html 을 되살리는 일을 막기 위해 순서를 앞당김)
apt-get -y "${APT_O[@]}" dist-upgrade
# 9/29: libpam-pwquality 설치(U-02), nginx headers-more 모듈(WEB-16 more_clear_headers)
apt-get install -y "${APT_O[@]}" libpam-pwquality libnginx-mod-http-headers-more-filter
# 실서버에 설치돼 있음(10/2 보안 업데이트 목록의 imagemagick 6종 [C U-64]).
# TODO(확인필요) 설치 사유·사용처 미확인. 필요 없다고 확인되면 이 줄을 지운다.
apt-get install -y "${APT_O[@]}" imagemagick
# 10/2 U-65: systemd-timesyncd -> chrony (설치 시 timesyncd 자동 제거) [C U-65_chrony]
dpkg -s chrony >/dev/null 2>&1 || apt-get install -y "${APT_O[@]}" chrony

# CloudWatch Agent: 실서버 active, /etc/systemd/system/amazon-cloudwatch-agent.service, 계정 cwagent [C precheck]
if ! dpkg -s amazon-cloudwatch-agent >/dev/null 2>&1; then
  # TODO(확인필요) 원래 설치 방법·버전·에이전트 설정(json) 미확보. AWS 공식 배포 경로로 설치만 하고
  #                설정 적용·기동은 하지 않는다(설정 확보 후 amazon-cloudwatch-agent-ctl -a fetch-config ...).
  T=$(mktemp -d)
  curl -fsSL -o "$T/cwa.deb" \
    "https://amazoncloudwatch-agent-${REGION}.s3.${REGION}.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb"
  dpkg -i -E "$T/cwa.deb"
  rm -rf "$T"
fi

# ---- 2. 계정·PAM ---------------------------------------------------------------
log "2. 계정 / PAM"
backup /etc/login.defs /etc/security/pwquality.conf /etc/pam.d/common-password /etc/pam.d/common-auth \
       /etc/pam.d/common-account /etc/pam.d/su /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive

# [9/29] U-02 기간·길이, U-13 SHA512, U-30 UMASK/USERGROUPS_ENAB [E U-02·U-13·U-30, D U-02]
set_kv /etc/login.defs PASS_MAX_DAYS 90
set_kv /etc/login.defs PASS_MIN_DAYS 1
set_kv /etc/login.defs PASS_WARN_AGE 7
set_kv /etc/login.defs PASS_MIN_LEN 8
set_kv /etc/login.defs ENCRYPT_METHOD SHA512
set_kv /etc/login.defs UMASK 022
set_kv /etc/login.defs USERGROUPS_ENAB no
# [9/29] pwquality: minlen=8, minclass=3 [C precheck 출력]
set_eq /etc/security/pwquality.conf minlen 8
set_eq /etc/security/pwquality.conf minclass 3
chage -m 1 -M 90 team                                   # [9/29] team 1/90 [E U-02]

# [9/29] U-03 pam_tally2 (common-auth 1행, common-account 끝) [E U-03 원문 인용]
grep -qE '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_tally2\.so' /etc/pam.d/common-auth || \
  sed -i '1i auth required pam_tally2.so deny=5 unlock_time=120 onerr=fail audit' /etc/pam.d/common-auth
ensure_line /etc/pam.d/common-account 'account required pam_tally2.so'

# [9/29] U-06 su 제한: wheel 그룹(구성원 team, 실서버 GID 1002) + pam_wheel + su 4750 [E U-06·U-08·U-09]
getent group wheel >/dev/null || groupadd wheel
usermod -aG wheel team
if ! grep -qE '^[[:space:]]*auth[[:space:]].*pam_wheel\.so' /etc/pam.d/su; then
  # TODO(확인필요) 실서버 pam_wheel 줄의 정확한 형식 미확보('wheel 그룹 제한 적용'만 확인됨)
  sed -i '/^auth[[:space:]]\+sufficient[[:space:]]\+pam_rootok\.so/a auth       required   pam_wheel.so group=wheel' /etc/pam.d/su
fi
chgrp wheel /usr/bin/su; chmod 4750 /usr/bin/su

# [9/29] U-07 ubuntu(클라우드 기본) 계정: nologin + 잠금 [E U-07·U-11]
if id ubuntu >/dev/null 2>&1; then usermod -s /usr/sbin/nologin ubuntu; passwd -l ubuntu >/dev/null; fi

# [9/29] U-30 pam_umask umask=022 (common-session, -noninteractive) [E U-30]
for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  grep -qE '^session[[:space:]].*pam_umask\.so.*umask=022' "$f" || \
    sed -i -E 's/^(session[[:space:]]+optional[[:space:]]+pam_umask\.so)[[:space:]]*$/\1 umask=022/' "$f"
  grep -qE 'pam_umask\.so.*umask=022' "$f" || warn "$f 에 pam_umask umask=022 가 없다(수동 확인)"
done

# [10/2] U-02 최근 비밀번호 기억 + 복잡성 -1 + root 기간 [A web-adm1 U-02, C U-02_final]
grep -q 'pam_pwhistory' /etc/pam.d/common-password || \
  sed -i '/^password.*pam_pwquality\.so/a password    requisite    pam_pwhistory.so use_authtok remember=4 enforce_for_root' /etc/pam.d/common-password
for l in 'dcredit = -1' 'ucredit = -1' 'lcredit = -1' 'ocredit = -1' 'enforce_for_root'; do
  ensure_line /etc/security/pwquality.conf "$l"
done
chage -m 1 -M 90 -W 7 root
ORDER=$(grep '^password' /etc/pam.d/common-password | grep -oE 'pam_(pwquality|pwhistory|unix)\.so' | tr '\n' ' ')
[ "$ORDER" = "pam_pwquality.so pam_pwhistory.so pam_unix.so " ] || warn "common-password 순서 이상: $ORDER"

# ---- 3. 파일 권한 ----------------------------------------------------------------
log "3. 파일 권한"
# [9/29] U-18 /etc/shadow root:root 400 [E U-04·U-18]
chown root:root /etc/shadow; chmod 400 /etc/shadow
# [9/29] U-21 rsyslog 설정 root 640 [E U-21, D U-21]
chown root:root /etc/rsyslog.conf /etc/rsyslog.d/*.conf
chmod 640 /etc/rsyslog.conf /etc/rsyslog.d/*.conf
# [9/29] U-23 제거권고 SUID/SGID 해제: unix_chkpwd·at·newgrp·wall -> 755 [E U-23]
for f in /usr/sbin/unix_chkpwd /usr/bin/at /usr/bin/newgrp /usr/bin/wall; do
  if [ -e "$f" ]; then chmod 755 "$f"; fi
done
# [9/29] U-37 cron 관련 파일: /etc/crontab 640, cron.allow(root) 640, at.deny root:daemon 640, cron.d/* 640 [E U-37]
chmod 640 /etc/crontab
[ "$(cat /etc/cron.allow 2>/dev/null || true)" = root ] || echo root > /etc/cron.allow
chown root:root /etc/cron.allow; chmod 640 /etc/cron.allow
if [ -f /etc/at.deny ]; then chown root:daemon /etc/at.deny; chmod 640 /etc/at.deny; fi
find /etc/cron.d -maxdepth 1 -type f ! -name '.*' -exec chmod 640 {} +

# [10/2] U-23 bsd-write SGID 제거(패키지 갱신 후에도 유지) [A, C U-23]
statov root tty 0755 /usr/bin/bsd-write
# [10/2] U-37 crontab·at root 750(SGID 제거), cron.* 디렉터리 640 [A, C U-37]
statov root root 0750 /usr/bin/crontab
statov root root 0750 /usr/bin/at
for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do statov root root 0640 "$d"; done

# [10/2] U-32 홈 디렉터리 존재 (nologin 계정은 셸 유지) [A, C U-32]
if [ "$(getent passwd irc | cut -d: -f6 || true)" != /var/lib/irc ]; then usermod -d /var/lib/irc irc; fi
for u in lp news uucp list irc gnats nobody messagebus syslog _apt tcpdump ec2-instance-connect cwagent; do
  h=$(getent passwd "$u" | cut -d: -f6 || true)
  { [ -n "$h" ] && [ ! -d "$h" ]; } || continue
  mkdir -p "$h"
  case "$h" in
    /nonexist*) chown root:root "$h"; chmod 755 "$h" ;;
    *)          chown "$u": "$h";     chmod 750 "$h" ;;
  esac
done

# ---- 4. 세션·배너·접속 제한 (9/29) -----------------------------------------------
log "4. 세션 / 배너 / TCP Wrapper"
backup /etc/profile /etc/ssh/sshd_config /etc/hosts.allow /etc/hosts.deny /etc/issue /etc/issue.net /etc/motd
# U-12·U-30: /etc/profile 28~30행 = TMOUT=600 / export TMOUT / umask 022 (profile.d 루프 뒤) [E U-12·U-30]
ensure_line /etc/profile 'TMOUT=600'
ensure_line /etc/profile 'export TMOUT'
ensure_line /etc/profile 'umask 022'

# U-62 경고문: /etc/issue, /etc/issue.net, /etc/motd + sshd Banner /etc/issue.net [E U-62]
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
if ! grep -qE '^[[:space:]]*Banner[[:space:]]+/etc/issue\.net' /etc/ssh/sshd_config; then
  if grep -qE '^#?[[:space:]]*Banner[[:space:]]' /etc/ssh/sshd_config; then
    sed -i -E 's|^#?[[:space:]]*Banner[[:space:]].*|Banner /etc/issue.net|' /etc/ssh/sshd_config
  else
    echo 'Banner /etc/issue.net' >> /etc/ssh/sshd_config
  fi
fi
sshd -t; systemctl reload ssh

# U-28 TCP Wrapper: SSH 는 bastion(10.0.0.176)만 허용 [E U-28 원문 인용, D U-28 'hosts.allow 1줄']
# TODO(확인필요) 두 파일의 주석 등 나머지 내용은 미확보 - 규칙 줄만 맞춘다(allow 를 먼저 넣어 잠김 방지)
ensure_line /etc/hosts.allow 'sshd : 10.0.0.176'
ensure_line /etc/hosts.deny 'ALL : ALL'

# ---- 5. Nginx --------------------------------------------------------------------
log "5. Nginx"
backup "$NG" "$SITE" /etc/logrotate.d/nginx
# [9/29] nginx 재설치(dpkg.log '<none>' configure)로 nginx.conf 가 패키지 기본값이 됨 [E WEB-07, C precheck2]
#        user_data 의 자체 nginx.conf(로그 포맷 main, who.html 서버 블록)면 패키지 기본값으로 되돌린다.
if grep -qE 'who\.html|log_format main' "$NG" 2>/dev/null; then
  rm -f "$NG"
  apt-get install -y --reinstall -o Dpkg::Options::=--force-confmiss nginx-common
fi
# [9/29] http 블록 ssl_protocols TLSv1.2 TLSv1.3 [E WEB-20]
# TODO(확인필요) 이 줄의 정확한 형식(줄 끝 주석 등)과 그 밖의 9/29 nginx.conf 수정 여부 미확보
#                (확인된 것: 1~15행·35~50행이 패키지 기본값과 같음 [C precheck2])
sed -i -E 's/^([[:space:]]*)ssl_protocols[[:space:]].*/\1ssl_protocols TLSv1.2 TLSv1.3;/' "$NG"
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/*.conf    # 활성 사이트는 clinic-admin 하나 [E WEB-04~06]

# [9/29] 웹 루트 /srv/clinic-admin root:www-data 750, error.html 640 [E WEB-11·WEB-14·WEB-22]
install -d -o root -g www-data -m 750 /srv/clinic-admin
if [ -f "$FILES/error.html" ]; then
  install -o root -g www-data -m 640 "$FILES/error.html" /srv/clinic-admin/error.html
elif [ ! -f /srv/clinic-admin/error.html ]; then
  # TODO(확인필요) error.html(208B, 일반 안내 문구) 내용 미확보 - files/error.html 을 넣고 다시 실행
  warn "/srv/clinic-admin/error.html 없음 - error_page 응답 본문이 비게 된다"
fi
install -d -o root -g root -m 755 /opt/clinic                     # 실서버에 빈 디렉터리로 존재 [E U-15·U-31]

# [9/29] 자체서명 인증서 (CN=admin.zerodayclinic.p-e.kr, 1년, key 600 root, crt 644) [E WEB-14·WEB-20]
if [ ! -s /etc/ssl/private/clinic-admin.key ] || [ ! -s /etc/ssl/certs/clinic-admin.crt ]; then
  # TODO(확인필요) 실서버 키 알고리즘·길이와 CN 이외 주체 필드 미확보 (개인키 자체는 재현 불가 - 새로 만든다)
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=admin.zerodayclinic.p-e.kr" \
    -keyout /etc/ssl/private/clinic-admin.key -out /etc/ssl/certs/clinic-admin.crt 2>/dev/null
fi
chown root:root /etc/ssl/private/clinic-admin.key /etc/ssl/certs/clinic-admin.crt
chmod 600 /etc/ssl/private/clinic-admin.key
chmod 644 /etc/ssl/certs/clinic-admin.crt

# [10/6] 사이트 설정 = files/clinic-admin (resolver 10.0.0.2 + 변수 proxy_pass + connect_timeout 5s) [F]
if ! cmp -s "$FILES/clinic-admin" "$SITE"; then
  if [ -e "$SITE" ]; then cp -p "$SITE" "/root/clinic-admin.bak.$D"; fi
  install -o root -g root -m 640 "$FILES/clinic-admin" "$SITE"
fi
ln -sfn "$SITE" /etc/nginx/sites-enabled/clinic-admin

# [10/2] U-67·WEB-26: nginx 로그를 syslog 로 (http 블록 + main 레벨) [A, C U-67_WEB-26·U-67_followup]
sed -i -e 's#^\([[:space:]]*\)access_log /var/log/nginx/access.log;#\1access_log syslog:server=unix:/dev/log,tag=nginx;#' \
       -e 's#^\([[:space:]]*\)error_log /var/log/nginx/error.log;#\1error_log syslog:server=unix:/dev/log,tag=nginx;#' "$NG"
if ! grep -qE '^error_log ' "$NG"; then
  sed -i '/^pid \/run\/nginx.pid;$/a error_log syslog:server=unix:/dev/log,tag=nginx;\nerror_log stderr emerg;   # main-level non-file log so nginx does not reopen/chown default /var/log/nginx/error.log (U-67/WEB-26)' "$NG"
fi
REM=$(grep -RnE '^[[:space:]]*(access_log|error_log)[[:space:]]+/' /etc/nginx/ || true)
[ -z "$REM" ] || warn "파일 경로 로그 지시어가 남아 있다: $REM"
sed -i 's/create 0640 www-data adm/create 0640 root adm/' /etc/logrotate.d/nginx

# [9/29] WEB-14: /etc/nginx 750, 하위 설정 디렉터리 750, 설정 파일 640 [E WEB-14]
chmod 750 /etc/nginx
for d in conf.d sites-available sites-enabled snippets; do
  if [ -d "/etc/nginx/$d" ]; then chmod 750 "/etc/nginx/$d"; fi
done
find /etc/nginx -type f -exec chmod 640 {} +

# [10/2] WEB-07 기본 html 제거 + [9/29] who.html 제거 [A, C WEB-07, E WEB-07]
install -d -m 700 /root/backup_web07
for f in /usr/share/nginx/html/index.html /var/www/html/index.nginx-debian.html; do
  if [ -e "$f" ]; then mv -f "$f" /root/backup_web07/; fi
done
rm -f /usr/share/nginx/html/who.html

nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

# [10/2] 이전 nginx 로그 보관, error.log 는 root:adm 640, /var/log/nginx root:adm 750(statoverride)
mkdir -p /root/u67_bak/nginx_logs
for f in /var/log/nginx/*.log.* /var/log/nginx/access.log; do
  if [ -e "$f" ]; then mv -f "$f" /root/u67_bak/nginx_logs/; fi
done
if [ -e /var/log/nginx/error.log ]; then chown root:adm /var/log/nginx/error.log; chmod 640 /var/log/nginx/error.log; fi
statov root adm 0750 /var/log/nginx
nginx -s reopen

# ---- 6. 시스템 로그 ----------------------------------------------------------------
log "6. 로그(rsyslog / tmpfiles / logrotate)"
backup /etc/rsyslog.conf /etc/logrotate.conf /etc/logrotate.d/wtmp /etc/logrotate.d/btmp
# [9/29] U-66 logrotate 보존 104주 [E U-66]
sed -i -E 's/^rotate[[:space:]]+[0-9]+/rotate 104/' /etc/logrotate.conf
# [9/29] logrotate wtmp/btmp 생성 권한 0644/0600 [E U-67]
# TODO(확인필요) 실서버에서 바꾼 파일 위치는 미기재(값만 확인) - Ubuntu 20.04 기본 위치(logrotate.d)에 적용
if [ -f /etc/logrotate.d/wtmp ]; then sed -i 's/create 0664 root utmp/create 0644 root utmp/' /etc/logrotate.d/wtmp; fi
if [ -f /etc/logrotate.d/btmp ]; then sed -i 's/create 0660 root utmp/create 0600 root utmp/' /etc/logrotate.d/btmp; fi

# [10/2] U-67 1) utmp 계열 tmpfiles 덮어쓰기 [A, C U-67_WEB-26]
cp -p /usr/lib/tmpfiles.d/var.conf /etc/tmpfiles.d/var.conf
sed -i -e 's#^f /var/log/wtmp 0664#f /var/log/wtmp 0644#' -e 's#^f /var/log/btmp 0660#f /var/log/btmp 0600#' \
       -e 's#^f /var/log/lastlog 0664#f /var/log/lastlog 0644#' /etc/tmpfiles.d/var.conf
chmod 644 /var/log/wtmp /var/log/lastlog
chmod 600 /var/log/btmp
if [ -e /var/log/btmp.1.gz ]; then chmod 600 /var/log/btmp.1.gz; fi
# 2) rsyslog 를 root 로 기록
sed -i -e 's/^\$FileOwner syslog/$FileOwner root/' -e 's/^\$PrivDropToUser syslog/#&/' -e 's/^\$PrivDropToGroup syslog/#&/' /etc/rsyslog.conf
rsyslogd -N1 >/dev/null 2>&1
systemctl restart rsyslog
for f in /var/log/syslog* /var/log/auth.log* /var/log/kern.log*; do
  if [ -e "$f" ]; then chown root "$f"; fi
done
# 3) /var/log 755 유지 (패키지 00rsyslog.conf 를 같은 이름으로 덮어씀)
install -o root -g root -m 644 "$FILES/00rsyslog.conf" /etc/tmpfiles.d/00rsyslog.conf
chmod 755 /var/log
# 4) cloud-init 로그 소유자 root:adm
install -o root -g root -m 644 "$FILES/99-logperm.cfg" /etc/cloud/cloud.cfg.d/99-logperm.cfg
for f in /var/log/cloud-init.log*; do
  if [ -e "$f" ]; then chown root "$f"; fi
done

# ---- 7. 시각 동기화 (10/2 U-65: chrony -> AWS Time Sync) ------------------------------
log "7. chrony"
backup /etc/chrony/chrony.conf
# 기존 pool/server 줄은 주석, 169.254.169.123 한 줄만 사용 [C U-65_chrony]
sed -i -E '/169\.254\.169\.123/!s/^(pool|server)([[:space:]])/#\1\2/' /etc/chrony/chrony.conf
grep -q '^server 169.254.169.123 ' /etc/chrony/chrony.conf || \
  echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' >> /etc/chrony/chrony.conf
systemctl enable chrony >/dev/null 2>&1
systemctl restart chrony

# ---- 8. /etc/systemd 권한 + 유지 유닛 (10/2 U-20) ----------------------------------------
log "8. U-20 /etc/systemd 600 + kisa-u20-perm.path"
# TODO(확인필요) /etc/systemd/system/clinic-admin.service(실서버: disabled·inactive 잔존 유닛) 내용 미확보 - 재현하지 않음
find /etc/systemd -xdev -type f -exec chown root {} + -exec chmod 600 {} +
for u in kisa-u20-perm.service kisa-u20-perm.path; do
  if ! cmp -s "$FILES/$u" "/etc/systemd/system/$u"; then
    install -o root -g root -m 600 "$FILES/$u" "/etc/systemd/system/$u"
  fi
done
systemctl daemon-reload
systemctl enable --now kisa-u20-perm.service kisa-u20-perm.path >/dev/null 2>&1

# ---- 9. 확인 (읽기 전용 출력) ---------------------------------------------------------
log "9. 확인"
echo "  os/kernel     : $(lsb_release -ds 2>/dev/null) / $(uname -r)"
echo "  nginx         : $(systemctl is-active nginx)  /health=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1/health || true)"
echo "  rsyslogd user : $(ps -o user= -C rsyslogd | head -1)"
echo "  chrony        : $(systemctl is-active chrony)  timesyncd=$(systemctl is-active systemd-timesyncd 2>/dev/null || true)"
echo "  U-20 path unit: $(systemctl is-active kisa-u20-perm.path)  비적합 파일=$(find /etc/systemd -xdev -type f \( ! -user root -o -perm /177 \) | wc -l)"
echo "  statoverride  : $(dpkg-statoverride --list | grep -cE 'crontab|/usr/bin/at|bsd-write|cron\.|/var/log/nginx') 건"
echo "  /var/log/nginx: $(stat -c '%a %U:%G' /var/log/nginx)  www-data 파일=$(find /var/log/nginx -user www-data | wc -l)"
echo "  /var/log 비적합: $(find /var/log -xdev -maxdepth 4 -type f \( ! -user root -o -perm /7133 \) | wc -l)"
echo "  PAM password  : $ORDER"
echo "  failed units  : [$(systemctl --failed --no-legend --plain | awk '{print $1}' | xargs)]"

if [ -f /var/run/reboot-required ]; then
  if [ "${REBOOT:-0}" = 1 ]; then
    shutdown -r +1 "baseline: kernel update reboot (10/2 U-64)"
  else
    warn "재부팅 필요(/var/run/reboot-required) - REBOOT=1 로 다시 실행하거나 직접 재부팅"
  fi
fi
log "완료"
