#!/usr/bin/env bash
#==============================================================================
# KISA 주요정보통신기반시설 기술적 취약점 점검 (Unix/Linux)  U-01 ~ U-67
#  - "주요정보통신기반시설 기술적 취약점 분석·평가 상세가이드" 판단기준 적용
#  - 각 항목 앞에 [기준] 주석으로 양호/취약 조건 명시. 판단은 이 기준으로만 한다.
#  - 읽기 전용(READ-ONLY): 자동 조치(수정) 없음. 판정 + 근거만 출력
#  - 대상: RHEL 계열(Rocky/Amazon Linux/RHEL/CentOS) 및 Debian 계열(Debian/Ubuntu)
#  - 권장 실행: sudo bash kisa_unix_check.sh   (shadow / iptables / sshd -T / lastlog)
#
# 판정 표기
#   양호     : 판단기준 충족
#   취약     : 판단기준 미충족
#   N/A      : 점검 대상 서비스/파일 미사용 → 위협 없음
#   수동확인 : 정책 수립 여부 등 시스템 상태만으로 확정 불가(인터뷰 필요) 잔여 항목
#==============================================================================

# ---- 실행 셸 보정 ----
# 이 스크립트는 연관배열(declare -A) 등 bash 전용 문법을 사용한다.
# Ubuntu/Debian 에서 'sh kisa_unix_check.sh' 로 실행하면 /bin/sh(dash)라 즉시 실패하므로
# bash 로 실행되지 않았으면 bash 로 재실행한다. (없으면 명확히 에러)
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
  echo "이 스크립트는 bash 로 실행해야 합니다:  sudo bash $0" >&2
  exit 1
fi

# ---- 인자 파싱 ----
JSON_FILE=""; NOCOLOR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)     JSON_FILE="${2:-}"; shift 2 ;;
    --no-color) NOCOLOR=1; shift ;;
    *)          shift ;;
  esac
done

# ---- 색상 ----
if [ -t 1 ] && [ "$NOCOLOR" -eq 0 ]; then
  G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; B='\033[1;34m'; C='\033[1;36m'; W='\033[1m'; N='\033[0m'
else
  G=''; R=''; Y=''; B=''; C=''; W=''; N=''
fi

good=0; vuln=0; na=0; man=0
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

# ---- 중요도 (상세가이드 기준) ----
declare -A IMP=(
  [U-01]=상 [U-02]=상 [U-03]=상 [U-04]=상 [U-05]=상 [U-06]=상 [U-07]=하 [U-08]=중 [U-09]=하 [U-10]=중 [U-11]=하 [U-12]=하 [U-13]=중
  [U-14]=상 [U-15]=상 [U-16]=상 [U-17]=상 [U-18]=상 [U-19]=상 [U-20]=상 [U-21]=상 [U-22]=상 [U-23]=상 [U-24]=상 [U-25]=상 [U-26]=상 [U-27]=상 [U-28]=상 [U-29]=하 [U-30]=중 [U-31]=중 [U-32]=중 [U-33]=하
  [U-34]=상 [U-35]=상 [U-36]=상 [U-37]=상 [U-38]=상 [U-39]=상 [U-40]=상 [U-41]=상 [U-42]=상 [U-43]=상 [U-44]=상 [U-45]=상 [U-46]=상 [U-47]=상 [U-48]=중 [U-49]=상 [U-50]=상 [U-51]=중 [U-52]=중 [U-53]=하 [U-54]=중 [U-55]=중 [U-56]=하 [U-57]=중 [U-58]=중 [U-59]=상 [U-60]=중 [U-61]=상 [U-62]=하 [U-63]=중
  [U-64]=상 [U-65]=중 [U-66]=중 [U-67]=중
)

JBUF=""
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/ }; s=${s//$'\r'/ }; s=${s//$'\n'/ }
  printf '%s' "$s"
}

# 사용: rep CODE "제목" STATUS "근거1" "근거2" ...
rep() {
  local code="$1" title="$2" status="$3"; shift 3
  local tag kstat
  case "$status" in
    GOOD) good=$((good+1)); tag="${G}양호${N}";   kstat="양호";;
    VULN) vuln=$((vuln+1)); tag="${R}취약${N}";   kstat="취약";;
    NA)   na=$((na+1));     tag="${Y}N/A${N}";    kstat="N/A";;
    MAN)  man=$((man+1));   tag="${B}수동확인${N}"; kstat="수동확인";;
  esac
  printf "${C}%-6s${N} %-46s [%b]\n" "$code" "$title" "$tag"
  local l
  for l in "$@"; do printf "         ${W}·${N} %s\n" "$l"; done
  local ev="" first=1 e
  for l in "$@"; do
    e=$(json_escape "$l")
    if [ "$first" -eq 1 ]; then ev="\"$e\""; first=0; else ev="$ev,\"$e\""; fi
  done
  JBUF="${JBUF}{\"code\":\"$code\",\"importance\":\"${IMP[$code]}\",\"title\":\"$(json_escape "$title")\",\"status\":\"$kstat\",\"evidence\":[$ev]},"
}

#------------------------------------------------------------------------------
# 공통 헬퍼
#------------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# 미적용 보안 업데이트 개수 조회 (계열/패키지관리자 자동 분기)
#  $1 = dnf/yum updateinfo 에서 찾을 grep 패턴 (예: 'postfix|sendmail', 'bind')
#  $2 = apt list --upgradable 에서 찾을 grep 패턴 (예: '^(postfix|sendmail)/')
#  패턴을 비우면 전체 보안 업데이트 건수를 센다.
#  dnf > yum > apt 순으로 '하나만' 실행 → Rocky(yum=dnf 심링크) 중복 실행/이중 카운트 방지.
sec_update_count() {
  local dpat="$1" apat="$2"
  if have dnf; then
    if [ -n "$dpat" ]; then dnf -q updateinfo list --security 2>/dev/null | grep -icE "$dpat"
    else dnf -q updateinfo list --security 2>/dev/null | grep -cE '/|[0-9]{4}'; fi
  elif have yum; then   # Amazon Linux 2 / CentOS 7 등 yum 세대
    if [ -n "$dpat" ]; then yum -q updateinfo list security 2>/dev/null | grep -icE "$dpat"
    else yum -q updateinfo list security 2>/dev/null | grep -icE 'ALAS|RHSA|CVE|[0-9]{4}-[0-9]+'; fi
  elif have apt; then
    if [ -n "$apat" ]; then apt list --upgradable 2>/dev/null | grep -icE "$apat"
    else apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst.*-security'; fi
  else
    echo "?"
  fi
}

# 8진수 권한 비교 : perm <= max ?  (stat -c %a 출력 그대로 사용)
perm_le() {
  local p m
  p=$(( 8#${1:-7777} )) 2>/dev/null || return 1
  m=$(( 8#${2:-0} ))
  [ "$p" -le "$m" ]
}
# (perm & mask) 비트가 하나라도 켜져 있으면 참  (예: 타 사용자 쓰기 검사 perm_has 002)
perm_has() { [ "$(( 8#${1:-0} & 8#$2 ))" -ne 0 ]; }

# 파일 소유자·권한 → GOOD/VULN/NA 직접 판정
chk_perm() {  # code title file maxperm "owner1 owner2 ..."
  local code=$1 title=$2 f=$3 maxp=$4 owners=$5 p o
  if [ ! -e "$f" ]; then rep "$code" "$title" NA "$f 미존재 → 점검 대상 없음"; return; fi
  p=$(stat -c '%a' "$f" 2>/dev/null); o=$(stat -c '%U' "$f" 2>/dev/null)
  case " $owners " in
    *" $o "*) : ;;
    *) rep "$code" "$title" VULN "$f 소유자=$o 권한=$p  (기준: 소유자 [$owners], 권한 $maxp 이하)"; return ;;
  esac
  if perm_le "$p" "$maxp"; then
    rep "$code" "$title" GOOD "$f 소유자=$o 권한=$p  (기준: 소유자 [$owners], 권한 $maxp 이하)"
  else
    rep "$code" "$title" VULN "$f 소유자=$o 권한=$p  (기준: 소유자 [$owners], 권한 $maxp 이하)"
  fi
}

# 설정값 추출(주석 제외)
conf_line() { grep -hiE "$1" "${@:2}" 2>/dev/null | grep -vE '^[[:space:]]*#' | tail -1; }

pkg_installed() {
  { have rpm && rpm -q "$1" >/dev/null 2>&1; } || { have dpkg && dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'; }
}
svc_active()  { systemctl is-active   "$1" 2>/dev/null | grep -q '^active$'; }
svc_enabled() { systemctl is-enabled  "$1" 2>/dev/null | grep -qE '^(enabled|static)$'; }
svc_on()      { svc_active "$1" || { svc_active "${1}.socket" ; } ; }
proc_run()    { pgrep -x "$1" >/dev/null 2>&1 || pgrep -f "(^|[/ ])$1( |$)" >/dev/null 2>&1; }

_listen() { { ss -Hlntu 2>/dev/null | awk '{print $5}'; netstat -lntun 2>/dev/null | awk '/^(tcp|udp)/{print $4}'; } ; }
port_listen()     { _listen | grep -qE "[:.]$1\$"; }
port_listen_ext() { _listen | grep -E "[:.]$1\$" | grep -qvE '^127\.|^\[?::1\]?[:.]|^::1[:.]'; }

never_login() {   # 0=한번도 로그인 안함, 1=로그인 이력 있음, 2=확인불가
  have lastlog || return 2
  local o; o=$(lastlog -u "$1" 2>/dev/null | tail -n +2)
  [ -z "$o" ] && return 2
  echo "$o" | grep -qiE 'Never logged in|\*\*Never' && return 0
  return 1
}
acct_locked() { case "$(passwd -S "$1" 2>/dev/null | awk '{print $2}')" in L|LK) return 0;; *) return 1;; esac; }

# ---- OS / 계열 정보 ----
. /etc/os-release 2>/dev/null
FAM="unknown"
have rpm  && FAM="rhel"
have dpkg && FAM="deb"
UID_MIN=$(awk '/^[[:space:]]*UID_MIN/{print $2}' /etc/login.defs 2>/dev/null); UID_MIN=${UID_MIN:-1000}
CLOUD_DEFAULT=" ec2-user ubuntu rocky centos almalinux fedora debian admin cloud-user opc bitnami cloud_user "

if [ "$FAM" = "rhel" ]; then
  PAM_PW="/etc/pam.d/system-auth /etc/pam.d/password-auth"
  PAM_AUTH="/etc/pam.d/system-auth /etc/pam.d/password-auth"
  LOG_FILES="/var/log/messages /var/log/secure /var/log/maillog /var/log/cron /var/log/boot.log /var/log/dmesg /var/log/spooler"
else
  PAM_PW="/etc/pam.d/common-password"
  PAM_AUTH="/etc/pam.d/common-auth /etc/pam.d/common-account"
  LOG_FILES="/var/log/syslog /var/log/auth.log /var/log/kern.log /var/log/mail.log /var/log/messages /var/log/debug /var/log/daemon.log"
fi
LOG_FILES_UTMP="/var/log/wtmp /var/log/btmp /var/log/lastlog"

# sshd 유효 설정 1회 캐시(root 일 때만). Ubuntu/Debian 은 sshd_config.d/*.conf drop-in 을 쓰므로
# sshd -T(전체 반영값) → sshd_config + sshd_config.d/*.conf 순으로 조회한다.
SSHD_T=""
[ "$IS_ROOT" -eq 1 ] && command -v sshd >/dev/null 2>&1 && SSHD_T=$(sshd -T 2>/dev/null)
sshd_val() {  # $1 = 소문자 키워드 (예: permitrootlogin)
  local v
  v=$(printf '%s\n' "$SSHD_T" | awk -v k="$1" 'tolower($1)==k{print $2; exit}')
  [ -z "$v" ] && v=$(conf_line "^[[:space:]]*$1[[:space:]]" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}')
  printf '%s' "$v"
}

echo
echo -e "${W}==============================================================${N}"
echo -e "${W} KISA Unix/Linux 취약점 점검 (U-01~U-67)  READ-ONLY${N}"
echo -e "${W}==============================================================${N}"
echo -e " 호스트 : $(hostname)"
echo -e " OS     : ${PRETTY_NAME:-unknown}  (family=$FAM, UID_MIN=$UID_MIN)"
echo -e " 시각   : $(date '+%Y-%m-%d %H:%M:%S')"
[ "$IS_ROOT" -ne 1 ] && echo -e " ${Y}주의: root 권한이 아니므로 shadow/iptables/sshd -T/lastlog 등 일부 항목은 '수동확인'으로 표기될 수 있습니다.${N}"
{ have ss || have netstat; } || echo -e " ${Y}주의: ss/netstat 둘 다 없어 포트 기반 서비스 점검(U-34/38/39/44/52 등)이 부정확할 수 있습니다. iproute2(ss) 설치 권장.${N}"
{ have dnf || have yum || have apt; } || echo -e " ${Y}주의: dnf/yum/apt 를 찾지 못해 보안 패치 점검(U-45/49/64)이 '확인불가'로 처리됩니다.${N}"
echo

#==============================================================================
echo -e "${W}[ 1. 계정 관리 ]${N}"
#==============================================================================

# U-01 root 계정 원격 접속 제한
# [기준] 양호 - 원격 터미널 서비스 미사용, 또는 사용 시 root 직접 원격 접속 차단
#        취약 - 원격 터미널 서비스 사용 중 root 직접 원격 접속 허용
telnet_on=0
port_listen 23 && telnet_on=1
svc_active telnet.socket >/dev/null 2>&1 && telnet_on=1
proc_run "in.telnetd" && telnet_on=1
pkg_installed telnet-server && systemctl is-enabled telnet.socket >/dev/null 2>&1 && telnet_on=1
if [ "$telnet_on" -eq 0 ]; then
  tv=GOOD; te="Telnet 미사용"
else
  if [ ! -e /etc/securetty ]; then tv=VULN; te="Telnet 사용 중 + /etc/securetty 없음(root 원격 제한 없음)"
  elif grep -vE '^[[:space:]]*#' /etc/securetty 2>/dev/null | grep -qE 'pts|:0'; then tv=VULN; te="/etc/securetty 에 pts/원격 tty 존재(root 원격 접속 허용)"
  elif ! grep -qE 'pam_securetty' /etc/pam.d/login /etc/pam.d/remote 2>/dev/null; then tv=VULN; te="securetty엔 pts 없으나 pam_securetty 미적용"
  else tv=GOOD; te="securetty에 원격 tty 없음 + pam_securetty 적용"; fi
fi
ssh_used=0
{ [ -e /etc/ssh/sshd_config ] || port_listen 22 || svc_active sshd || svc_active ssh; } && ssh_used=1
if [ "$ssh_used" -eq 0 ]; then sv=NA; se="SSH 미사용"
else
  prl=$(sshd_val permitrootlogin)
  case "$prl" in
    no)                              sv=GOOD; se="PermitRootLogin=no" ;;
    yes)                             sv=VULN; se="PermitRootLogin=yes (root 직접 접속 허용)" ;;
    prohibit-password|without-password|forced-commands-only)
                                     sv=VULN; se="PermitRootLogin=$prl (키/제한 기반이나 root 직접 접속 가능 → 상세가이드상 '차단' 아님)" ;;
    "")  if [ "$IS_ROOT" -eq 1 ]; then sv=VULN; se="PermitRootLogin 미지정 → OpenSSH 기본값 prohibit-password (root 접속 가능)"
         else sv=MAN; se="PermitRootLogin 미지정 + 비-root 실행으로 유효값 확인 불가 → root로 'sshd -T' 재확인"; fi ;;
    *)                               sv=VULN; se="PermitRootLogin=$prl" ;;
  esac
fi
if   [ "$tv" = VULN ] || [ "$sv" = VULN ]; then fv=VULN
elif [ "$sv" = MAN ];                       then fv=MAN
else fv=GOOD; fi
rep U-01 "root 계정 원격 접속 제한" $fv "Telnet: $te" "SSH: $se"

# U-02 비밀번호 관리정책 설정
# [기준] 양호 - 최대사용기간·최소길이·복잡성 등 비밀번호 관리 정책이 설정된 경우
#        취약 - 정책이 설정되지 않은 경우
maxd=$(conf_line '^[[:space:]]*PASS_MAX_DAYS' /etc/login.defs | awk '{print $2}')
mind=$(conf_line '^[[:space:]]*PASS_MIN_DAYS' /etc/login.defs | awk '{print $2}')
minl=$(conf_line '^[[:space:]]*PASS_MIN_LEN'  /etc/login.defs | awk '{print $2}')
warn=$(conf_line '^[[:space:]]*PASS_WARN_AGE' /etc/login.defs | awk '{print $2}')
pq_minlen=$(conf_line '^[[:space:]]*minlen' /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null | grep -oE '[0-9]+' | tail -1)
pq_cx=$(conf_line '^[[:space:]]*(minclass|dcredit|ucredit|lcredit|ocredit)' /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null)
pam_cx=$(grep -hE 'pam_pwquality\.so|pam_cracklib\.so' $PAM_PW 2>/dev/null | grep -vE '^[[:space:]]*#' | head -1)
[ -n "$pam_cx" ] && [ -z "$pq_cx" ] && pq_cx="$(echo "$pam_cx" | grep -oE '(minlen|dcredit|ucredit|lcredit|ocredit|minclass)=[-0-9]+' | tr '\n' ' ')"
eff_len=${pq_minlen:-$minl}
miss=""
{ [ -n "$maxd" ] && [ "$maxd" -ge 1 ] && [ "$maxd" -le 90 ]; } || miss="$miss 최대사용기간(${maxd:-미설정},기준 1~90)"
{ [ -n "$mind" ] && [ "$mind" -ge 1 ]; }                       || miss="$miss 최소사용기간(${mind:-미설정},기준 1이상)"
{ [ -n "$eff_len" ] && [ "$eff_len" -ge 8 ]; }                 || miss="$miss 최소길이(${eff_len:-미설정},기준 8이상)"
{ [ -n "$pq_cx" ] || [ -n "$pam_cx" ]; }                       || miss="$miss 복잡성(미설정)"
ev="MAX=${maxd:-미} MIN=${mind:-미} WARN=${warn:-미} LEN=${eff_len:-미} 복잡성=[${pq_cx:-${pam_cx:+pam_pwquality 적용}}]"
if [ -z "$miss" ]; then rep U-02 "비밀번호 관리정책 설정" GOOD "$ev"
else rep U-02 "비밀번호 관리정책 설정" VULN "미흡:$miss" "$ev"; fi

# U-03 계정 잠금 임계값 설정
# [기준] 양호 - 계정 잠금 임계값이 10회 이하로 설정
#        취약 - 미설정 또는 10회 초과
fl_mod=$(grep -hE 'pam_faillock\.so|pam_tally2\.so' $PAM_AUTH 2>/dev/null | grep -vE '^[[:space:]]*#' | head -1)
deny=$(grep -rhoE 'deny[[:space:]]*=[[:space:]]*[0-9]+' /etc/security/faillock.conf $PAM_AUTH 2>/dev/null | grep -oE '[0-9]+' | head -1)
if [ -z "$fl_mod" ] && ! grep -qE '^[[:space:]]*deny' /etc/security/faillock.conf 2>/dev/null; then
  rep U-03 "계정 잠금 임계값 설정" VULN "pam_faillock/pam_tally2 미적용 → 로그인 실패 임계값 없음"
elif [ -n "$deny" ] && [ "$deny" -ge 1 ] && [ "$deny" -le 10 ]; then
  rep U-03 "계정 잠금 임계값 설정" GOOD "잠금 모듈 적용 + deny=$deny (10회 이하)"
else
  rep U-03 "계정 잠금 임계값 설정" VULN "잠금 모듈은 적용됐으나 deny=${deny:-미지정} (1~10 필요)"
fi

# U-04 비밀번호 파일 보호
# [기준] 양호 - 쉐도우 패스워드 사용(또는 암호화 저장)
#        취약 - /etc/passwd 2번째 필드에 해시가 직접 존재(shadow 미사용)
plain=$(awk -F: '$2 != "x" && $2 != "" && $2 !~ /^[!*]/ {print $1}' /etc/passwd 2>/dev/null | tr '\n' ' ')
if [ -n "$plain" ]; then rep U-04 "비밀번호 파일 보호" VULN "/etc/passwd 2번째 필드에 값이 존재하는 계정: $plain (shadow 분리 안됨)"
else rep U-04 "비밀번호 파일 보호" GOOD "모든 계정의 /etc/passwd 2번째 필드가 x → 해시가 /etc/shadow로 분리됨"; fi

# U-05 root 이외의 UID '0' 금지
# [기준] 양호 - UID 0 계정이 root 뿐 / 취약 - root 외 UID 0 계정 존재
uid0=$(awk -F: '$3==0 {print $1}' /etc/passwd | grep -vx root | tr '\n' ' ')
if [ -z "$uid0" ]; then rep U-05 "root 이외의 UID '0' 금지" GOOD "UID 0 = root 뿐"
else rep U-05 "root 이외의 UID '0' 금지" VULN "root와 동일한 UID(0) 계정: $uid0"; fi

# U-06 사용자 계정 su 기능 제한
# [기준] 양호 - su 를 특정 그룹(wheel 등)만 사용하도록 제한 (일반 계정 없이 root만 쓰면 불필요)
#        취약 - 모든 사용자가 su 사용 가능
gen_users=$(awk -F: -v m="$UID_MIN" '$3>=m && $3<60000 && $7 !~ /(nologin|false)/ {print $1}' /etc/passwd | tr '\n' ' ')
pw_wheel=$(grep -E '^[[:space:]]*auth[[:space:]].*pam_wheel\.so' /etc/pam.d/su 2>/dev/null | grep -vE '^[[:space:]]*#')
su_wo=$(conf_line '^[[:space:]]*SU_WHEEL_ONLY' /etc/login.defs | awk '{print $2}')
su_perm=$(stat -c '%a' /usr/bin/su 2>/dev/null)
if [ -n "$pw_wheel" ]; then
  rep U-06 "사용자 계정 su 기능 제한" GOOD "/etc/pam.d/su 에 pam_wheel 그룹 제한 적용 (su 권한=$su_perm)"
elif [ "$su_wo" = "yes" ]; then
  rep U-06 "사용자 계정 su 기능 제한" GOOD "/etc/login.defs SU_WHEEL_ONLY=yes"
elif [ -z "$gen_users" ]; then
  rep U-06 "사용자 계정 su 기능 제한" GOOD "일반 사용자 계정 없음(root 전용) → su 제한 불필요"
else
  rep U-06 "사용자 계정 su 기능 제한" VULN "일반 계정($gen_users) 존재하나 pam_wheel/SU_WHEEL_ONLY 미설정 → 모든 사용자 su 가능 (su 권한=$su_perm)"
fi

# U-07 불필요한 계정 제거
# [기준] 양호 - 로그인이 필요 없는 불필요 기본계정이 로그인 불가(nologin/false)로 설정된 경우
#        취약 - 불필요한 기본계정(lp, uucp, games 등)이 로그인 가능한 셸을 가진 경우
#  ※ "퇴사자·미사용 사용자 계정" 존재 여부는 업무 컨텍스트가 필요 → 인터뷰(MAN) 로 분리
badsys=""
for u in lp uucp nuucp games gopher news operator ftp halt sync shutdown adm; do
  ent=$(awk -F: -v U="$u" '$1==U{print $1":"$7}' /etc/passwd 2>/dev/null)
  [ -n "$ent" ] || continue                       # 해당 기본계정 없음 → 문제 아님
  s=${ent#*:}
  echo "$s" | grep -qE 'nologin|false|/bin/sync|/sbin/shutdown|/sbin/halt' || badsys="$badsys $u(${s:-기본셸})"
done
# 로그인 셸을 가진 일반 계정 중 로그인 이력이 없거나 잠긴 것 → 방치 의심(인터뷰 대상)
review=""
while IFS=: read -r u _ uid _ _ _ sh; do
  case "$uid" in ''|*[!0-9]*) continue;; esac
  { [ "$uid" -ge "$UID_MIN" ] && [ "$uid" -lt 60000 ]; } || continue
  echo "$sh" | grep -qE 'nologin|false' && continue
  case "$CLOUD_DEFAULT" in *" $u "*) continue;; esac
  if acct_locked "$u"; then review="$review ${u}(잠금)"; continue; fi
  never_login "$u" && review="$review ${u}(로그인이력없음)"
done < /etc/passwd
logins=$(awk -F: -v m="$UID_MIN" '$3>=m && $3<60000 && $7 !~ /(nologin|false)/ {print $1}' /etc/passwd | tr '\n' ' ')
if [ -n "$badsys" ]; then
  rep U-07 "불필요한 계정 제거" VULN "제거 권고 기본계정이 로그인 가능한 셸 보유:$badsys → 삭제 또는 nologin 처리"
elif [ -n "$review" ]; then
  rep U-07 "불필요한 계정 제거" MAN "로그인 셸 보유 기본계정 없음(양호). 다음 계정의 사용 여부 인터뷰 확인 필요:$review (전체 일반계정:${logins:- 없음})"
else
  rep U-07 "불필요한 계정 제거" GOOD "제거 권고 기본계정 모두 로그인 불가 설정, 방치 의심 계정 없음. 현재 일반계정:${logins:- 없음}"
fi

# U-08 관리자 그룹에 최소한의 계정 포함
# [기준] 양호 - 관리자 그룹(root/wheel/sudo 등)에 불필요한 계정이 등록되어 있지 않은 경우
#        취약 - GID 0 그룹에 root 외 계정, 또는 관리자 그룹에 방치(미사용/잠금) 계정 등록
rootg=$(getent group root 2>/dev/null | awk -F: '{print $4}')
sudo_groups=$(grep -rhE '^[[:space:]]*%[A-Za-z0-9_.-]+[[:space:]]+ALL=\(ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/^[[:space:]]*%//' | awk '{print $1}' | sort -u | tr '\n' ' ')
sudoall=$(grep -rhE '^[[:space:]]*[%A-Za-z0-9_.-]+[[:space:]]+ALL=\(ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
adm_view=""; stale_adm=""
for g in root wheel sudo adm $sudo_groups; do
  mm=$(getent group "$g" 2>/dev/null | awk -F: '{gsub(/,/," ",$4); print $4}')
  [ -z "$mm" ] && continue
  adm_view="$adm_view ${g}:{${mm}}"
  for u in $mm; do
    case "$CLOUD_DEFAULT" in *" $u "*) continue;; esac
    if acct_locked "$u"; then stale_adm="$stale_adm ${u}($g,잠금)"
    elif never_login "$u"; then stale_adm="$stale_adm ${u}($g,로그인이력없음)"; fi
  done
done
if [ -n "$rootg" ]; then
  rep U-08 "관리자 그룹에 최소한의 계정 포함" VULN "GID 0(root) 그룹에 일반 계정: $rootg"
elif [ -n "$stale_adm" ]; then
  rep U-08 "관리자 그룹에 최소한의 계정 포함" VULN "관리자 그룹에 방치 계정:$stale_adm (sudo ALL 권한 부여: ${sudoall:-없음})"
elif [ -z "$adm_view" ]; then
  rep U-08 "관리자 그룹에 최소한의 계정 포함" GOOD "관리자 그룹(root/wheel/sudo)에 추가 계정 없음"
else
  rep U-08 "관리자 그룹에 최소한의 계정 포함" MAN "관리자 그룹 구성:${adm_view} (sudo ALL: ${sudoall:-없음}) → 각 계정의 관리자 권한 필요성 확인"
fi

# U-09 계정이 존재하지 않는 GID 금지
# [기준] 양호 - 시스템 운용에 불필요한 그룹이 없는 경우 / 취약 - 소속 계정이 없는 불필요 그룹 존재
empty_grp=""
while IFS=: read -r gn _ gid members; do
  case "$gid" in ''|*[!0-9]*) continue;; esac
  { [ "$gid" -ge "$UID_MIN" ] && [ "$gid" -lt 60000 ]; } || continue
  awk -F: -v G="$gid" '$4==G{f=1} END{exit !f}' /etc/passwd && continue   # 어떤 계정의 기본 그룹이면 정상
  [ -z "$members" ] && empty_grp="$empty_grp ${gn}($gid)"
done < /etc/group
if [ -z "$empty_grp" ]; then rep U-09 "계정이 존재하지 않는 GID 금지" GOOD "소속 계정이 없는 불필요 그룹 없음"
else rep U-09 "계정이 존재하지 않는 GID 금지" VULN "소속 계정 없는 그룹:$empty_grp → 미사용이면 제거"; fi

# U-10 동일한 UID 금지
# [기준] 양호 - 동일 UID 계정 없음 / 취약 - 존재
dupuid=$(awk -F: '$1!~"^[+#]"{print $3}' /etc/passwd | sort -n | uniq -d | tr '\n' ' ')
if [ -z "$dupuid" ]; then rep U-10 "동일한 UID 금지" GOOD "중복 UID 없음"
else
  det=$(for x in $dupuid; do echo -n "UID $x=[$(awk -F: -v X="$x" '$3==X{printf "%s ",$1}' /etc/passwd)] "; done)
  rep U-10 "동일한 UID 금지" VULN "중복 UID: $det"
fi

# U-11 사용자 Shell 점검
# [기준] 양호 - 로그인 불필요 계정에 /bin/false(/sbin/nologin) 부여
#        취약 - 로그인 불필요(시스템) 계정에 로그인 가능 셸 부여
sysshell=$(awk -F: -v m="$UID_MIN" '($3<m && $3!=0) && $7!="" && $7 !~ /(nologin|false|\/sync|\/shutdown|\/halt)/ {print $1"("$7")"}' /etc/passwd | tr '\n' ' ')
if [ -z "$sysshell" ]; then rep U-11 "사용자 Shell 점검" GOOD "시스템 계정(UID<$UID_MIN)에 로그인 가능 셸 없음"
else rep U-11 "사용자 Shell 점검" VULN "로그인 가능 셸을 가진 시스템 계정: $sysshell → nologin/false 로 변경"; fi

# U-12 세션 종료 시간 설정
# [기준] 양호 - Session Timeout(TMOUT) 600초 이하로 설정 / 취약 - 미설정 또는 초과
tmout=$(grep -rhE '^[[:space:]]*(export[[:space:]]+)?TMOUT=' /etc/profile /etc/profile.d/ /etc/bashrc /etc/bash.bashrc /etc/csh.cshrc /etc/csh.login 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -oE 'TMOUT=[0-9]+' | grep -oE '[0-9]+' | sort -n | head -1)
cai=$(sshd_val clientaliveinterval)
cac=$(sshd_val clientalivecountmax)
if [ -n "$tmout" ] && [ "$tmout" -ge 1 ] && [ "$tmout" -le 600 ]; then
  rep U-12 "세션 종료 시간 설정" GOOD "TMOUT=$tmout (<=600). SSH ClientAliveInterval=${cai:-미설정}"
else
  rep U-12 "세션 종료 시간 설정" VULN "TMOUT=${tmout:-미설정} (600초 이하 필요). SSH ClientAliveInterval=${cai:-미설정}/CountMax=${cac:-미설정}"
fi

# U-13 안전한 비밀번호 암호화 알고리즘 사용
# [기준] 양호 - SHA-256/512, yescrypt 등 안전한 알고리즘 / 취약 - DES, MD5 등
em=$(conf_line '^[[:space:]]*ENCRYPT_METHOD' /etc/login.defs | awk '{print $2}')
pamsha=$(grep -rhE 'pam_unix\.so.*(sha512|sha256|yescrypt)' $PAM_PW 2>/dev/null | grep -vE '^[[:space:]]*#' | head -1)
if [ "$IS_ROOT" -eq 1 ] && [ -r /etc/shadow ]; then
  weakacc=$(awk -F: '$2 ~ /^\$1\$/ || ($2 != "" && $2 !~ /^[\*!]/ && $2 !~ /^\$/ && length($2) >= 13 && length($2) <= 14) {print $1}' /etc/shadow | tr '\n' ' ')
  strong=$(awk -F: '$2 ~ /^\$(5|6|7|y|gy|2b)\$/ {c++} END{print c+0}' /etc/shadow)
else
  weakacc=""; strong="?"
fi
if [ -n "$weakacc" ]; then
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" VULN "MD5($1$)/DES 해시 사용 계정: $weakacc"
elif echo "$em" | grep -qiE 'SHA512|SHA256|YESCRYPT' || [ -n "$pamsha" ] || { [ "$strong" != "?" ] && [ "$strong" -gt 0 ]; }; then
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" GOOD "ENCRYPT_METHOD=${em:-미명시}, pam_unix=${pamsha:+sha/yescrypt}, 강한해시 계정수=$strong"
elif [ "$strong" = "?" ]; then
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" MAN "ENCRYPT_METHOD=${em:-미명시} (SHA-2 이상 권장). shadow 확인 불가(비-root) → root로 재점검"
else
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" VULN "ENCRYPT_METHOD=${em:-미명시}, pam_unix에 sha512/yescrypt 미지정 → 기본 알고리즘 확인 필요"
fi

#==============================================================================
echo -e "${W}[ 2. 파일 및 디렉토리 관리 ]${N}"
#==============================================================================

# U-14 root 홈, PATH 디렉터리 및 PATH 설정
# [기준] 양호 - PATH 환경변수에 "."이 맨 앞/중간에 없음 / 취약 - 포함
path_src=$(cat /etc/environment 2>/dev/null; conf_line '(^|[[:space:]])PATH=' /etc/profile /etc/profile.d/*.sh /root/.bash_profile /root/.bashrc /root/.profile 2>/dev/null; echo "PATH=$PATH")
if echo "$path_src" | grep -qE 'PATH=[^#]*(^|=|:)\.(/|:|$)|PATH=[^#]*::|PATH=:[^#]'; then
  rep U-14 "root 홈, PATH 디렉터리 및 PATH 설정" VULN "PATH 설정에 '.' 또는 빈 경로(::) 포함: $(echo "$path_src" | grep -E 'PATH=' | tr '\n' ' ' | cut -c1-180)"
else
  rep U-14 "root 홈, PATH 디렉터리 및 PATH 설정" GOOD "PATH 설정에 '.' / 빈 경로 없음"
fi

# U-15 파일 및 디렉터리 소유자 설정
# [기준] 양호 - 소유자/그룹이 없는 파일·디렉터리 없음 / 취약 - 존재
if [ "$IS_ROOT" -ne 1 ]; then
  rep U-15 "파일 및 디렉터리 소유자 설정" MAN "전체 파일시스템 탐색은 root 필요 → root로 'find / -xdev -nouser -o -nogroup' 재점검"
else
  orphan=$(timeout 120 find / -xdev \( -nouser -o -nogroup \) -not -path '/proc/*' 2>/dev/null)
  oc=$(printf '%s\n' "$orphan" | grep -c . )
  if [ "$oc" -eq 0 ]; then rep U-15 "파일 및 디렉터리 소유자 설정" GOOD "소유자/그룹 없는 파일·디렉터리 없음"
  else rep U-15 "파일 및 디렉터리 소유자 설정" VULN "소유자/그룹 없는 항목 ${oc}개 (예: $(printf '%s ' $(printf '%s\n' "$orphan" | head -5)))"; fi
fi

# U-16 /etc/passwd
chk_perm U-16 "/etc/passwd 파일 소유자 및 권한 설정" /etc/passwd 644 "root"

# U-17 시스템 시작 스크립트 권한 설정
# [기준] 양호 - 시작 스크립트 소유자 root + 일반 사용자 쓰기 권한 없음 / 취약 - 아님
ssbad=$(find -L /etc/init.d /etc/rc.d /etc/rc*.d /lib/systemd/system /usr/lib/systemd/system /etc/systemd/system -maxdepth 2 -type f 2>/dev/null \
        | while read -r f; do o=$(stat -Lc '%U' "$f" 2>/dev/null); p=$(stat -Lc '%a' "$f" 2>/dev/null)
            { [ "$o" != root ] || perm_has "$p" 022; } && echo "$f($o,$p)"; done | head -5 | tr '\n' ' ')
if [ -z "$ssbad" ]; then rep U-17 "시스템 시작 스크립트 권한 설정" GOOD "시작 스크립트 소유자 root + group/other 쓰기 권한 없음"
else rep U-17 "시스템 시작 스크립트 권한 설정" VULN "부적절: $ssbad (기준: root 소유, g/o 쓰기 없음)"; fi

# U-18 /etc/shadow  [기준] 양호 - 소유자 root + 권한 400 이하
if [ ! -e /etc/shadow ]; then rep U-18 "/etc/shadow 파일 소유자 및 권한 설정" NA "/etc/shadow 없음"
else
  sp=$(stat -c '%a' /etc/shadow); so=$(stat -c '%U' /etc/shadow); sg=$(stat -c '%G' /etc/shadow)
  if [ "$so" = root ] && perm_le "$sp" 400; then
    rep U-18 "/etc/shadow 파일 소유자 및 권한 설정" GOOD "/etc/shadow 소유자=$so 권한=$sp (기준 400 이하)"
  elif [ "$so" = root ] && [ "$sg" = shadow ] && perm_le "$sp" 640 && ! perm_has "$sp" 007; then
    rep U-18 "/etc/shadow 파일 소유자 및 권한 설정" VULN "/etc/shadow $so:$sg 권한=$sp → Debian 계열 기본값이나 상세가이드 기준(400) 초과"
  else
    rep U-18 "/etc/shadow 파일 소유자 및 권한 설정" VULN "/etc/shadow 소유자=$so 권한=$sp (기준: root, 400 이하)"
  fi
fi

# U-19 /etc/hosts   [기준] 양호 - 소유자 root + 권한 644 이하  (양식 진단기준 기준)
chk_perm U-19 "/etc/hosts 파일 소유자 및 권한 설정" /etc/hosts 644 "root"

# U-20 /etc/(x)inetd.conf   [기준] 양호 - 소유자 root + 권한 600 이하
inetd_f=""
[ -e /etc/xinetd.conf ] && inetd_f=/etc/xinetd.conf
[ -z "$inetd_f" ] && [ -e /etc/inetd.conf ] && inetd_f=/etc/inetd.conf
if [ -z "$inetd_f" ]; then rep U-20 "/etc/(x)inetd.conf 파일 소유자 및 권한 설정" NA "(x)inetd 미사용"
else
  bad=$(for f in "$inetd_f" /etc/xinetd.d/*; do [ -f "$f" ] || continue
          o=$(stat -c '%U' "$f"); p=$(stat -c '%a' "$f"); { [ "$o" != root ] || ! perm_le "$p" 600; } && echo "$f($o,$p)"; done | tr '\n' ' ')
  [ -z "$bad" ] && rep U-20 "/etc/(x)inetd.conf 파일 소유자 및 권한 설정" GOOD "$inetd_f 및 xinetd.d/* 소유자 root + 600 이하" \
                || rep U-20 "/etc/(x)inetd.conf 파일 소유자 및 권한 설정" VULN "부적절: $bad (기준: root, 600 이하)"
fi

# U-21 /etc/(r)syslog.conf   [기준] 양호 - 소유자 root(또는 bin,sys) + 권한 640 이하
sysl_f=/etc/rsyslog.conf; [ -e "$sysl_f" ] || sysl_f=/etc/syslog.conf
sysl_bad=""
for f in "$sysl_f" /etc/rsyslog.d/*.conf; do
  [ -f "$f" ] || continue
  o=$(stat -c '%U' "$f"); p=$(stat -c '%a' "$f")
  case " root bin sys syslog " in *" $o "*) : ;; *) sysl_bad="$sysl_bad $f(소유자=$o)";; esac
  perm_le "$p" 640 || sysl_bad="$sysl_bad $f($p)"
done
if [ ! -e "$sysl_f" ]; then rep U-21 "/etc/(r)syslog.conf 파일 소유자 및 권한 설정" NA "syslog 설정파일 없음"
elif [ -z "$sysl_bad" ]; then rep U-21 "/etc/(r)syslog.conf 파일 소유자 및 권한 설정" GOOD "$sysl_f (+rsyslog.d) 소유자 root(bin/sys) + 640 이하"
else rep U-21 "/etc/(r)syslog.conf 파일 소유자 및 권한 설정" VULN "부적절:$sysl_bad (기준: root/bin/sys, 640 이하)"; fi

# U-22 /etc/services   [기준] 양호 - 소유자 root(또는 bin,sys) + 권한 644 이하
chk_perm U-22 "/etc/services 파일 소유자 및 권한 설정" /etc/services 644 "root bin sys"

# U-23 SUID/SGID/Sticky bit 설정 파일 점검
# [기준] 양호 - 주요 실행 파일에 불필요한 SUID/SGID 없음 / 취약 - 상세가이드 제거권고 파일에 SUID/SGID 설정
KISA_SUID_RM="/sbin/dump /sbin/restore /sbin/unix_chkpwd /usr/bin/at /usr/bin/lpq /usr/bin/lpq-lpd /usr/bin/lpr /usr/bin/lpr-lpd /usr/bin/lprm /usr/bin/lprm-lpd /usr/bin/newgrp /usr/sbin/lpc /usr/sbin/lpc-lpd /usr/sbin/traceroute /usr/bin/traceroute6 /usr/bin/wall /usr/bin/write"
if [ "$IS_ROOT" -ne 1 ]; then
  rep U-23 "SUID, SGID, Sticky bit 설정 파일 점검" MAN "전체 SUID/SGID 탐색은 root 필요 → root로 'find / -xdev -perm /6000' 재점검"
else
  rm_hit=""
  for f in $KISA_SUID_RM; do [ -f "$f" ] && [ -n "$(find "$f" -perm /6000 2>/dev/null)" ] && rm_hit="$rm_hit $f"; done
  suid_cnt=$(timeout 90 find / -xdev -type f -perm /6000 2>/dev/null | wc -l)
  if [ -n "$rm_hit" ]; then
    rep U-23 "SUID, SGID, Sticky bit 설정 파일 점검" VULN "상세가이드 제거권고 파일에 SUID/SGID:$rm_hit (총 SUID/SGID 파일 ${suid_cnt}개)"
  else
    rep U-23 "SUID, SGID, Sticky bit 설정 파일 점검" GOOD "제거권고 목록 파일에 SUID/SGID 없음 (총 ${suid_cnt}개는 배포판 표준 → 목록 검토 권장)"
  fi
fi

# U-24 사용자/시스템 환경변수 파일 소유자 및 권한
# [기준] 양호 - 환경변수 파일 소유자가 root 또는 해당 계정, root/소유자만 쓰기
env_bad=""
for f in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/csh.cshrc /etc/csh.login /etc/environment; do
  [ -e "$f" ] || continue
  o=$(stat -c '%U' "$f"); p=$(stat -c '%a' "$f")
  { [ "$o" = root ] && ! perm_has "$p" 022; } || env_bad="$env_bad $f($o,$p)"
done
if [ "$IS_ROOT" -eq 1 ]; then
  while IFS=: read -r u _ uid _ _ home _; do
    case "$uid" in ''|*[!0-9]*) continue;; esac
    { [ "$uid" -ge "$UID_MIN" ] || [ "$uid" = 0 ]; } || continue
    [ -d "$home" ] || continue
    for d in .profile .bashrc .bash_profile .bash_login .cshrc .kshrc .login .exrc .netrc; do
      [ -e "$home/$d" ] || continue
      o=$(stat -c '%U' "$home/$d"); p=$(stat -c '%a' "$home/$d")
      { { [ "$o" = "$u" ] || [ "$o" = root ]; } && ! perm_has "$p" 022; } || env_bad="$env_bad $home/$d($o,$p)"
    done
  done < /etc/passwd
fi
if [ -z "$env_bad" ]; then rep U-24 "사용자, 시스템 환경변수 파일 소유자 및 권한" GOOD "환경변수 파일 소유자 root/해당계정 + g/o 쓰기 없음"
else rep U-24 "사용자, 시스템 환경변수 파일 소유자 및 권한" VULN "부적절: $(echo $env_bad | cut -c1-200)"; fi

# U-25 world writable 파일 점검
# [기준] 양호 - world writable 파일 없음(또는 사유 인지) / 취약 - 사유 미인지 world writable 존재
if [ "$IS_ROOT" -ne 1 ]; then
  rep U-25 "world writable 파일 점검" MAN "전체 탐색 root 필요 → root로 'find / -xdev -type f -perm -0002' 재점검"
else
  ww=$(timeout 90 find / -xdev -type f -perm -0002 -not -path '/proc/*' 2>/dev/null)
  wc_=$(printf '%s\n' "$ww" | grep -c .)
  if [ "$wc_" -eq 0 ]; then rep U-25 "world writable 파일 점검" GOOD "world writable 일반 파일 없음"
  else rep U-25 "world writable 파일 점검" VULN "world writable 파일 ${wc_}개 (예: $(printf '%s ' $(printf '%s\n' "$ww" | head -5))) → 사유 없으면 권한 제거"; fi
fi

# U-26 /dev에 존재하지 않는 device 파일 점검
# [기준] 양호 - /dev 내 비정상 일반 파일 없음 / 취약 - 존재
devf=$(find /dev -type f ! -path '/dev/shm/*' ! -path '/dev/mqueue/*' ! -path '/dev/hugepages/*' ! -name MAKEDEV ! -name .udev ! -name core 2>/dev/null | head -10)
devc=$(printf '%s\n' "$devf" | grep -c .)
if [ "$devc" -eq 0 ]; then rep U-26 "/dev에 존재하지 않는 device 파일 점검" GOOD "/dev 내 비정상 일반 파일 없음"
else rep U-26 "/dev에 존재하지 않는 device 파일 점검" VULN "/dev 내 일반 파일 ${devc}개: $(echo $devf | cut -c1-150)"; fi

# U-27 $HOME/.rhosts, hosts.equiv 사용 금지
# [기준] 양호 - r계열 미사용, 또는 사용 시 소유자 root/계정 + 권한 600이하 + "+" 없음
r_used=0
{ pkg_installed rsh-server || pkg_installed rsh || svc_active rlogin.socket || svc_active rsh.socket || port_listen 513 || port_listen 514; } && r_used=1
rfiles="/etc/hosts.equiv"
if [ "$IS_ROOT" -eq 1 ]; then
  while IFS=: read -r _ _ uid _ _ home _; do case "$uid" in ''|*[!0-9]*) continue;; esac
    { [ "$uid" -ge "$UID_MIN" ] || [ "$uid" = 0 ]; } && [ -f "$home/.rhosts" ] && rfiles="$rfiles $home/.rhosts"; done < /etc/passwd
fi
found=""; plusbad=""; permbad=""
for f in $rfiles; do
  [ -e "$f" ] || continue; found="$found $f"
  grep -qE '^[[:space:]]*\+' "$f" 2>/dev/null && plusbad="$plusbad $f"
  o=$(stat -c '%U' "$f"); p=$(stat -c '%a' "$f")
  { [ "$o" = root ] || perm_le "$p" 600; } || permbad="$permbad $f($o,$p)"
done
if [ -z "$found" ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" GOOD ".rhosts/hosts.equiv 파일 없음 (r계열 서비스 사용=$r_used)"
elif [ -n "$plusbad" ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" VULN "'+' 설정 존재:$plusbad"
elif [ -n "$permbad" ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" VULN "소유자/권한 부적절:$permbad (기준: root/계정, 600 이하)"
elif [ "$r_used" -eq 1 ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" VULN "r계열 서비스 사용 중 + 신뢰파일 존재:$found → r계열 비활성화 권장"
else rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" GOOD "신뢰파일 존재하나 '+' 없음 + 권한 적절 + r계열 미사용:$found"; fi

# U-28 접속 IP 및 포트 제한
# [기준] 양호 - 허용 호스트 IP/포트 제한 설정(TCP Wrapper 또는 호스트 방화벽) / 취약 - 미설정
tcpw_deny=$(grep -viE '^[[:space:]]*#|^[[:space:]]*$' /etc/hosts.deny 2>/dev/null | grep -icE 'ALL[[:space:]]*:[[:space:]]*ALL')
tcpw_allow=$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$' /etc/hosts.allow 2>/dev/null)
fw="none"; fw_rules=0
svc_active firewalld && { fw="firewalld"; firewall-cmd --list-rich-rules 2>/dev/null | grep -q . && fw_rules=1; firewall-cmd --list-sources 2>/dev/null | grep -q . && fw_rules=1; }
{ have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; } && { fw="ufw"; ufw status 2>/dev/null | grep -qiE 'ALLOW|DENY' && fw_rules=1; }
if [ "$fw" = none ] && [ "$IS_ROOT" -eq 1 ]; then
  if have nft && nft list ruleset 2>/dev/null | grep -qE 'ip (saddr|daddr)|tcp dport'; then fw="nftables"; fw_rules=1
  elif have iptables && iptables -S 2>/dev/null | grep -qE '(-s |--dport ).*-j (ACCEPT|DROP|REJECT)'; then fw="iptables"; fw_rules=1; fi
fi
if [ "$tcpw_deny" -ge 1 ] && [ "$tcpw_allow" -ge 1 ]; then
  rep U-28 "접속 IP 및 포트 제한" GOOD "TCP Wrapper: hosts.deny ALL:ALL + hosts.allow ${tcpw_allow}줄 (방화벽=$fw)"
elif [ "$fw_rules" -eq 1 ]; then
  rep U-28 "접속 IP 및 포트 제한" GOOD "호스트 방화벽($fw)에 소스/포트 제한 규칙 존재"
elif [ "$fw" = none ] && [ "$IS_ROOT" -ne 1 ]; then
  rep U-28 "접속 IP 및 포트 제한" MAN "TCP Wrapper 미설정. 방화벽 규칙은 root 확인 필요 (클라우드는 SG/NACL 별도 점검)"
else
  rep U-28 "접속 IP 및 포트 제한" VULN "TCP Wrapper 미설정 + 호스트 방화벽($fw) 제한 규칙 없음 (클라우드 SG는 별도 점검)"
fi

# U-29 hosts.lpd   [기준] 양호 - 파일 없음, 또는 소유자 root + 권한 600 이하
if [ ! -e /etc/hosts.lpd ]; then rep U-29 "hosts.lpd 파일 소유자 및 권한 설정" NA "/etc/hosts.lpd 없음 (lpd 미사용)"
else chk_perm U-29 "hosts.lpd 파일 소유자 및 권한 설정" /etc/hosts.lpd 600 "root"; fi

# U-30 UMASK 설정 관리
# [기준] 양호 - UMASK 값이 022 이상(그룹·타 사용자 쓰기 비트가 마스킹) / 취약 - 022 미만
#  점검 대상: /etc/login.defs, PAM pam_umask, /etc/profile·bashrc·csh 계열,
#            /etc/profile.d/*, /etc/default/login, 로그인 계정 dotfile, 현재 세션 umask
um_ge() { [ "$(( 8#${1:-0} & 8#022 ))" -eq "$(( 8#022 ))" ]; }
um_all=""; um_bad=""
um_take() {   # $1=출처라벨  $2=umask값
  [ -n "$2" ] || return 0
  um_all="$um_all $1=$2"
  um_ge "$2" || um_bad="$um_bad $1($2)"
}
# 1) /etc/login.defs
um_take login.defs "$(conf_line '^[[:space:]]*UMASK[[:space:]]' /etc/login.defs | awk '{print $2}')"
# 2) PAM pam_umask 의 umask= 인자
um_take pam_umask "$(grep -rhE 'pam_umask\.so' /etc/pam.d/ 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -oE 'umask=[0-7]{3,4}' | head -1 | cut -d= -f2)"
# 3) 시스템 셸 프로파일 계열
for f in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/csh.cshrc /etc/csh.login /etc/default/login; do
  [ -f "$f" ] || continue
  while read -r v; do um_take "$(basename "$f")" "$v"; done < <(
    grep -hE '^[[:space:]]*umask[[:space:]]+[0-7]{3,4}' "$f" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -oE '[0-7]{3,4}')
done
# 4) /etc/profile.d/*
while read -r v; do um_take profile.d "$v"; done < <(
  grep -rhE '^[[:space:]]*umask[[:space:]]+[0-7]{3,4}' /etc/profile.d/ 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -oE '[0-7]{3,4}')
# 5) 로그인 가능한 계정의 dotfile (root + 홈 디렉터리)
for d in /root $(awk -F: -v m="$UID_MIN" '$3>=m && $3<60000 && $7 !~ /(nologin|false)/ {print $6}' /etc/passwd 2>/dev/null | sort -u); do
  for rc in "$d/.bash_profile" "$d/.bashrc" "$d/.profile" "$d/.cshrc"; do
    [ -f "$rc" ] || continue
    while read -r v; do um_take "${rc#/}" "$v"; done < <(
      grep -hE '^[[:space:]]*umask[[:space:]]+[0-7]{3,4}' "$rc" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -oE '[0-7]{3,4}')
  done
done
# 6) RHEL UPG 조건부 umask 002 (/etc/bashrc·/etc/profile 의 "id -gn = id -un" 블록 한정)는
#    Red Hat 표준 동작이므로 취약으로 보지 않음. profile.d/login.defs 등의 002 는 그대로 평가.
if [ "$FAM" = rhel ] && grep -qsE 'id -gn.*id -un|UID.*-gt.*(199|200)' /etc/bashrc /etc/profile; then
  um_bad=$(printf '%s' " $um_bad " | sed -E 's/ (bashrc|profile)\(00[27]\) / /g' | xargs)
fi
cur_um=$(umask 2>/dev/null)
if [ -n "$um_bad" ]; then
  rep U-30 "UMASK 설정 관리" VULN "022 미만 UMASK 설정 존재:${um_bad} (현재 세션 umask=$cur_um) → 022 이상으로 설정"
elif [ -n "$um_all" ]; then
  rep U-30 "UMASK 설정 관리" GOOD "UMASK 설정 모두 022 이상:${um_all# } (현재 세션 umask=$cur_um)"
elif um_ge "$cur_um"; then
  rep U-30 "UMASK 설정 관리" GOOD "별도 UMASK 설정 없음, 현재 적용 umask=$cur_um (022 이상)"
else
  rep U-30 "UMASK 설정 관리" VULN "UMASK 명시 설정 없음 + 현재 적용 umask=$cur_um (022 미만)"
fi

# U-31 홈 디렉토리 소유자 및 권한
# [기준] 양호 - 홈 디렉토리 소유자가 해당 계정 + 타 사용자(other) 쓰기 권한 없음
home_bad=$(awk -F: -v m="$UID_MIN" '$3>=m && $3<60000 && $6 ~ /^\/(home|users|export\/home)\// {print $1":"$6}' /etc/passwd \
  | while IFS=: read -r u h; do [ -d "$h" ] || continue
      o=$(stat -c '%U' "$h"); p=$(stat -c '%a' "$h")
      { [ "$o" != "$u" ] || perm_has "$p" 002; } && echo "$h(소유자=$o,$p)"; done | tr '\n' ' ')
if [ -z "$home_bad" ]; then rep U-31 "홈 디렉토리 소유자 및 권한 설정" GOOD "일반 사용자 홈 소유자 일치 + other 쓰기 없음"
else rep U-31 "홈 디렉토리 소유자 및 권한 설정" VULN "부적절: $home_bad (기준: 소유자=계정, other 쓰기 없음)"; fi

# U-32 홈 디렉토리로 지정한 디렉토리의 존재 관리
# [기준] 양호 - 홈 디렉토리가 없는 계정 없음 / 취약 - 존재
nohome=$(awk -F: -v m="$UID_MIN" '$3>=m && $3<60000 && $7 !~ /(nologin|false)/ {print $1":"$6}' /etc/passwd \
  | while IFS=: read -r u h; do { [ -z "$h" ] || [ ! -d "$h" ]; } && echo "$u($h)"; done | tr '\n' ' ')
if [ -z "$nohome" ]; then rep U-32 "홈 디렉토리로 지정한 디렉토리의 존재 관리" GOOD "로그인 가능 계정의 홈 디렉토리 모두 존재"
else rep U-32 "홈 디렉토리로 지정한 디렉토리의 존재 관리" VULN "홈 디렉토리 없음: $nohome"; fi

# U-33 숨겨진 파일 및 디렉토리 검색 및 제거
# [기준] 양호 - 불필요/의심 숨김 파일·디렉토리 없음 / 취약 - 존재
susp=$(find /tmp /var/tmp /dev/shm -maxdepth 2 -name '.*' ! -name '.' ! -name '..' ! -name '.X11-unix' ! -name '.ICE-unix' ! -name '.font-unix' ! -name '.Test-unix' ! -name '.XIM-unix' 2>/dev/null | head -10 | tr '\n' ' ')
if [ -z "$susp" ]; then rep U-33 "숨겨진 파일 및 디렉토리 검색 및 제거" GOOD "임시 디렉토리(/tmp,/var/tmp,/dev/shm)에 비정상 숨김 파일 없음"
else rep U-33 "숨겨진 파일 및 디렉토리 검색 및 제거" VULN "임시 디렉토리에 숨김 파일 존재:$susp → 사유 확인 후 제거"; fi

#==============================================================================
echo -e "${W}[ 3. 서비스 관리 ]${N}"
#==============================================================================

# 서비스 비활성화 공통 판정
svc_off() {  # code title "port들" "proc패턴" "pkg명"
  local code=$1 title=$2 ports=$3 procp=$4 pkg=$5 hit=""
  for p in $ports; do port_listen "$p" && hit="$hit port:$p"; done
  [ -n "$procp" ] && proc_run "$procp" && hit="$hit proc:$procp"
  if [ -n "$hit" ]; then rep "$code" "$title" VULN "서비스 실행/노출:$hit → 미사용 시 비활성화"
  else rep "$code" "$title" GOOD "미실행/미노출 (pkg=${pkg:+$(pkg_installed "$pkg" && echo 설치됨 || echo 미설치)})"; fi
}

# U-34 Finger   [기준] 양호 - 비활성화 / 취약 - 활성화
svc_off U-34 "Finger 서비스 비활성화" 79 "fingerd|in.fingerd" finger-server

# U-35 Anonymous FTP 비활성화
# [기준] 양호 - 익명 접근 제한 / 취약 - 익명 접근 허용
if grep -qiE '^[[:space:]]*anonymous_enable[[:space:]]*=[[:space:]]*YES' /etc/vsftpd/vsftpd.conf /etc/vsftpd.conf 2>/dev/null; then
  rep U-35 "Anonymous FTP 비활성화" VULN "vsftpd anonymous_enable=YES (익명 FTP 허용)"
elif grep -qiE '^[[:space:]]*<Anonymous' /etc/proftpd/proftpd.conf /etc/proftpd.conf 2>/dev/null; then
  rep U-35 "Anonymous FTP 비활성화" VULN "proftpd <Anonymous> 블록 존재 (익명 FTP 허용)"
elif port_listen 21; then
  rep U-35 "Anonymous FTP 비활성화" MAN "FTP(21) 실행 중이나 익명 설정 미확인 → anonymous 설정 점검"
else
  rep U-35 "Anonymous FTP 비활성화" GOOD "FTP 미실행 or 익명 접근 설정 없음"
fi

# U-36 r 계열 서비스 비활성화   [기준] 양호 - 비활성화 / 취약 - 활성화
r_hit=""
for p in 512 513 514; do port_listen "$p" && r_hit="$r_hit port:$p"; done
proc_run "rlogind|in.rlogind|rshd|in.rshd|rexecd|in.rexecd" && r_hit="$r_hit proc"
{ svc_active rsh.socket || svc_active rlogin.socket || svc_active rexec.socket; } && r_hit="$r_hit socket"
if [ -n "$r_hit" ]; then rep U-36 "r 계열 서비스 비활성화" VULN "r계열 서비스 활성:$r_hit"
else rep U-36 "r 계열 서비스 비활성화" GOOD "rlogin/rsh/rexec 미실행"; fi

# U-37 crontab 설정파일 권한 설정
# [기준] 양호 - 일반 사용자 crontab 실행 제한 + cron/at 관련 파일 권한 640 이하 / 취약 - 아님
cron_bad=""
for f in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
  [ -e "$f" ] || continue; p=$(stat -c '%a' "$f"); o=$(stat -c '%U' "$f")
  { [ "$o" = root ] && perm_le "$p" 640; } || cron_bad="$cron_bad $f($o,$p)"
done
for d in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do [ -f "$f" ] || continue; p=$(stat -c '%a' "$f"); perm_le "$p" 640 || cron_bad="$cron_bad $f($p)"; done
done
[ -e /etc/cron.allow ] && cron_restrict="cron.allow 존재(허용목록 방식)" || cron_restrict="cron.allow 없음(전체 사용자 crontab 가능)"
if [ -z "$cron_bad" ] && [ -e /etc/cron.allow ]; then
  rep U-37 "crontab 설정파일 권한 설정" GOOD "$cron_restrict + cron/at 파일 640 이하"
elif [ -n "$cron_bad" ]; then
  rep U-37 "crontab 설정파일 권한 설정" VULN "권한 기준(640 이하) 초과:$cron_bad. $cron_restrict"
else
  rep U-37 "crontab 설정파일 권한 설정" VULN "$cron_restrict → cron.allow 로 일반 사용자 실행 제한 필요"
fi

# U-38 DoS 취약 서비스 비활성화   [기준] 양호 - 비활성화 / 취약 - 활성화
dos_hit=""
for p in 7 9 13 19 37; do port_listen "$p" && dos_hit="$dos_hit $p"; done
grep -rlqE '^[[:space:]]*(echo|discard|daytime|chargen|time)[[:space:]]' /etc/xinetd.d/ 2>/dev/null && \
  grep -rLqE 'disable[[:space:]]*=[[:space:]]*yes' /etc/xinetd.d/echo /etc/xinetd.d/daytime 2>/dev/null && dos_hit="$dos_hit xinetd"
if [ -z "$dos_hit" ]; then rep U-38 "DoS 공격에 취약한 서비스 비활성화" GOOD "echo/discard/daytime/chargen/time 미실행"
else rep U-38 "DoS 공격에 취약한 서비스 비활성화" VULN "취약 서비스 포트/설정:$dos_hit"; fi

# U-39 불필요한 NFS 서비스 비활성화   [기준] 양호 - NFS 데몬 비활성화 / 취약 - 활성화
if svc_active nfs-server || svc_active nfs || proc_run nfsd || port_listen 2049; then
  rep U-39 "불필요한 NFS 서비스 비활성화" VULN "NFS 서버 실행 중 (nfsd/2049) → 미사용 시 중지"
else
  rep U-39 "불필요한 NFS 서비스 비활성화" GOOD "NFS 서버 미실행"
fi

# U-40 NFS 접근 통제
# [기준] 양호 - 접근 통제 설정 + exports 권한 644 이하 / 취약 - everyone(*) 등 위험 설정
if [ ! -s /etc/exports ] || ! grep -qvE '^[[:space:]]*#|^[[:space:]]*$' /etc/exports 2>/dev/null; then
  rep U-40 "NFS 접근 통제" NA "/etc/exports 공유 설정 없음"
else
  ep=$(stat -c '%a' /etc/exports); permok=1; perm_le "$ep" 644 || permok=0
  if grep -qE '(\*|everyone)' /etc/exports 2>/dev/null || grep -qE 'no_root_squash|insecure' /etc/exports 2>/dev/null; then
    rep U-40 "NFS 접근 통제" VULN "/etc/exports 에 everyone(*) / no_root_squash / insecure 등 위험 설정 (파일 권한=$ep)"
  elif [ "$permok" -eq 0 ]; then
    rep U-40 "NFS 접근 통제" VULN "/etc/exports 권한=$ep (644 이하 필요)"
  else
    rep U-40 "NFS 접근 통제" GOOD "/etc/exports 호스트 지정 공유 + 권한 $ep + 위험 옵션 없음"
  fi
fi

# U-41 automountd 제거   [기준] 양호 - 비활성화 / 취약 - 활성화
if svc_active autofs || proc_run automount || proc_run automountd; then
  rep U-41 "불필요한 automountd 제거" VULN "autofs/automountd 실행 중 → 미사용 시 제거"
else rep U-41 "불필요한 automountd 제거" GOOD "automountd 미실행"; fi

# U-42 RPC 서비스 확인
# [기준] 양호 - 취약한 RPC 서비스 비활성화 / 취약 - 활성화
rpc_bad=""
if have rpcinfo; then
  rpc_bad=$(rpcinfo -p 2>/dev/null | grep -iE 'rusersd|rstatd|sprayd|walld|rexd|ttdbserverd|cmsd|kcms_server|cachefsd|rquotad|rpc.nisd|rpc.pcnfsd|ypupdated|rusers|status' | awk '{print $5}' | sort -u | tr '\n' ' ')
fi
if [ -n "$rpc_bad" ]; then rep U-42 "불필요한 RPC 서비스 비활성화" VULN "취약 RPC 서비스 등록: $rpc_bad"
elif svc_active rpcbind || port_listen 111; then rep U-42 "불필요한 RPC 서비스 비활성화" GOOD "취약 RPC 서비스 없음 (rpcbind/111 은 동작 중 → NFS 등 필요 시에만 유지)"
else rep U-42 "불필요한 RPC 서비스 비활성화" GOOD "RPC 서비스 미실행"; fi

# U-43 NIS, NIS+ 점검   [기준] 양호 - NIS 비활성화 / 취약 - NIS 활성화
if systemctl list-units --type=service --state=running 2>/dev/null | grep -qE 'ypserv|ypbind|ypxfrd|yppasswdd|ypupdated' || proc_run "ypserv|ypbind"; then
  rep U-43 "NIS, NIS+ 점검" VULN "NIS 관련 서비스 활성 (ypserv/ypbind 등)"
else rep U-43 "NIS, NIS+ 점검" GOOD "NIS 서비스 미실행"; fi

# U-44 tftp, talk 서비스 비활성화   [기준] 양호 - 비활성화 / 취약 - 활성화
tt_hit=""
port_listen 69 && tt_hit="$tt_hit tftp(69)"
for p in 517 518; do port_listen "$p" && tt_hit="$tt_hit talk($p)"; done
proc_run "in.tftpd|tftpd|in.talkd|talkd|in.ntalkd|ntalkd" && tt_hit="$tt_hit proc"
{ svc_active tftp.socket || svc_active tftp; } && tt_hit="$tt_hit tftp.socket"
if [ -z "$tt_hit" ]; then rep U-44 "tftp, talk 서비스 비활성화" GOOD "tftp/talk/ntalk 미실행"
else rep U-44 "tftp, talk 서비스 비활성화" VULN "활성:$tt_hit"; fi

# 메일 서비스 공통
mail_run=0
{ port_listen 25 || svc_active postfix || svc_active sendmail || proc_run "master|sendmail"; } && mail_run=1
mail_kind="none"
{ svc_active postfix || pkg_installed postfix; } && mail_kind="postfix"
{ svc_active sendmail || pkg_installed sendmail || pkg_installed sendmail-cf; } && mail_kind="sendmail"

# U-45 메일 서비스 버전 점검
# [기준] 양호 - SMTP 서비스를 사용하지 않거나, 사용 시 알려진 취약점이 없는 최신(패치) 버전 / 취약 - 구버전
#  ※ 로컬(127.0.0.1) 전용 postfix 는 외부 SMTP 서비스 제공이 아니므로 양호로 본다.
if [ "$mail_kind" = none ]; then
  rep U-45 "메일 서비스 버전 점검" GOOD "sendmail/postfix/exim 등 메일 서비스 미설치"
elif ! port_listen_ext 25; then
  rep U-45 "메일 서비스 버전 점검" GOOD "$mail_kind 설치되어 있으나 외부 인터페이스로 SMTP(25) 미제공 (localhost 전용/미기동)"
else
  mv=""
  [ "$mail_kind" = postfix ] && mv=$(postconf mail_version 2>/dev/null | awk '{print $3}')
  [ -z "$mv" ] && mv=$( (sendmail -d0.1 -bv root 2>/dev/null; echo) | grep -i 'Version' | head -1)
  pend=$(sec_update_count 'postfix|sendmail' '^(postfix|sendmail)/')
  if [ "$pend" = "?" ]; then
    rep U-45 "메일 서비스 버전 점검" MAN "$mail_kind 외부 제공 중 (버전=${mv:-확인필요}) — 패키지 관리자 없음, 최신 버전 여부 수동 확인 필요"
  elif [ "${pend:-0}" -gt 0 ]; then
    rep U-45 "메일 서비스 버전 점검" VULN "$mail_kind 외부 제공 중 (버전=${mv:-확인필요}) + 보안 업데이트 ${pend}건 미적용"
  else
    rep U-45 "메일 서비스 버전 점검" GOOD "$mail_kind 외부 제공 중 (버전=${mv:-확인필요}), 미적용 보안 업데이트 없음"
  fi
fi

# U-46 일반 사용자의 메일 서비스 실행 방지
# [기준] 양호 - 일반 사용자의 메일 서비스(큐 조작 등) 실행 방지 설정 / 취약 - 미설정
if [ "$mail_kind" = none ]; then rep U-46 "일반 사용자의 메일 서비스 실행 방지" NA "메일 서비스 미설치/미실행"
elif [ "$mail_kind" = postfix ]; then
  au=$(postconf -h authorized_submit_users 2>/dev/null)
  ps_perm=$(stat -c '%a' /usr/sbin/postdrop 2>/dev/null)
  if echo "$au" | grep -qiE 'root|@?[a-z]' && ! echo "$au" | grep -qi 'static:anyone'; then
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" GOOD "postfix authorized_submit_users=$au"
  else
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" VULN "postfix authorized_submit_users 제한 없음(=${au:-미설정}) → 특정 사용자만 허용 필요"
  fi
else
  if grep -qiE 'O PrivacyOptions.*restrictqrun|RunAsUser' /etc/mail/sendmail.cf 2>/dev/null; then
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" GOOD "sendmail PrivacyOptions restrictqrun / RunAsUser 설정"
  else
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" VULN "sendmail PrivacyOptions 에 restrictqrun 미설정"
  fi
fi

# U-47 스팸 메일 릴레이 제한
# [기준] 양호 - 릴레이 제한 설정 / 취약 - 오픈 릴레이 가능
if [ "$mail_kind" = none ] || { [ "$mail_run" -eq 0 ] && ! port_listen_ext 25; }; then
  rep U-47 "스팸 메일 릴레이 제한" NA "메일 서비스 외부 노출 없음"
elif [ "$mail_kind" = postfix ]; then
  rr="$(postconf -h smtpd_relay_restrictions 2>/dev/null) $(postconf -h smtpd_recipient_restrictions 2>/dev/null)"
  mynet=$(postconf -h mynetworks 2>/dev/null)
  if echo "$rr" | grep -qE 'reject_unauth_destination|defer_unauth_destination'; then
    rep U-47 "스팸 메일 릴레이 제한" GOOD "postfix reject_unauth_destination 설정 (mynetworks=$mynet)"
  else
    rep U-47 "스팸 메일 릴레이 제한" VULN "postfix 릴레이 제한(reject_unauth_destination) 미설정 → 오픈릴레이 가능"
  fi
else
  if grep -qiE 'promiscuous_relay' /etc/mail/sendmail.cf 2>/dev/null; then rep U-47 "스팸 메일 릴레이 제한" VULN "sendmail promiscuous_relay (오픈릴레이)"
  elif grep -qiE 'R\$\*[[:space:]]*\$#error|access' /etc/mail/sendmail.cf 2>/dev/null || [ -e /etc/mail/access.db ]; then rep U-47 "스팸 메일 릴레이 제한" GOOD "sendmail access DB 기반 릴레이 제한"
  else rep U-47 "스팸 메일 릴레이 제한" MAN "sendmail 릴레이 정책 확인 필요 (access DB / relay-domains)"; fi
fi

# U-48 expn, vrfy 명령어 제한
# [기준] 양호 - noexpn/novrfy(또는 disable_vrfy_command) 설정 / 취약 - 미설정
if [ "$mail_kind" = none ] || [ "$mail_run" -eq 0 ]; then rep U-48 "expn, vrfy 명령어 제한" NA "메일 서비스 미실행"
elif [ "$mail_kind" = postfix ]; then
  if postconf -h disable_vrfy_command 2>/dev/null | grep -qi yes; then rep U-48 "expn, vrfy 명령어 제한" GOOD "postfix disable_vrfy_command=yes"
  else rep U-48 "expn, vrfy 명령어 제한" VULN "postfix disable_vrfy_command=no → VRFY 명령 허용"; fi
else
  if grep -qiE 'PrivacyOptions.*(noexpn|novrfy|goaway)' /etc/mail/sendmail.cf 2>/dev/null; then rep U-48 "expn, vrfy 명령어 제한" GOOD "sendmail PrivacyOptions noexpn,novrfy 설정"
  else rep U-48 "expn, vrfy 명령어 제한" VULN "sendmail PrivacyOptions 에 noexpn/novrfy 미설정"; fi
fi

# DNS 공통 (systemd-resolved 127.0.0.53 은 DNS 서버 아님)
dns_srv=0
{ proc_run named || pkg_installed bind || pkg_installed bind9 || svc_active named || svc_active bind9; } && dns_srv=1
{ port_listen 53 && _listen | grep -E '[:.]53$' | grep -qvE '^127\.0\.0\.53|^127\.0\.0\.1|^\[?::1'; } && dns_srv=1

# U-49 DNS 보안 버전 패치   [기준] 양호 - 주기적 패치 관리 / 취약 - 아님
if [ "$dns_srv" -eq 0 ]; then rep U-49 "DNS 보안 버전 패치" NA "BIND(named) 미운영 (systemd-resolved 는 DNS 서버 아님)"
else
  bpend=$(sec_update_count 'bind' '^bind9')
  bver=$(named -v 2>/dev/null)
  if [ "${bpend:-0}" -gt 0 ]; then rep U-49 "DNS 보안 버전 패치" VULN "BIND 실행 중 ($bver) + 보안 업데이트 ${bpend}건 미적용"
  else rep U-49 "DNS 보안 버전 패치" MAN "BIND 실행 중 ($bver), 미적용 보안 업데이트 없음 → 패치 관리 정책/이력 확인"; fi
fi

# U-50 DNS Zone Transfer 설정   [기준] 양호 - 허가된 사용자에게만 허용 / 취약 - 전체 허용
if [ "$dns_srv" -eq 0 ]; then rep U-50 "DNS Zone Transfer 설정" NA "named 미운영"
else
  at=$(conf_line 'allow-transfer' /etc/named.conf /etc/bind/named.conf* /etc/named/*.conf 2>/dev/null)
  if [ -z "$at" ]; then rep U-50 "DNS Zone Transfer 설정" VULN "allow-transfer 미설정 → 기본 전체 허용 가능"
  elif echo "$at" | grep -qiE 'any'; then rep U-50 "DNS Zone Transfer 설정" VULN "allow-transfer { any } → 전체 허용"
  else rep U-50 "DNS Zone Transfer 설정" GOOD "allow-transfer 특정 대상 지정: $(echo $at | cut -c1-120)"; fi
fi

# U-51 DNS 취약한 동적 업데이트 설정 금지   [기준] 양호 - 비활성화 또는 접근통제 / 취약 - 활성화+통제없음
if [ "$dns_srv" -eq 0 ]; then rep U-51 "DNS 취약한 동적 업데이트 설정 금지" NA "named 미운영"
else
  au=$(conf_line 'allow-update' /etc/named.conf /etc/bind/named.conf* /etc/named/*.conf 2>/dev/null)
  if [ -z "$au" ] || echo "$au" | grep -qiE 'none|\{\s*\}'; then rep U-51 "DNS 취약한 동적 업데이트 설정 금지" GOOD "allow-update none (동적 업데이트 비활성화)"
  elif echo "$au" | grep -qiE 'any'; then rep U-51 "DNS 취약한 동적 업데이트 설정 금지" VULN "allow-update { any } → 무제한 동적 업데이트"
  else rep U-51 "DNS 취약한 동적 업데이트 설정 금지" MAN "allow-update 설정 존재 ($au) → 키/IP 기반 접근통제 적정성 확인"; fi
fi

# U-52 Telnet 서비스 비활성화   [기준] 양호 - 비활성화(SSH 사용) / 취약 - 활성화
if port_listen 23 || svc_active telnet.socket || proc_run "in.telnetd|telnetd"; then
  rep U-52 "Telnet 서비스 비활성화" VULN "Telnet(23) 활성 → SSH 로 대체 필요"
else rep U-52 "Telnet 서비스 비활성화" GOOD "Telnet 미실행"; fi

# FTP 공통
ftp_run=0; port_listen 21 && ftp_run=1
proc_run "vsftpd|proftpd|in.ftpd|pure-ftpd" && ftp_run=1
ftp_conf=""
[ -e /etc/vsftpd/vsftpd.conf ] && ftp_conf=/etc/vsftpd/vsftpd.conf
[ -z "$ftp_conf" ] && [ -e /etc/vsftpd.conf ] && ftp_conf=/etc/vsftpd.conf
[ -z "$ftp_conf" ] && [ -e /etc/proftpd/proftpd.conf ] && ftp_conf=/etc/proftpd/proftpd.conf

# U-53 FTP 서비스 정보 노출 제한   [기준] 양호 - 배너에 버전 정보 미노출 / 취약 - 노출
if [ "$ftp_run" -eq 0 ]; then rep U-53 "FTP 서비스 정보 노출 제한" NA "FTP 서비스 미실행"
elif grep -qiE '^[[:space:]]*(ftpd_banner|banner_file)[[:space:]]*=' "$ftp_conf" 2>/dev/null || grep -qiE '^[[:space:]]*(ServerIdent[[:space:]]+off|DisplayLogin)' "$ftp_conf" 2>/dev/null; then
  rep U-53 "FTP 서비스 정보 노출 제한" GOOD "FTP 배너 커스터마이즈/버전 숨김 설정 존재"
else
  rep U-53 "FTP 서비스 정보 노출 제한" VULN "FTP 배너에 기본 버전 정보 노출 (ftpd_banner/ServerIdent off 미설정)"
fi

# U-54 암호화되지 않는 FTP 서비스 비활성화   [기준] 양호 - 평문 FTP 비활성화 / 취약 - 활성화
if [ "$ftp_run" -eq 0 ]; then
  if pkg_installed vsftpd || pkg_installed proftpd || pkg_installed proftpd-basic; then rep U-54 "암호화되지 않는 FTP 서비스 비활성화" GOOD "FTP 패키지 설치됐으나 미실행"
  else rep U-54 "암호화되지 않는 FTP 서비스 비활성화" GOOD "평문 FTP 미설치/미실행 (SFTP는 SSH 기반)"; fi
elif grep -qiE '^[[:space:]]*(ssl_enable|TLSEngine)[[:space:]]*(=|[[:space:]])[[:space:]]*(YES|on)' "$ftp_conf" 2>/dev/null; then
  rep U-54 "암호화되지 않는 FTP 서비스 비활성화" MAN "FTP(21) 실행 중이나 TLS 설정 존재 → 평문 접속 강제 차단(force TLS) 여부 확인"
else
  rep U-54 "암호화되지 않는 FTP 서비스 비활성화" VULN "평문 FTP(21) 실행 중 (TLS 미설정) → SFTP/FTPS 로 전환"
fi

# U-55 FTP 계정 Shell 제한   [기준] 양호 - ftp 계정 셸 nologin/false / 취약 - 아님
ftpsh=$(awk -F: '$1=="ftp"{print $7}' /etc/passwd)
if [ -z "$ftpsh" ]; then rep U-55 "FTP 계정 Shell 제한" NA "ftp 계정 없음"
elif echo "$ftpsh" | grep -qE 'nologin|false'; then rep U-55 "FTP 계정 Shell 제한" GOOD "ftp 계정 셸=$ftpsh"
else rep U-55 "FTP 계정 Shell 제한" VULN "ftp 계정 셸=$ftpsh (nologin/false 필요)"; fi

# U-56 FTP 서비스 접근 제어 설정   [기준] 양호 - 특정 IP/호스트만 허용 / 취약 - 미적용
if [ "$ftp_run" -eq 0 ]; then rep U-56 "FTP 서비스 접근 제어 설정" NA "FTP 미실행"
elif grep -qiE '^[[:space:]]*tcp_wrappers[[:space:]]*=[[:space:]]*YES' "$ftp_conf" 2>/dev/null && grep -qiE 'ftp|vsftpd' /etc/hosts.allow 2>/dev/null; then
  rep U-56 "FTP 서비스 접근 제어 설정" GOOD "vsftpd tcp_wrappers=YES + hosts.allow 제한"
elif grep -qiE '^[[:space:]]*<Limit|AllowUser|DenyAll' "$ftp_conf" 2>/dev/null; then
  rep U-56 "FTP 서비스 접근 제어 설정" GOOD "proftpd <Limit> 접근 제어 설정"
else
  rep U-56 "FTP 서비스 접근 제어 설정" VULN "FTP 접근 제어(tcp_wrappers/<Limit>) 미설정"
fi

# U-57 Ftpusers 파일 설정   [기준] 양호 - root 계정 FTP 접속 차단 / 취약 - 허용
if [ "$ftp_run" -eq 0 ] && ! pkg_installed vsftpd && ! pkg_installed proftpd; then
  rep U-57 "Ftpusers 파일 설정" NA "FTP 미설치/미실행 → root FTP 접속 위협 없음"
elif grep -qiE '^root$' /etc/ftpusers /etc/vsftpd/ftpusers /etc/vsftpd.ftpusers 2>/dev/null; then
  rep U-57 "Ftpusers 파일 설정" GOOD "ftpusers 에 root 포함 (FTP 접속 차단)"
elif grep -qiE '^[[:space:]]*userlist_deny[[:space:]]*=[[:space:]]*NO' "$ftp_conf" 2>/dev/null && grep -qiE '^root$' /etc/vsftpd/user_list 2>/dev/null; then
  rep U-57 "Ftpusers 파일 설정" GOOD "vsftpd user_list(허용목록)에 root 미포함"
else
  rep U-57 "Ftpusers 파일 설정" VULN "ftpusers/user_list 에 root 차단 설정 없음 → root FTP 접속 가능"
fi

# SNMP 공통
snmp_run=0
{ svc_active snmpd || port_listen 161 || proc_run snmpd; } && snmp_run=1
snmp_conf=/etc/snmp/snmpd.conf

# U-58 불필요한 SNMP 서비스 구동 점검   [기준] 양호 - 미사용 / 취약 - 사용
if [ "$snmp_run" -eq 1 ]; then rep U-58 "불필요한 SNMP 서비스 구동 점검" VULN "SNMP(snmpd/161) 실행 중 → 미사용 시 중지"
else rep U-58 "불필요한 SNMP 서비스 구동 점검" GOOD "SNMP 미실행"; fi

# U-59 안전한 SNMP 버전 사용   [기준] 양호 - v3 이상 / 취약 - v2 이하
if [ "$snmp_run" -eq 0 ]; then rep U-59 "안전한 SNMP 버전 사용" NA "SNMP 미실행"
elif grep -qiE '^[[:space:]]*(createUser|rouser|rwuser)' "$snmp_conf" 2>/dev/null && ! grep -qiE '^[[:space:]]*(rocommunity|rwcommunity)[[:space:]]' "$snmp_conf" 2>/dev/null; then
  rep U-59 "안전한 SNMP 버전 사용" GOOD "SNMPv3(createUser/rouser)만 사용, v1/v2c community 없음"
else
  rep U-59 "안전한 SNMP 버전 사용" VULN "SNMP v1/v2c community 설정 존재 → v3 전용으로 전환"
fi

# U-60 SNMP Community String 복잡성 설정
# [기준] 양호 - public/private 아님 + 복잡성 충족 / 취약 - 기본값 또는 단순
if [ "$snmp_run" -eq 0 ]; then rep U-60 "SNMP Community String 복잡성 설정" NA "SNMP 미실행"
elif grep -qiE '^[[:space:]]*(rocommunity|rwcommunity)[[:space:]]+(public|private)\b' "$snmp_conf" 2>/dev/null; then
  rep U-60 "SNMP Community String 복잡성 설정" VULN "community=public/private (기본값 사용)"
elif grep -qiE '^[[:space:]]*(rocommunity|rwcommunity)[[:space:]]+\S{1,7}\b' "$snmp_conf" 2>/dev/null; then
  rep U-60 "SNMP Community String 복잡성 설정" VULN "community 문자열이 8자리 미만 → 복잡성 미달"
elif grep -qiE '^[[:space:]]*(rocommunity|rwcommunity)' "$snmp_conf" 2>/dev/null; then
  rep U-60 "SNMP Community String 복잡성 설정" MAN "community 설정 존재(기본값 아님) → 문자 조합/길이 복잡성 상세 확인"
else
  rep U-60 "SNMP Community String 복잡성 설정" GOOD "v1/v2c community 미사용"
fi

# U-61 SNMP Access Control 설정   [기준] 양호 - 접근 제어 설정 / 취약 - 미설정
if [ "$snmp_run" -eq 0 ]; then rep U-61 "SNMP Access Control 설정" NA "SNMP 미실행"
elif grep -qiE '^[[:space:]]*com2sec|^[[:space:]]*(rocommunity|rwcommunity)[[:space:]]+\S+[[:space:]]+[0-9]' "$snmp_conf" 2>/dev/null; then
  rep U-61 "SNMP Access Control 설정" GOOD "snmpd.conf 에 com2sec/소스 IP 제한 설정 존재"
else
  rep U-61 "SNMP Access Control 설정" VULN "SNMP 접근 허용 대상(소스 IP) 제한 미설정"
fi

# U-62 로그인 시 경고 메시지 설정
# [기준] 양호 - 서버 및 Telnet/FTP/SMTP/DNS 서비스 로그온 시 경고 메시지 설정 / 취약 - 미설정
warn_re='(경고|허가|무단|승인|비인가|접근이 제한|unauthorized|authorized (users|personnel|access)|prohibited|monitored|warning|access is restricted)'
sshban=$(sshd_val banner)
b_local=0; b_ssh=0
grep -qiE "$warn_re" /etc/issue /etc/issue.net /etc/motd 2>/dev/null && b_local=1
{ [ -n "$sshban" ] && [ "$sshban" != none ] && { [ -s "$sshban" ] || grep -qiE "$warn_re" "$sshban" 2>/dev/null; }; } && b_ssh=1
if [ "$b_local" -eq 1 ] && [ "$b_ssh" -eq 1 ]; then
  rep U-62 "로그인 시 경고 메시지 설정" GOOD "서버 경고문(issue/motd) + SSH Banner 설정"
elif [ "$b_local" -eq 1 ] || [ "$b_ssh" -eq 1 ]; then
  rep U-62 "로그인 시 경고 메시지 설정" VULN "일부만 설정(서버 경고문=$b_local, SSH Banner=$b_ssh) → 서버 및 원격 서비스 전체에 경고 메시지 필요"
else
  rep U-62 "로그인 시 경고 메시지 설정" VULN "로그온 경고 메시지 미설정 (기본 issue 는 OS 정보만 노출)"
fi

# U-63 sudo 명령어 접근 관리   [기준] 양호 - /etc/sudoers 소유자 root + 권한 640 이하
if [ ! -e /etc/sudoers ]; then rep U-63 "sudo 명령어 접근 관리" NA "/etc/sudoers 없음"
else
  so=$(stat -c '%U' /etc/sudoers); sp=$(stat -c '%a' /etc/sudoers)
  d_bad=$(find /etc/sudoers.d -maxdepth 1 -type f 2>/dev/null | while read -r f; do
            p=$(stat -c '%a' "$f"); o=$(stat -c '%U' "$f"); { [ "$o" != root ] || ! perm_le "$p" 640; } && echo "$f($o,$p)"; done | tr '\n' ' ')
  nopw=$(grep -rhE '^[^#]*NOPASSWD:[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | grep -vE '^[[:space:]]*#' | awk '{print $1}' | tr '\n' ' ')
  if [ "$so" = root ] && perm_le "$sp" 640 && [ -z "$d_bad" ]; then
    rep U-63 "sudo 명령어 접근 관리" GOOD "/etc/sudoers 소유자=$so 권한=$sp + sudoers.d 권한 적절 (NOPASSWD:ALL 대상=${nopw:-없음})"
  else
    rep U-63 "sudo 명령어 접근 관리" VULN "sudoers=$so/$sp, sudoers.d 부적절:${d_bad:-없음} (기준: root, 640 이하)"
  fi
fi

#==============================================================================
echo -e "${W}[ 4. 패치 관리 ]${N}"
#==============================================================================

# U-64 주기적인 보안 패치 및 벤더 권고사항 적용
# [기준] 양호 - 패치 정책 수립 + 주기적 패치 관리 + 패치 확인/적용 / 취약 - 아님
sec_pend=$(sec_update_count '' '')   # 전체 보안 업데이트 건수 (dnf/yum/apt 자동 분기)
eol_note=""
case "${ID}:${VERSION_ID}" in
  debian:11) [ "$(date +%Y%m%d)" -ge 20260831 ] && eol_note=" (Debian 11 표준 지원 종료)";;
  ubuntu:20.04) [ "$(date +%Y%m%d)" -ge 20250531 ] && eol_note=" (Ubuntu 20.04 표준 지원 종료, ESM 필요)";;
  amzn:2) [ "$(date +%Y%m%d)" -ge 20260630 ] && eol_note=" (Amazon Linux 2 지원 종료 임박/종료)";;
esac
if [ "$sec_pend" != "?" ] && [ "${sec_pend:-0}" -gt 0 ]; then
  rep U-64 "주기적인 보안 패치 및 벤더 권고사항 적용" VULN "미적용 보안 업데이트 약 ${sec_pend}건$eol_note"
elif [ -n "$eol_note" ]; then
  rep U-64 "주기적인 보안 패치 및 벤더 권고사항 적용" VULN "OS 지원 종료$eol_note → 보안 패치 수급 불가"
else
  rep U-64 "주기적인 보안 패치 및 벤더 권고사항 적용" MAN "미적용 보안 업데이트 없음(sec_pend=$sec_pend). 패치 적용 정책/주기/이력은 인터뷰 확인"
fi

#==============================================================================
echo -e "${W}[ 5. 로그 관리 ]${N}"
#==============================================================================

# U-65 NTP 및 시각 동기화 설정   [기준] 양호 - NTP/시각 동기화가 기준에 따라 적용 / 취약 - 아님
ntp_svc=""
for s in chronyd ntpd ntp systemd-timesyncd; do svc_active "$s" && ntp_svc="$s"; done
synced=$(timedatectl show 2>/dev/null | grep -E 'NTPSynchronized=yes|SystemClockSynchronized=yes')
if [ -n "$ntp_svc" ] && { [ -n "$synced" ] || chronyc tracking >/dev/null 2>&1 || ntpstat >/dev/null 2>&1; }; then
  rep U-65 "NTP 및 시각 동기화 설정" GOOD "$ntp_svc 활성 + 시각 동기화됨"
elif [ -n "$ntp_svc" ]; then
  rep U-65 "NTP 및 시각 동기화 설정" VULN "$ntp_svc 활성이나 동기화 미확인 → NTP 서버 접근/설정 확인"
else
  rep U-65 "NTP 및 시각 동기화 설정" VULN "NTP/시각 동기화 서비스 미실행"
fi

# U-66 정책에 따른 시스템 로깅 설정
# [기준] 양호 - 로그 기록 정책 수립 + 정책에 따라 설정 + 로그 기록 / 취약 - 미수립 또는 미기록
log_svc=""
for s in rsyslog syslog-ng systemd-journald; do svc_active "$s" && log_svc="$log_svc $s"; done
authlog_ok=0
{ grep -qsE 'auth(priv)?\.\*|authpriv' /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null; } && authlog_ok=1
[ "$FAM" = deb ] && [ -s /var/log/auth.log ] && authlog_ok=1
[ "$FAM" = rhel ] && [ -s /var/log/secure ] && authlog_ok=1
remote_log=$(grep -hsE '^[^#]*@@?[0-9A-Za-z]' /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null | head -1)
if [ -z "$log_svc" ]; then
  rep U-66 "정책에 따른 시스템 로깅 설정" VULN "시스템 로깅 서비스(rsyslog 등) 미실행 → 로그가 기록되지 않음"
elif [ "$authlog_ok" -eq 0 ]; then
  rep U-66 "정책에 따른 시스템 로깅 설정" VULN "로깅 서비스는 동작하나 인증(auth/secure) 로그 설정/기록 미확인"
else
  rep U-66 "정책에 따른 시스템 로깅 설정" MAN "로깅 정상 동작($log_svc), 인증 로그 기록됨, 원격 전송=${remote_log:+설정됨}. 로그 종류/보존기간 등 로깅 정책 수립 여부는 인터뷰 확인"
fi

# U-67 로그 디렉터리 및 로그 파일 소유자/권한
# [기준] 양호 - 디렉터리 내 로그 파일 소유자 root + 권한 644 이하 / 취약 - 아님
log_bad=""
dp=$(stat -c '%a' /var/log 2>/dev/null); do_=$(stat -c '%U' /var/log 2>/dev/null)
{ [ "$do_" = root ] && perm_le "$dp" 755; } || log_bad="$log_bad /var/log($do_,$dp)"
for f in $LOG_FILES $LOG_FILES_UTMP; do
  [ -e "$f" ] || continue
  p=$(stat -c '%a' "$f"); o=$(stat -c '%U' "$f")
  case " root syslog adm " in *" $o "*) : ;; *) log_bad="$log_bad ${f}(소유자=$o)";; esac
  perm_le "$p" 644 || log_bad="$log_bad ${f}($p)"
done
if [ -z "$log_bad" ]; then rep U-67 "로그 디렉토리 소유자 및 권한 설정" GOOD "/var/log 및 주요 로그 파일 소유자 root(syslog/adm) + 권한 644 이하"
else rep U-67 "로그 디렉토리 소유자 및 권한 설정" VULN "기준(root, 644 이하) 초과:$log_bad"; fi

#==============================================================================
echo
echo -e "${W}==============================================================${N}"
echo -e "${W} 요약${N}   ${G}양호=$good${N}   ${R}취약=$vuln${N}   ${Y}N/A=$na${N}   ${B}수동확인=$man${N}   (총 $((good+vuln+na+man)))"
echo -e "${W}==============================================================${N}"
echo -e " ${B}수동확인${N} 항목은 정책 수립 여부 등 인터뷰가 필요한 잔여 항목입니다."
echo -e " 이 스크립트는 읽기 전용입니다. 조치는 각 항목 [기준] 에 맞춰 별도 수행하세요."
echo

# ---- JSON 파일 출력 (GUI 연동: --json <파일>) ----
if [ -n "$JSON_FILE" ]; then
  {
    printf '{"host":"%s","os":"%s","family":"%s","results":[' \
      "$(json_escape "$(hostname)")" "$(json_escape "${PRETTY_NAME:-unknown}")" "$FAM"
    printf '%s' "${JBUF%,}"
    printf ']}'
  } > "$JSON_FILE"
  echo " JSON 저장: $JSON_FILE"
fi
