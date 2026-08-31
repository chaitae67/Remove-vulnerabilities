#!/usr/bin/env bash
#==============================================================================
# KISA 주요정보통신기반시설 기술적 취약점 점검 (Unix/Linux)  U-01 ~ U-67
#  - 2026 상세가이드 항목/판단기준 기반
#  - 읽기 전용(READ-ONLY): 자동 조치(수정) 없음. 판정 + 근거만 출력
#  - 대상: RHEL 계열(Rocky/Amazon Linux/RHEL) 및 Debian 계열(Debian/Ubuntu)
#  - 권장 실행: sudo bash kisa_unix_check.sh   (shadow/iptables 등 root 필요)
#
# 판정 표기
#   양호   : 기준 충족
#   취약   : 기준 미충족
#   N/A    : 해당 서비스/파일 미사용 → 점검 대상 없음
#   수동확인: 자동 판정이 부정확할 수 있어 사람이 근거를 보고 판단해야 하는 항목
#==============================================================================

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

# ---- JSON 출력용 (GUI 연동) ----
declare -A IMP=(
  [U-01]=상 [U-02]=상 [U-03]=상 [U-04]=상 [U-05]=상 [U-06]=상 [U-07]=하 [U-08]=중 [U-09]=하 [U-10]=중 [U-11]=하 [U-12]=하 [U-13]=중
  [U-14]=상 [U-15]=상 [U-16]=상 [U-17]=상 [U-18]=상 [U-19]=상 [U-20]=상 [U-21]=상 [U-22]=상 [U-23]=상 [U-24]=상 [U-25]=상 [U-26]=상 [U-27]=상 [U-28]=상 [U-29]=하 [U-30]=중 [U-31]=중 [U-32]=중 [U-33]=하
  [U-34]=상 [U-35]=상 [U-36]=상 [U-37]=상 [U-38]=상 [U-39]=상 [U-40]=상 [U-41]=상 [U-42]=상 [U-43]=상 [U-44]=상 [U-45]=상 [U-46]=상 [U-47]=상 [U-48]=중 [U-49]=상 [U-50]=상 [U-51]=중 [U-52]=중 [U-53]=하 [U-54]=중 [U-55]=중 [U-56]=하 [U-57]=중 [U-58]=중 [U-59]=상 [U-60]=중 [U-61]=상 [U-62]=하 [U-63]=중
  [U-64]=상 [U-65]=중 [U-66]=중 [U-67]=중
)
JBUF=""
json_escape() {   # 순수 bash (sed 미사용): 백슬래시/따옴표/제어문자 처리
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/ }
  s=${s//$'\r'/ }
  s=${s//$'\n'/ }
  printf '%s' "$s"
}

# ---- 결과 출력 ----
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
  printf "${C}%-6s${N} %-52s [%b]\n" "$code" "$title" "$tag"
  local l
  for l in "$@"; do printf "         ${W}·${N} %s\n" "$l"; done
  # --- JSON 누적 (GUI 연동) ---
  local ev="" first=1 e
  for l in "$@"; do
    e=$(json_escape "$l")
    if [ "$first" -eq 1 ]; then ev="\"$e\""; first=0; else ev="$ev,\"$e\""; fi
  done
  JBUF="${JBUF}{\"code\":\"$code\",\"importance\":\"${IMP[$code]}\",\"title\":\"$(json_escape "$title")\",\"status\":\"$kstat\",\"evidence\":[$ev]},"
}

# ---- 헬퍼 ----
octal_le() { [ "$(printf '%d' "0$1" 2>/dev/null || echo 999)" -le "$(printf '%d' "0$2")" ]; }

# 파일 소유자/권한 점검 (없으면 N/A)
chk_file() { # code title file maxperm owner
  local code="$1" title="$2" f="$3" maxp="$4" own="$5"
  if [ ! -e "$f" ]; then rep "$code" "$title" NA "$f 없음 → 해당없음"; return; fi
  local p o; p=$(stat -c '%a' "$f" 2>/dev/null); o=$(stat -c '%U' "$f" 2>/dev/null)
  if [ "$o" = "$own" ] && octal_le "$p" "$maxp"; then
    rep "$code" "$title" GOOD "$f  소유자=$o 권한=$p  (기준: $own, ${maxp} 이하)"
  else
    rep "$code" "$title" VULN "$f  소유자=$o 권한=$p  (기준: $own, ${maxp} 이하)"
  fi
}

port_listen() { ss -lntuH 2>/dev/null | grep -qE "[:.]$1[[:space:]]" || netstat -lntu 2>/dev/null | grep -qE "[:.]$1[[:space:]]"; }
proc_run()   { pgrep -x "$1" >/dev/null 2>&1 || pgrep -f "$1" >/dev/null 2>&1; }
pkg_installed(){ { command -v rpm >/dev/null && rpm -q "$1" >/dev/null 2>&1; } || { command -v dpkg >/dev/null && dpkg -s "$1" >/dev/null 2>&1; }; }
svc_active() { systemctl is-active "$1" 2>/dev/null | grep -q '^active$'; }

# ---- OS 정보 ----
. /etc/os-release 2>/dev/null
FAM="unknown"
command -v rpm  >/dev/null 2>&1 && FAM="rhel"
command -v dpkg >/dev/null 2>&1 && FAM="deb"

# ---- 배포판별 PAM 파일 경로 ----
# RHEL 계열(Amazon Linux/Rocky): system-auth + password-auth
# Debian 계열(Ubuntu/Debian)   : common-password / common-auth / common-account
if [ "$FAM" = "rhel" ]; then
  PAM_PW="/etc/pam.d/system-auth /etc/pam.d/password-auth"
  PAM_AUTH="/etc/pam.d/system-auth /etc/pam.d/password-auth"
else
  PAM_PW="/etc/pam.d/common-password"
  PAM_AUTH="/etc/pam.d/common-auth /etc/pam.d/common-account"
fi

echo
echo -e "${W}==============================================================${N}"
echo -e "${W} KISA Unix/Linux 취약점 점검 (U-01~U-67)  READ-ONLY${N}"
echo -e "${W}==============================================================${N}"
echo -e " 호스트 : $(hostname)"
echo -e " OS     : ${PRETTY_NAME:-unknown}  (family=$FAM)"
echo -e " 시각   : $(date '+%Y-%m-%d %H:%M:%S')"
[ "$(id -u)" -ne 0 ] && echo -e " ${Y}주의: root가 아니라 일부 항목(shadow/iptables 등) 확인이 제한될 수 있습니다.${N}"
echo

#==============================================================================
echo -e "${W}[ 1. 계정 관리 ]${N}"
#==============================================================================

# U-01 root 계정 원격 접속 제한 (Telnet securetty + SSH PermitRootLogin)
telnet_on=0
port_listen 23 && telnet_on=1
systemctl is-active telnet.socket >/dev/null 2>&1 && telnet_on=1
proc_run "in.telnetd\|telnetd" && telnet_on=1
# [Telnet 측]
if [ "$telnet_on" -eq 0 ]; then
  tv=GOOD; te="telnet 미사용"
elif [ ! -e /etc/securetty ]; then
  tv=VULN; te="telnet 사용 중 + /etc/securetty 없음(root 원격 제한 없음)"
elif grep -v '^#' /etc/securetty 2>/dev/null | grep -q 'pts'; then
  tv=VULN; te="securetty에 pts 존재(root 원격 접속 허용)"
elif ! grep -q 'pam_securetty' /etc/pam.d/login 2>/dev/null; then
  tv=VULN; te="securetty엔 pts 없으나 pam_securetty 미적용"
else
  tv=GOOD; te="securetty pts 없음 + pam_securetty 적용"
fi
# [SSH 측] 실제 유효값은 sshd -T 로 확인
prl=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
[ -z "$prl" ] && prl=$(grep -iE '^[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
if [ ! -e /etc/ssh/sshd_config ]; then sv=NA; se="sshd 없음"
elif [ "$prl" = "no" ]; then sv=GOOD; se="PermitRootLogin=no"
elif echo "$prl" | grep -qiE 'prohibit-password|forced-commands-only'; then sv=MAN; se="PermitRootLogin=$prl(키기반 root 접속 가능 → 정책 확인)"
elif [ -z "$prl" ]; then sv=MAN; se="PermitRootLogin 확인 불가"
else sv=VULN; se="PermitRootLogin=$prl(root 접속 허용)"
fi
if [ "$tv" = VULN ] || [ "$sv" = VULN ]; then fv=VULN
elif [ "$tv" = MAN ] || [ "$sv" = MAN ]; then fv=MAN
else fv=GOOD; fi
rep U-01 "root 계정 원격 접속 제한" $fv "Telnet: $te" "SSH: $se"

# U-02 비밀번호 관리정책 설정 (기준: 최대90/최소1일, 길이8, 재사용4, 복잡성)
maxd=$(awk '/^PASS_MAX_DAYS/{print $2}' /etc/login.defs 2>/dev/null)
mind=$(awk '/^PASS_MIN_DAYS/{print $2}' /etc/login.defs 2>/dev/null)
minl=$(awk '/^PASS_MIN_LEN/{print $2}'  /etc/login.defs 2>/dev/null)
pqlen=$(grep -hE '^[[:space:]]*minlen' /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null | grep -oE '[0-9]+' | tail -1)
remember=$(grep -rhoE 'remember=[0-9]+' /etc/security/pwhistory.conf $PAM_PW 2>/dev/null | grep -oE '[0-9]+' | head -1)
cmplx=$(grep -hE '^[[:space:]]*(minclass|dcredit|ucredit|lcredit|ocredit)' /etc/security/pwquality.conf 2>/dev/null | tr '\n' ' ')
grep -hqE 'pam_pwquality|pam_cracklib' $PAM_PW 2>/dev/null && [ -z "$cmplx" ] && cmplx="pam_pwquality 적용(값 확인)"
ml=${pqlen:-$minl}; miss=""
{ [ -n "$maxd" ] && [ "$maxd" -le 90 ] && [ "$maxd" -gt 0 ]; } || miss="$miss 최대사용일(${maxd:-미설정})"
{ [ -n "$mind" ] && [ "$mind" -ge 1 ]; } || miss="$miss 최소사용일(${mind:-미설정})"
{ [ -n "$ml" ] && [ "$ml" -ge 8 ]; } || miss="$miss 최소길이(${ml:-미설정})"
{ [ -n "$remember" ] && [ "$remember" -ge 4 ]; } || miss="$miss 재사용제한(${remember:-미설정})"
ev="MAX=${maxd:-미} MIN=${mind:-미} LEN=${ml:-미} remember=${remember:-미} 복잡성=[${cmplx:-미설정}]"
if [ -z "$miss" ] && [ -n "$cmplx" ]; then
  rep U-02 "비밀번호 관리정책 설정" GOOD "$ev"
elif [ -n "$miss" ]; then
  rep U-02 "비밀번호 관리정책 설정" VULN "미흡:$miss" "$ev (기준 90/1/8/4+복잡성)"
else
  rep U-02 "비밀번호 관리정책 설정" MAN "복잡성 설정 확인 필요" "$ev"
fi

# U-03 계정 잠금 임계값 설정 (기준: deny <= 10)
deny=$(grep -rhoE 'deny[[:space:]]*=[[:space:]]*[0-9]+' /etc/security/faillock.conf $PAM_AUTH 2>/dev/null | grep -oE '[0-9]+' | head -1)
if grep -rhqE 'pam_faillock|pam_tally2' $PAM_AUTH /etc/security/faillock.conf 2>/dev/null; then
  if [ -n "$deny" ] && [ "$deny" -ge 1 ] && [ "$deny" -le 10 ]; then
    rep U-03 "계정 잠금 임계값 설정" GOOD "잠금 모듈 적용 + deny=$deny (<=10)"
  else
    rep U-03 "계정 잠금 임계값 설정" VULN "모듈 적용됐으나 deny=${deny:-미설정} (10 이하 필요)"
  fi
else
  rep U-03 "계정 잠금 임계값 설정" VULN "pam_faillock/pam_tally2 미적용(임계값 없음)"
fi

# U-04 비밀번호 파일 보호 (shadow 사용)
if awk -F: '$2!="x" && $2!="*" && $2!="!" && $2!="!!" {c++} END{exit (c>0)?0:1}' /etc/passwd; then
  rep U-04 "비밀번호 파일 보호" VULN "/etc/passwd 2번째 필드에 해시가 직접 존재(shadow 미사용)"
else
  rep U-04 "비밀번호 파일 보호" GOOD "패스워드가 /etc/shadow로 분리됨(passwd 2번째 필드 = x)"
fi

# U-05 root 이외의 UID 0 금지
uid0=$(awk -F: '$3==0 {print $1}' /etc/passwd | grep -vx root | tr '\n' ' ')
if [ -z "$uid0" ]; then
  rep U-05 "root 이외의 UID '0' 금지" GOOD "UID 0 계정 = root 뿐"
else
  rep U-05 "root 이외의 UID '0' 금지" VULN "UID 0 추가 계정: $uid0"
fi

# U-06 사용자 계정 su 기능 제한
if grep -qE '^[[:space:]]*auth.*pam_wheel\.so' /etc/pam.d/su 2>/dev/null; then
  rep U-06 "사용자 계정 su 기능 제한" GOOD "/etc/pam.d/su 에 pam_wheel 제한 적용"
else
  rep U-06 "사용자 계정 su 기능 제한" MAN "pam_wheel 미적용 → wheel 그룹 기반 su 제한 확인 필요"
fi

# U-07 불필요한 계정 제거
unnec=""; for u in lp uucp nuucp games gopher news adm sync shutdown halt; do
  grep -q "^$u:" /etc/passwd 2>/dev/null && unnec="$unnec $u"; done
rep U-07 "불필요한 계정 제거" MAN "기본 시스템 계정 존재:${unnec:- 없음} → 미사용 계정 여부 확인"

# U-08 관리자 그룹에 최소한의 계정 포함
rootg=$(getent group root | awk -F: '{print $4}')
rep U-08 "관리자 그룹에 최소한의 계정 포함" MAN "root 그룹 멤버: ${rootg:-없음} → 불필요 계정 포함 여부 확인"

# U-09 계정이 존재하지 않는 GID 금지 (사용자 없는 그룹은 정상; 여기선 근거 제시)
rep U-09 "계정이 존재하지 않는 GID 금지" MAN "불필요/미사용 그룹 존재 여부는 조직 정책에 따라 확인"

# U-10 동일한 UID 금지
dupuid=$(awk -F: '{print $3}' /etc/passwd | sort | uniq -d | tr '\n' ' ')
if [ -z "$dupuid" ]; then
  rep U-10 "동일한 UID 금지" GOOD "중복 UID 없음"
else
  rep U-10 "동일한 UID 금지" VULN "중복 UID: $dupuid"
fi

# U-11 사용자 Shell 점검 (로그인 불필요 시스템계정의 셸 제한)
badshell=$(awk -F: '($3<1000 && $3!=0) && $7 !~ /(nologin|false|sync|shutdown|halt)/ {print $1"("$7")"}' /etc/passwd | tr '\n' ' ')
if [ -z "$badshell" ]; then
  rep U-11 "사용자 Shell 점검" GOOD "시스템 계정에 로그인 셸 없음(nologin/false)"
else
  rep U-11 "사용자 Shell 점검" MAN "로그인 셸 가진 시스템계정: $badshell → 필요성 확인"
fi

# U-12 세션 종료 시간 설정 (TMOUT)
tmout=$(grep -rhE '^[[:space:]]*(export[[:space:]]+)?TMOUT=' /etc/profile /etc/profile.d/ /etc/bashrc /etc/bash.bashrc 2>/dev/null | grep -oE 'TMOUT=[0-9]+' | head -1 | cut -d= -f2)
if [ -n "$tmout" ] && [ "$tmout" -gt 0 ] && [ "$tmout" -le 600 ]; then
  rep U-12 "세션 종료 시간 설정" GOOD "TMOUT=$tmout (<=600)"
else
  rep U-12 "세션 종료 시간 설정" VULN "TMOUT ${tmout:-미설정} (600초 이하 권장)"
fi

# U-13 안전한 비밀번호 암호화 알고리즘 사용
em=$(grep -E '^ENCRYPT_METHOD' /etc/login.defs 2>/dev/null | awk '{print $2}')
sha=$(awk -F: '$2 ~ /^\$6\$/ {c++} END{print c+0}' /etc/shadow 2>/dev/null)
if echo "$em" | grep -qiE 'SHA512|SHA256|YESCRYPT'; then
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" GOOD "ENCRYPT_METHOD=$em, SHA512 해시 계정=$sha"
else
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" MAN "ENCRYPT_METHOD=${em:-미설정} (SHA512 권장), \$6\$해시=$sha"
fi

#==============================================================================
echo -e "${W}[ 2. 파일 및 디렉토리 관리 ]${N}"
#==============================================================================

# U-14 root 홈, PATH 디렉터리 권한 및 PATH 설정 ('.' 포함 여부)
if echo "$PATH" | grep -qE '(^|:)\.($|:)|(^|:):'; then
  rep U-14 "root 홈, PATH 디렉터리 및 PATH 설정" VULN "PATH에 '.' 또는 '::' 포함: $PATH"
else
  rep U-14 "root 홈, PATH 디렉터리 및 PATH 설정" GOOD "PATH에 '.'/'::' 없음"
fi

# U-15 파일 및 디렉터리 소유자 설정 (nouser/nogroup)
orphan=$(find / -xdev \( -nouser -o -nogroup \) 2>/dev/null | head -5)
oc=$(find / -xdev \( -nouser -o -nogroup \) 2>/dev/null | wc -l)
if [ "$oc" -eq 0 ]; then
  rep U-15 "파일 및 디렉터리 소유자 설정" GOOD "소유자/그룹 없는 파일 없음"
else
  rep U-15 "파일 및 디렉터리 소유자 설정" VULN "소유자/그룹 없는 파일 ${oc}개 (예: $(echo $orphan | cut -c1-120))"
fi

# U-16 /etc/passwd
chk_file U-16 "/etc/passwd 소유자 및 권한 설정" /etc/passwd 644 root
# U-17 시스템 시작 스크립트 권한 설정
ssbad=$(find -L /etc/systemd/system /lib/systemd/system /etc/rc.d /etc/init.d -maxdepth 2 -type f \( ! -user root -o -perm -002 \) 2>/dev/null | head -5)
if [ -z "$ssbad" ]; then
  rep U-17 "시스템 시작 스크립트 권한 설정" GOOD "시작 스크립트 root 소유 + other 쓰기 없음"
else
  rep U-17 "시스템 시작 스크립트 권한 설정" VULN "부적절 항목: $(echo $ssbad | cut -c1-120)"
fi
# U-18 /etc/shadow
chk_file U-18 "/etc/shadow 소유자 및 권한 설정" /etc/shadow 640 root
# U-19 /etc/hosts
chk_file U-19 "/etc/hosts 소유자 및 권한 설정" /etc/hosts 600 root
# U-20 /etc/(x)inetd.conf
if [ -e /etc/xinetd.conf ]; then chk_file U-20 "/etc/(x)inetd.conf 소유자 및 권한 설정" /etc/xinetd.conf 600 root
elif [ -e /etc/inetd.conf ]; then chk_file U-20 "/etc/(x)inetd.conf 소유자 및 권한 설정" /etc/inetd.conf 600 root
else rep U-20 "/etc/(x)inetd.conf 소유자 및 권한 설정" NA "(x)inetd 미사용"; fi
# U-21 /etc/(r)syslog.conf
if [ -e /etc/rsyslog.conf ]; then chk_file U-21 "/etc/(r)syslog.conf 소유자 및 권한 설정" /etc/rsyslog.conf 640 root
else chk_file U-21 "/etc/(r)syslog.conf 소유자 및 권한 설정" /etc/syslog.conf 640 root; fi
# U-22 /etc/services
chk_file U-22 "/etc/services 소유자 및 권한 설정" /etc/services 644 root

# U-23 SUID/SGID/Sticky 점검 (비정상 SUID/SGID 목록 제시)
suidc=$(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | wc -l)
rep U-23 "SUID, SGID, Sticky bit 설정 파일 점검" MAN "SUID/SGID 파일 ${suidc}개 → 알려진 정상 목록과 대조 필요 (find / -perm -4000 -o -perm -2000)"

# U-24 사용자/시스템 환경변수 파일 소유자 및 권한
envbad=""
for f in /etc/profile /etc/bashrc /etc/bash.bashrc; do
  [ -e "$f" ] || continue
  perl=$(stat -c '%a' "$f"); [ "$(stat -c '%U' "$f")" != root ] && envbad="$envbad $f(소유자)"; octal_le "$perl" 644 || envbad="$envbad $f($perl)"
done
if [ -z "$envbad" ]; then rep U-24 "사용자, 시스템 환경변수 파일 소유자 및 권한" GOOD "주요 환경파일 root 소유 + 644 이하"
else rep U-24 "사용자, 시스템 환경변수 파일 소유자 및 권한" VULN "부적절:$envbad (홈 dotfile은 추가 확인)"; fi

# U-25 world writable 파일 점검
wwc=$(find / -xdev -type f -perm -0002 2>/dev/null | wc -l)
wwex=$(find / -xdev -type f -perm -0002 2>/dev/null | head -3 | tr '\n' ' ')
if [ "$wwc" -eq 0 ]; then rep U-25 "world writable 파일 점검" GOOD "world writable 일반 파일 없음"
else rep U-25 "world writable 파일 점검" VULN "world writable 파일 ${wwc}개 (예: $wwex)"; fi

# U-26 /dev에 존재하지 않는 device 파일 점검
devf=$(find /dev -type f ! -path '/dev/shm/*' ! -path '/dev/mqueue/*' 2>/dev/null | head -5)
devc=$(find /dev -type f ! -path '/dev/shm/*' ! -path '/dev/mqueue/*' 2>/dev/null | wc -l)
if [ "$devc" -eq 0 ]; then rep U-26 "/dev에 존재하지 않는 device 파일 점검" GOOD "/dev 내 비정상 일반파일 없음(shm/mqueue 제외)"
else rep U-26 "/dev에 존재하지 않는 device 파일 점검" VULN "/dev 일반파일 ${devc}개: $(echo $devf|cut -c1-100)"; fi

# U-27 $HOME/.rhosts, hosts.equiv
rc=$(find / -xdev \( -name .rhosts -o -name hosts.equiv \) 2>/dev/null)
if [ -z "$rc" ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" GOOD ".rhosts/hosts.equiv 파일 없음"
else
  if grep -qE '^\+' $rc 2>/dev/null; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" VULN "'+' 설정 존재: $rc"
  else rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" MAN "파일 존재(내용/권한 확인): $rc"; fi
fi

# U-28 접속 IP 및 포트 제한
tcpw=$(grep -vE '^\s*#|^\s*$' /etc/hosts.allow /etc/hosts.deny 2>/dev/null | grep -c .)
fw="none"
svc_active firewalld && fw="firewalld"
{ command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi active; } && fw="ufw"
{ [ "$fw" = none ] && command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -q 'type filter'; } && fw="nftables"
{ [ "$fw" = none ] && iptables -S 2>/dev/null | grep -qvE '^-P|^-N'; } && fw="iptables"
if [ "$tcpw" -gt 0 ] || [ "$fw" != none ]; then
  rep U-28 "접속 IP 및 포트 제한" MAN "TCPWrapper설정=${tcpw}줄, 방화벽=$fw → 특정 IP/포트 제한 여부 확인"
else
  rep U-28 "접속 IP 및 포트 제한" VULN "TCPWrapper·방화벽 모두 제한 없음 (AWS라면 보안그룹 별도 확인)"
fi

# U-29 hosts.lpd
chk_file U-29 "hosts.lpd 파일 소유자 및 권한 설정" /etc/hosts.lpd 600 root

# U-30 UMASK
um=$(umask)
if octal_le "022" "$um" || [ "$(printf '%d' "0$um")" -ge "$(printf '%d' 022)" ]; then
  rep U-30 "UMASK 설정 관리" GOOD "umask=$um (022 이상)"
else
  rep U-30 "UMASK 설정 관리" VULN "umask=$um (022 이상 필요)"
fi

# U-31 홈 디렉토리 소유자 및 권한
homebad=$(awk -F: '$3>=1000 && $6 ~ /^\/home\// {print $1":"$6}' /etc/passwd | while IFS=: read u h; do
  [ -d "$h" ] || continue; o=$(stat -c '%U' "$h"); p=$(stat -c '%a' "$h")
  { [ "$o" != "$u" ] || [ "$((0$p & 022))" -ne 0 ]; } && echo "$h(소유자=$o,$p)"; done | tr '\n' ' ')
if [ -z "$homebad" ]; then rep U-31 "홈 디렉토리 소유자 및 권한 설정" GOOD "일반사용자 홈 소유자 일치 + group/other 쓰기 없음"
else rep U-31 "홈 디렉토리 소유자 및 권한 설정" VULN "부적절: $homebad"; fi

# U-32 홈 디렉토리로 지정한 디렉토리의 존재 관리
nohome=$(awk -F: '$3>=1000 && $6 ~ /^\/home\// {print $1":"$6}' /etc/passwd | while IFS=: read u h; do [ -d "$h" ] || echo "$u($h)"; done | tr '\n' ' ')
if [ -z "$nohome" ]; then rep U-32 "홈 디렉토리로 지정한 디렉토리의 존재 관리" GOOD "홈 디렉터리 모두 존재"
else rep U-32 "홈 디렉토리로 지정한 디렉토리의 존재 관리" VULN "홈 디렉터리 없음: $nohome"; fi

# U-33 숨겨진 파일 및 디렉토리 검색 및 제거
rep U-33 "숨겨진 파일 및 디렉토리 검색 및 제거" MAN "숨김파일(.*)은 정상도 많음 → 비정상 숨김파일 존재 여부 수동 확인"

#==============================================================================
echo -e "${W}[ 3. 서비스 관리 ]${N}"
#==============================================================================

svc_off_check() { # code title "port" "procpattern" "pkg"
  local code="$1" title="$2" port="$3" proc="$4" pkg="$5"
  if { [ -n "$port" ] && port_listen "$port"; } || { [ -n "$proc" ] && proc_run "$proc"; }; then
    rep "$code" "$title" VULN "서비스 실행/노출 중 (port=$port proc=$proc) → 미사용 시 비활성화"
  else
    rep "$code" "$title" GOOD "미실행/미노출"
  fi
}

# U-34 Finger
svc_off_check U-34 "Finger 서비스 비활성화" 79 "fingerd" ""
# U-35 공유 서비스 익명 접근 (anonymous FTP)
if grep -qi '^anonymous_enable=YES' /etc/vsftpd/vsftpd.conf /etc/vsftpd.conf 2>/dev/null; then
  rep U-35 "공유 서비스에 대한 익명 접근 제한 설정" VULN "vsftpd anonymous_enable=YES"
elif port_listen 21; then
  rep U-35 "공유 서비스에 대한 익명 접근 제한 설정" MAN "FTP 실행 중 → 익명 접근 설정 확인"
else
  rep U-35 "공유 서비스에 대한 익명 접근 제한 설정" NA "FTP 미실행 → 익명 접근 위협 없음"
fi
# U-36 r 계열
svc_off_check U-36 "r 계열 서비스 비활성화" 513 "rlogind|rshd|rexecd" ""
# U-37 crontab 설정파일 권한
crbad=""
for f in /etc/crontab /etc/cron.allow /etc/cron.deny; do
  [ -e "$f" ] || continue; p=$(stat -c '%a' "$f"); octal_le "$p" 640 || crbad="$crbad $f($p)"; done
if [ -z "$crbad" ]; then rep U-37 "crontab 설정파일 권한 설정" GOOD "crontab 관련 파일 640 이하"
else rep U-37 "crontab 설정파일 권한 설정" VULN "권한 과다:$crbad"; fi
# U-38 DoS 취약 서비스 (echo/discard/daytime/chargen)
dosp=""; for p in 7 9 13 19; do port_listen $p && dosp="$dosp $p"; done
if [ -z "$dosp" ]; then rep U-38 "DoS 공격에 취약한 서비스 비활성화" GOOD "echo/discard/daytime/chargen 미실행"
else rep U-38 "DoS 공격에 취약한 서비스 비활성화" VULN "취약 서비스 포트 실행:$dosp"; fi
# U-39 불필요한 NFS 서비스
if svc_active nfs-server || proc_run nfsd; then rep U-39 "불필요한 NFS 서비스 비활성화" VULN "NFS 서버 실행 중 → 미사용 시 중지"
else rep U-39 "불필요한 NFS 서비스 비활성화" GOOD "NFS 서버 미실행"; fi
# U-40 NFS 접근 통제
if [ -s /etc/exports ] && grep -qvE '^\s*#|^\s*$' /etc/exports 2>/dev/null; then
  if grep -qE '\*|everyone|no_root_squash|insecure' /etc/exports 2>/dev/null; then
    rep U-40 "NFS 접근 통제" VULN "/etc/exports 에 everyone(*)/no_root_squash 등 위험 설정"
  else
    rep U-40 "NFS 접근 통제" MAN "/etc/exports 공유 존재 → 호스트 지정/옵션 확인"
  fi
else
  rep U-40 "NFS 접근 통제" NA "exports 설정 없음(공유 없음)"
fi
# U-41 automountd
if proc_run automount || svc_active autofs; then rep U-41 "불필요한 automountd 제거" VULN "automount/autofs 실행 중 → 미사용 시 제거"
else rep U-41 "불필요한 automountd 제거" GOOD "automountd 미실행"; fi
# U-42 불필요한 RPC 서비스
rpcbad=$(rpcinfo -p 2>/dev/null | egrep -i 'cmsd|ttdbserver|sadmind|rusers|walld|spray|rstat|nisd|rexd|pcnfsd|ypupdated|rquotad|kcms|cachefs' | awk '{print $5}' | sort -u | tr '\n' ' ')
if [ -z "$rpcbad" ]; then rep U-42 "불필요한 RPC 서비스 비활성화" GOOD "위험 RPC 서비스 미등록(rpcbind만이면 양호)"
else rep U-42 "불필요한 RPC 서비스 비활성화" VULN "위험 RPC 등록: $rpcbad"; fi
# U-43 NIS, NIS+
if systemctl list-units --type=service 2>/dev/null | grep -qE 'ypserv|ypbind|ypxfrd|yppasswdd'; then
  rep U-43 "NIS, NIS+ 점검" VULN "NIS 관련 서비스 활성"
else rep U-43 "NIS, NIS+ 점검" GOOD "NIS 서비스 미사용"; fi
# U-44 tftp, talk
tt=""; port_listen 69 && tt="$tt tftp(69)"; proc_run "in.talkd\|talkd" && tt="$tt talk"
if [ -z "$tt" ]; then rep U-44 "tftp, talk 서비스 비활성화" GOOD "tftp/talk 미실행"
else rep U-44 "tftp, talk 서비스 비활성화" VULN "실행:$tt"; fi
# U-45 메일 서비스 버전
if port_listen 25 || proc_run "master\|sendmail"; then
  mv=$(postconf mail_version 2>/dev/null | awk '{print $3}'); [ -z "$mv" ] && mv=$(sendmail -d0.1 -bv root 2>/dev/null | grep -i version | head -1)
  rep U-45 "메일 서비스 버전 점검" MAN "메일 서비스 실행 중 (버전=${mv:-확인필요}) → 최신 보안버전 여부 확인"
else rep U-45 "메일 서비스 버전 점검" NA "메일 서비스 미실행"; fi
# U-46 일반 사용자의 메일 서비스 실행 방지 (postfix postsuper o-x)
if [ -e /usr/sbin/postsuper ]; then
  pp=$(stat -c '%a' /usr/sbin/postsuper)
  if [ "$((0$pp & 0001))" -eq 0 ]; then rep U-46 "일반 사용자의 메일 서비스 실행 방지" GOOD "postsuper 권한=$pp (other 실행 없음)"
  else rep U-46 "일반 사용자의 메일 서비스 실행 방지" VULN "postsuper 권한=$pp (other 실행 가능) → chmod o-x"; fi
elif grep -qi 'restrictqrun' /etc/mail/sendmail.cf 2>/dev/null; then
  rep U-46 "일반 사용자의 메일 서비스 실행 방지" GOOD "sendmail PrivacyOptions restrictqrun 설정"
else
  rep U-46 "일반 사용자의 메일 서비스 실행 방지" NA "postfix/sendmail 미확인"
fi
# U-47 스팸 메일 릴레이 제한
if command -v postconf >/dev/null 2>&1; then
  rr=$(postconf -h smtpd_relay_restrictions 2>/dev/null)$(postconf -h smtpd_recipient_restrictions 2>/dev/null)
  if echo "$rr" | grep -qE 'reject_unauth_destination|defer_unauth_destination'; then
    rep U-47 "스팸 메일 릴레이 제한" GOOD "릴레이 제한 설정됨(reject/defer_unauth_destination)"
  elif port_listen 25; then
    rep U-47 "스팸 메일 릴레이 제한" VULN "릴레이 제한 미설정(오픈릴레이 가능)"
  else
    rep U-47 "스팸 메일 릴레이 제한" NA "메일 미실행"
  fi
elif grep -qi 'promiscuous_relay' /etc/mail/sendmail.cf 2>/dev/null; then
  rep U-47 "스팸 메일 릴레이 제한" VULN "sendmail promiscuous_relay(오픈릴레이)"
else
  rep U-47 "스팸 메일 릴레이 제한" NA "메일 서비스 미확인"
fi
# U-48 expn, vrfy 명령어 제한
if port_listen 25; then
  if postconf -h disable_vrfy_command 2>/dev/null | grep -qi yes || grep -qiE 'noexpn|novrfy' /etc/mail/sendmail.cf 2>/dev/null; then
    rep U-48 "expn, vrfy 명령어 제한" GOOD "vrfy/expn 제한 설정"
  else rep U-48 "expn, vrfy 명령어 제한" MAN "메일 실행 중 → disable_vrfy_command=yes / noexpn,novrfy 확인"; fi
else rep U-48 "expn, vrfy 명령어 제한" NA "메일 미실행"; fi
# U-49 DNS 보안 버전 패치
if proc_run named || port_listen 53; then
  { port_listen 53 && ! (ss -lntuH 2>/dev/null|grep -qE '127.0.0.53'); }
  rep U-49 "DNS 보안 버전 패치" MAN "DNS(named) 관련 → BIND 버전/패치 확인 (127.0.0.53은 systemd-resolved로 서버 아님)"
else rep U-49 "DNS 보안 버전 패치" NA "BIND named 미실행"; fi
# U-50 DNS Zone Transfer
if proc_run named; then
  if grep -qiE 'allow-transfer' /etc/named.conf /etc/named/*.conf /etc/bind/named.conf* 2>/dev/null; then
    rep U-50 "DNS Zone Transfer 설정" MAN "allow-transfer 설정 존재 → 특정 IP만 허용/any 아님 확인"
  else rep U-50 "DNS Zone Transfer 설정" VULN "allow-transfer 미설정(기본 전체 허용 가능)"; fi
else rep U-50 "DNS Zone Transfer 설정" NA "named 미실행"; fi
# U-51 DNS 동적 업데이트
if proc_run named; then
  if grep -qiE 'allow-update\s*\{\s*none' /etc/named.conf /etc/bind/named.conf* 2>/dev/null; then rep U-51 "DNS 취약한 동적 업데이트 설정 금지" GOOD "allow-update none"
  else rep U-51 "DNS 취약한 동적 업데이트 설정 금지" MAN "allow-update 설정 확인(none/키기반 권장)"; fi
else rep U-51 "DNS 취약한 동적 업데이트 설정 금지" NA "named 미실행"; fi
# U-52 Telnet
svc_off_check U-52 "Telnet 서비스 비활성화" 23 "telnetd" ""
# U-53 FTP 서비스 정보 노출 제한 (banner)
if port_listen 21; then rep U-53 "FTP 서비스 정보 노출 제한" MAN "FTP 실행 중 → 배너에 버전정보 노출 여부 확인(ftpd_banner)"
else rep U-53 "FTP 서비스 정보 노출 제한" NA "FTP 미실행"; fi
# U-54 암호화되지 않는 FTP 서비스 비활성화
if port_listen 21 || pkg_installed vsftpd || pkg_installed proftpd-basic || pkg_installed proftpd; then
  if port_listen 21; then rep U-54 "암호화되지 않는 FTP 서비스 비활성화" VULN "평문 FTP(21) 실행 중 → SFTP/FTPS 권장"
  else rep U-54 "암호화되지 않는 FTP 서비스 비활성화" MAN "FTP 패키지 설치됨(미실행) → 필요성 확인"; fi
else rep U-54 "암호화되지 않는 FTP 서비스 비활성화" GOOD "평문 FTP 미실행/미설치"; fi
# U-55 FTP 계정 Shell 제한
ftpsh=$(awk -F: '$1=="ftp"{print $7}' /etc/passwd)
if [ -z "$ftpsh" ]; then rep U-55 "FTP 계정 Shell 제한" NA "ftp 계정 없음"
elif echo "$ftpsh" | grep -qE 'nologin|false'; then rep U-55 "FTP 계정 Shell 제한" GOOD "ftp 셸=$ftpsh"
else rep U-55 "FTP 계정 Shell 제한" VULN "ftp 셸=$ftpsh (nologin/false 필요)"; fi
# U-56 FTP 서비스 접근 제어
if port_listen 21; then rep U-56 "FTP 서비스 접근 제어 설정" MAN "FTP 실행 중 → ftphosts/TCP Wrapper 접근제어 확인"
else rep U-56 "FTP 서비스 접근 제어 설정" NA "FTP 미실행"; fi
# U-57 Ftpusers (root 차단)
if ! port_listen 21; then rep U-57 "Ftpusers 파일 설정" NA "FTP 미실행 → root FTP 접속 위협 없음"
elif grep -qiE '^root$' /etc/ftpusers /etc/vsftpd/ftpusers /etc/vsftpd/user_list 2>/dev/null; then rep U-57 "Ftpusers 파일 설정" GOOD "ftpusers에 root 포함(차단)"
else rep U-57 "Ftpusers 파일 설정" VULN "ftpusers에 root 없음 → root FTP 접속 가능"; fi
# U-58 불필요한 SNMP 서비스 구동
if svc_active snmpd || port_listen 161; then rep U-58 "불필요한 SNMP 서비스 구동 점검" VULN "SNMP(snmpd/161) 실행 중 → 미사용 시 중지"
else rep U-58 "불필요한 SNMP 서비스 구동 점검" GOOD "SNMP 미실행"; fi
# U-59 안전한 SNMP 버전
if port_listen 161; then
  if grep -qiE '^\s*createUser|^\s*rouser|^\s*rwuser' /etc/snmp/snmpd.conf 2>/dev/null; then rep U-59 "안전한 SNMP 버전 사용" MAN "SNMPv3 사용 흔적 → v1/v2c 미사용 확인"
  else rep U-59 "안전한 SNMP 버전 사용" VULN "SNMP 실행 중 v3 설정 미확인(v1/v2c 취약)"; fi
else rep U-59 "안전한 SNMP 버전 사용" NA "SNMP 미실행"; fi
# U-60 SNMP Community String
if port_listen 161; then
  if grep -qiE '^\s*(rocommunity|rwcommunity)\s+(public|private)\b' /etc/snmp/snmpd.conf 2>/dev/null; then rep U-60 "SNMP Community String 복잡성 설정" VULN "community=public/private 사용"
  else rep U-60 "SNMP Community String 복잡성 설정" MAN "community 문자열 복잡성 확인"; fi
else rep U-60 "SNMP Community String 복잡성 설정" NA "SNMP 미실행"; fi
# U-61 SNMP Access Control
if port_listen 161; then rep U-61 "SNMP Access Control 설정" MAN "snmpd.conf의 접근 허용 대상(com2sec/소스제한) 확인"
else rep U-61 "SNMP Access Control 설정" NA "SNMP 미실행"; fi
# U-62 로그인 시 경고 메시지
banner_ok=0
[ -s /etc/motd ] && banner_ok=1
grep -qiE '^\s*Banner\s+\S' /etc/ssh/sshd_config 2>/dev/null && banner_ok=1
[ -s /etc/issue.net ] && banner_ok=1
if [ "$banner_ok" -eq 1 ]; then rep U-62 "로그인 시 경고 메시지 설정" MAN "경고 배너 존재(motd/issue/sshd Banner) → 내용 적절성 확인"
else rep U-62 "로그인 시 경고 메시지 설정" VULN "로그인 경고 메시지 미설정"; fi
# U-63 sudo 명령어 접근 관리
if [ -e /etc/sudoers ]; then
  sp=$(stat -c '%a' /etc/sudoers)
  rep U-63 "sudo 명령어 접근 관리" MAN "sudoers 권한=$sp → NOPASSWD/ALL 남발 여부 및 최소권한 확인"
else rep U-63 "sudo 명령어 접근 관리" NA "sudoers 없음"; fi

#==============================================================================
echo -e "${W}[ 4. 패치 관리 ]${N}"
#==============================================================================
# U-64 주기적 보안 패치
if command -v dnf >/dev/null; then upd=$(dnf -q check-update 2>/dev/null | grep -c .)
elif command -v yum >/dev/null; then upd=$(yum -q check-update 2>/dev/null | grep -c .)
elif command -v apt >/dev/null; then upd=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst'); fi
rep U-64 "주기적 보안 패치 및 벤더 권고사항 적용" MAN "미적용 업데이트 약 ${upd:-확인필요}건 → 패치 정책/적용 이력 확인"

#==============================================================================
echo -e "${W}[ 5. 로그 관리 ]${N}"
#==============================================================================
# U-65 NTP 및 시각 동기화
if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes' || svc_active chronyd || svc_active ntpd || svc_active systemd-timesyncd; then
  rep U-65 "NTP 및 시각 동기화 설정" GOOD "시각 동기화 서비스 활성/동기화됨"
else rep U-65 "NTP 및 시각 동기화 설정" VULN "NTP/시각동기화 미설정"; fi
# U-66 정책에 따른 시스템 로깅
if svc_active rsyslog || svc_active syslog-ng || svc_active systemd-journald; then
  rep U-66 "정책에 따른 시스템 로깅 설정" MAN "로깅 서비스 활성 → 로그 종류/보존정책이 기준 충족하는지 확인"
else rep U-66 "정책에 따른 시스템 로깅 설정" VULN "시스템 로깅 서비스 미실행"; fi
# U-67 로그 디렉토리 소유자 및 권한
if [ -d /var/log ]; then
  lp=$(stat -c '%a' /var/log); lo=$(stat -c '%U' /var/log)
  if [ "$lo" = root ] && octal_le "$lp" 755; then rep U-67 "로그 디렉토리 소유자 및 권한 설정" GOOD "/var/log 소유자=$lo 권한=$lp"
  else rep U-67 "로그 디렉토리 소유자 및 권한 설정" VULN "/var/log 소유자=$lo 권한=$lp (root, 755 이하 권장)"; fi
else rep U-67 "로그 디렉토리 소유자 및 권한 설정" NA "/var/log 없음"; fi

#==============================================================================
echo
echo -e "${W}==============================================================${N}"
echo -e "${W} 요약${N}   ${G}양호=$good${N}   ${R}취약=$vuln${N}   ${Y}N/A=$na${N}   ${B}수동확인=$man${N}   (총 $((good+vuln+na+man)))"
echo -e "${W}==============================================================${N}"
echo -e " ${B}수동확인${N} 항목은 근거를 보고 사람이 최종 판정하세요."
echo -e " 이 스크립트는 읽기 전용입니다. 조치는 각 항목 기준에 맞춰 별도 수행하세요."
echo

# ---- JSON 파일 출력 (GUI 연동: --json <파일>) ----
if [ -n "$JSON_FILE" ]; then
  {
    printf '{"host":"%s","os":"%s","family":"%s","results":[' \
      "$(json_escape "$(hostname)")" "$(json_escape "${PRETTY_NAME:-unknown}")" "$FAM"
    printf '%s' "${JBUF%,}"
    printf ']}'
  } > "$JSON_FILE"
fi