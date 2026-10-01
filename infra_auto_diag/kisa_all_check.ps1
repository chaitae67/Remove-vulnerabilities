echo --% >/dev/null 2>&1 ; : ' | Out-Null
<#'
#==============================================================================
# kisa_all_check.ps1 — 인프라 + 웹서버 통합 점검 (리눅스·윈도우 겸용 단일 파일)
#   ※ 자동 생성 파일 — 직접 고치지 말고 원본 수정 후 build_allinone.py 로 재생성
#
#   리눅스 :  sudo bash kisa_all_check.ps1 [옵션]
#   윈도우 :  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1 [옵션]   (관리자)
#
#   1) 인프라 점검    : 리눅스 U-01~U-67 / 윈도우 W-01~W-64
#   2) 웹서비스 점검  : 감지된 웹서버마다 WEB-01~WEB-26
#                      (리눅스 Nginx·Tomcat / 윈도우 IIS·Tomcat, 미감지 시 생략)
#   결과 CSV(+웹은 HTML)는 4종으로 분리 저장 (현재 폴더, 한 번 실행한 결과는 같은 일시):
#     리눅스            server_linux_<호스트>_<YYYYMMDD_HHMM>.csv
#     리눅스 웹서비스   web_linux_<nginx|tomcat>_<호스트>_<YYYYMMDD_HHMM>.csv/.html
#     윈도우            server_windows_<호스트>_<YYYYMMDD_HHMM>.csv
#     윈도우 웹서비스   web_windows_<iis|tomcat>_<호스트>_<YYYYMMDD_HHMM>.csv/.html
#   → python make_reports.py <폴더> 로 바로 보고서 변환 가능
#
#   내장 원본: kisa_unix_check.sh(aeb06f83), kisa_win_check.ps1(e6956d73), web_linux_check.sh(243a6c2a), web_windows_check.ps1(c7713331)
#==============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

kisa_all_usage() {
  cat <<'__KISA_ALL_USAGE__'
사용법 (리눅스):  sudo bash kisa_all_check.ps1 [옵션]
  --only all|infra|web   실행 범위 (기본 all = 인프라 + 웹)
  -o, --out-dir DIR      결과(CSV/HTML) 저장 폴더 (기본: 현재 폴더)
  --no-save              결과 파일 저장 안 함(콘솔 출력만)
  --no-color             색상 끄기
  --force-web            웹서버가 감지되지 않아도 웹 점검 실행
  웹 점검 옵션(지정 시 해당 대상 1회만 점검, 그대로 전달):
    --target nginx|tomcat  --app-url URL  --app-jar JAR  --app-yml FILE  --conf nginx.conf  --nginx BIN
예)
  sudo bash kisa_all_check.ps1
  sudo bash kisa_all_check.ps1 --only web --target tomcat --app-url http://localhost:8080
  sudo bash kisa_all_check.ps1 -o /tmp/kisa_result
결과 파일: server_linux_<호스트>_<일시>.csv (리눅스) / web_linux_<nginx|tomcat>_<호스트>_<일시>.csv·.html (리눅스 웹서비스)
종료코드: 0 = 취약 없음, 1 = 취약 항목 존재, 2 = 실행 오류
__KISA_ALL_USAGE__
}

kisa_all_detect_web() {   # 감지된 웹서버 종류를 한 줄에 하나씩 출력 (nginx / tomcat)
  local b
  for b in nginx /usr/sbin/nginx /usr/local/nginx/sbin/nginx; do
    if command -v "$b" >/dev/null 2>&1; then echo nginx; break; fi
  done
  if ps -eo args 2>/dev/null | grep -iE 'java .*(\.jar|catalina|tomcat)' | grep -v grep >/dev/null; then
    echo tomcat
  fi
}

kisa_all_count() {        # $1=결과 JSON  $2=판정값  → 개수 (파일 없으면 -)
  if [ -f "$1" ]; then grep -o "\"status\":\"$2\"" "$1" | wc -l | tr -d ' '; else printf -- '-'; fi
}

kisa_all_main() {
  local only=all outdir="" force_web=0 nocolor=0 nosave=0 web_opt=0
  local -a common=() webargs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --only)        only="${2:-}"; shift 2 ;;
      -o|--out-dir)  outdir="${2:-}"; shift 2 ;;
      --force-web)   force_web=1; shift ;;
      --no-color)    nocolor=1; shift ;;
      --no-save)     nosave=1; shift ;;
      --target|--conf|--nginx|--app-jar|--app-yml|--app-url|--nginx-url)
                     webargs+=("$1" "${2:-}"); web_opt=1; shift 2 ;;
      -h|--help)     kisa_all_usage; return 0 ;;
      *)             echo "[!] 알 수 없는 옵션: $1  (--help 참고)" >&2; shift ;;
    esac
  done
  case "$only" in all|infra|web) ;; *) echo "[!] --only 는 all | infra | web 중 하나입니다" >&2; return 2 ;; esac
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      echo "[!] 윈도우에서는 PowerShell 로 실행하세요:  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1" >&2
      return 2 ;;
  esac
  [ "$nocolor" -eq 1 ] && common+=(--no-color)
  [ "$nosave" -eq 1 ] && common+=(--no-save)

  local H='' Y='' N=''
  if [ -t 1 ] && [ "$nocolor" -eq 0 ]; then H='\033[1;36m'; Y='\033[1;33m'; N='\033[0m'; fi

  # 내장 원본을 임시폴더(700)에 풀기 — 종료 시 자동 삭제
  local tmp
  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t kisa_all) || { echo "[!] 임시 폴더 생성 실패" >&2; return 2; }
  trap "rm -rf '$tmp'" EXIT
  chmod 700 "$tmp"
  kisa_payload_unix      > "$tmp/kisa_unix_check.sh"
  kisa_payload_web_linux > "$tmp/web_linux_check.sh"

  if [ -n "$outdir" ]; then
    mkdir -p "$outdir" && cd "$outdir" || { echo "[!] 출력 폴더로 이동 실패: $outdir" >&2; return 2; }
  fi
  [ "$(id -u)" -ne 0 ] && echo -e "${Y}[!] root 권한이 아닙니다 → shadow·sshd -T·방화벽 등 일부 항목이 '수동확인'으로 나옵니다 (권장: sudo bash kisa_all_check.ps1)${N}"

  local -a labels=() jsons=() files=()
  local rc=0 f
  # 4종 결과 파일명(한 번 실행한 결과는 같은 일시) — 호스트명 정리 방식은 원본(kisa_unix)과 동일
  local hostn stamp
  hostn=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-'); [ -z "$hostn" ] && hostn=linux
  stamp=$(date +%Y%m%d_%H%M)

  # ---- 1) 리눅스 (인프라) ----
  if [ "$only" != web ]; then
    echo; echo -e "${H}######## [1] 리눅스 — 인프라 U-01~U-67 ########${N}"
    local -a isave=()
    [ "$nosave" -eq 0 ] && isave=(--csv "server_linux_${hostn}_${stamp}.csv")
    bash "$tmp/kisa_unix_check.sh" --json "$tmp/infra.json" "${common[@]}" "${isave[@]}"
    labels+=("리눅스 (인프라 U-01~67)"); jsons+=("$tmp/infra.json")
    [ "$nosave" -eq 0 ] && files+=("server_linux_${hostn}_${stamp}.csv")
  fi

  # ---- 2) 리눅스 웹서비스 ----
  local web_note="" k kinds="" opt_target="" j
  if [ "$only" != infra ]; then
    local detected
    detected=$(kisa_all_detect_web)
    if [ "$web_opt" -eq 1 ]; then
      # 웹 옵션을 직접 준 경우 → 1회 실행. --target 이 없으면 원본(web_linux_check.sh)의
      # 자동 판단 규칙을 그대로 따라 대상을 정한다(파일명에 nginx/tomcat 을 넣기 위해).
      local has_ngx=0 has_java=0 has_conf=0 has_jar=0
      case " $detected " in *" nginx "*) has_ngx=1;; esac
      case " $detected " in *" tomcat "*) has_java=1;; esac
      for ((j = 0; j < ${#webargs[@]}; j += 2)); do
        case "${webargs[$j]}" in
          --target)            opt_target=$(printf '%s' "${webargs[$j+1]}" | tr 'A-Z' 'a-z') ;;
          --nginx)             has_ngx=1 ;;
          --conf)              has_conf=1 ;;
          --app-jar|--app-yml) has_jar=1 ;;
        esac
      done
      if [ -n "$opt_target" ]; then kinds=$opt_target
      elif [ "$has_ngx" -eq 1 ] && { [ "$has_java" -eq 0 ] || [ "$has_conf" -eq 1 ]; }; then kinds=nginx
      elif [ "$has_java" -eq 1 ] || [ "$has_jar" -eq 1 ]; then kinds=tomcat
      else kinds=nginx; fi
    else
      kinds=$detected
      if [ -z "$kinds" ] && { [ "$force_web" -eq 1 ] || [ "$only" = web ]; }; then
        echo -e "${Y}[!] 웹서버(nginx/Java WAS)가 감지되지 않았지만 요청에 따라 기본 대상(nginx)으로 점검합니다.${N}"
        kinds=nginx
      fi
      [ -z "$kinds" ] && web_note="웹서버(nginx/Java WAS) 미감지 → 리눅스 웹서비스 점검 생략  (강제: --force-web 또는 --target nginx|tomcat)"
    fi
    for k in $kinds; do
      echo; echo -e "${H}######## [2] 리눅스 웹서비스 — ${k} WEB-01~WEB-26 ########${N}"
      local -a wsave=() targ=()
      [ "$nosave" -eq 0 ] && wsave=(--csv "web_linux_${k}_${hostn}_${stamp}.csv" --html "web_linux_${k}_${hostn}_${stamp}.html")
      [ -z "$opt_target" ] && targ=(--target "$k")
      bash "$tmp/web_linux_check.sh" "${targ[@]}" --json "$tmp/web_$k.json" "${common[@]}" "${wsave[@]}" "${webargs[@]}"
      labels+=("리눅스 웹서비스 - $k (WEB-01~26)"); jsons+=("$tmp/web_$k.json")
      [ "$nosave" -eq 0 ] && files+=("web_linux_${k}_${hostn}_${stamp}.csv" "web_linux_${k}_${hostn}_${stamp}.html")
    done
  fi

  # ---- 통합 요약 ----
  local i v total_vuln=0
  echo
  echo -e "${H}==============================================================${N}"
  echo -e "${H} 통합 요약  —  $(hostname 2>/dev/null)  ($(date '+%Y-%m-%d %H:%M'))${N}"
  echo -e "${H}==============================================================${N}"
  # 한글은 printf 폭 계산이 어긋나므로 숫자 열을 앞에, 구분명을 맨 뒤에 둔다
  echo "   양호  취약   N/A  수동확인  구분"
  for i in "${!labels[@]}"; do
    v=$(kisa_all_count "${jsons[$i]}" 취약)
    printf ' %6s%6s%6s%10s  %s\n' "$(kisa_all_count "${jsons[$i]}" 양호)" "$v" \
      "$(kisa_all_count "${jsons[$i]}" N/A)" "$(kisa_all_count "${jsons[$i]}" 수동확인)" "${labels[$i]}"
    if [ "$v" = "-" ]; then echo -e "   ${Y}↳ 결과가 생성되지 않았습니다(점검 중 오류) — 위 출력 확인${N}"; rc=2
    else total_vuln=$((total_vuln + v)); fi
  done
  [ -n "$web_note" ] && echo " · $web_note"
  if [ "$nosave" -eq 0 ]; then
    echo " · 결과 파일 (저장 위치: $(pwd))"
    for f in "${files[@]}"; do
      if [ -f "$f" ]; then echo "     $f"; else echo -e "     ${Y}$f  ← 생성 안 됨${N}"; fi
    done
    echo "   → 보고서: python make_reports.py <이 폴더>"
  fi
  echo -e "${H}==============================================================${N}"
  [ "$rc" -ne 0 ] && return "$rc"
  [ "$total_vuln" -gt 0 ] && return 1
  return 0
}

# ------------------------------------------------------------------------------
# 내장 원본 (수정 금지 — build_allinone.py 가 원본 파일에서 그대로 복사)
# ------------------------------------------------------------------------------
kisa_payload_unix() {
  cat <<'__KISA_EMBED_UNIX_EOF__'
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
JSON_FILE=""; CSV_FILE=""; NO_SAVE=0; NOCOLOR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)     JSON_FILE="${2:-}"; shift 2 ;;
    --csv)      CSV_FILE="${2:-}"; shift 2 ;;
    --no-save)  NO_SAVE=1; shift ;;
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

JBUF=""; CBUF=""
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/ }; s=${s//$'\r'/ }; s=${s//$'\n'/ }
  printf '%s' "$s"
}

csv_escape() {   # CSV 필드 이스케이프(콤마/따옴표/줄바꿈 포함 시 큰따옴표로 감싸고 내부 " 는 "")
  local s=$1
  s=${s//$'\r'/ }; s=${s//$'\n'/ }
  case "$s" in
    *[,\"]* ) s=${s//\"/\"\"}; s="\"$s\"" ;;
  esac
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
  # CSV 한 줄(근거는 ' | ' 로 합침, 상태는 보고서 표기로)
  local evtext="" rstat="$kstat"; [ "$kstat" = "수동확인" ] && rstat="인터뷰 필요"; [ "$kstat" = "N/A" ] && rstat="양호"
  for l in "$@"; do evtext="${evtext:+$evtext | }$l"; done
  CBUF="${CBUF}$(csv_escape "$code"),$(csv_escape "${IMP[$code]}"),$(csv_escape "$title"),$(csv_escape "$rstat"),$(csv_escape "$evtext")
"
}

#------------------------------------------------------------------------------
# 공통 헬퍼
#------------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
# 느릴 수 있는 조회 명령을 제한 시간(초) 안에서만 실행 (timeout 이 없으면 그냥 실행)
run_to() { local s=$1; shift; if have timeout; then timeout -k 2 "$s" "$@"; else "$@"; fi; }

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

# 권한 'max 이하' 판정 (stat -c %a 출력 그대로 사용)
#   숫자 크기가 아니라 비트 부분집합으로 비교: max 에 없는 비트(소유자·그룹·기타·SUID/SGID/Sticky)가
#   하나라도 켜져 있으면 거짓.  예) 기준 644 → 600·640·444 참 / 622·466·4644·700 거짓
#   (숫자 비교는 622<644, 044<400 처럼 그룹·기타 권한이 더 넓어도 '이하'로 통과시켜 미탐이 났다)
perm_le() {
  local p m
  case "${1:-}" in ''|*[!0-7]*) return 1 ;; esac   # 빈 값·비정상 값(stat 실패) → 거짓
  p=$(( 8#$1 )); m=$(( 8#${2:-0} ))
  [ $(( p & ~m & 8#7777 )) -eq 0 ]
}
# (perm & mask) 비트가 하나라도 켜져 있으면 참  (예: 타 사용자 쓰기 검사 perm_has 002)
perm_has() { [ "$(( 8#${1:-0} & 8#$2 ))" -ne 0 ]; }

# 그룹/기타 권한이 기준을 넘지 않으면 참(소유자 권한·특수비트는 무시. 특수비트가 문제인 곳은 호출부에서 따로 검사 — 예: U-37 명령어).
#   그룹/기타 비트가 기준의 부분집합인지로 판단한다. 소유자·특수비트까지 보는 perm_le 와 다른 점:
#   예) 기준 640 에서 700 은 참(perm_le 는 소유자 x 비트 초과로 거짓).
perm_go_le() {  # $1=파일권한  $2=기준(기본 640)
  local p m
  p=$(( 8#${1:-777} )) 2>/dev/null || return 1
  m=$(( 8#${2:-640} ))
  [ $(( (p & 8#070) & ~(m & 8#070) )) -eq 0 ] && [ $(( (p & 8#007) & ~(m & 8#007) )) -eq 0 ]
}

# find 미사용 파일 순회 — 지정한 디렉터리들을 순수 bash 로 재귀 순회하며
#   "일반 파일" 경로만 한 줄씩 출력한다. (find 명령을 쓰지 않기 위한 대체 구현)
#   * 전체 파일시스템(/) 이 아니라 범위가 한정된 디렉터리에만 사용할 것(메모리·성능).
#   * 심볼릭 링크는 대상이 일반 파일이면 포함하되, 디렉터리 링크 안으로는 들어가지 않는다.
#   * globstar(**) 를 쓰지 않는다: bash 4.2 이하(Amazon Linux 2·CentOS 7)의 ** 는 디렉터리 링크를 따라가
#     /dev/fd → /proc/self/fd → /proc·/ 로 끝없이 확장되고, 결과를 전부 메모리에 쌓은 뒤 순회해
#     메모리 고갈로 서버가 멈춘다(db-active 9/29·9/30 장애). 디렉터리 단위로 읽고 깊이도 제한한다.
walk_reg_files() {
  ( shopt -s nullglob dotglob 2>/dev/null
    _walk_dir() {   # $1=디렉터리 $2=깊이
      local f
      [ "$2" -gt 20 ] && return
      for f in "$1"/*; do
        if [ -L "$f" ]; then [ -f "$f" ] && printf '%s\n' "$f"
        elif [ -d "$f" ]; then _walk_dir "$f" $(( $2 + 1 ))
        elif [ -f "$f" ]; then printf '%s\n' "$f"; fi
      done
    }
    for d in "$@"; do
      [ -d "$d" ] && _walk_dir "$d" 0
    done )
}

# 파일 소유자·권한 → GOOD/VULN/NA 직접 판정
chk_perm() {  # code title file maxperm "owner1 owner2 ..."
  local code=$1 title=$2 f=$3 maxp=$4 owners=$5 p o
  if [ ! -e "$f" ]; then rep "$code" "$title" NA "$f 미존재 → 점검 대상 없음"; return; fi
  p=$(stat -Lc '%a' "$f" 2>/dev/null); o=$(stat -Lc '%U' "$f" 2>/dev/null)   # 링크면 대상 파일 기준
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
has_keys() { [ -s "$1/.ssh/authorized_keys" ] || [ -s "$1/.ssh/authorized_keys2" ]; }   # $1=홈 → SSH 키 로그인 가능 여부

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
# [기준] 양호 - 비밀번호 관리 정책이 설정된 경우 / 취약 - 설정되지 않은 경우
#   정책 = 가이드 조치 기준: 영문·숫자·특수문자 포함 8자리 이상(비밀번호 관리 방법: 3종류 이상 8자리
#          또는 2종류 이상 10자리), 최소 사용기간 1일, 최대 사용기간 90일, 최근 비밀번호 기억 4회 이상,
#          "root 계정을 포함한 사용자 계정" 에 적용.
#   ※ pwquality.conf 값은 PAM 비밀번호 스택에 pam_pwquality.so 가 있을 때만 적용된다(모듈 없으면 무효).
#     pam_cracklib 은 pwquality.conf 를 읽지 않으므로 모듈 인자만 인정. 모듈 인자가 conf 를 덮어쓴다.
#     conf 는 pwquality.conf → pwquality.conf.d/*.conf 순서로 키별 마지막 값을 쓴다. '-password' 줄도 인정.
#   ※ 복잡성(최소 요구 항목 값은 반드시 -1): 영문·숫자·특수 = dcredit·ocredit·(ucredit 또는 lcredit) 모두 -1 이하
#     또는 minclass>=3 → 길이 8 이상 / 2종류(-1 이하 credit 2개 이상 또는 minclass>=2) → 길이 10 이상.
#     모듈만 있고 credit/minclass 가 없으면 문자종류 요구 0 → 미흡.
#   ※ 길이는 모듈 인자/pwquality minlen(미지정이면 모듈 기본값 9), 모듈이 없으면 pam_unix minlen= 만 인정.
#     login.defs PASS_MIN_LEN 은 PAM 이 쓰지 않으므로 참고로만 표시.
#   ※ pam_pwquality·pam_pwhistory 는 같은 파일에서 password 유형 pam_unix.so 보다 위에 있어야 적용됨.
#     대상 파일은 주 비밀번호 스택(RHEL: system-auth, Debian: common-password).
#   ※ 최근 비밀번호 기억: pam_pwhistory remember=(없으면 pwhistory.conf, 그것도 없으면 모듈 기본값 10) 또는
#     pam_unix remember=. pwhistory.conf 는 PAM 1.5+(RHEL 8.8+ 백포트)만 읽고 PAM 1.3.x/1.4 는 무시하므로
#     설치된 pam_pwhistory.so 가 pwhistory.conf 를 참조(문자열 포함)할 때만 인정.
#   ※ login.defs 는 신규 계정에만 적용 → /etc/shadow 에서 비밀번호가 설정된(해시 '$' 시작) 기존 계정
#     (root 포함)의 최소 1일·최대 90일 적용 여부도 확인한다(잠금 '!'·'*' 계정 제외, root 권한 필요).
#   ※ enforce_for_root 는 조치 권고 사항이라 참고로만 표시한다.
maxd=$(conf_line '^[[:space:]]*PASS_MAX_DAYS' /etc/login.defs | awk '{print $2}')
mind=$(conf_line '^[[:space:]]*PASS_MIN_DAYS' /etc/login.defs | awk '{print $2}')
minl=$(conf_line '^[[:space:]]*PASS_MIN_LEN'  /etc/login.defs | awk '{print $2}')
warn=$(conf_line '^[[:space:]]*PASS_WARN_AGE' /etc/login.defs | awk '{print $2}')
pq_get() {  # $1=키 → pwquality.conf + conf.d/*.conf 의 마지막 값(주석 제외)
  local f x v=""
  for f in /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf; do
    [ -f "$f" ] || continue
    x=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$f" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//')
    [ -n "$x" ] && v=$x
  done
  printf '%s' "$v"
}
pam_arg() { printf '%s\n' "$1" | grep -oE "(^|[[:space:]])$2=[-0-9]+" | tail -1 | cut -d= -f2; }   # $1=PAM줄 $2=인자명
is_int()  { case "${1:-}" in ''|-|*[!-0-9]*|?*-*) return 1;; esac; return 0; }
PW_MAIN=${PAM_PW%% *}                                   # 주 비밀번호 스택
pw_stack=$(grep -nE '^[[:space:]]*-?password[[:space:]]' "$PW_MAIN" 2>/dev/null)   # 주석 제외, 줄번호 포함
ux_ln=$(printf '%s\n' "$pw_stack" | grep -E 'pam_unix\.so' | head -1 | cut -d: -f1)
ux_txt=$(printf '%s\n' "$pw_stack" | grep -E 'pam_unix\.so' | head -1 | cut -d: -f2-)
cx_line=$(printf '%s\n' "$pw_stack" | grep -E 'pam_(pwquality|cracklib|passwdqc)\.so' | head -1)
cx_ln=${cx_line%%:*}; cx_txt=${cx_line#*:}
cx_mod=$(printf '%s' "$cx_txt" | grep -oE 'pam_(pwquality|cracklib|passwdqc)' | head -1)
hs_line=$(printf '%s\n' "$pw_stack" | grep -E 'pam_pwhistory\.so' | head -1)
hs_ln=${hs_line%%:*}; hs_txt=${hs_line#*:}
miss=""
# (1) 사용기간(login.defs)
{ [ -n "$maxd" ] && [ "$maxd" -ge 1 ] && [ "$maxd" -le 90 ]; } 2>/dev/null || miss="$miss 최대사용기간(${maxd:-미설정},기준 1~90)"
{ [ -n "$mind" ] && [ "$mind" -ge 1 ]; } 2>/dev/null                       || miss="$miss 최소사용기간(${mind:-미설정},기준 1이상)"
# (2) 복잡성·길이 (PAM 모듈 적용 필수)
declare -A CX=(); n_cls=0; eff_len=""; len_src=""
if [ -z "$cx_mod" ]; then
  miss="$miss 복잡성(${PW_MAIN##*/} 에 pam_pwquality/pam_cracklib 미적용 → pwquality.conf 값 무효)"
  ul=$(pam_arg "$ux_txt" minlen); if is_int "$ul"; then eff_len=$ul; len_src="pam_unix"; fi
  { [ -n "$eff_len" ] && [ "$eff_len" -ge 8 ]; } || miss="$miss 최소길이(PAM 미적용${eff_len:+,$eff_len})"
elif [ "$cx_mod" = pam_passwdqc ]; then
  len_src="pam_passwdqc"                                # passwdqc 는 자체 min= 정책(기본 3종 8자 수준) → 적용으로 인정
else
  for k in minlen dcredit ucredit lcredit ocredit minclass; do
    v=$(pam_arg "$cx_txt" "$k")
    [ -z "$v" ] && [ "$cx_mod" = pam_pwquality ] && v=$(pq_get "$k")
    is_int "$v" && CX[$k]=$v
  done
  for k in dcredit ucredit lcredit ocredit; do [ "${CX[$k]:-0}" -le -1 ] && n_cls=$((n_cls+1)); done
  mcl=${CX[minclass]:-0}
  if [ -n "${CX[minlen]:-}" ]; then eff_len=${CX[minlen]}; len_src=$cx_mod; else eff_len=9; len_src="$cx_mod 기본값"; fi
  cls3=0   # 영문·숫자·특수 3종류 요구
  { [ "${CX[dcredit]:-0}" -le -1 ] && [ "${CX[ocredit]:-0}" -le -1 ] && { [ "${CX[ucredit]:-0}" -le -1 ] || [ "${CX[lcredit]:-0}" -le -1 ]; }; } && cls3=1
  [ "$mcl" -ge 3 ] && cls3=1
  cls2=0; { [ "$n_cls" -ge 2 ] || [ "$mcl" -ge 2 ]; } && cls2=1
  { [ "$cls3" -eq 1 ] && [ "$eff_len" -ge 8 ]; } || { [ "$cls2" -eq 1 ] && [ "$eff_len" -ge 10 ]; } \
    || miss="$miss 복잡성/길이(-1 credit ${n_cls}개·minclass ${mcl}·${eff_len}자 → 기준 영문·숫자·특수 3종 8자 또는 2종 10자)"
  [ -n "$ux_ln" ] && [ "$cx_ln" -gt "$ux_ln" ] && miss="$miss 모듈순서($cx_mod 가 pam_unix 아래 → 미적용)"
fi
# (3) 최근 비밀번호 기억 4회 이상
rem=""; rem_src=""
if [ -n "$hs_line" ] && { [ -z "$ux_ln" ] || [ "$hs_ln" -lt "$ux_ln" ]; }; then
  rem=$(pam_arg "$hs_txt" remember); rem_src="pam_pwhistory"
  if [ -z "$rem" ] && [ -f /etc/security/pwhistory.conf ]; then
    pwh_so=""
    for so in /lib*/security/pam_pwhistory.so /usr/lib*/security/pam_pwhistory.so /lib/*/security/pam_pwhistory.so /usr/lib/*/security/pam_pwhistory.so; do
      [ -f "$so" ] && { pwh_so=$so; break; }
    done
    if [ -n "$pwh_so" ] && grep -qsF pwhistory.conf "$pwh_so"; then   # 모듈이 pwhistory.conf 를 읽는 버전일 때만
      rem=$(grep -E '^[[:space:]]*remember[[:space:]]*=[[:space:]]*[0-9]+' /etc/security/pwhistory.conf 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
      [ -n "$rem" ] && rem_src="pwhistory.conf"
    fi
  fi
  [ -z "$rem" ] && { rem=10; rem_src="pam_pwhistory 기본값"; }
elif [ -n "$hs_line" ]; then
  miss="$miss 모듈순서(pam_pwhistory 가 pam_unix 아래 → 미적용)"
fi
ur=$(pam_arg "$ux_txt" remember)
if is_int "$ur" && { [ -z "$rem" ] || [ "$ur" -gt "$rem" ]; }; then rem=$ur; rem_src="pam_unix"; fi
{ [ -n "$rem" ] && [ "$rem" -ge 4 ]; } || miss="$miss 최근비밀번호기억(${rem:-미설정},기준 4회 이상)"
# (4) 기존 계정(root 포함) 사용기간 적용 여부
if [ "$IS_ROOT" -eq 1 ] && [ -r /etc/shadow ]; then
  sh_bad=$(awk -F: '$2 ~ /^\$/ && ($5=="" || $5+0>90 || $4=="" || $4+0<1) {printf "%s(%s/%s) ", $1, ($4==""?"-":$4), ($5==""?"-":$5)}' /etc/shadow 2>/dev/null)
  [ -n "$sh_bad" ] && miss="$miss 기존계정_사용기간미적용(최소/최대):${sh_bad% }"
  sh_note="shadow 기존계정 확인"
else
  sh_note="shadow 확인불가(비-root)"
fi
efr="없음"
{ printf '%s\n' "$cx_txt" | grep -qw enforce_for_root || grep -qsE '^[[:space:]]*enforce_for_root([[:space:]]|$)' /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf; } && efr="있음"
cx_view="${cx_mod:-미적용}"
[ ${#CX[@]} -gt 0 ] && cx_view="$cx_view $(for k in minlen dcredit ucredit lcredit ocredit minclass; do [ -n "${CX[$k]:-}" ] && printf '%s=%s ' "$k" "${CX[$k]}"; done | sed 's/ $//')"
ev="MAX=${maxd:-미} MIN=${mind:-미} WARN=${warn:-미} LEN=${eff_len:-미}(${len_src:-없음}) 복잡성=[${cx_view}] 기억=${rem:-미}(${rem_src:-없음}) | ${PW_MAIN}, login.defs PASS_MIN_LEN=${minl:-미}(참고), enforce_for_root=${efr}(권고), ${sh_note}"
if [ -z "$miss" ]; then rep U-02 "비밀번호 관리정책 설정" GOOD "$ev"
else rep U-02 "비밀번호 관리정책 설정" VULN "미흡:$miss" "$ev"; fi

# U-03 계정 잠금 임계값 설정
# [기준] 양호 - 계정 잠금 임계값이 10회 이하로 설정
#        취약 - 미설정 또는 10회 초과
#   ※ 잠금은 PAM auth 스택($PAM_AUTH)에 pam_faillock(또는 pam_tally/pam_tally2)이 실제로 로드될 때만 동작한다
#     (주석 아닌 'auth'/'-auth' 줄). faillock.conf 는 pam_faillock.so 가 읽는 설정일 뿐 → 파일에 deny 만 있고
#     모듈이 없으면 취약.
#   ※ deny 우선순위: 모듈 인자 > faillock.conf 의 주석 아닌 deny(pam_faillock 일 때만) > pam_faillock 기본값 3.
#     pam_tally(2) 는 deny 미지정 시 잠금 없음 → 취약.
fl_lines=$(grep -hE '^[[:space:]]*-?auth[[:space:]].*pam_(faillock|tally2?)\.so' $PAM_AUTH 2>/dev/null)
fl_mod=$(printf '%s\n' "$fl_lines" | grep -oE 'pam_(faillock|tally2?)' | head -1)
fl_conf_deny=$(grep -E '^[[:space:]]*deny[[:space:]]*=[[:space:]]*[0-9]+' /etc/security/faillock.conf 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
deny=$(printf '%s\n' "$fl_lines" | grep -oE '(^|[[:space:]])deny=[0-9]+' | cut -d= -f2 | sort -n | tail -1); deny_src="PAM 인자"
if [ -z "$deny" ] && [ "$fl_mod" = pam_faillock ]; then
  if [ -n "$fl_conf_deny" ]; then deny=$fl_conf_deny; deny_src="faillock.conf"; else deny=3; deny_src="pam_faillock 기본값"; fi
fi
if [ -z "$fl_mod" ]; then
  rep U-03 "계정 잠금 임계값 설정" VULN "PAM auth 스택($PAM_AUTH)에 pam_faillock/pam_tally2 미적용 → 로그인 실패 임계값 없음${fl_conf_deny:+ (faillock.conf deny=$fl_conf_deny 는 모듈 미로드로 무효)}"
elif [ -n "$deny" ] && [ "$deny" -ge 1 ] && [ "$deny" -le 10 ]; then
  rep U-03 "계정 잠금 임계값 설정" GOOD "잠금 모듈($fl_mod) 적용 + deny=$deny (${deny_src}, 10회 이하)"
else
  rep U-03 "계정 잠금 임계값 설정" VULN "잠금 모듈($fl_mod)은 적용됐으나 deny=${deny:-미지정} (1~10 필요)"
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
  # 클라우드 기본계정(ec2-user 등)도 '미사용(로그인 이력 없음)/잠금' 이면 방치 의심으로 검토 대상에 포함한다.
  #   (실제로 사용 중이면 로그인 이력이 있어 걸리지 않음 — 미사용 관리자 계정 방치를 놓치지 않기 위함)
  cd_tag=""; case "$CLOUD_DEFAULT" in *" $u "*) cd_tag="클라우드기본,";; esac
  # 관리자 권한(sudo/wheel/GID0) 보유 여부 표시 → 미사용 관리자 계정을 우선 검토
  adm_tag=""
  { id -nG "$u" 2>/dev/null | grep -qwE 'wheel|sudo|root|adm'; } && adm_tag="관리자권한,"
  if acct_locked "$u"; then review="$review ${u}(${adm_tag}${cd_tag}잠금)"; continue; fi
  never_login "$u" && review="$review ${u}(${adm_tag}${cd_tag}로그인이력없음)"
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
# [기준] 양호 - 관리자 그룹에 불필요한 계정이 등록되어 있지 않은 경우
#        취약 - 관리자 그룹에 불필요한 계정이 등록된 경우
#   원문 점검(Step 1)은 /etc/group 의 root 그룹(GID 0) 구성원 확인 → root 그룹에 root 외 계정이 있으면 취약.
#   확장 범위(원문 밖 — 판정은 양호/수동확인만): wheel·sudo 그룹, sudoers 에서 ALL 권한을 받는 %그룹·사용자.
#   ※ Debian/Ubuntu 의 adm 그룹은 로그 열람용 시스템 그룹(기본 구성원 syslog: nologin·잠금)이라
#     root 권한과 무관하다 → 점검 대상에서 제외. (포함하면 기본 설치 Ubuntu 가 항상 취약으로 오탐)
#   ※ 확장 범위 계정은 lastlog 로그인 이력이 있으면 암호 잠금과 무관하게 활성으로 본다
#     (키 전용 관리자 계정은 useradd 기본 '!'/'!!' 라 passwd -S 가 L/LK — 잠금만으로 방치로 보지 않음).
#     root 자신과, amazon-ssm-agent 가 동작 중인 ssm-user(Session Manager 전용)는 사용 중으로 본다.
#   ※ 로그인 이력 없음·확인불가 계정(잠금 + authorized_keys 없음이면 '로그인 불가·방치 의심' 표기)은 불필요 여부를
#     시스템 상태로 확정할 수 없어 수동확인. 미사용 클라우드 기본계정의 취약 판정은 U-07 에서 한다(이중 계상 방지).
#   판정: root 그룹 구성원 → 취약 / 확장 범위에 사용 확인 필요 계정 → 수동확인 / 그 외(모두 활성·해당 없음) → 양호.
rootg=$(getent group root 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -vxE 'root|' | tr '\n' ' ')
sudo_groups=$(grep -rhE '^[[:space:]]*%[A-Za-z0-9_.-]+[[:space:]]+ALL=\(ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/^[[:space:]]*%//' | awk '{print $1}' | sort -u | tr '\n' ' ')
sudoall=$(grep -rhE '^[[:space:]]*[%A-Za-z0-9_.-]+[[:space:]]+ALL=\(ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
sudo_users=$(printf '%s\n' $sudoall | grep -vE '^$|^%|^root$|^[A-Z][A-Z0-9_]*$' | tr '\n' ' ')   # 사용자 단위 ALL (별칭 제외)
adm_view=""; idle_adm=""; declare -A adm_src=()
adm_chk() {  # $1=계정  $2=소속(그룹명 또는 sudoers) → 사용 확인이 필요하면 idle_adm 에 추가
  local u=$1 g=$2 nl h t
  id "$u" >/dev/null 2>&1 || return 0                 # 존재하지 않는 계정 참조는 무시
  [ "$u" = root ] && return 0
  [ "$u" = ssm-user ] && proc_run amazon-ssm-agent && return 0   # Session Manager 사용 중
  never_login "$u"; nl=$?                               # 0=이력없음 1=이력있음 2=확인불가
  [ "$nl" -eq 1 ] && return 0                           # 로그인 이력 있음 → 활성(암호 잠금 여부 무관)
  h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
  case $nl in 0) t="로그인이력없음";; *) t="로그인이력 확인불가";; esac
  case "$CLOUD_DEFAULT" in *" $u "*) t="클라우드기본,$t";; esac
  if acct_locked "$u"; then
    if has_keys "$h"; then t="$t,암호잠금(authorized_keys 있음 → 키 로그인 가능)"; else t="$t,잠금·키없음(로그인 불가·방치 의심)"; fi
  elif has_keys "$h"; then t="$t,authorized_keys있음"; fi
  idle_adm="$idle_adm ${u}($g,$t)"
}
for g in $(printf '%s\n' root wheel sudo $sudo_groups | awk 'NF && !s[$0]++'); do
  mm=$(getent group "$g" 2>/dev/null | awk -F: '{gsub(/,/," ",$4); print $4}')
  [ -z "$mm" ] && continue
  adm_view="$adm_view ${g}:{${mm}}"
  for u in $mm; do adm_src[$u]="${adm_src[$u]:+${adm_src[$u]}/}$g"; done
done
for u in $sudo_users; do adm_src[$u]="${adm_src[$u]:+${adm_src[$u]}/}sudoers"; done
for u in $(printf '%s\n' "${!adm_src[@]}" | sort); do adm_chk "$u" "${adm_src[$u]}"; done   # 계정별 1회 판정
[ -n "$sudo_users" ] && adm_view="$adm_view sudoers-ALL:{${sudo_users% }}"
if [ -n "$rootg" ]; then
  rep U-08 "관리자 그룹에 최소한의 계정 포함" VULN "GID 0(root) 그룹에 root 외 계정: ${rootg% } → 불필요 계정은 root 그룹에서 제거" ${adm_view:+"참고(확장 범위) 관리자 권한 계정 구성:${adm_view}"}
elif [ -z "$adm_view" ]; then
  rep U-08 "관리자 그룹에 최소한의 계정 포함" GOOD "root 그룹(GID 0)에 root 외 계정 없음, wheel/sudo·sudoers ALL 에도 root 외 계정 없음"
elif [ -n "$idle_adm" ]; then
  rep U-08 "관리자 그룹에 최소한의 계정 포함" MAN "root 그룹(GID 0)에 root 외 계정 없음(원문 기준 충족). 확장 범위(wheel/sudo·sudoers ALL) 계정 중 사용 확인 필요:${idle_adm} → 불필요하면 관리자 그룹/sudoers 에서 제거" "확장 범위 구성:${adm_view}"
else
  rep U-08 "관리자 그룹에 최소한의 계정 포함" GOOD "root 그룹(GID 0)에 root 외 계정 없음. 확장 범위 관리자 권한 계정 구성:${adm_view} — 모두 로그인 이력이 있는 활성 계정(ssm-user 는 SSM 에이전트 동작)"
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
# [기준] 양호 - Session Timeout 600초(10분) 이하로 설정 / 취약 - 미설정 또는 초과
#   ※ sh/ksh/bash: 로그인 셸이 읽는 순서(아래 sh_sys)대로 TMOUT 대입을 따라가 마지막 값(실효값)으로 판정한다(최솟값 아님).
#     readonly 가 걸린 뒤의 대입·unset 은 무시(bash 동작). export/readonly/declare/typeset 접두, 따옴표 값,
#     ';'·'&&'·'||' 로 이은 문장, unset TMOUT 도 반영. 실효값이 숫자가 아니면(변수·산술식) 수동확인.
#   ※ csh/tcsh: 로그인 셸이 csh/tcsh 인 계정이 있을 때만 /etc/csh.cshrc·csh.login·profile.d/*.csh(읽는 순서) 의
#     set autologout(분) 1~10 도 요구한다(csh 파일의 TMOUT= 는 보지 않음).
#   ※ SSH ClientAliveInterval 은 가이드 판단 대상이 아니라 참고로만 표시.
# sh_sys: sh 계열 로그인 셸이 시스템 환경설정 파일을 읽는 실제 순서(U-12·U-14 공용). 파일마다 awk 에 읽을 줄 범위 lo·hi(빈값=끝까지)를 넘긴다.
#   /etc/profile 은 /etc/bash.bashrc 를 source 하는 줄과 profile.d 루프 줄에서 나눠 그 자리에 해당 파일을 끼워 읽는다.
#   /etc/profile(~source 줄) → /etc/bash.bashrc → /etc/profile(~루프 줄) → /etc/profile.d/*.sh·sh.local → /etc/profile(루프 뒤) → /etc/bashrc
#   (루프 앞에서 bash.bashrc 를 source 하는 줄이 없으면 bash.bashrc 를 맨 앞에 둔다)
sh_pd=$(grep -nE '^[^#]*/etc/profile\.d' /etc/profile 2>/dev/null | head -1 | cut -d: -f1)
sh_bb=$(grep -nE '^[^#]*(\.|source)[[:space:]]+["'\'']?/etc/bash\.bashrc' /etc/profile 2>/dev/null | head -1 | cut -d: -f1)
[ -n "$sh_pd" ] && [ -n "$sh_bb" ] && [ "$sh_pd" -lt "$sh_bb" ] && sh_bb=""
sh_sys=()
sh_seg() { [ -f "$1" ] && [ -r "$1" ] && sh_sys+=("lo=$2" "hi=$3" "$1"); }
if [ -n "$sh_bb" ]; then sh_seg /etc/profile 1 "$sh_bb"; sh_seg /etc/bash.bashrc 1 ""; sh_seg /etc/profile $((sh_bb+1)) "$sh_pd"
else sh_seg /etc/bash.bashrc 1 ""; sh_seg /etc/profile 1 "$sh_pd"; fi
for f in /etc/profile.d/*.sh /etc/profile.d/sh.local; do sh_seg "$f" 1 ""; done
[ -n "$sh_pd" ] && sh_seg /etc/profile $((sh_pd+1)) ""
sh_seg /etc/bashrc 1 ""
tm_res=$(awk -v q="'" '
  FNR < lo+0 || (hi != "" && hi+0 < FNR) { next }      # sh_sys 의 줄 범위 밖
  { l=$0; sub(/^[ \t]+/, "", l); if (l ~ /^#/) next; sub(/[ \t]#.*$/, "", l)
    n=split(l, st, /;|&&|\|\|/)
    for (i=1; i<=n; i++) {
      s=st[i]; sub(/^[ \t]+/, "", s)
      while (s ~ /^(then|do|else|\{)[ \t]/) sub(/^[^ \t]+[ \t]+/, "", s)
      if (s ~ /^unset[ \t]+(-v[ \t]+)?TMOUT([ \t]|$)/) { if (!ro) { v=""; src=FILENAME ":" FNR "(unset)" }; continue }
      kw=""
      while (match(s, /^(export|readonly|declare|typeset)([ \t]+-[a-zA-Z]+)*[ \t]+/)) { if (kw == "") kw=substr(s, 1, RLENGTH); s=substr(s, RLENGTH+1) }
      r=(kw ~ /^readonly/ || kw ~ /^(declare|typeset)[ \t].*-[a-zA-Z]*r/)
      if (s ~ /^TMOUT=/) {
        x=substr(s, 7); sub(/[ \t].*$/, "", x); gsub(/"/, "", x); gsub(q, "", x)
        if (!ro) { v=x; src=FILENAME ":" FNR }
        if (r) ro=1
      } else if (r && s ~ /^TMOUT([ \t]|$)/) ro=1
    } }
  END { printf "%s|%s|%s", v, src, (ro ? ",readonly" : "") }' "${sh_sys[@]}" /dev/null 2>/dev/null)
tmout=${tm_res%%|*}; tm_rest=${tm_res#*|}; tm_src=${tm_rest%%|*}; tm_ro=${tm_rest#*|}
tm_ok=0; tm_num=1
case "$tmout" in ''|*[!0-9]*) tm_num=0 ;; *) [ "$tmout" -ge 1 ] 2>/dev/null && [ "$tmout" -le 600 ] && tm_ok=1 ;; esac
csh_users=$(awk -F: '$7 ~ /(^|\/)t?csh$/ {printf "%s ", $1}' /etc/passwd 2>/dev/null)
csh_ok=1; csh_ev=""
if [ -n "$csh_users" ]; then
  cf=(); for f in /etc/csh.cshrc /etc/csh.login /etc/profile.d/*.csh; do [ -f "$f" ] && [ -r "$f" ] && cf+=("$f"); done
  alo_res=$(awk '{ l=$0; sub(/#.*$/, "", l) }
    l ~ /^[ \t]*set[ \t]+autologout([ \t]|=|$)/ { x=l; sub(/^[^=]*=?[ \t]*\(?[ \t]*/, "", x); sub(/[^0-9].*$/, "", x); a=x; src=FILENAME ":" FNR }
    l ~ /^[ \t]*unset[ \t]+autologout/ { a=""; src=FILENAME ":" FNR "(unset)" }
    END { printf "%s|%s", a, src }' "${cf[@]}" /dev/null 2>/dev/null)
  alo=${alo_res%%|*}; alo_src=${alo_res#*|}; csh_ok=0
  case "$alo" in ''|*[!0-9]*) ;; *) [ "$alo" -ge 1 ] 2>/dev/null && [ "$alo" -le 10 ] && csh_ok=1 ;; esac
  csh_ev="csh·tcsh 로그인 계정(${csh_users% }) autologout=${alo:-미설정}${alo_src:+ ($alo_src)} (10분 이하 필요)"
fi
cai=$(sshd_val clientaliveinterval)
cac=$(sshd_val clientalivecountmax)
if [ "$tm_ok" -eq 1 ]; then tm_ev="TMOUT=$tmout (<=600, 실효값 ${tm_src}${tm_ro})"
else tm_ev="TMOUT=${tmout:-미설정}${tm_src:+ (실효값 ${tm_src}${tm_ro})} (600초 이하 필요)"; fi
if [ "$tm_ok" -eq 1 ] && [ "$csh_ok" -eq 1 ]; then
  rep U-12 "세션 종료 시간 설정" GOOD "$tm_ev. SSH ClientAliveInterval=${cai:-미설정}" ${csh_ev:+"$csh_ev"}
elif [ "$tm_num" -eq 0 ] && [ -n "$tmout" ] && [ "$csh_ok" -eq 1 ]; then
  rep U-12 "세션 종료 시간 설정" MAN "TMOUT=$tmout (실효값 ${tm_src}${tm_ro}) 숫자가 아님(변수·산술식) → 로그인 셸에서 echo \$TMOUT 로 600 이하 확인. SSH ClientAliveInterval=${cai:-미설정}"
else
  rep U-12 "세션 종료 시간 설정" VULN "$tm_ev. SSH ClientAliveInterval=${cai:-미설정}/CountMax=${cac:-미설정}" ${csh_ev:+"$csh_ev"}
fi

# U-13 안전한 비밀번호 암호화 알고리즘 사용
# [기준] 양호 - SHA-2 이상의 안전한 비밀번호 암호화 알고리즘 사용 / 취약 - 취약한 알고리즘 사용
#   가이드 점검 Step1~3 을 모두 만족해야 양호(AND — 설정·기존 해시 중 하나만 강하다고 양호로 보지 않음):
#   ① /etc/login.defs ENCRYPT_METHOD = SHA256·SHA512(Debian 은 YESCRYPT 도). 미설정이면 기본 DES/MD5 라 취약.
#   ② $PAM_PW 의 password 유형 pam_unix.so 줄마다 sha256·sha512·yescrypt 지정, md5·bigcrypt 없음.
#   ③ /etc/shadow 해시가 모두 SHA-2 이상($5·$6·$y·$gy·$7 형식, 잠금 '!' 뒤에 남은 해시 포함).
#      그 밖의 $ 형식(MD5 $1 등)·DES(13자 이상 비-$ 해시)는 취약.
#   ※ Blowfish($2a·$2b·$2y 해시, pam blowfish, BCRYPT)는 가이드에 SHA-2 이상 여부가 없어 수동확인.
#   ※ 비-root 로 shadow 를 못 읽으면 ①② 충족 시 수동확인(root 재점검), 미충족이면 취약.
em=$(conf_line '^[[:space:]]*ENCRYPT_METHOD' /etc/login.defs | awk '{print $2}')
u13_bad=""; u13_bf=""
case "$(printf '%s' "$em" | tr '[:lower:]' '[:upper:]')" in
  SHA256|SHA512|YESCRYPT) ;;
  BCRYPT) u13_bf=" ENCRYPT_METHOD=$em" ;;
  *)      u13_bad=" ENCRYPT_METHOD=${em:-미설정}" ;;
esac
pam_f=(); for f in $PAM_PW; do [ -f "$f" ] && pam_f+=("$f"); done
pam_res=$(awk '{ l=$0; sub(/#.*$/, "", l) }
  l ~ /^[ \t]*-?password[ \t]/ && l ~ /pam_unix\.so/ {
    n++; l=" " l " "; gsub(/[ \t]+/, " ", l); f=FILENAME; sub(/.*\//, "", f)
    if (l ~ / (md5|bigcrypt) /) b=b " " f ":" FNR "(md5·bigcrypt)"
    else if (l ~ / blowfish /) bf=bf " " f ":" FNR "(blowfish)"
    else if (l !~ / (sha256|sha512|yescrypt|gost_yescrypt) /) b=b " " f ":" FNR "(알고리즘 미지정)"
  }
  END { printf "%d|%s|%s", n, b, bf }' "${pam_f[@]}" /dev/null 2>/dev/null)
pam_n=${pam_res%%|*}; pam_rest=${pam_res#*|}
u13_bad="$u13_bad${pam_rest%%|*}"; u13_bf="$u13_bf${pam_rest#*|}"
[ "${pam_n:-0}" -gt 0 ] 2>/dev/null || u13_bad="$u13_bad pam_unix(password) 줄 없음($PAM_PW)"
sh_s="?"; sh_w=""; sh_b=""
if [ "$IS_ROOT" -eq 1 ] && [ -r /etc/shadow ]; then
  sh_res=$(awk -F: '{ h=$2; lk=""; if (h ~ /^!/) lk="(잠금)"; sub(/^!+/, "", h) }
    h == "" || h ~ /^\*/ { next }
    h ~ /^\$(5|6|7|y|gy)\$/ { s++; next }
    h ~ /^\$2[abxy]?\$/ { b=b " " $1 lk; next }
    h ~ /^\$/ || 13 <= length(h) { w=w " " $1 lk }
    END { printf "%d|%s|%s", s, w, b }' /etc/shadow 2>/dev/null)
  if [ -n "$sh_res" ]; then sh_s=${sh_res%%|*}; sh_rest=${sh_res#*|}; sh_w=${sh_rest%%|*}; sh_b=${sh_rest#*|}; fi
fi
u13_ev="ENCRYPT_METHOD=${em:-미설정}, pam_unix(password) ${pam_n:-0}줄, SHA-2 이상 해시 계정수=$sh_s"
if [ -n "$u13_bad" ] || [ -n "$sh_w" ]; then
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" VULN "SHA-2 미만 설정·해시:${u13_bad}${sh_w:+ 해시 계정$sh_w(passwd 로 재설정 필요)}" "$u13_ev"
elif [ "$sh_s" = "?" ]; then
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" MAN "ENCRYPT_METHOD·pam_unix 는 SHA-2 이상${u13_bf:+(Blowfish:$u13_bf)}. shadow 확인 불가(비-root) → root로 재점검" "$u13_ev"
elif [ -n "$u13_bf$sh_b" ]; then
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" MAN "Blowfish(bcrypt) 사용:${u13_bf}${sh_b:+ 해시 계정$sh_b} → SHA-2 이상 인정 여부 확인 필요" "$u13_ev"
else
  rep U-13 "안전한 비밀번호 암호화 알고리즘 사용" GOOD "ENCRYPT_METHOD=$em, pam_unix(password) ${pam_n}줄 모두 SHA-2 이상 지정, SHA-2 이상 해시 계정수=$sh_s(그 외 해시 없음)"
fi

#==============================================================================
echo -e "${W}[ 2. 파일 및 디렉토리 관리 ]${N}"
#==============================================================================

# U-14 root 홈, PATH 디렉터리 및 PATH 설정
# [기준] 양호 - PATH 환경변수에 "."이 맨 앞/중간에 없음 / 취약 - 맨 앞이나 중간에 포함
#   ※ 가이드 조치: /etc/profile → root → 일반 사용자 환경설정 파일을 차례로 확인(셸별 대상 파일
#     + /etc/environment, login.defs ENV_PATH·ENV_SUPATH). 마지막 줄만이 아니라 모든 PATH 대입 줄을 본다:
#     sh 계열 'PATH=…'·'PATH+=…'(export 등 접두 포함), csh 'setenv PATH …'·'set path=( … )'. CLASSPATH 등은 제외.
#   ※ 값을 ':'(csh path 는 공백)로 나눠 마지막이 아닌 위치에 '.'·'..'·'./…'·빈 항목이 있으면 취약.
#     끝의 '.' 은 기준상 양호(참고 표기). 단 셸이 그 뒤에 읽는 파일이 PATH=$PATH:… 로 덧붙이면 중간이 되므로 취약.
#   ※ 읽는 순서: 시스템 파일은 /etc/environment·login.defs → U-12 의 sh_sys 순서 → csh 시스템 파일.
#     계정마다 그 상태에서 다시 시작해 로그인 파일(.bash_profile→.bash_login→.profile 중 처음 것, 단위 L)을 읽되
#     .bashrc 를 부르는 줄 자리에 .bashrc 를 끼운다. L 에 묶이지 않은 나머지 파일(.bashrc·.profile·.kshrc 등)과
#     csh 파일(.cshrc·.tcshrc·.login)은 단위마다 시스템 상태에서 따로 이어 읽는다(다른 셸·비로그인 셸 흐름).
#     같은 흐름에서 끝 '.' 뒤에 덧붙이면 취약. 끝 '.' 과 덧붙이기가 서로 다른 계정 단위에 있으면 읽는 순서를
#     확정할 수 없어 양호 대신 수동확인.
#   ※ 함수 정의 본문('name () { … }'·'function name', 중괄호 깊이로 추적) 안의 PATH 대입은 호출 여부를 알 수 없어
#     덧붙이기·재지정 판정에서 뺀다(맨 앞·중간 '.' 은 그대로 취약). 예: RHEL /etc/bashrc 의 pathmunge 재정의.
#     대신 호출 줄로 판정한다: pathmunge 는 대입으로 본다('after' 면 $PATH 뒤에, 아니면 앞에 추가).
#     그 밖에 본문에서 $PATH 뒤에 덧붙이는 함수를 끝 '.' 뒤에 부르면 인자·분기에 따라 달라 수동확인.
#   ※ 스크립트 프로세스의 $PATH(SSM·sudo 비로그인 값)는 실행 방식마다 달라 판정에 쓰지 않는다.
p14_args=(g=sys); p14_nf=0
p14_add() {   # $1=단위 $2=파일 $3·$4=읽을 줄 범위(빈값=끝까지)
  [ -f "$2" ] && [ -r "$2" ] || return 0
  p14_args+=("u=$1" "lo=$3" "hi=$4" "$2"); [ "$3" = 1 ] && p14_nf=$((p14_nf+1)); return 0
}
p14_add S /etc/environment 1 ""; p14_add S /etc/login.defs 1 ""
p14_args+=(u=S "${sh_sys[@]}")
for f in "${sh_sys[@]}"; do [ "$f" = lo=1 ] && p14_nf=$((p14_nf+1)); done
for f in /etc/csh.cshrc /etc/csh.login /etc/profile.d/*.csh; do p14_add S "$f" 1 ""; done
p14_rh=$(awk -F: '$1=="root" {print $6; exit}' /etc/passwd 2>/dev/null)
for d in "${p14_rh:-/root}" $(awk -F: -v m="$UID_MIN" 'm <= $3+0 && $3+0 < 60000 && $7 !~ /(nologin|false)/ {print $6}' /etc/passwd 2>/dev/null | sort -u); do
  [ -d "$d" ] || continue
  p14_args+=("g=$d")
  p14_lf=""; for rc in .bash_profile .bash_login .profile; do [ -f "$d/$rc" ] && { p14_lf=$rc; break; }; done
  p14_bl=""; [ -n "$p14_lf" ] && [ -f "$d/.bashrc" ] && p14_bl=$(grep -nE '^[^#]*(~|\$HOME|\$\{HOME\}|'"$d"')["'\'']?/\.bashrc' "$d/$p14_lf" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$p14_bl" ]; then p14_add L "$d/$p14_lf" 1 "$p14_bl"; p14_add L "$d/.bashrc" 1 ""; p14_add L "$d/$p14_lf" $((p14_bl+1)) ""
  elif [ -n "$p14_lf" ]; then p14_add L "$d/$p14_lf" 1 ""; fi
  for rc in .bash_profile .bash_login .profile .bashrc .kshrc; do
    [ "$rc" = "$p14_lf" ] || { [ "$rc" = .bashrc ] && [ -n "$p14_bl" ]; } || p14_add "$rc" "$d/$rc" 1 ""
  done
  for rc in .cshrc .tcshrc .login; do p14_add C "$d/$rc" 1 ""; done
done
p14_res=$(awk -v q="'" '
  function val1(x,   i, c, o, qc) {          # 대입 값 한 단어(따옴표 안 공백 허용, 따옴표 제거)
    o=""; qc=""
    for (i=1; i<=length(x); i++) {
      c=substr(x, i, 1)
      if (qc != "") { if (c == qc) qc=""; else o=o c; continue }
      if (c == "\"" || c == q) { qc=c; continue }
      if (c ~ /[ \t;&|]/) break
      o=o c
    }
    return o
  }
  function addb(m) { if (m in sb) return; sb[m]=1; nb++; if (nb <= 5) B=B " " m }
  function addm(m) { if (m in sm) return; sm[m]=1; nm++; if (nm <= 3) M=M " " m }
  function fnb(l,   t, o, c) {             # 함수 정의 본문(정의·닫는 줄 포함)이면 1. 파일마다 중괄호 깊이(fd)로 추적
    if (l == "") return (0 < fd)
    if (fw) { fw=0; if (l !~ /^[{]/) return 0 }                     # "name ()" 다음 줄의 "{"
    else if (fd == 0) {
      if (l !~ /^(function[ \t]+[^ \t(){}]+|[A-Za-z_][A-Za-z0-9_.:-]*[ \t]*\([ \t]*\))/) return 0
      fnm=l; sub(/^function[ \t]+/, "", fnm); sub(/[ \t(){].*$/, "", fnm)  # 함수 이름
      if (l !~ /[{]/) { fw=1; return 1 }
    }
    t=l; o=gsub(/[{]/, "", t); c=gsub(/[}]/, "", t); fd+=o-c; if (fd < 0) fd=0
    return 1
  }
  function chk(v, sp, c, f,   e, n, i, k, hit, last, o, x) {   # PATH 값 하나 판정(sp=공백 구분, c=0 sh·1 csh 흐름, f=함수 본문)
    o=v
    if (sp) { gsub(/\$\{path(:q)?\}|\$path:q/, "$path", v); n=split(v, e, " ") }   # ${path:q}(RHEL csh.login) 도 $path
    else { gsub(/\$\{PATH\}/, "$PATH", v); gsub(/\$\{PATH:\+/, "", v); gsub(/\$\{[^}]*\}/, "$V", v); gsub(/[}]/, "", v); gsub(/\$\([^)]*\)/, "$C", v); n=split(v, e, ":") }   # ${PATH:+$PATH:}x → $PATH:x
    k=0; hit=0; last=0
    for (i=1; i<=n; i++) {
      if (e[i] == "$PATH" || e[i] == "$path") { if (!k) k=i; continue }
      if (e[i] == "" || e[i] ~ /^\.\.?(\/|$)/) { if (i < n || n == 1) hit=1; else last=1 }
    }
    if (hit) addb(here "[" substr(o, 1, 50) "]")
    if (last) { nt++; if (nt <= 5) T=T " " here }
    if (f) { if (k && k < n) fa[fnm]=1; return }                     # 함수 본문: 실행이 확정되지 않아 순서 판정 제외(덧붙이는 함수만 기록)
    if (!k) pend[c]=0                                                # PATH 를 새로 지정 → 앞의 끝 . 무효
    else if (k < n) {                                                # $PATH 뒤에 경로를 덧붙임
      if (pend[c]) addb(psrc[c] "(끝 " q "." q ")+" here "(뒤에 경로 추가)")
      if (u != "S") { ap[c SUBSEP u]=here; for (x in tp) { split(x, e, SUBSEP); if (e[1] == c "" && e[2] != u) addm(tp[x] "(끝 " q "." q ")·" here "(뒤에 경로 추가)") } }
    }
    if (last) { pend[c]=1; psrc[c]=here; pu[c]=u }
  }
  function endu(   j, x, e) {               # 계정 단위가 끝날 때 끝 . 이 남아 있으면, 다른 계정 단위의 덧붙이기와는 순서 불확정
    if (cu == "" || cu == "S") return
    for (j=0; j<2; j++) if (pend[j] && pu[j] == cu) {
      tp[j SUBSEP cu]=psrc[j]
      for (x in ap) { split(x, e, SUBSEP); if (e[1] == j "" && e[2] != cu) addm(psrc[j] "(끝 " q "." q ")·" ap[x] "(뒤에 경로 추가)") }
    }
  }
  FNR == 1 && (g != cg || u != cu) {        # 계정·단위가 바뀌면 시스템 파일까지의 상태에서 다시 시작
    endu()
    if (cg == "sys" && g != "sys") for (j=0; j<2; j++) { s0[j]=pend[j]; s1[j]=psrc[j]; s2[j]=pu[j] }
    if (g != cg) { split("", ap); split("", tp) }
    if (g != "sys") for (j=0; j<2; j++) { pend[j]=s0[j]; psrc[j]=s1[j]; pu[j]=s2[j] }
    cg=g; cu=u }
  FNR == 1 { fd=0; fw=0 }                   # 함수 본문 추적은 파일(구간)마다 1행부터
  { l=$0; sub(/^[ \t]+/, "", l); if (l ~ /^#/) l=""; sub(/[ \t]#.*$/, "", l); fb=fnb(l) }
  l == "" || FNR < lo+0 || (hi != "" && hi+0 < FNR) { next }   # 빈 줄·주석, 끼워 읽기용 줄 범위 밖
  { here=FILENAME ":" FNR
    if (match(l, /(^|[ \t;(])setenv[ \t]+PATH[ \t]+/)) chk(val1(substr(l, RSTART+RLENGTH)), 0, 1, fb)
    if (match(l, /(^|[ \t;(])set[ \t]+path[ \t]*=[ \t]*\(/)) { x=substr(l, RSTART+RLENGTH); sub(/\).*$/, "", x); chk(x, 1, 1, fb) }
    if (match(l, /(^|[ \t;&|])pathmunge[ \t]+[^ \t;&|()]+/)) {      # pathmunge 디렉터리 [after]
      x=substr(l, RSTART, RLENGTH); sub(/^.*pathmunge[ \t]+/, "", x); gsub(/"/, "", x); gsub(q, "", x)
      s=substr(l, RSTART+RLENGTH); gsub(/"/, "", s); gsub(q, "", s)
      if (s ~ /^[ \t]+after([ \t;&|)]|$)/) x="$PATH:" x; else x=x ":$PATH"
      chk(x, 0, 0, fb) }
    if (!fb && pend[0] && l !~ /^unset[ \t]/)                       # 덧붙이는 함수(pathmunge 외) 호출
      for (x in fa) if (x != "pathmunge" && l ~ ("(^|[ \t;&|])" x "([ \t;&|)]|$)")) addm(psrc[0] "(끝 " q "." q ")·" here "(" x " 호출)")
    s=l
    while (match(s, /(^|[ \t;&|(])PATH\+?=/)) {
      p=substr(s, RSTART, RLENGTH); s=substr(s, RSTART+RLENGTH); x=val1(s)
      if (p ~ /\+=$/) x="$PATH" x
      chk(x, 0, 0, fb)
    } }
  END { endu(); if (5 < nb) B=B " 외 " (nb-5) "건"; if (3 < nm) M=M " 외 " (nm-3) "건"; printf "OK|%s|%s|%s", B, M, T }' "${p14_args[@]}" /dev/null 2>/dev/null)
p14_ok=0; p14_bad=""; p14_unk=""; p14_tail=""
case "$p14_res" in "OK|"*) p14_ok=1; p14_res=${p14_res#OK|}; p14_bad=${p14_res%%|*}; p14_res=${p14_res#*|}; p14_unk=${p14_res%%|*}; p14_tail=${p14_res#*|} ;; esac
p14_note=""; [ "$IS_ROOT" -ne 1 ] && p14_note=" (비-root 실행: 읽을 수 없는 root·타 계정 파일 제외)"
if [ "$p14_ok" -ne 1 ]; then
  rep U-14 "root 홈, PATH 디렉터리 및 PATH 설정" MAN "PATH 설정 파일 분석 실패 → root 로그인 셸 echo \$PATH 와 환경설정 파일 수동 확인"
elif [ -n "$p14_bad" ]; then
  rep U-14 "root 홈, PATH 디렉터리 및 PATH 설정" VULN "PATH 맨 앞·중간에 '.' 또는 빈 항목:${p14_bad}"
elif [ -n "$p14_unk" ]; then
  rep U-14 "root 홈, PATH 디렉터리 및 PATH 설정" MAN "끝 '.' 뒤 \$PATH 경로 추가의 순서·실행 여부 확정 불가(서로 묶이지 않은 계정 파일·덧붙이는 함수 호출):${p14_unk} → 해당 계정 로그인 셸에서 echo \$PATH 로 '.' 이 맨 끝인지 확인${p14_note}"
else
  rep U-14 "root 홈, PATH 디렉터리 및 PATH 설정" GOOD "PATH 맨 앞·중간에 '.'·빈 항목 없음(전역·root·일반계정 환경설정 ${p14_nf}개 파일 점검)${p14_note}" ${p14_tail:+"참고: 끝에 '.' 있음(기준상 양호, 삭제 권고):$p14_tail"}
fi

# U-15 파일 및 디렉터리 소유자 설정
# [기준] 양호 - 소유자/그룹이 없는 파일·디렉터리 없음 / 취약 - 존재
#   전체 파일시스템 소유자 점검은 부하가 크고(find 미사용 정책) 자동 판정이 어려워 수동확인으로 둔다.
rep U-15 "파일 및 디렉터리 소유자 설정" MAN "전체 파일시스템의 소유자/그룹 없는(orphan) 파일 유무는 관리자 수동 점검 필요 (예: 파일 소유권 감사 도구 활용)"

# U-16 /etc/passwd
chk_perm U-16 "/etc/passwd 파일 소유자 및 권한 설정" /etc/passwd 644 "root"

# U-17 시스템 시작 스크립트 권한 설정
# [기준] 양호 - 시작 스크립트 소유자 root + 일반 사용자 쓰기 권한 없음 / 취약 - 아님
ssbad=$( shopt -s nullglob
  for f in /etc/init.d/* /etc/rc.d/* /etc/rc.d/*/* /etc/rc*.d/* \
           /lib/systemd/system/* /lib/systemd/system/*/* \
           /usr/lib/systemd/system/* /usr/lib/systemd/system/*/* \
           /etc/systemd/system/* /etc/systemd/system/*/*; do
    [ -f "$f" ] || continue     # 심볼릭 링크는 대상이 일반 파일이면 -f 로 참
    o=$(stat -Lc '%U' "$f" 2>/dev/null); p=$(stat -Lc '%a' "$f" 2>/dev/null)
    { [ "$o" != root ] || perm_has "$p" 022; } && echo "$f($o,$p)"
  done | head -5 | tr '\n' ' ')
if [ -z "$ssbad" ]; then rep U-17 "시스템 시작 스크립트 권한 설정" GOOD "시작 스크립트 소유자 root + group/other 쓰기 권한 없음"
else rep U-17 "시스템 시작 스크립트 권한 설정" VULN "부적절: $ssbad (기준: root 소유, g/o 쓰기 없음)"; fi

# U-18 /etc/shadow  [기준] 양호 - 소유자 root + 권한 400 이하
if [ ! -e /etc/shadow ]; then rep U-18 "/etc/shadow 파일 소유자 및 권한 설정" NA "/etc/shadow 없음"
else
  sp=$(stat -Lc '%a' /etc/shadow); so=$(stat -Lc '%U' /etc/shadow); sg=$(stat -Lc '%G' /etc/shadow)
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
#   대상: 있는 것 모두 — /etc/inetd.conf, /etc/xinetd.conf, xinetd 사용 시 /etc/xinetd.d/* (가이드 [xinetd] 조치 Step 2).
#   xinetd.d 파일은 xinetd.conf 의 includedir 로 읽히므로 xinetd.conf 가 있거나 xinetd 설치 시에만 대상.
#   [systemd] system.conf 는 조치 사례에만 있고 판단기준 밖이라 제외.
u20_fs=(); xd_fs=()
for f in /etc/inetd.conf /etc/xinetd.conf; do [ -e "$f" ] && u20_fs+=("$f"); done
for f in /etc/xinetd.d/*; do [ -f "$f" ] && xd_fs+=("$f"); done
if [ ${#xd_fs[@]} -gt 0 ] && { [ -e /etc/xinetd.conf ] || pkg_installed xinetd; }; then u20_fs+=("${xd_fs[@]}"); fi
if [ ${#u20_fs[@]} -eq 0 ]; then
  if [ ${#xd_fs[@]} -gt 0 ]; then rep U-20 "/etc/(x)inetd.conf 파일 소유자 및 권한 설정" NA "(x)inetd 미사용 (/etc/xinetd.d 에 파일 ${#xd_fs[@]}개 있으나 xinetd.conf 없음·xinetd 미설치)"
  else rep U-20 "/etc/(x)inetd.conf 파일 소유자 및 권한 설정" NA "(x)inetd 미사용"; fi
else
  bad=""
  for f in "${u20_fs[@]}"; do
    o=$(stat -Lc '%U' "$f" 2>/dev/null); p=$(stat -Lc '%a' "$f" 2>/dev/null)
    { [ "$o" = root ] && perm_le "$p" 600; } || bad="$bad $f($o,$p)"
  done
  if [ -z "$bad" ]; then rep U-20 "/etc/(x)inetd.conf 파일 소유자 및 권한 설정" GOOD "$(echo "${u20_fs[*]}" | cut -c1-200) 소유자 root + 600 이하"
  else rep U-20 "/etc/(x)inetd.conf 파일 소유자 및 권한 설정" VULN "부적절:$(echo "$bad" | cut -c1-200) (기준: root, 600 이하)"; fi
fi

# U-21 /etc/(r)syslog.conf   [기준] 양호 - 소유자 root(또는 bin,sys) + 권한 640 이하
#   rsyslog.conf·syslog.conf 는 있는 것 모두 + rsyslog.d/*.conf. 소유자는 가이드대로 root/bin/sys 만 허용.
sysl_f=""; sysl_bad=""; sysl_ok=""
for f in /etc/rsyslog.conf /etc/syslog.conf; do [ -e "$f" ] && sysl_f="$sysl_f $f"; done
for f in /etc/rsyslog.conf /etc/syslog.conf /etc/rsyslog.d/*.conf; do
  [ -f "$f" ] || continue
  o=$(stat -Lc '%U' "$f" 2>/dev/null); p=$(stat -Lc '%a' "$f" 2>/dev/null)
  case " root bin sys " in *" $o "*) : ;; *) sysl_bad="$sysl_bad $f(소유자=$o)";; esac
  perm_le "$p" 640 || sysl_bad="$sysl_bad $f($p)"
  sysl_ok="$sysl_ok ${f##*/}($o,$p)"
done
if [ -z "$sysl_f" ]; then rep U-21 "/etc/(r)syslog.conf 파일 소유자 및 권한 설정" NA "syslog 설정파일 없음"
elif [ -z "$sysl_bad" ]; then rep U-21 "/etc/(r)syslog.conf 파일 소유자 및 권한 설정" GOOD "소유자 root(bin/sys) + 640 이하:$(echo "$sysl_ok" | cut -c1-200)"
else rep U-21 "/etc/(r)syslog.conf 파일 소유자 및 권한 설정" VULN "부적절:$sysl_bad (기준: root/bin/sys, 640 이하)"; fi

# U-22 /etc/services   [기준] 양호 - 소유자 root(또는 bin,sys) + 권한 644 이하
chk_perm U-22 "/etc/services 파일 소유자 및 권한 설정" /etc/services 644 "root bin sys"

# U-23 SUID/SGID/Sticky bit 설정 파일 점검
# [기준] 양호 - 주요 실행 파일에 불필요한 SUID/SGID 없음 / 취약 - 상세가이드 제거권고 파일에 SUID/SGID 설정
KISA_SUID_RM="/sbin/dump /sbin/restore /sbin/unix_chkpwd /usr/bin/at /usr/bin/lpq /usr/bin/lpq-lpd /usr/bin/lpr /usr/bin/lpr-lpd /usr/bin/lprm /usr/bin/lprm-lpd /usr/bin/newgrp /usr/sbin/lpc /usr/sbin/lpc-lpd /usr/sbin/traceroute /usr/bin/traceroute6 /usr/bin/wall /usr/bin/write"
# 전체 파일시스템 SUID/SGID 탐색(find / -perm)은 부하가 크고 금지되어, 상세가이드
# '제거 권고' 목록 파일에 SUID/SGID 비트가 남아있는지만 stat 로 직접 점검한다.
rm_hit=""
for f in $KISA_SUID_RM; do
  [ -f "$f" ] || continue
  p=$(stat -Lc '%a' "$f" 2>/dev/null)
  perm_has "$p" 6000 && rm_hit="$rm_hit $f($p)"
done
if [ -n "$rm_hit" ]; then
  rep U-23 "SUID, SGID, Sticky bit 설정 파일 점검" VULN "상세가이드 제거권고 파일에 SUID/SGID 설정:$rm_hit → 불필요 시 권한 제거"
else
  rep U-23 "SUID, SGID, Sticky bit 설정 파일 점검" MAN "상세가이드 제거권고 목록 파일에는 SUID/SGID 없음 — 다만 전체 SUID/SGID 파일의 업무상 필요성은 기계적으로 확정 불가(인터뷰 필요), 표준 패키지 소속만으로 필요성이 보장되지 않으므로 목록 검토 권장"
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
#   전체 파일시스템 탐색은 부하가 크고(find 미사용 정책) 사유 인지 여부 판단이 필요해 수동확인으로 둔다.
rep U-25 "world writable 파일 점검" MAN "전체 파일시스템의 world-writable(기타 쓰기) 일반 파일 유무는 관리자 수동 점검 필요 → 사유 없는 파일은 기타 쓰기 권한 제거"

# U-26 /dev에 존재하지 않는 device 파일 점검
# [기준] 양호 - /dev 내 비정상 일반 파일 없음 / 취약 - 존재
devf=$(walk_reg_files /dev 2>/dev/null \
       | grep -Ev '^/dev/(shm|mqueue|hugepages)/' \
       | grep -Ev '/(MAKEDEV|\.udev|core)$' | head -10)
devc=$(printf '%s\n' "$devf" | grep -c .)
if [ "$devc" -eq 0 ]; then rep U-26 "/dev에 존재하지 않는 device 파일 점검" GOOD "/dev 내 비정상 일반 파일 없음"
else rep U-26 "/dev에 존재하지 않는 device 파일 점검" VULN "/dev 내 일반 파일 ${devc}개: $(echo $devf | cut -c1-150)"; fi

# U-27 $HOME/.rhosts, hosts.equiv 사용 금지
# [기준] 양호 - rlogin/rsh/rexec 미사용, 또는 사용 시 hosts.equiv·.rhosts 가 아래를 모두 충족
#              1) 소유자 root 또는 해당 계정  2) 권한 600 이하  3) "+" 설정 없음
#        취약 - r계열 사용 중 위 조건 중 하나라도 미충족 (미사용이면 신뢰파일이 있어도 양호, 삭제 권고만 남김)
#   ※ r계열 사용: 서버 패키지·소켓 활성·TCP 512~514 LISTEN·inetd.conf/xinetd.d 활성 설정
#     (rsh 클라이언트 패키지는 서비스가 아니고, UDP 514 는 syslog 라 제외)
#   ※ "+": '+ +'·'+ 계정'·'호스트 +' 처럼 '+' 로 시작하는 항목(주석 줄 제외)
#   ※ .rhosts 는 /etc/passwd 의 모든 계정 홈(시스템 계정 포함, 같은 홈은 1회)에서 찾는다.
r_used=0
{ pkg_installed rsh-server || pkg_installed rsh-redone-server \
  || svc_active rexec.socket || svc_active rlogin.socket || svc_active rsh.socket \
  || { ss -Hlnt 2>/dev/null | awk '{print $4}'; netstat -lnt 2>/dev/null | awk '/^tcp/{print $4}'; } | grep -qE '[:.](512|513|514)$' \
  || grep -qsE '^[[:space:]]*(exec|login|shell)[[:space:]]' /etc/inetd.conf; } && r_used=1
for r_s in rexec rlogin rsh; do   # xinetd 는 'disable = yes' 가 없으면 활성
  [ -f "/etc/xinetd.d/$r_s" ] && ! grep -qiE '^[[:space:]]*disable[[:space:]]*=[[:space:]]*yes' "/etc/xinetd.d/$r_s" && r_used=1
done
found=""; plusbad=""; permbad=""
r_chk() {  # $1=신뢰파일  $2=허용 소유자(root 외 해당 계정)
  local f=$1 o p
  [ -f "$f" ] && [ ! -L "$f" ] || return 0   # rsh(ruserok)는 일반 파일만 읽음(심볼릭 링크·/dev/null 링크는 무시)
  found="$found $f"
  grep -vE '^[[:space:]]*#' "$f" 2>/dev/null | grep -qE '(^|[[:space:]])\+' && plusbad="$plusbad $f"
  o=$(stat -c '%U' "$f" 2>/dev/null); p=$(stat -c '%a' "$f" 2>/dev/null)
  { { [ "$o" = root ] || [ "$o" = "$2" ]; } && perm_le "$p" 600; } || permbad="$permbad $f($o,$p)"
}
r_chk /etc/hosts.equiv root
if [ "$IS_ROOT" -eq 1 ]; then
  r_seen=" "
  while IFS=: read -r r_u _ _ _ _ r_home _; do
    [ -n "$r_home" ] || continue
    case "$r_seen" in *" $r_home "*) continue;; esac; r_seen="$r_seen$r_home "
    r_chk "${r_home%/}/.rhosts" "$r_u"
  done < /etc/passwd
fi
r_bad="${plusbad:+ '+' 설정:$plusbad}${permbad:+ 소유자/권한 부적절:$permbad}"
if [ "$r_used" -eq 1 ] && [ -n "$r_bad" ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" VULN "r계열 서비스 사용 중 +$r_bad (기준: 소유자 root/해당 계정, 권한 600 이하, '+' 없음)"
elif [ "$r_used" -eq 1 ] && [ "$IS_ROOT" -ne 1 ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" MAN "r계열 서비스 사용 중, hosts.equiv 는 적절(또는 없음). 계정 홈 .rhosts 는 root 권한으로 확인 필요"
elif [ -z "$found" ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" GOOD ".rhosts/hosts.equiv 파일 없음 (r계열 서비스 사용=$r_used)"
elif [ "$r_used" -eq 1 ]; then rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" GOOD "r계열 서비스 사용 중, 신뢰파일 소유자·권한 적절 + '+' 없음:$found"
else rep U-27 "\$HOME/.rhosts, hosts.equiv 사용 금지" GOOD "r계열 서비스 미사용 (신뢰파일 존재:$found${r_bad:+ / 참고:$r_bad} → 불필요 시 삭제 권장)"; fi

# U-28 접속 IP 및 포트 제한
# [기준] 양호 - 허용 호스트 IP/포트 제한 설정(TCP Wrapper 또는 호스트 방화벽) / 취약 - 미설정
#   ※ TCP Wrapper 는 hosts.deny ALL:ALL + hosts.allow 허용 줄이 있고, 다음을 모두 만족할 때만 제한으로 인정한다.
#     - 데몬 필드가 sshd 또는 ALL 인 허용 줄이 전체 허용이 아님: 클라이언트 목록에 ALL(목록 중간 포함)·0.0.0.0/0
#       이 있으면 전체 허용(단, ': DENY' 로 끝나는 거부 줄은 제외).
#     - sshd 가 libwrap 에 링크됨(ldd). RHEL/Rocky 8+ 등 tcp_wrappers 가 제거된 sshd 는 hosts.allow/deny 가 무효.
#     위 조건을 못 채우면 호스트 방화벽 판정으로 넘어간다.
tcpw_deny=$(grep -viE '^[[:space:]]*#|^[[:space:]]*$' /etc/hosts.deny 2>/dev/null | grep -icE 'ALL[[:space:]]*:[[:space:]]*ALL')
tcpw_allow=$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$' /etc/hosts.allow 2>/dev/null)
allow_open=$(grep -vE '^[[:space:]]*(#|$)' /etc/hosts.allow 2>/dev/null \
  | grep -iE '^[[:space:]]*([^:]*[,[:space:]])?(sshd|ALL)([,[:space:]][^:]*)?:' \
  | grep -viE ':[[:space:]]*DENY[[:space:]]*$' \
  | grep -iE '^[^:]*:[[:space:]]*([^:]*[,[:space:]])?(ALL|0\.0\.0\.0/0)([[:space:]]*$|[[:space:]]*:|[[:space:],]|$)' | head -3 | tr '\n' ';')
sshd_bin=$(command -v sshd 2>/dev/null); [ -z "$sshd_bin" ] && [ -x /usr/sbin/sshd ] && sshd_bin=/usr/sbin/sshd
wrap_ok=0; [ -n "$sshd_bin" ] && have ldd && ldd "$sshd_bin" 2>/dev/null | grep -q libwrap && wrap_ok=1
fw="none"; fw_rules=0
svc_active firewalld && { fw="firewalld"; firewall-cmd --list-rich-rules 2>/dev/null | grep -q . && fw_rules=1; firewall-cmd --list-sources 2>/dev/null | grep -q . && fw_rules=1; }
{ have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; } && { fw="ufw"; ufw status 2>/dev/null | grep -qiE 'ALLOW|DENY' && fw_rules=1; }
if [ "$fw" = none ] && [ "$IS_ROOT" -eq 1 ]; then
  if have nft && nft list ruleset 2>/dev/null | grep -qE 'ip (saddr|daddr)|tcp dport'; then fw="nftables"; fw_rules=1
  elif have iptables && iptables -S 2>/dev/null | grep -qE '(-s |--dport ).*-j (ACCEPT|DROP|REJECT)'; then fw="iptables"; fw_rules=1; fi
fi
u28_why="TCP Wrapper 미설정"
[ "$tcpw_deny" -ge 1 ] && [ -n "$allow_open" ] && u28_why="TCP Wrapper hosts.allow 가 전체 허용(${allow_open%;})"
[ "$tcpw_deny" -ge 1 ] && [ -z "$allow_open" ] && [ "$wrap_ok" -eq 0 ] && u28_why="TCP Wrapper 설정은 있으나 sshd 가 libwrap 미연동(${sshd_bin:-sshd 없음}) → 무효"
if [ "$tcpw_deny" -ge 1 ] && [ "$tcpw_allow" -ge 1 ] && [ -z "$allow_open" ] && [ "$wrap_ok" -eq 1 ]; then
  rep U-28 "접속 IP 및 포트 제한" GOOD "TCP Wrapper: hosts.deny ALL:ALL + hosts.allow ${tcpw_allow}줄(특정 호스트만 허용), sshd libwrap 연동 (방화벽=$fw)"
elif [ "$fw_rules" -eq 1 ]; then
  rep U-28 "접속 IP 및 포트 제한" GOOD "호스트 방화벽($fw)에 소스/포트 제한 규칙 존재"
elif [ "$fw" = none ] && [ "$IS_ROOT" -ne 1 ]; then
  rep U-28 "접속 IP 및 포트 제한" MAN "$u28_why. 방화벽 규칙은 root 확인 필요 (클라우드는 SG/NACL 별도 점검)"
else
  rep U-28 "접속 IP 및 포트 제한" VULN "$u28_why + 호스트 방화벽($fw) 제한 규칙 없음 (클라우드 SG는 별도 점검)"
fi

# U-29 hosts.lpd   [기준] 양호 - 파일 없음, 또는 소유자 root + 권한 600 이하
if [ ! -e /etc/hosts.lpd ]; then rep U-29 "hosts.lpd 파일 소유자 및 권한 설정" NA "/etc/hosts.lpd 없음 (lpd 미사용)"
else chk_perm U-29 "hosts.lpd 파일 소유자 및 권한 설정" /etc/hosts.lpd 600 "root"; fi

# U-30 UMASK 설정 관리
# [기준] 양호 - UMASK 값이 022 이상(그룹·타 사용자 쓰기 비트가 마스킹) / 취약 - 022 미만
#  점검 대상: /etc/login.defs, PAM pam_umask, /etc/profile·bashrc·csh 계열,
#            /etc/profile.d/*, /etc/default/login, 로그인 계정 dotfile, 현재 세션 umask
#  ※ 가이드는 "022 미만이면 취약" 이며 예외가 없다 → RHEL 기본 /etc/profile·bashrc 의 UPG 조건부
#    "UID>199 && 그룹명=계정명 → umask 002" 도 그대로 취약으로 평가한다(일반 사용자에게 실제 적용되는 값).
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
# [기준] 양호 - 홈 디렉토리 소유자가 해당 계정이고, 타 사용자(other) 쓰기 권한이 제거된 경우
#        취약 - 소유자가 해당 계정이 아니거나, 타 사용자 쓰기 권한이 부여된 경우
#   대상: /etc/passwd 의 root·일반 사용자(UID_MIN~59999)·로그인 셸 계정 홈 — 위치(/home 등)와 무관
#   (가이드: 사용자 홈 외 개별 디렉토리도 점검). 공용 시스템 경로(/, /bin, /sbin, /usr/bin 등)는 제외.
#   심볼릭 링크 홈은 대상 디렉토리 기준(stat -L), 소유자는 UID 로 비교(UID 0 별칭 오탐 방지).
home_bad=$(awk -F: -v m="$UID_MIN" '$3 ~ /^[0-9]+$/ && ($3==0 || ($3>=m && $3<60000) || $7 !~ /\/(nologin|false|true|sync|shutdown|halt)$/) {print $1":"$3":"$6}' /etc/passwd \
  | while IFS=: read -r u uid h; do
      case "$h" in ""|/|/bin|/sbin|/usr|/usr/bin|/usr/sbin|/usr/games|/dev|/proc|/var/empty*) continue;; esac
      [ -d "$h" ] || continue
      ou=$(stat -Lc '%u' "$h" 2>/dev/null); o=$(stat -Lc '%U' "$h" 2>/dev/null); p=$(stat -Lc '%a' "$h" 2>/dev/null)
      { [ "$ou" != "$uid" ] || perm_has "$p" 002; } && echo "$h(계정=$u,소유자=$o,$p)"; done | tr '\n' ' ')
if [ -z "$home_bad" ]; then rep U-31 "홈 디렉토리 소유자 및 권한 설정" GOOD "root·일반 사용자·로그인 가능 계정의 홈 소유자 일치 + other 쓰기 없음"
else rep U-31 "홈 디렉토리 소유자 및 권한 설정" VULN "부적절: $home_bad (기준: 소유자=계정, other 쓰기 없음)"; fi

# U-32 홈 디렉토리로 지정한 디렉토리의 존재 관리
# [기준] 양호 - 홈 디렉토리가 존재하지 않는 계정이 발견되지 않는 경우 / 취약 - 발견된 경우
#   대상: UID 와 무관하게 로그인 가능한 모든 계정(root·시스템 계정 포함, 빈 셸 필드=/bin/sh). NIS(+/-) 줄 제외.
#   셸이 nologin·false·true·sync·shutdown·halt 인 계정은 가이드 위협(로그인 시 / 할당)이 없어 판정에서 빼고,
#   그중 홈이 /home 아래로 지정됐는데 없는 계정만 참고로 표시.
nohome=$(awk -F: 'NF>=7 && $1 !~ /^[+-]/ && $7 !~ /\/(nologin|false|true|sync|shutdown|halt)$/ {print $1":"$6}' /etc/passwd \
  | while IFS=: read -r u h; do { [ -z "$h" ] || [ ! -d "$h" ]; } && echo "$u($h)"; done | tr '\n' ' ')
nohome_ref=$(awk -F: 'NF>=7 && $1 !~ /^[+-]/ && $7 ~ /\/(nologin|false|true)$/ && $6 ~ /^\/home\// {print $1":"$6}' /etc/passwd \
  | while IFS=: read -r u h; do [ -d "$h" ] || echo "$u($h)"; done | tr '\n' ' ')
u32_ref=""; [ -n "$nohome_ref" ] && u32_ref="참고(로그인 불가 계정, 판정 제외) /home 하위 홈 미존재: ${nohome_ref% }"
if [ -z "$nohome" ]; then rep U-32 "홈 디렉토리로 지정한 디렉토리의 존재 관리" GOOD "로그인 가능 계정(root·시스템 계정 포함)의 홈 디렉토리 모두 존재" ${u32_ref:+"$u32_ref"}
else rep U-32 "홈 디렉토리로 지정한 디렉토리의 존재 관리" VULN "홈 디렉토리 없음: ${nohome% }" ${u32_ref:+"$u32_ref"}; fi

# U-33 숨겨진 파일 및 디렉토리 검색 및 제거
# [기준] 양호 - 불필요하거나 의심스러운 숨겨진 파일·디렉토리를 제거한 경우 / 취약 - 제거하지 않은 경우
#   가이드 점검(find / -name ".*")은 전체 탐색이라 부하가 커서(find 미사용 정책) 악성파일이 주로 놓이는 경로만
#   깊이를 제한해 bash 로 순회한다(링크·숨김 디렉토리 안으로는 내려가지 않음, 소켓 제외).
#   1) 숨김 파일이 있을 이유가 없는 경로 — 표준 항목 외 숨김 항목이 있으면 취약
#      /tmp·/var/tmp·/dev/shm·/dev(2단계), /bin·/sbin·/usr/bin·/usr/sbin·/usr/local/bin·/usr/local/sbin(1단계)
#      표준: X11 계열(.X11-unix .ICE-unix .font-unix .Test-unix .XIM-unix .X<n>-lock), .s.PGSQL.*, 임시 디렉토리 .oracle,
#            /dev 의 .udev .initramfs* .lxc* .lxd-mounts, bin 의 FIPS 무결성 파일(.*.hmac)
#   2) 설정 dotfile 이 정상인 경로 — 의심 항목만 취약: 내용이 실행파일(ELF·#! 스크립트)이거나 스크립트·웹 확장자
#      (.sh .pl .py .php .jsp .asp .cgi 등)인 숨김 파일, 이름이 점·공백뿐인 위장 항목('...' 등)
#      /root·/home/*·/etc(2단계), /opt·/srv·/usr/local·/var/www(3단계). 권한이 아니라 내용으로 보므로
#      chmod -R 로 실행 비트가 붙은 .bashrc·cron .placeholder 등은 걸리지 않는다.
u33_scan() {  # $1=깊이 $2..=시작 디렉토리 → 숨김 항목 경로(소켓 제외). 단계마다 하위 디렉토리 최대 2000개
  local maxd=$1 depth=1 d e; shift
  local -a cur=("$@") nxt
  while [ ${#cur[@]} -gt 0 ] && [ "$depth" -le "$maxd" ]; do
    nxt=()
    for d in "${cur[@]}"; do
      [ -d "$d" ] || continue
      for e in "$d"/.[!.]* "$d"/..?*; do [ -S "$e" ] || printf '%s\n' "$e"; done
      [ "$depth" -lt "$maxd" ] || continue
      for e in "$d"/*; do [ ${#nxt[@]} -lt 2000 ] || break; [ -d "$e" ] && [ ! -L "$e" ] && nxt+=("$e"); done
    done
    cur=("${nxt[@]}"); depth=$((depth+1))
  done
}
susp=$( shopt -s nullglob
  { { u33_scan 2 /tmp /var/tmp /dev/shm /dev
      for d in /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin; do [ -L "$d" ] || u33_scan 1 "$d"; done
    } | sort -u | while IFS= read -r f; do
      case "${f##*/}" in (.X11-unix|.ICE-unix|.font-unix|.Test-unix|.XIM-unix|.X[0-9]*-lock|.s.PGSQL.*) continue;; esac
      case "$f" in (/tmp/.oracle|/var/tmp/.oracle|/dev/.udev|/dev/.initramfs*|/dev/.lxc*|/dev/.lxd-mounts|*bin/.*.hmac) continue;; esac
      printf '%s\n' "$f"
    done
    { u33_scan 2 /root /home/* /etc; u33_scan 3 /opt /srv /usr/local /var/www; } | sort -u | while IFS= read -r f; do
      b=${f##*/}
      case "$f" in (/usr/local/bin/*|/usr/local/sbin/*) continue;; esac
      case "$b" in (*[!.[:space:]]*) ;; (*) printf '%s(위장 이름)\n' "$f"; continue;; esac
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      case "$b" in (*.sh|*.pl|*.py|*.php|*.php[0-9]|*.phtml|*.jsp|*.jspx|*.asp|*.aspx|*.cgi) printf '%s(스크립트)\n' "$f"; continue;; esac
      hdr=""; IFS= read -r -n 4 hdr 2>/dev/null < "$f"
      case "$hdr" in ($'\177ELF'|'#!'*) printf '%s(실행파일)\n' "$f";; esac
    done
  } 2>/dev/null | head -10 | tr '\n' ' ')
if [ -z "$susp" ]; then rep U-33 "숨겨진 파일 및 디렉토리 검색 및 제거" GOOD "점검 경로(/tmp·/var/tmp·/dev·bin 디렉토리, 홈·/etc·/opt·/srv·/usr/local·/var/www)에 비정상·의심 숨김 파일 없음"
else rep U-33 "숨겨진 파일 및 디렉토리 검색 및 제거" VULN "불필요·의심 숨김 파일 존재: ${susp% } → 사유 확인 후 제거"; fi

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

# U-35 공유 서비스에 대한 익명 접근 제한 설정
# [기준] 양호 - 공유 서비스(FTP/NFS/Samba) 익명 접근 제한, 또는 공유 서비스 미사용(가이드: 양호 또는 N/A)
#        취약 - 공유 서비스 익명 접근 허용
#   ※ [vsFTP] anonymous_enable 마지막 유효값(미설정 시 vsftpd 기본값 YES) / [ProFTP] <Anonymous> 블록(User·UserAlias 근거)
#   ※ [NFS] /etc/exports(+exports.d) anonuid·anongid / [Samba] guest ok(=public) = yes
#   ※ 설정은 그 데몬이 실행 중일 때만 판정 근거로 쓴다(vsftpd·proftpd 는 각자 프로세스/서비스, NFS: nfs-server·nfsd·2049,
#     Samba: smb/smbd·139/445). 데몬이 꺼져 있으면 남은 설정(패키지 제거 후 conffile 등)은 참고로만 표시
#   ※ FTP(21 LISTEN·pure-ftpd·in.ftpd)가 실행 중인데 vsftpd·proftpd 가 아니면(inetd in.ftpd·pure-ftpd 등은 ftp 계정이
#     있으면 익명 허용) [기본 FTP] ftp/anonymous 계정을 근거로 수동확인
u35_v=""; u35_g=""; u35_m=""; u35_n=""
ftp_on=0; { port_listen 21 || proc_run pure-ftpd || proc_run in.ftpd; } && ftp_on=1
vs_on=0; { proc_run vsftpd || svc_active vsftpd; } && vs_on=1
pf_on=0; { proc_run proftpd || svc_active proftpd; } && pf_on=1
vs_cf=0
for f in /etc/vsftpd/vsftpd.conf /etc/vsftpd.conf; do
  [ -f "$f" ] || continue; vs_cf=1
  v=$(conf_line '^[[:space:]]*anonymous_enable[[:space:]]*=' "$f"); v=${v#*=}
  v=$(printf '%s' "$v" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  case "${v:-YES}" in
    YES|TRUE|1) u35_a="vsftpd anonymous_enable=${v:-미설정(기본값 YES)}($f)"
                if [ "$vs_on" -eq 1 ]; then u35_v="$u35_v $u35_a"; else u35_n="$u35_n vsftpd 미실행, $u35_a 잔존"; fi ;;
    *)          [ "$vs_on" -eq 1 ] && u35_g="$u35_g vsftpd anonymous_enable=$v($f)" ;;
  esac
done
[ "$vs_on" -eq 1 ] && [ "$vs_cf" -eq 0 ] && u35_m="$u35_m vsftpd 실행 중이나 /etc/vsftpd/vsftpd.conf·/etc/vsftpd.conf 없음 → 실제 설정파일의 anonymous_enable 확인"
pf=""; for f in /etc/proftpd/proftpd.conf /etc/proftpd.conf /etc/proftpd/conf.d/*.conf; do [ -f "$f" ] && pf="$pf $f"; done
if [ -n "$pf" ] && grep -qiE '^[[:space:]]*<Anonymous' $pf 2>/dev/null; then
  ua=$(awk 'tolower($1) ~ /^<anonymous/ {a=1} a && tolower($1) ~ /^(user|useralias)$/ {printf "%s%s %s%s", s, $1, $2, ($3 != "" ? " " $3 : ""); s=", "} tolower($1) ~ /^<\/anonymous/ {a=0}' $pf 2>/dev/null)
  u35_a="proftpd <Anonymous> 블록 존재${ua:+($ua)}"
  if [ "$pf_on" -eq 1 ]; then u35_v="$u35_v $u35_a"; else u35_n="$u35_n proftpd 미실행, $u35_a 잔존"; fi
elif [ "$pf_on" -eq 1 ]; then
  if [ -n "$pf" ]; then u35_g="$u35_g proftpd <Anonymous> 블록 없음"
  else u35_m="$u35_m proftpd 실행 중이나 /etc/proftpd/proftpd.conf·/etc/proftpd.conf 없음 → 실제 설정파일의 <Anonymous> 블록 확인"; fi
fi
if [ "$ftp_on" -eq 1 ] && [ "$vs_on" -eq 0 ] && [ "$pf_on" -eq 0 ]; then
  fa=$(awk -F: '$1=="ftp" || $1=="anonymous" {printf " %s", $1}' /etc/passwd 2>/dev/null)
  u35_m="$u35_m FTP 실행 중(21 LISTEN 또는 pure-ftpd/in.ftpd)이나 vsftpd·proftpd 아님 → 익명 접속 허용 여부 점검([기본 FTP] ftp/anonymous 계정:${fa:- 없음})"
fi
nfs_anon=$(sed 's/#.*//' /etc/exports /etc/exports.d/*.exports 2>/dev/null | grep -E 'anon(uid|gid)[[:space:]]*=' | awk '{printf " %s", $1}')
if svc_active nfs-server || svc_active nfs || proc_run nfsd || port_listen 2049; then
  if [ -n "$nfs_anon" ]; then u35_v="$u35_v NFS anonuid/anongid 설정:$nfs_anon"
  else u35_g="$u35_g NFS 실행 중이나 anonuid/anongid 없음"; fi
elif [ -n "$nfs_anon" ]; then u35_n="$u35_n NFS 미실행, /etc/exports anon 옵션 잔존:$nfs_anon"; fi
smb_on=0; { svc_active smb || svc_active smbd || proc_run smbd || port_listen 445 || port_listen 139; } && smb_on=1
smb_t=""; [ "$smb_on" -eq 1 ] && have testparm && smb_t=$(run_to 10 testparm -s </dev/null 2>/dev/null)
[ -z "$smb_t" ] && smb_t=$(cat /etc/samba/smb.conf 2>/dev/null)
smb_g=$(printf '%s\n' "$smb_t" | awk '/^[ \t]*\[/ {s=$0; gsub(/^[ \t]+|[ \t]+$/, "", s)} tolower($0) ~ /^[ \t]*(guest[ _]*ok|public)[ \t]*=[ \t]*(yes|true|on|1)[ \t]*$/ {printf " %s", (s == "" ? "[global]" : s)}')
if [ "$smb_on" -eq 1 ]; then
  if [ -n "$smb_g" ]; then u35_v="$u35_v Samba guest ok=yes:$smb_g"
  else u35_g="$u35_g Samba 실행 중이나 guest ok 허용 없음"; fi
elif [ -n "$smb_g" ]; then u35_n="$u35_n Samba 미실행, smb.conf guest ok=yes 잔존:$smb_g"; fi
if [ -n "$u35_v" ]; then
  rep U-35 "공유 서비스에 대한 익명 접근 제한 설정" VULN "익명 접근 허용:$u35_v"
elif [ -n "$u35_m" ]; then
  rep U-35 "공유 서비스에 대한 익명 접근 제한 설정" MAN "익명 설정 확인 필요:$u35_m${u35_g:+ / 제한 확인:$u35_g}${u35_n:+ / 참고:$u35_n}"
elif [ -n "$u35_g" ]; then
  rep U-35 "공유 서비스에 대한 익명 접근 제한 설정" GOOD "익명 접근 제한:$u35_g${u35_n:+ / 참고:$u35_n}"
else
  rep U-35 "공유 서비스에 대한 익명 접근 제한 설정" GOOD "공유 서비스(FTP/NFS/Samba) 미사용 → 가이드: 양호 또는 N/A${u35_n:+ / 참고:$u35_n}"
fi

# U-36 r 계열 서비스 비활성화
# [기준] 양호 - 불필요한 r 계열 서비스 비활성화 / 취약 - 불필요한 r 계열 서비스 활성화
#   ※ 대상 exec(512)·login(513)·shell(514)는 TCP. UDP 512(biff)·513(rwho)·514(syslog)는 r 계열이 아니므로 TCP 만 본다.
#     TCP 514 를 rsyslog(imtcp)·syslog-ng 가 쓰는 경우도 있어, 소유 프로세스가 syslog 데몬이면 제외하고 참고로 표시
#   ※ 활성: TCP 512~514 LISTEN, rshd/rlogind/rexecd 프로세스, rsh/rlogin/rexec.socket 활성,
#     inetd 실행 중 inetd.conf 비주석 shell/login/exec 줄, xinetd 실행 중 xinetd.d shell/login/exec 서비스(disable=yes 아님)
#     (inetd·xinetd 미실행이면 남은 설정은 참고로 표시)
#   ※ 사용 여부: hosts.equiv·$HOME/.rhosts(U-27 수집값 found)에 설정이 있으면 사용 중 → 필요성 확인(수동확인),
#     파일이 없거나 설정이 없으면 미사용으로 간주(가이드) → 활성 시 취약
#   ※ rsync 데몬(가이드 참고상 r-command)은 백업 등 정상 용도가 많아 활성 시 사용 목적 확인(수동확인)
r_hit=""; r_sync=""; r_n=""
r_tcp=$( { ss -lnt 2>/dev/null | awk '$1 == "LISTEN" {print $4}'; netstat -lnt 2>/dev/null | awk '/^tcp/ {print $4}'; } )
for p in 512 513 514; do
  printf '%s\n' "$r_tcp" | grep -qE "[:.]$p\$" || continue
  o=$( { ss -lntp 2>/dev/null; netstat -lntp 2>/dev/null; } | grep -E "[:.]$p[[:space:]]" )
  if [ -n "$o" ] && ! printf '%s\n' "$o" | grep -qvE 'rsyslogd|syslog-ng'; then r_n="$r_n TCP $p=syslog 데몬 수신(r 계열 아님)"
  else r_hit="$r_hit tcp:$p"; fi
done
proc_run "rlogind|in.rlogind|rshd|in.rshd|rexecd|in.rexecd" && r_hit="$r_hit proc"
{ svc_active rsh.socket || svc_active rlogin.socket || svc_active rexec.socket; } && r_hit="$r_hit socket"
o=$(grep -E '^[[:space:]]*(shell|login|exec)[[:space:]]' /etc/inetd.conf 2>/dev/null | awk '{printf " %s", $1}')
if [ -n "$o" ]; then
  if proc_run inetd || proc_run inetutils-inetd; then r_hit="$r_hit inetd.conf:$o"
  else r_n="$r_n inetd 미실행, inetd.conf 활성 줄 잔존:$o"; fi
fi
r_xi=""; r_xs=""
for f in /etc/xinetd.d/*; do
  [ -f "$f" ] || continue
  grep -qiE '^[[:space:]]*disable[[:space:]]*=[[:space:]]*yes' "$f" && continue
  grep -qE '^[[:space:]]*service[[:space:]]+(shell|login|exec)([[:space:]]|$)' "$f" && r_xi="$r_xi ${f##*/}"
  grep -qE '^[[:space:]]*service[[:space:]]+rsync([[:space:]]|$)' "$f" && r_xs="$r_xs ${f##*/}"
done
if [ -n "$r_xi$r_xs" ]; then
  if proc_run xinetd; then r_hit="$r_hit${r_xi:+ xinetd:$r_xi}"; r_sync="$r_sync${r_xs:+ xinetd:$r_xs}"
  else r_n="$r_n xinetd 미실행, xinetd.d 활성 설정 잔존:$r_xi$r_xs"; fi
fi
printf '%s\n' "$r_tcp" | grep -qE '[:.]873$' && r_sync="$r_sync tcp:873"
{ svc_active rsync || svc_active rsyncd || svc_active rsyncd.socket; } && r_sync="$r_sync service"
proc_run "rsync --daemon" && r_sync="$r_sync proc"
r_tr=""; [ -n "$found" ] && r_tr=$(grep -lvE '^[[:space:]]*(#|$)' $found 2>/dev/null | awk '{printf " %s", $0}')
r_ev="신뢰파일(hosts.equiv/.rhosts) 설정:${r_tr:- 없음}${r_n:+ / 참고:$r_n}"
if [ -n "$r_hit" ] && [ -n "$r_tr" ]; then rep U-36 "r 계열 서비스 비활성화" MAN "r계열 서비스 활성:$r_hit, 신뢰파일 설정 있음(사용 중으로 간주) → 업무상 필요 여부 확인, 불필요 시 비활성화 ($r_ev)"
elif [ -n "$r_hit" ]; then rep U-36 "r 계열 서비스 비활성화" VULN "r계열 서비스 활성:$r_hit, 신뢰파일 설정 없음(미사용으로 간주) → 비활성화 ($r_ev)"
elif [ -n "$r_sync" ]; then rep U-36 "r 계열 서비스 비활성화" MAN "rlogin/rsh/rexec 미실행. rsync 데몬 활성:$r_sync → 사용 목적 확인, 불필요 시 중지 ($r_ev)"
else rep U-36 "r 계열 서비스 비활성화" GOOD "rlogin/rsh/rexec(TCP 512~514·inetd·xinetd·socket)·rsync 데몬 미실행 ($r_ev)"; fi

# U-37 crontab 설정파일 권한 설정
# [기준] 양호 - crontab·at 명령어에 일반 사용자 실행 권한이 제거되어 있고, cron/at 관련 파일 권한이 640 이하
#        취약 - 위 두 조건 중 하나라도 미충족
#   ※ 명령어: /usr/bin/crontab, /usr/bin/at → 소유자 root + 750 이하(타 사용자 실행 없음, SUID/SGID 제거).
#     (배포판 기본값 crontab 2755/4755, at 6755/4755 는 일반 사용자가 예약 작업을 등록할 수 있어 취약)
#   ※ 관련 파일: /etc/crontab, /etc/cron.allow, /etc/cron.deny, /etc/at.allow, /etc/at.deny,
#      /etc/cron.d/*, /var/spool/cron/ 하위 사용자 crontab → 소유자 root + 640 이하.
#   ※ run-parts 스크립트 디렉터리(cron.hourly/daily/weekly/monthly)의 실행 스크립트는
#      설정파일이 아니라 실행 권한(x)이 필요한 스크립트이므로 상세가이드 점검 대상이 아니다.
#   ※ 권한은 숫자 크기가 아니라 그룹/기타 비트로 비교(perm_go_le) — 700 은 640 보다 제한적이라 양호.
cmd_bad=""
for f in /usr/bin/crontab /usr/bin/at; do
  [ -e "$f" ] || continue; p=$(stat -Lc '%a' "$f"); o=$(stat -Lc '%U' "$f")
  { [ "$o" = root ] && [ $(( 8#$p & 8#7000 )) -eq 0 ] && perm_go_le "$p" 750; } || cmd_bad="$cmd_bad $f($o,$p)"
done
cron_bad=""
for f in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
  [ -e "$f" ] || continue; p=$(stat -c '%a' "$f"); o=$(stat -c '%U' "$f")
  { [ "$o" = root ] && perm_go_le "$p" 640; } || cron_bad="$cron_bad $f($o,$p)"
done
if [ -d /etc/cron.d ]; then
  for f in /etc/cron.d/*; do
    [ -f "$f" ] || continue; p=$(stat -c '%a' "$f"); o=$(stat -c '%U' "$f")
    { [ "$o" = root ] && perm_go_le "$p" 640; } || cron_bad="$cron_bad $f($o,$p)"
  done
fi
for f in /var/spool/cron/* /var/spool/cron/crontabs/*; do
  [ -f "$f" ] || continue; p=$(stat -c '%a' "$f")
  perm_go_le "$p" 600 || cron_bad="$cron_bad $f($p)"
done
[ -e /etc/cron.allow ] && cron_restrict="cron.allow 존재(허용목록 방식)" || cron_restrict="cron.allow 없음(전체 사용자 crontab 가능)"
if [ -n "$cmd_bad$cron_bad" ]; then
  u37=""
  [ -n "$cmd_bad" ]  && u37="$u37 명령어 일반 사용자 실행/SUID·SGID 허용(기준: root, 750 이하):$cmd_bad."
  [ -n "$cron_bad" ] && u37="$u37 설정파일 권한 초과(기준: root, 640 이하):$cron_bad."
  rep U-37 "crontab 설정파일 권한 설정" VULN "${u37# } $cron_restrict"
elif [ -e /etc/cron.allow ]; then
  rep U-37 "crontab 설정파일 권한 설정" GOOD "crontab/at 명령어 root·750 이하(SUID/SGID 없음) + cron/at 설정파일 root·640 이하, $cron_restrict"
else
  rep U-37 "crontab 설정파일 권한 설정" MAN "crontab/at 명령어·설정파일 권한은 양호. 다만 $cron_restrict → cron.allow 로 일반 사용자 crontab 제한 권고(인터뷰)"
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

# 메일 서비스 공통 (가이드 U-45~U-48 점검 대상: Sendmail / Postfix / Exim)
#  ※ proc_run "master|sendmail" 은 -f 정규식이 '(^|[/ ])master|sendmail( |$)' 로 풀려 'nginx: master process' 도
#    메일로 오인했다 → postfix master 는 실행 경로(.../postfix/[sbin/]master), exim·sendmail 은 프로세스명(-x)으로 본다.
mail_pf_run=0; { svc_active postfix || pgrep -f '^[^ ]*/postfix/(sbin/)?master( |$)' >/dev/null 2>&1; } && mail_pf_run=1
mail_ex_run=0; { svc_active exim4 || svc_active exim || pgrep -x 'exim4?' >/dev/null 2>&1; } && mail_ex_run=1
mail_kind="none"
{ [ "$mail_pf_run" -eq 1 ] || pkg_installed postfix; } && mail_kind="postfix"
{ [ "$mail_ex_run" -eq 1 ] || pkg_installed exim || pkg_installed exim4-base || [ -x /usr/sbin/exim ] || [ -x /usr/sbin/exim4 ]; } && mail_kind="exim"
{ svc_active sendmail || pkg_installed sendmail || pkg_installed sendmail-cf; } && mail_kind="sendmail"
# 둘 이상 설치된 경우 실제 기동 중인 MTA 를 점검 대상으로 한다
if [ "$mail_pf_run" -eq 1 ]; then mail_kind="postfix"; elif [ "$mail_ex_run" -eq 1 ]; then mail_kind="exim"; fi
mail_run=0
{ port_listen 25 || [ "$mail_pf_run" -eq 1 ] || [ "$mail_ex_run" -eq 1 ] || \
  { [ "$mail_kind" = sendmail ] && { svc_active sendmail || pgrep -x sendmail >/dev/null 2>&1; }; }; } && mail_run=1
# 미기동이어도 부팅 시 자동기동(enabled)이면 '사용'으로 본다 (가이드 조치: 미사용 시 서비스 중지 '및 비활성화')
mail_used=$mail_run
case "$mail_kind" in
  postfix)  svc_enabled postfix  && mail_used=1 ;;
  sendmail) svc_enabled sendmail && mail_used=1 ;;
  exim)     { svc_enabled exim4 || svc_enabled exim; } && mail_used=1 ;;
esac
mail_na="메일 서비스 미설치"; [ "$mail_kind" = none ] || mail_na="$mail_kind 설치되어 있으나 미기동·비활성화 (SMTP 서비스 미사용)"
# exim 설정 파일 (RHEL /etc/exim, Debian /etc/exim4 또는 update-exim4.conf 생성본)
mail_excf=""
for mf in /etc/exim/exim.conf /etc/exim4/exim4.conf /var/lib/exim4/config.autogenerated; do [ -f "$mf" ] && mail_excf="$mail_excf $mf"; done

# U-45 메일 서비스 버전 점검
# [기준] 양호 - SMTP 서비스를 사용하지 않거나, 사용 시 알려진 취약점이 없는 최신(패치) 버전 / 취약 - 구버전
#  ※ 판정 근거는 '리스닝 범위'가 아니라 '버전(미적용 보안 업데이트)' 이다.
#    localhost 전용이라도 서비스가 기동 중이면 버전으로 판정하고, 외부/로컬 노출 여부는 근거에 함께 기재한다.
#  ※ 미기동이라도 enabled 이면 '미사용 시 중지 및 비활성화' 조치가 안 된 것이므로 버전으로 판정한다.
if [ "$mail_kind" = none ]; then
  rep U-45 "메일 서비스 버전 점검" GOOD "sendmail/postfix/exim 등 메일 서비스 미설치"
elif [ "$mail_used" -ne 1 ]; then
  rep U-45 "메일 서비스 버전 점검" GOOD "$mail_na"
else
  mst="기동 중"; expose="localhost 전용"; port_listen_ext 25 && expose="외부(25) 제공"
  [ "$mail_run" -eq 1 ] || { mst="미기동이나 enabled(부팅 시 자동기동)"; expose="리슨 없음"; }
  mv=""
  case "$mail_kind" in   # 버전은 가이드 확인 명령으로, 보안 업데이트는 해당 MTA 패키지만 센다
    postfix)  mv=$(postconf mail_version 2>/dev/null | awk '{print $3}'); mail_dp='postfix'; mail_ap='^postfix[^/]*/' ;;
    exim)     mv=$( { run_to 10 exim -bV || run_to 10 exim4 -bV; } 2>/dev/null | head -1); mail_dp='exim'; mail_ap='^exim4?[^/]*/' ;;
    *)        mv=$( (sendmail -d0.1 -bv root 2>/dev/null; echo) | grep -i 'Version' | head -1); mail_dp='sendmail'; mail_ap='^sendmail[^/]*/' ;;
  esac
  pend=$(sec_update_count "$mail_dp" "$mail_ap")
  if [ "$pend" = "?" ]; then
    rep U-45 "메일 서비스 버전 점검" MAN "$mail_kind $mst($expose, 버전=${mv:-확인필요}) — 패키지 관리자 없음, 최신 버전 여부 수동 확인 필요"
  elif [ "${pend:-0}" -gt 0 ]; then
    rep U-45 "메일 서비스 버전 점검" VULN "$mail_kind $mst($expose, 버전=${mv:-확인필요}) + 보안 업데이트 ${pend}건 미적용(구버전)"
  else
    rep U-45 "메일 서비스 버전 점검" GOOD "$mail_kind $mst($expose, 버전=${mv:-확인필요}), 미적용 보안 업데이트 없음(최신)"
  fi
fi

# U-46 일반 사용자의 메일 서비스 실행 방지
# [기준] 양호 - 일반 사용자의 메일 서비스(큐 조작 등) 실행 방지 설정 / 취약 - 미설정
#  가이드는 'SMTP 서비스 사용 시' 점검: Sendmail=PrivacyOptions 에 restrictqrun,
#  Postfix=/usr/sbin/postsuper, Exim=/usr/sbin/exiqgrep 의 일반 사용자 실행 권한(o+x) 제거
if [ "$mail_kind" = none ] || [ "$mail_used" -ne 1 ]; then rep U-46 "일반 사용자의 메일 서비스 실행 방지" NA "$mail_na"
elif [ "$mail_kind" = sendmail ]; then
  if [ -n "$(conf_line '^[[:space:]]*O[[:space:]]+PrivacyOptions[[:space:]]*=.*restrictqrun' /etc/mail/sendmail.cf)" ]; then
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" GOOD "sendmail PrivacyOptions restrictqrun 설정"
  else
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" VULN "sendmail PrivacyOptions 에 restrictqrun 미설정"
  fi
else
  mq=/usr/sbin/exiqgrep
  if [ "$mail_kind" = postfix ]; then mq=/usr/sbin/postsuper; [ -e "$mq" ] || mq="$(postconf -h command_directory 2>/dev/null)/postsuper"; fi
  mqp=$(stat -Lc '%a' "$mq" 2>/dev/null)
  if [ -z "$mqp" ]; then
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" MAN "$mail_kind 사용 중이나 $mq 미존재 → 큐 관리 명령 위치·권한 수동 확인 필요"
  elif perm_has "$mqp" 001; then
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" VULN "$mail_kind $mq 권한=$mqp (일반 사용자 실행 가능) → chmod o-x $mq 필요"
  else
    rep U-46 "일반 사용자의 메일 서비스 실행 방지" GOOD "$mail_kind $mq 권한=$mqp (일반 사용자 실행 권한 없음)"
  fi
fi

# U-47 스팸 메일 릴레이 제한
# [기준] 양호 - 릴레이 제한 설정 / 취약 - 오픈 릴레이 가능   (※ 메일 서비스 미사용 시 양호 또는 N/A)
if [ "$mail_kind" = none ] || [ "$mail_used" -ne 1 ]; then
  rep U-47 "스팸 메일 릴레이 제한" NA "$mail_na"
elif [ "$mail_kind" = exim ]; then
  # 가이드: relay_from_hosts / 'hosts =' 확인 → 전체(*, 0.0.0.0/0) 허용이면 오픈릴레이
  ex_rl=$(grep -hiE '^[[:space:]]*(hostlist[[:space:]]+relay_from_hosts|MAIN_RELAY_NETS|dc_relay_nets|(accept[[:space:]]+)?hosts)[[:space:]]*=' $mail_excf /etc/exim4/update-exim4.conf.conf 2>/dev/null)
  ex_open=$(printf '%s\n' "$ex_rl" | grep -E '(^|[^[:alnum:]._+-])\*([^[:alnum:].]|$)|0\.0\.0\.0/0|::/0' | head -1 | tr -s ' \t' ' ')
  ex_rv=$(printf '%s\n' "$ex_rl" | grep -iE 'relay_from_hosts|relay_nets' | tr -s ' \t\n' ' ')
  if [ -n "$ex_open" ]; then
    rep U-47 "스팸 메일 릴레이 제한" VULN "exim 릴레이 허용 범위 전체($ex_open) → relay_from_hosts 를 허용 네트워크로 한정 필요"
  elif [ -z "$mail_excf" ]; then
    rep U-47 "스팸 메일 릴레이 제한" MAN "exim 설정 파일(/etc/exim/exim.conf, /etc/exim4/exim4.conf) 미발견 → 릴레이 정책 수동 확인 필요"
  else
    rep U-47 "스팸 메일 릴레이 제한" GOOD "exim 릴레이 허용 대상 제한 (${ex_rv:-relay_from_hosts 미설정})"
  fi
elif [ "$mail_kind" = postfix ]; then
  rr="$(postconf -h smtpd_relay_restrictions 2>/dev/null) $(postconf -h smtpd_recipient_restrictions 2>/dev/null)"
  mynet=$(postconf -h mynetworks 2>/dev/null)
  if echo "$mynet" | grep -qE '(^|[[:space:],])(0\.0\.0\.0/0|\[?::\]?/0)([[:space:],]|$)'; then
    rep U-47 "스팸 메일 릴레이 제한" VULN "postfix mynetworks=$mynet (전체 대역) → permit_mynetworks 로 오픈릴레이 가능"
  elif echo "$rr" | grep -qE 'reject_unauth_destination|defer_unauth_destination'; then
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
# [기준] 양호 - noexpn/novrfy(또는 disable_vrfy_command) 설정 / 취약 - 미설정   (※ 메일 서비스 미사용 시 양호 또는 N/A)
if [ "$mail_kind" = none ] || [ "$mail_used" -ne 1 ]; then rep U-48 "expn, vrfy 명령어 제한" NA "$mail_na"
elif [ "$mail_kind" = postfix ]; then
  if postconf -h disable_vrfy_command 2>/dev/null | grep -qi yes; then rep U-48 "expn, vrfy 명령어 제한" GOOD "postfix disable_vrfy_command=yes"
  else rep U-48 "expn, vrfy 명령어 제한" VULN "postfix disable_vrfy_command=no → VRFY 명령 허용"; fi
elif [ "$mail_kind" = exim ]; then   # 가이드: acl_smtp_vrfy/acl_smtp_expn = accept 가 있으면 제거 대상
  if [ -z "$mail_excf" ]; then rep U-48 "expn, vrfy 명령어 제한" MAN "exim 설정 파일 미발견 → acl_smtp_vrfy/acl_smtp_expn 수동 확인 필요"
  elif grep -qiE '^[[:space:]]*acl_smtp_(vrfy|expn)[[:space:]]*=[[:space:]]*accept([[:space:]]|$)' $mail_excf 2>/dev/null; then rep U-48 "expn, vrfy 명령어 제한" VULN "exim acl_smtp_vrfy/acl_smtp_expn = accept → VRFY/EXPN 허용"
  else rep U-48 "expn, vrfy 명령어 제한" GOOD "exim acl_smtp_vrfy/acl_smtp_expn = accept 미설정 (VRFY/EXPN 거부)"; fi
else   # sendmail: 주석 제외, noexpn 과 novrfy 둘 다(또는 goaway) 있어야 양호
  mpo=$(conf_line '^[[:space:]]*O[[:space:]]+PrivacyOptions[[:space:]]*=' /etc/mail/sendmail.cf)
  if echo "$mpo" | grep -qi goaway || { echo "$mpo" | grep -qi noexpn && echo "$mpo" | grep -qi novrfy; }; then rep U-48 "expn, vrfy 명령어 제한" GOOD "sendmail PrivacyOptions noexpn,novrfy(또는 goaway) 설정"
  else rep U-48 "expn, vrfy 명령어 제한" VULN "sendmail PrivacyOptions 에 noexpn/novrfy(또는 goaway) 미설정 (현재: ${mpo:-없음})"; fi
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
# 설정 파일은 실행 중인 데몬 기준으로 고른다(다른 데몬이 남긴 설정을 읽지 않도록). 데몬을 모르면 존재 순서대로.
ftp_d=""
for f in vsftpd proftpd pure-ftpd in.ftpd; do pgrep -x "$f" >/dev/null 2>&1 && { ftp_d=$f; break; }; done
ftp_conf=""
for f in /etc/vsftpd/vsftpd.conf /etc/vsftpd.conf /etc/proftpd/proftpd.conf /etc/proftpd.conf; do
  [ -e "$f" ] || continue
  case "$ftp_d:$f" in vsftpd:*proftpd*|proftpd:*vsftpd*|pure-ftpd:*|in.ftpd:*) continue;; esac
  ftp_conf=$f; break
done
case "$ftp_conf" in *vsftpd*) ftp_d=vsftpd;; *proftpd*) ftp_d=proftpd;; esac
# 설정값(주석 제외 마지막 값). vsftpd 는 'key=값', proftpd 는 'Key 값' 형식
ftp_val() { conf_line "^[[:space:]]*$1([[:space:]]*=|[[:space:]])" "${@:2}" | sed -E 's/^[[:space:]]*[^=[:space:]]+[[:space:]]*=?[[:space:]]*//; s/[[:space:]]+$//'; }
ftp_yes() { case "${1^^}" in YES|TRUE|ON|1) return 0;; esac; return 1; }
ftp_no()  { case "${1^^}" in NO|FALSE|OFF|0) return 0;; esac; return 1; }
ftp_root_in() { local f; for f in "$@"; do grep -qE '^[[:space:]]*root[[:space:]]*$' "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }; done; return 1; }   # root 줄(주석 제외)이 있는 첫 파일
# stdin=21/tcp 허용 규칙 줄, $1=출발지 지정 표시(정규식) → 출발지 없는(전체) 허용이 없을 때만 첫 줄 출력
ftp_fw_pick() { local r; r=$(grep -v '^[[:space:]]*$'); [ -n "$r" ] || return 1; printf '%s\n' "$r" | grep -qvE "$1" && return 1; printf '%s\n' "$r" | head -1; }

# U-53 FTP 서비스 정보 노출 제한   [기준] 양호 - 접속 배너에 노출되는 정보 없음 / 취약 - 노출
#   vsftpd : banner_file(우선)·ftpd_banner 가 없거나 값·파일이 비면(vsftpd 는 빈 값을 미설정으로 처리) 기본 배너 "(vsFTPd 버전)" 노출
#   proftpd: ServerIdent off 또는 ServerIdent on "<배너>" 만 인정 (DisplayLogin 은 로그인 후 메시지라 무관)
#   지정한 배너에 서비스명·버전이 들어 있어도 취약(가이드 권고: 서비스 이름·버전 미노출)
ftp_info_re='(vs|pro|pure-?|wu-?)ftpd|[0-9]+(\.[0-9]+)+'
u53_src=""; u53_txt=""; u53_def=""
if [ -n "$ftp_conf" ] && [ "$ftp_d" = vsftpd ]; then
  u53_bf=$(ftp_val banner_file "$ftp_conf"); u53_fb=$(ftp_val ftpd_banner "$ftp_conf")
  [ -n "$u53_bf" ] && [ -r "$u53_bf" ] && [ ! -s "$u53_bf" ] && u53_bf=""   # 빈 banner_file 은 vsftpd 가 무시(ftpd_banner/기본 배너로 폴백)
  if [ -n "$u53_bf" ]; then u53_src="banner_file=$u53_bf"; u53_txt=$(head -c 2048 "$u53_bf" 2>/dev/null) || u53_src="$u53_src(읽기 불가)"
  elif [ -n "$u53_fb" ]; then u53_src="ftpd_banner"; u53_txt=$u53_fb; fi
  u53_def="vsftpd ftpd_banner/banner_file 미설정(빈 값·빈 파일 포함) → 기본 배너에 vsFTPd 버전 노출 ($ftp_conf)"
elif [ -n "$ftp_conf" ]; then   # proftpd
  u53_si=$(ftp_val ServerIdent "$ftp_conf" /etc/proftpd/conf.d/*.conf)
  u53_st=$(printf '%s' "${u53_si:2}" | sed -E 's/^[[:space:]]+//; s/^"(.*)"$/\1/')   # on 뒤 배너 문자열(따옴표 제거)
  case "${u53_si,,}" in
    off|off[[:space:]]*) u53_src="ServerIdent off";;
    on[[:space:]]*) [ -n "$u53_st" ] && { u53_src="ServerIdent on \"배너\""; u53_txt=$u53_st; };;
  esac
  u53_def="proftpd ServerIdent ${u53_si:-미설정(기본 on)} → 배너 문자열 미지정, 기본 배너에 ProFTPD 서비스명 노출 ($ftp_conf)"
fi
if [ "$ftp_run" -eq 0 ]; then rep U-53 "FTP 서비스 정보 노출 제한" NA "FTP 서비스 미실행"
elif [ -z "$u53_def" ]; then
  rep U-53 "FTP 서비스 정보 노출 제한" MAN "FTP(21) 실행 중이나 vsftpd/proftpd 설정 미확인(데몬=${ftp_d:-불명}) → 접속 배너(220 응답) 수동 확인"
elif [ -z "$u53_src" ]; then
  rep U-53 "FTP 서비스 정보 노출 제한" VULN "$u53_def"
elif [ "${u53_src%(읽기 불가)}" != "$u53_src" ]; then
  rep U-53 "FTP 서비스 정보 노출 제한" MAN "$u53_src → 접속 배너 수동 확인"
elif u53_hit=$(printf '%s' "$u53_txt" | grep -oiE "$ftp_info_re" | head -3 | tr '\n' ' '); [ -n "$u53_hit" ]; then
  rep U-53 "FTP 서비스 정보 노출 제한" VULN "$u53_src 설정됐으나 배너에 서비스명·버전 노출: ${u53_hit% }"
else
  rep U-53 "FTP 서비스 정보 노출 제한" GOOD "$u53_src 설정 → 배너에 서비스명·버전 미노출 ($ftp_conf)"
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
#   ftpusers(/etc/ftpusers·/etc/ftpd/ftpusers, vsftpd 는 /etc/vsftpd/ftpusers·/etc/vsftpd.ftpusers 도)에 root 줄(주석 제외) → 차단
#   vsftpd : local_enable 이 YES 가 아니면(기본 NO) 로컬 계정 로그인 불가. userlist_enable=YES 일 때
#            userlist_deny=YES(기본)는 user_list 에 root 가 있어야, userlist_deny=NO(허용 목록)는 root 가 없어야 차단
#   proftpd: UseFtpUsers off 면 ftpusers 미적용. RootLogin on 이 아니면(기본 off) root 차단
if [ "$ftp_run" -eq 0 ] && ! pkg_installed vsftpd && ! pkg_installed proftpd && ! pkg_installed proftpd-basic \
   && ! pkg_installed proftpd-core && ! pkg_installed pure-ftpd; then
  rep U-57 "Ftpusers 파일 설정" NA "FTP 미설치/미실행 → root FTP 접속 위협 없음"
else
  u57_fl="/etc/ftpusers /etc/ftpd/ftpusers"; [ "$ftp_d" = proftpd ] || u57_fl="$u57_fl /etc/vsftpd/ftpusers /etc/vsftpd.ftpusers"
  u57_fu=$(ftp_root_in $u57_fl)
  if [ -n "$ftp_conf" ] && [ "$ftp_d" = vsftpd ]; then
    u57_le=$(ftp_val local_enable "$ftp_conf"); u57_ue=$(ftp_val userlist_enable "$ftp_conf"); u57_ud=$(ftp_val userlist_deny "$ftp_conf")
    u57_uf=$(ftp_val userlist_file "$ftp_conf"); u57_ul=$(ftp_root_in ${u57_uf:-/etc/vsftpd/user_list /etc/vsftpd.user_list})
    if [ -n "$u57_fu" ]; then rep U-57 "Ftpusers 파일 설정" GOOD "$u57_fu 에 root 포함 (FTP 접속 차단)"
    elif ! ftp_yes "$u57_le"; then rep U-57 "Ftpusers 파일 설정" GOOD "vsftpd local_enable=${u57_le:-미설정(기본 NO)} → root 등 로컬 계정 FTP 로그인 불가"
    elif ftp_yes "$u57_ue" && ! ftp_no "$u57_ud" && [ -n "$u57_ul" ]; then
      rep U-57 "Ftpusers 파일 설정" GOOD "vsftpd userlist_enable=YES, userlist_deny=${u57_ud:-YES(기본)} + $u57_ul 에 root 포함 (접속 차단)"
    elif ftp_yes "$u57_ue" && ftp_no "$u57_ud" && [ -z "$u57_ul" ]; then
      rep U-57 "Ftpusers 파일 설정" GOOD "vsftpd userlist_deny=NO(허용 목록) + user_list 에 root 없음 → root 접속 불가"
    elif ftp_yes "$u57_ue" && ftp_no "$u57_ud"; then
      rep U-57 "Ftpusers 파일 설정" VULN "vsftpd userlist_deny=NO(허용 목록)인데 $u57_ul 에 root 포함 + ftpusers 차단 없음 → root FTP 접속 허용"
    else rep U-57 "Ftpusers 파일 설정" VULN "vsftpd ftpusers·user_list(userlist_enable=${u57_ue:-NO})에 root 차단 없음 → root FTP 접속 가능"; fi
  elif [ -n "$ftp_conf" ]; then   # proftpd
    u57_uu=$(ftp_val UseFtpUsers "$ftp_conf" /etc/proftpd/conf.d/*.conf); u57_rl=$(ftp_val RootLogin "$ftp_conf" /etc/proftpd/conf.d/*.conf)
    if ! ftp_no "$u57_uu" && [ -n "$u57_fu" ]; then rep U-57 "Ftpusers 파일 설정" GOOD "proftpd UseFtpUsers=${u57_uu:-on(기본)} + $u57_fu 에 root 포함 (접속 차단)"
    elif ! ftp_yes "$u57_rl"; then rep U-57 "Ftpusers 파일 설정" GOOD "proftpd RootLogin=${u57_rl:-미설정(기본 off)} → root 로그인 차단"
    else rep U-57 "Ftpusers 파일 설정" VULN "proftpd RootLogin=$u57_rl + ftpusers 차단 없음(UseFtpUsers=${u57_uu:-on}) → root FTP 접속 허용"; fi
  elif [ -n "$u57_fu" ]; then rep U-57 "Ftpusers 파일 설정" GOOD "$u57_fu 에 root 포함 (FTP 접속 차단)"
  elif [ "$ftp_d" = pure-ftpd ] || { [ -z "$ftp_d" ] && pkg_installed pure-ftpd; }; then
    rep U-57 "Ftpusers 파일 설정" MAN "pure-ftpd: ftpusers 에 root 없음 → MinUID 등 root 로그인 차단 여부 수동 확인"
  else rep U-57 "Ftpusers 파일 설정" VULN "ftpusers(/etc/ftpusers, /etc/ftpd/ftpusers)에 root 차단 설정 없음 → root FTP 접속 가능"; fi
fi

# SNMP 공통
snmp_run=0
{ svc_active snmpd || port_listen 161 || proc_run snmpd; } && snmp_run=1
snmp_conf=/etc/snmp/snmpd.conf

# U-58 불필요한 SNMP 서비스 구동 점검   [기준] 양호 - 미사용 / 취약 - 사용
if [ "$snmp_run" -eq 1 ]; then rep U-58 "불필요한 SNMP 서비스 구동 점검" VULN "SNMP(snmpd/161) 실행 중 → 미사용 시 중지"
else rep U-58 "불필요한 SNMP 서비스 구동 점검" GOOD "SNMP 미실행"; fi

# SNMP 설정 파싱(U-59~U-61 공통) — snmpd 설정 경로(/etc/snmp, /usr/share/snmp) + snmpd.conf.d/*.conf, 주석 줄 제외
#  v1/v2c = community 정의(com2sec[6] / rocommunity[6] / rwcommunity[6]. Redhat 기본 설정은 com2sec)
#  v3     = rouser/rwuser/createUser, 또는 영속 파일(/var/lib/net-snmp, /var/lib/snmp)의 usmUser
#  snmp_cs 한 줄 = "키워드 출발지 community" (community 는 공백을 포함할 수 있어 맨 끝에 둔다)
#    com2sec [-Cn 컨텍스트] 이름 출발지 community → community 바로 앞 필드가 출발지
#    (ro|rw)community community [출발지 ...]     → community 바로 뒤 필드가 출발지(생략=default)
#    따옴표로 묶은 community 는 공백이 있어도 한 토큰(net-snmp copy_nword) → 따옴표 토큰을 먼저 떼어 낸다
snmp_files="$snmp_conf /etc/snmp/snmpd.local.conf /etc/snmp/snmpd.conf.d/*.conf /usr/share/snmp/snmpd.conf"
snmp_cs=$(grep -hiE '^[[:space:]]*(com2sec6?|rocommunity6?|rwcommunity6?)[[:space:]]' $snmp_files 2>/dev/null |
  awk '{ k = tolower($1); c = ""; s = ""
         if (k ~ /^com2sec/) {
           if (match($0, /[ \t]("[^"]*"|\047[^\047]*\047)[ \t]*$/)) {
             c = substr($0, RSTART + 1); sub(/[ \t]+$/, "", c)
             n = split(substr($0, 1, RSTART), a); if (n < 3) next; s = a[n]
           } else { if (NF < 4) next; s = $(NF-1); c = $NF }
         } else {
           if ($2 ~ /^["\047]/ && match($0, /"[^"]*"|\047[^\047]*\047/)) {
             c = substr($0, RSTART, RLENGTH); split(substr($0, RSTART + RLENGTH), a); s = a[1]
           } else { c = $2; s = $3 }
           if (s == "" || s ~ /^-/) s = "default"
         }
         if (c ~ /^["\047]/ && 1 < length(c) && substr(c, length(c)) == substr(c, 1, 1)) c = substr(c, 2, length(c) - 2)
         if (s ~ /^["\047]/ && 1 < length(s) && substr(s, length(s)) == substr(s, 1, 1)) s = substr(s, 2, length(s) - 2)
         if (s ~ /["\047]/) s = "default"   # 닫히지 않은 따옴표 등 해석 불가 → 보수적으로 전체 허용으로 본다
         print k, s, c }')
snmp_v3=0
grep -qiE '^[[:space:]]*(rouser|rwuser|createUser|usmUser)[[:space:]]' $snmp_files /var/lib/net-snmp/snmpd.conf /var/lib/snmp/snmpd.conf 2>/dev/null && snmp_v3=1

# U-59 안전한 SNMP 버전 사용   [기준] 양호 - v3 이상 / 취약 - v2 이하
#  community 정의가 하나라도 있으면 v1/v2c 로도 접근 가능 → 취약 (rouser 를 추가해도 기본 com2sec 이 남아 있으면 취약)
if [ "$snmp_run" -eq 0 ]; then rep U-59 "안전한 SNMP 버전 사용" NA "SNMP 미실행"
elif [ -n "$snmp_cs" ]; then
  rep U-59 "안전한 SNMP 버전 사용" VULN "SNMP v1/v2c community 설정 존재($(printf '%s\n' "$snmp_cs" | awk '!s[$1]++ { printf "%s%s", (n++ ? "," : ""), $1 }')) → v3 전용으로 전환"
elif [ "$snmp_v3" -eq 1 ]; then
  rep U-59 "안전한 SNMP 버전 사용" GOOD "SNMPv3(createUser/rouser)만 사용, v1/v2c community 없음"
else
  rep U-59 "안전한 SNMP 버전 사용" MAN "SNMP 실행 중이나 snmpd.conf 에서 community/v3 사용자 설정을 찾지 못함 → snmpd -c 설정 경로 확인"
fi

# U-60 SNMP Community String 복잡성 설정
# [기준] 양호 - public/private 아님 + (영문·숫자 포함 10자리 이상 또는 영문·숫자·특수문자 포함 8자리 이상)
#        취약 - 기본값(public/private) 또는 길이·문자 조합 미달   ※ v3 전용이면 인증 비밀번호 복잡도로 판단
#  community 마다 값을 직접 판정한다. 근거에는 기본값 외의 community 값은 남기지 않고 키워드·길이만 적는다.
c_def=""; c_weak=""
while read -r ck _ cs; do
  [ -z "$ck" ] && continue
  case "${cs,,}" in public|private) c_def="$c_def $ck=$cs"; continue ;; esac
  if [[ $cs =~ [A-Za-z] ]] && [[ $cs =~ [0-9] ]] && { [ "${#cs}" -ge 10 ] || { [[ $cs =~ [^A-Za-z0-9] ]] && [ "${#cs}" -ge 8 ]; }; }; then :
  else c_weak="$c_weak $ck(${#cs}자)"; fi
done <<< "$snmp_cs"
if [ "$snmp_run" -eq 0 ]; then rep U-60 "SNMP Community String 복잡성 설정" NA "SNMP 미실행"
elif [ -n "$c_def" ]; then
  rep U-60 "SNMP Community String 복잡성 설정" VULN "community 기본값 사용:$c_def"
elif [ -n "$c_weak" ]; then
  rep U-60 "SNMP Community String 복잡성 설정" VULN "community 복잡성 미달(영문·숫자 10자 이상 또는 영문·숫자·특수문자 8자 이상 아님):$c_weak"
elif [ -n "$snmp_cs" ]; then
  rep U-60 "SNMP Community String 복잡성 설정" GOOD "community 기본값 아님 + 길이·문자 조합 기준 충족"
elif [ "$snmp_v3" -eq 1 ]; then
  rep U-60 "SNMP Community String 복잡성 설정" MAN "community 미사용(v3 전용) → v3 인증/암호화 비밀번호 복잡도 확인"
else
  rep U-60 "SNMP Community String 복잡성 설정" MAN "SNMP 실행 중이나 community/v3 사용자 설정을 찾지 못함 → 설정 경로 확인"
fi

# U-61 SNMP Access Control 설정   [기준] 양호 - 접근 제어 설정 / 취약 - 미설정
#  community 별 출발지가 default·마스크 /0(0.0.0.0/0, ::/0 등)이거나 생략이면 전체 허용 → 취약. 모든 줄이 IP/대역/호스트로 제한돼야 양호
a_open=$(printf '%s\n' "$snmp_cs" | awk '2 <= NF && tolower($2) ~ /^default$|\/0$|\/0\.0\.0\.0$/ { printf " %s(%s)", $1, $2 }')
if [ "$snmp_run" -eq 0 ]; then rep U-61 "SNMP Access Control 설정" NA "SNMP 미실행"
elif [ -n "$a_open" ]; then
  a_lo=""; port_listen 161 && ! port_listen_ext 161 && a_lo=" (참고: 161 은 localhost 에서만 리스닝)"
  rep U-61 "SNMP Access Control 설정" VULN "SNMP 접근 허용 대상(소스 IP) 제한 미설정:$a_open$a_lo"
elif [ -n "$snmp_cs" ]; then
  rep U-61 "SNMP Access Control 설정" GOOD "community 별 허용 출발지(IP/대역/호스트) 제한 설정 존재"
elif [ "$snmp_v3" -eq 1 ]; then
  rep U-61 "SNMP Access Control 설정" MAN "community 미사용(v3 전용) → agentAddress/방화벽 등 접근 허용 대상 제한 확인"
else
  rep U-61 "SNMP Access Control 설정" MAN "SNMP 실행 중이나 community 설정을 찾지 못함 → 접근 제어 설정 확인"
fi

# U-62 로그인 시 경고 메시지 설정
# [기준] 양호 - 서버 및 Telnet/FTP/SMTP/DNS 서비스 로그온 시 경고 메시지 설정 / 취약 - 미설정
#  서버 = /etc/issue·/etc/motd, SSH = Banner 파일 내용에 경고문이 있어야 함(파일만 있고 OS 정보뿐이면 미설정)
#  Telnet(/etc/issue.net)·FTP·SMTP·DNS 배너는 해당 서비스를 사용 중일 때만 점검(가이드 조치 방법)
#  ※ 사용 여부는 포트/서비스/정확한 프로세스명(pgrep -x)으로 따로 본다. mail_run 의 proc_run "master|sendmail" 은
#    pgrep -f 로 명령줄을 보므로 nginx 'master process' 도 잡는다(web-adm1 실측). ftp_run 의 "vsftpd|proftpd|..." 는
#    -f 패턴에서 | 우선순위로 가운데 대안(proftpd, in.ftpd)이 앵커 없이 걸린다(예: vi /etc/proftpd/proftpd.conf)
warn_re='(경고|허가|무단|승인|비인가|접근이 제한|unauthorized|authorized (users|personnel|access)|prohibited|monitored|warning|access is restricted)'
sshban=$(sshd_val banner)
b_local=0; b_ssh=0
grep -qiE "$warn_re" /etc/issue /etc/motd 2>/dev/null && b_local=1
{ [ -n "$sshban" ] && [ "$sshban" != none ] && grep -qiE "$warn_re" "$sshban" 2>/dev/null; } && b_ssh=1
sv_ok=""; sv_no=""; sv_man=""
ban_chk() { if printf '%s\n' "$2" | grep -qiE "$warn_re"; then sv_ok="$sv_ok $1"; else sv_no="$sv_no $1"; fi; }   # $1=서비스 $2=배너 문자열
[ "${telnet_on:-0}" -eq 1 ] && ban_chk Telnet "$(cat /etc/issue.net 2>/dev/null)"
if port_listen 21 || pgrep -x 'vsftpd|proftpd|in.ftpd|pure-ftpd' >/dev/null 2>&1; then   # vsftpd ftpd_banner/banner_file, proftpd DisplayLogin/ServerIdent
  fcf="/etc/vsftpd/vsftpd.conf /etc/vsftpd.conf /etc/proftpd.conf /etc/proftpd/proftpd.conf"
  fex=0; for f in $fcf; do [ -f "$f" ] && fex=1; done
  fb=$(grep -hiE '^[[:space:]]*(ftpd_banner[[:space:]]*=|ServerIdent[[:space:]]+on)' $fcf 2>/dev/null); frel=""
  for bf in $(grep -hiE '^[[:space:]]*(banner_file[[:space:]]*=|DisplayLogin[[:space:]])' $fcf 2>/dev/null | sed -E 's/^[[:space:]]*[A-Za-z_]+[[:space:]=]+//; s/"//g'); do
    case "$bf" in /*) fb="$fb $(head -c 4096 "$bf" 2>/dev/null)" ;; *) frel="$frel $bf" ;; esac
  done
  if [ "$fex" -eq 0 ]; then sv_man="$sv_man FTP(vsftpd/proftpd 설정 파일 없음)"
  elif [ -n "$frel" ] && ! printf '%s\n' "$fb" | grep -qiE "$warn_re"; then sv_man="$sv_man FTP(DisplayLogin 상대경로:$frel)"
  else ban_chk FTP "$fb"; fi
fi
if port_listen 25 || svc_active postfix || svc_active sendmail || svc_active exim || svc_active exim4; then   # postfix smtpd_banner, sendmail SmtpGreetingMessage, exim smtp_banner
  mk=$mail_kind; svc_active postfix && mk=postfix; { svc_active exim || svc_active exim4; } && mk=exim
  case "$mk" in
    postfix)  ban_chk SMTP "$(postconf -h smtpd_banner 2>/dev/null)" ;;
    sendmail) ban_chk SMTP "$(grep -hiE '^O[[:space:]]+SmtpGreetingMessage' /etc/mail/sendmail.cf 2>/dev/null)" ;;
    exim)     ban_chk SMTP "$(grep -hiE '^[[:space:]]*(smtp_banner|MAIN_SMTP_BANNER)[[:space:]]*=' /etc/exim/exim.conf /etc/exim4/exim4.conf /etc/exim4/exim4.conf.template /etc/exim4/exim4.conf.localmacros /etc/exim4/conf.d/main/* 2>/dev/null)" ;;
    *)        sv_man="$sv_man SMTP(25 리스닝, MTA 종류 확인 필요)" ;;
  esac
fi
{ pgrep -x named >/dev/null 2>&1 || svc_active named || svc_active named-chroot || svc_active bind9; } && ban_chk DNS "$(grep -hiE '^[[:space:]]*version[[:space:]]' /etc/named.conf /etc/bind/named.conf /etc/bind/named.conf.options /etc/named/*.conf 2>/dev/null)"
if [ "$b_local" -eq 1 ] && [ "$b_ssh" -eq 1 ] && [ -z "$sv_no" ] && [ -z "$sv_man" ]; then
  rep U-62 "로그인 시 경고 메시지 설정" GOOD "서버 경고문(issue/motd) + SSH Banner 설정${sv_ok:+ + 서비스 배너:$sv_ok}"
elif [ "$b_local" -eq 1 ] && [ "$b_ssh" -eq 1 ] && [ -z "$sv_no" ]; then
  rep U-62 "로그인 시 경고 메시지 설정" MAN "서버 경고문(issue/motd) + SSH Banner 설정, 서비스 배너 확인 필요:$sv_man"
elif [ "$b_local" -eq 1 ] || [ "$b_ssh" -eq 1 ] || [ -n "$sv_ok" ]; then
  rep U-62 "로그인 시 경고 메시지 설정" VULN "일부만 설정(서버 경고문=$b_local, SSH Banner=$b_ssh${sv_no:+, 경고문 없는 서비스:$sv_no}) → 서버 및 원격 서비스 전체에 경고 메시지 필요"
else
  rep U-62 "로그인 시 경고 메시지 설정" VULN "로그온 경고 메시지 미설정 (기본 issue 는 OS 정보만 노출)${sv_no:+, 경고문 없는 서비스:$sv_no}"
fi

# U-63 sudo 명령어 접근 관리   [기준] 양호 - /etc/sudoers 소유자 root + 권한 640 이하
if [ ! -e /etc/sudoers ]; then rep U-63 "sudo 명령어 접근 관리" NA "/etc/sudoers 없음"
else
  so=$(stat -Lc '%U' /etc/sudoers); sp=$(stat -Lc '%a' /etc/sudoers)   # 권한은 비트 기준 640(440·600 양호, 444·604·460 취약)
  d_bad=$( shopt -s nullglob
    for f in /etc/sudoers.d/*; do
      [ -f "$f" ] || continue
      p=$(stat -Lc '%a' "$f"); o=$(stat -Lc '%U' "$f")
      { [ "$o" != root ] || ! perm_le "$p" 640; } && echo "$f($o,$p)"
    done | tr '\n' ' ')
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
#   ※ OS 표준 지원 종료(EOL)라도 확장 지원이 활성이면 보안 패치를 받으므로 EOL 로 보지 않는다.
#     Ubuntu ESM : /var/lib/ubuntu-advantage/status.json(오프라인 파일, 1순위)의 attached=true + esm-infra status=enabled
#                  (+ 계약 만료일 미경과). 파일이 없을 때만 'pro status'(timeout 20초)의 esm-infra enabled 로 확인.
#     Debian ELTS: 주석 제외 활성 소스(deb 줄·deb822 URIs)에 extended-lts(Freexian). Amazon Linux 2 는 연장 수단 없음.
sec_pend=$(sec_update_count '' '')   # 전체 보안 업데이트 건수 (dnf/yum/apt 자동 분기)
today=$(date +%Y%m%d)
ext_on=0; ext_note=""
if [ "${ID:-}" = ubuntu ]; then
  st=/var/lib/ubuntu-advantage/status.json
  if [ -f "$st" ]; then
    st_py=""
    have python3 && st_py=$(run_to 10 python3 -c 'import json,re,sys
d=json.loads(open(sys.argv[1],"rb").read().decode("utf-8","replace"))
s=[x.get("status","") for x in d.get("services",[]) if x.get("name")=="esm-infra"]
w=lambda v: re.sub(r"[^A-Za-z0-9_.:-]","",str(v)) or "none"
print(w(str(d.get("attached")).lower()), w(s[0] if s else "none"), w((d.get("expires") or "none")[:10]))' "$st" 2>/dev/null)
    att=$(printf '%s' "$st_py" | awk '{print $1}'); esm=$(printf '%s' "$st_py" | awk '{print $2}'); exp=$(printf '%s' "$st_py" | awk '{print $3}')
    [ -z "$att" ] && att=$(grep -oE '"attached": *(true|false)' "$st" 2>/dev/null | head -1 | grep -oE 'true|false')
    [ -z "$esm" ] && esm=$(grep -oE '"name": *"esm-infra"[^}]*' "$st" 2>/dev/null | grep -oE '"status": *"[a-z/-]+"' | head -1 | sed -E 's/.*"([a-z/-]+)"$/\1/')
    [ -z "$exp" ] && exp=$(grep -oE '"expires": *"[0-9]{4}-[0-9]{2}-[0-9]{2}' "$st" 2>/dev/null | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    ext_note="Ubuntu Pro status.json: attached=${att:-?}, esm-infra=${esm:-?}, 만료=${exp:-?}"
    if [ "$att" = true ] && [ "$esm" = enabled ]; then
      case "$exp" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) [ "${exp//-/}" -ge "$today" ] && ext_on=1 ;; *) ext_on=1 ;; esac
    fi
  elif have pro; then
    run_to 20 pro status 2>/dev/null | grep -qE '^esm-infra[[:space:]]+yes[[:space:]]+enabled' && ext_on=1
    ext_note="pro status: esm-infra $([ "$ext_on" -eq 1 ] && echo enabled || echo 미활성/확인불가)"
  fi
elif [ "${ID:-}" = debian ]; then
  if { grep -hsE '^[[:space:]]*deb(-src)?[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list
       grep -hsiE '^[[:space:]]*URIs:' /etc/apt/sources.list.d/*.sources; } | grep -q 'extended-lts'; then
    ext_on=1; ext_note="Debian ELTS(extended-lts) 활성 소스"
  fi
fi
eol_note=""
case "${ID}:${VERSION_ID}" in
  debian:11) [ "$today" -ge 20260831 ] && eol_note=" (Debian 11 표준 지원 종료)";;
  ubuntu:20.04) [ "$today" -ge 20250531 ] && eol_note=" (Ubuntu 20.04 표준 지원 종료, ESM 필요)";;
  amzn:2) [ "$today" -ge 20260630 ] && eol_note=" (Amazon Linux 2 지원 종료 임박/종료)";;
esac
[ -n "$eol_note" ] && [ "$ext_on" -eq 1 ] && { ext_note="OS 표준 지원 종료이나 확장 지원 활성 — $ext_note"; eol_note=""; }
if [ "$sec_pend" != "?" ] && [ "${sec_pend:-0}" -gt 0 ]; then
  rep U-64 "주기적인 보안 패치 및 벤더 권고사항 적용" VULN "미적용 보안 업데이트 약 ${sec_pend}건$eol_note" ${ext_note:+"확장지원: $ext_note"}
elif [ -n "$eol_note" ]; then
  rep U-64 "주기적인 보안 패치 및 벤더 권고사항 적용" VULN "OS 지원 종료$eol_note + 확장 지원(ESM/ELTS) 없음 → 보안 패치 수급 불가" ${ext_note:+"확장지원: $ext_note"}
else
  rep U-64 "주기적인 보안 패치 및 벤더 권고사항 적용" MAN "미적용 보안 업데이트 없음(sec_pend=$sec_pend). 패치 적용 정책/주기/이력은 인터뷰 확인" ${ext_note:+"확장지원: $ext_note"}
fi

#==============================================================================
echo -e "${W}[ 5. 로그 관리 ]${N}"
#==============================================================================

# U-65 NTP 및 시각 동기화 설정   [기준] 양호 - NTP/시각 동기화가 기준에 따라 적용 / 취약 - 아님
#   동기화 판단(원문 점검: chronyc sources / ntpq -pn 으로 '동기화된 서버' 확인) — 아래 중 하나면 동기화됨:
#     timedatectl NTPSynchronized=yes,
#     chronyc -n tracking 의 Leap status 가 Normal(Insert/Delete second 포함) + chronyc -n sources 에 선택된 소스
#       ('^*' 서버, '#*' 참조클럭, '=*' peer),
#     ntpstat 성공 또는 ntpq -pn 의 선택 피어('*').
#   ※ chronyc 종료코드는 쓰지 않는다(데몬과 통신만 되면 'Leap status: Not synchronised' 여도 0 을 돌려줌).
ntp_svc=""
for s in chronyd ntpd ntp systemd-timesyncd; do svc_active "$s" && ntp_svc="$s"; done
synced=$(timedatectl show 2>/dev/null | grep -E '^NTPSynchronized=yes')
chr_leap=""; chr_sel=""; chr_ok=0
if have chronyc && { svc_active chronyd || svc_active chrony; }; then
  chr_leap=$(run_to 10 chronyc -n tracking 2>/dev/null | sed -n 's/^Leap status[[:space:]]*:[[:space:]]*//p')
  chr_sel=$(run_to 10 chronyc -n sources 2>/dev/null | grep -E '^[#^=]\*' | head -1 | awk '{print $2}')
  case "$chr_leap" in Normal|"Insert second"|"Delete second") [ -n "$chr_sel" ] && chr_ok=1 ;; esac
fi
ntp_sel=""; ntp_ok=0
if svc_active ntpd || svc_active ntp; then
  have ntpq && ntp_sel=$(run_to 10 ntpq -pn 2>/dev/null | grep -E '^\*' | head -1 | awk '{print substr($1, 2)}')
  { [ -n "$ntp_sel" ] || { have ntpstat && run_to 10 ntpstat >/dev/null 2>&1; }; } && ntp_ok=1
fi
u65_ev="NTPSynchronized=$([ -n "$synced" ] && echo yes || echo no/확인불가)${chr_leap:+, chrony Leap status=$chr_leap}${chr_sel:+, chrony 선택 소스=$chr_sel}${ntp_sel:+, ntpd 선택 피어=$ntp_sel}"
if [ -n "$ntp_svc" ] && { [ -n "$synced" ] || [ "$chr_ok" -eq 1 ] || [ "$ntp_ok" -eq 1 ]; }; then
  rep U-65 "NTP 및 시각 동기화 설정" GOOD "$ntp_svc 활성 + 시각 동기화됨 ($u65_ev)"
elif [ -n "$ntp_svc" ]; then
  rep U-65 "NTP 및 시각 동기화 설정" VULN "$ntp_svc 활성이나 시각 동기화 안 됨($u65_ev, 선택된 소스 없음) → NTP 서버 접근(UDP 123)/설정 확인"
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
# [기준] 양호 - 디렉터리 내 로그 파일 소유자 root + 권한 644 이하 / 취약 - 소유자 root 아님 또는 권한 644 초과
#   고정 목록이 아니라 /var/log 아래 일반 파일 전체(깊이 4, 심볼릭 링크 제외)를 bash 로 순회한다(find 미사용).
#   가이드에 syslog/adm·데몬 계정 소유 예외가 없으므로 소유자는 root 만 인정한다.
#   권한은 숫자 크기가 아니라 비트로 본다: 644 밖 비트(특수권한·소유자 x·그룹/기타 w,x = 7133)가 있으면 초과
#   (숫자 비교는 460·606 처럼 그룹/기타 쓰기가 있어도 644 보다 작아 통과시킨다).
log_bad=""
dp=$(stat -c '%a' /var/log 2>/dev/null); do_=$(stat -c '%U' /var/log 2>/dev/null)
{ [ "$do_" = root ] && ! perm_has "${dp:-777}" 7022; } || log_bad=" /var/log($do_,$dp)"
log_st=$( shopt -s nullglob dotglob
  _lw() {   # $1=디렉터리 $2=깊이 → "권한 소유자 경로" 출력(stat 은 디렉터리별로 묶어 호출, 하위 디렉터리는 그 뒤에)
    local f fl=() dl=()
    for f in "$1"/*; do
      if [ -L "$f" ]; then continue
      elif [ -d "$f" ]; then dl+=("$f")
      elif [ -f "$f" ]; then fl+=("$f"); [ ${#fl[@]} -ge 500 ] && { stat -c '%a %U %n' -- "${fl[@]}"; fl=(); }
      fi
    done
    [ ${#fl[@]} -eq 0 ] || stat -c '%a %U %n' -- "${fl[@]}"
    [ "$2" -lt 4 ] || return 0
    for f in "${dl[@]}"; do _lw "$f" $(( $2 + 1 )); done
  }
  _lw /var/log 1 2>/dev/null )
n_log=0; n_own=0; n_perm=0; l_own=""; l_perm=""; o_list=""
while read -r p o f; do
  [ -n "$f" ] || continue
  n_log=$((n_log+1))
  if [ "$o" != root ]; then
    n_own=$((n_own+1)); [ "$n_own" -le 10 ] && l_own="$l_own ${f}($o,$p)"
    case " $o_list " in *" $o "*) ;; *) o_list="${o_list:+$o_list }$o";; esac
  elif perm_has "$p" 7133; then
    n_perm=$((n_perm+1)); [ "$n_perm" -le 10 ] && l_perm="$l_perm ${f}($p)"
  fi
done < <(printf '%s\n' "$log_st")
[ "$n_own" -gt 10 ] && l_own="$l_own 외 $((n_own-10))개"
[ "$n_perm" -gt 10 ] && l_perm="$l_perm 외 $((n_perm-10))개"
u67_ev=()
[ -n "$log_bad" ] && u67_ev+=("/var/log 디렉터리 기준(root, 755 이하) 초과:$log_bad")
[ "$n_own" -gt 0 ] && u67_ev+=("소유자 root 아님 ${n_own}개:$l_own → 서비스 계정($o_list)이 직접 기록하는 로그는 서비스 설정과 함께 root 로 변경(예외 운영 시 근거 문서화)")
[ "$n_perm" -gt 0 ] && u67_ev+=("권한 644 초과 ${n_perm}개:$l_perm")
if [ "${#u67_ev[@]}" -gt 0 ]; then
  rep U-67 "로그 디렉토리 소유자 및 권한 설정" VULN "기준(root, 644 이하) 위반 — /var/log 하위 일반 파일 ${n_log}개 점검(깊이 4, 링크 제외)" "${u67_ev[@]}"
elif [ "$IS_ROOT" -ne 1 ]; then
  rep U-67 "로그 디렉토리 소유자 및 권한 설정" MAN "/var/log 하위 일반 파일 ${n_log}개는 기준 충족. 단 root 가 아니어서 접근 제한 하위 디렉터리(audit 등)는 미점검 → root 로 재점검"
else
  rep U-67 "로그 디렉토리 소유자 및 권한 설정" GOOD "/var/log 및 하위 로그 파일 ${n_log}개(깊이 4, 링크 제외) 소유자 root + 권한 644 이하"
fi

#==============================================================================
echo
echo -e "${W}==============================================================${N}"
echo -e "${W} 요약${N}   ${G}양호=$good${N}   ${R}취약=$vuln${N}   ${Y}N/A=$na${N}   ${B}수동확인=$man${N}   (총 $((good+vuln+na+man)))"
echo -e "${W}==============================================================${N}"
echo -e " ${B}수동확인${N} 항목은 정책 수립 여부 등 인터뷰가 필요한 잔여 항목입니다."
echo -e " 이 스크립트는 읽기 전용입니다. 조치는 각 항목 [기준] 에 맞춰 별도 수행하세요."
echo

# ---- JSON 파일 출력 (--json <파일> 지정 시) ----
if [ -n "$JSON_FILE" ]; then
  {
    printf '{"host":"%s","os":"%s","family":"%s","results":[' \
      "$(json_escape "$(hostname)")" "$(json_escape "${PRETTY_NAME:-unknown}")" "$FAM"
    printf '%s' "${JBUF%,}"
    printf ']}'
  } > "$JSON_FILE"
  echo " JSON 저장: $JSON_FILE"
fi

# ---- CSV 파일 출력 (기본 자동 저장. --csv <파일> 지정, --no-save 로 생략) ----
if [ -z "$CSV_FILE" ] && [ "$NO_SAVE" -ne 1 ]; then
  _h=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-'); [ -z "$_h" ] && _h=linux
  CSV_FILE="server_linux_${_h}_$(date +%Y%m%d_%H%M).csv"
fi
if [ -n "$CSV_FILE" ]; then
  _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "$_ip" ] && _ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  {
    printf '\357\273\277'                              # UTF-8 BOM (엑셀 한글)
    printf '# host,%s\n' "$(hostname)"                 # 진단대상 Hostname/IP/버전정보 (make_report 가 읽음)
    printf '# ip,%s\n'   "${_ip:--}"
    printf '# os,%s\n'   "${PRETTY_NAME:-unknown}"
    printf '항목코드,중요도,진단항목,진단결과,상세\n'
    printf '%s' "$CBUF"
  } > "$CSV_FILE"
  echo " CSV 저장: $CSV_FILE   (엑셀에서 바로 열림)"
fi
__KISA_EMBED_UNIX_EOF__
}

kisa_payload_web_linux() {
  cat <<'__KISA_EMBED_WEB_LINUX_EOF__'
#!/usr/bin/env bash
#==============================================================================
# 웹서버(리눅스) 기술적 취약점 점검  WEB-01 ~ WEB-26   [Nginx / Apache Tomcat]
#  - KISA 주통기 / SK Shieldus 웹 보안가이드 기준(공식 결과보고서 WEB-01~26 항목·판단기준 반영)
#  - Nginx(웹서버)와 Spring Boot 내장 Tomcat(WAS)을 자동 감지하여 점검
#  - 읽기 전용(READ-ONLY): 설정/프로세스/파일 권한 조회만, 변경 없음
#  - 대상 서버에서 직접 실행(EC2 인스턴스 연결로 들어가 파일만 올리면 됨, SSH 불필요):
#       sudo bash web_linux_check.sh                          # 자동 감지
#       sudo bash web_linux_check.sh --target tomcat --app-jar /opt/app.jar --app-url http://localhost:8080
#  - 끝나면 콘솔 요약 + CSV + HTML 리포트를 현재 폴더에 자동 저장(추가 설치 불필요).
#
# 판정: 양호 / 취약 / N/A(점검대상 제외→보고서 양호) / 수동확인(인터뷰·런타임 확인 필요)
#   * 일부 항목(디렉터리 리스팅/HTTPS 리디렉션/에러페이지/헤더)은 서비스 기동 상태에서만
#     확정 가능 → --app-url(또는 --nginx-url) 지정 시 HTTP 로 실측, 없으면 수동확인 표기.
#==============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
  echo "이 스크립트는 bash 로 실행해야 합니다:  sudo bash $0" >&2; exit 1
fi

# ---- 인자 ----
JSON_FILE=""; CSV_FILE=""; HTML_FILE=""; NO_SAVE=0; NOCOLOR=0
TARGET=""; CONF_SRC=""; NGX_BIN=""; APP_JAR=""; APP_URL=""; APP_YML=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   TARGET="${2:-}"; shift 2 ;;          # nginx | tomcat
    --conf)     CONF_SRC="${2:-}"; shift 2 ;;         # nginx 설정파일(오프라인 테스트)
    --nginx)    NGX_BIN="${2:-}"; shift 2 ;;
    --app-jar)  APP_JAR="${2:-}"; shift 2 ;;          # Spring Boot jar 경로
    --app-yml)  APP_YML="${2:-}"; shift 2 ;;          # application.yml 직접 지정(오프라인)
    --app-url|--nginx-url) APP_URL="${2:-}"; shift 2 ;; # 기동중 서비스 URL(HTTP 실측)
    --json)     JSON_FILE="${2:-}"; shift 2 ;;
    --csv)      CSV_FILE="${2:-}"; shift 2 ;;
    --html)     HTML_FILE="${2:-}"; shift 2 ;;
    --no-save)  NO_SAVE=1; shift ;;
    --no-color) NOCOLOR=1; shift ;;
    -h|--help)
      cat <<'USAGE'
사용법:
  sudo bash web_linux_check.sh                                  # nginx/tomcat 자동감지
  sudo bash web_linux_check.sh --target nginx --app-url http://localhost
  sudo bash web_linux_check.sh --target tomcat --app-jar /opt/app.jar --app-url http://localhost:8080
옵션: --csv f  --html f  --json f  --no-save  --no-color  --conf nginx.conf  --app-yml application.yml
USAGE
      exit 0 ;;
    *) shift ;;
  esac
done

if [ -t 1 ] && [ "$NOCOLOR" -eq 0 ]; then
  G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; B='\033[1;34m'; C='\033[1;36m'; W='\033[1m'; N='\033[0m'
else G=''; R=''; Y=''; B=''; C=''; W=''; N=''; fi

good=0; vuln=0; na=0; man=0
HOSTN=$(hostname 2>/dev/null || echo web)

# 중요도(공식 결과보고서 기준)
declare -A IMP=(
  [WEB-01]=상 [WEB-02]=상 [WEB-03]=상 [WEB-04]=상 [WEB-05]=상 [WEB-06]=상 [WEB-07]=중 [WEB-08]=하 [WEB-09]=상
  [WEB-10]=상 [WEB-11]=중 [WEB-12]=중 [WEB-13]=상 [WEB-14]=상 [WEB-15]=상 [WEB-16]=중 [WEB-17]=중 [WEB-18]=상
  [WEB-19]=중 [WEB-20]=상 [WEB-21]=중 [WEB-22]=하 [WEB-23]=중 [WEB-24]=중 [WEB-25]=상 [WEB-26]=중
)
declare -A TITLE=(
  [WEB-01]="Default 관리자 계정명 변경" [WEB-02]="취약한 비밀번호 사용 제한" [WEB-03]="비밀번호 파일 권한 관리"
  [WEB-04]="웹 서비스 디렉터리 리스팅 방지 설정" [WEB-05]="지정하지 않은 CGI/ISAPI 실행 제한"
  [WEB-06]="웹 서비스 상위 디렉터리 접근 제한 설정" [WEB-07]="웹 서비스 경로 내 불필요한 파일 제거"
  [WEB-08]="웹 서비스 파일 업로드 및 다운로드 용량 제한" [WEB-09]="웹 서비스 프로세스 권한 제한"
  [WEB-10]="불필요한 프록시 설정 제한" [WEB-11]="웹 서비스 경로 설정" [WEB-12]="웹 서비스 링크 사용 금지"
  [WEB-13]="웹 서비스 설정 파일 노출 제한" [WEB-14]="웹 서비스 경로 내 파일의 접근 통제"
  [WEB-15]="웹 서비스의 불필요한 스크립트 매핑 제거" [WEB-16]="웹 서비스 헤더 정보 노출 제한"
  [WEB-17]="웹 서비스 가상 디렉토리 삭제" [WEB-18]="웹 서비스 WebDAV 비활성화"
  [WEB-19]="웹 서비스 SSI(Server Side Includes) 사용 제한" [WEB-20]="SSL/TLS 활성화" [WEB-21]="HTTP 리디렉션"
  [WEB-22]="에러 페이지 관리" [WEB-23]="LDAP 알고리즘 적절하게 구성" [WEB-24]="별도의 업로드 경로 사용 및 권한 설정"
  [WEB-25]="주기적 보안 패치 및 벤더 권고사항 적용" [WEB-26]="로그 디렉터리 및 파일 권한 설정"
)

JBUF=""; CBUF=""; HBUF=""
json_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\r'/ }; s=${s//$'\n'/ }; printf '%s' "$s"; }
csv_escape()  { local s=$1; s=${s//$'\r'/ }; s=${s//$'\n'/ }; case "$s" in *[,\"]*) s=${s//\"/\"\"}; s="\"$s\"";; esac; printf '%s' "$s"; }
html_escape() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; printf '%s' "$s"; }

# 사용: rep CODE STATUS "근거1" ...   (제목은 TITLE[CODE])
rep() {
  local code="$1" status="$2"; shift 2
  local title="${TITLE[$code]}" tag kstat cls
  case "$status" in
    GOOD) good=$((good+1)); tag="${G}양호${N}";   kstat="양호"; cls="good";;
    VULN) vuln=$((vuln+1)); tag="${R}취약${N}";   kstat="취약"; cls="vuln";;
    NA)   na=$((na+1));     tag="${Y}N/A${N}";    kstat="N/A";  cls="na";;
    MAN)  man=$((man+1));   tag="${B}수동확인${N}"; kstat="수동확인"; cls="man";;
  esac
  printf "${C}%-7s${N} %-42s [%b]\n" "$code" "$title" "$tag"
  local l; for l in "$@"; do printf "         ${W}·${N} %s\n" "$l"; done
  local ev="" first=1 e
  for l in "$@"; do e=$(json_escape "$l"); if [ "$first" = 1 ]; then ev="\"$e\""; first=0; else ev="$ev,\"$e\""; fi; done
  JBUF="${JBUF}{\"code\":\"$code\",\"importance\":\"${IMP[$code]}\",\"title\":\"$(json_escape "$title")\",\"status\":\"$kstat\",\"evidence\":[$ev]},"
  local evtext="" rstat="$kstat"; [ "$kstat" = "수동확인" ] && rstat="인터뷰 필요"; [ "$kstat" = "N/A" ] && rstat="양호"
  for l in "$@"; do evtext="${evtext:+$evtext | }$l"; done
  CBUF="${CBUF}$(csv_escape "$code"),$(csv_escape "${IMP[$code]}"),$(csv_escape "$title"),$(csv_escape "$rstat"),$(csv_escape "$evtext")
"
  HBUF="${HBUF}<tr class=\"$cls\"><td>$(html_escape "$code")</td><td>$(html_escape "${IMP[$code]}")</td><td>$(html_escape "$title")</td><td class=\"st\">$(html_escape "$rstat")</td><td>$(html_escape "$evtext")</td></tr>
"
}

have() { command -v "$1" >/dev/null 2>&1; }
conf_grep() { printf '%s\n' "$NGX_CONF" | grep -vE '^[[:space:]]*#' | grep -iE "$1"; }
# HTTP 응답(헤더+본문 일부) 취득
http_head() { have curl && curl -sk -m 5 -I "$1" 2>/dev/null; }
http_get()  { have curl && curl -sk -m 5 "$1" 2>/dev/null; }
other_readable() { local p; p=$(stat -c '%a' "$1" 2>/dev/null) || return 1; [ "$(( 8#$p & 8#004 ))" -ne 0 ]; }
other_writable() { local p; p=$(stat -c '%a' "$1" 2>/dev/null) || return 1; [ "$(( 8#$p & 8#002 ))" -ne 0 ]; }
tmo() { if have timeout; then timeout "$@"; else shift; "$@"; fi; }
# jar 내부 파일 읽기(표준출력만, 읽기 전용): unzip → python(zipfile, 바이트 그대로 출력해 LANG=C 에서도 안전)
#   ※ python 코드는 ASCII 만 사용(py3.6 은 C 로케일에서 -c 인자의 비 ASCII 로 실패)
read_jar() {
  local out="" p
  have unzip && out=$(unzip -p "$1" "$2" 2>/dev/null)
  if [ -z "$out" ]; then
    for p in python3 /usr/libexec/platform-python python; do
      have "$p" || continue
      out=$(tmo 30 "$p" -c 'import sys, zipfile
o = getattr(sys.stdout, "buffer", sys.stdout)
try:
    o.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))
except Exception:
    sys.exit(1)' "$1" "$2" 2>/dev/null)
      break
    done
  fi
  printf '%s' "$out"
}
# jar 내부 파일 목록(읽기 전용): unzip -l → python(zipfile)
jar_ls() {
  local out="" p
  have unzip && out=$(unzip -l "$1" 2>/dev/null)
  if [ -z "$out" ]; then
    for p in python3 /usr/libexec/platform-python python; do
      have "$p" || continue
      out=$(tmo 30 "$p" -c 'import sys, zipfile
try:
    print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))
except Exception:
    sys.exit(1)' "$1" 2>/dev/null)
      break
    done
  fi
  printf '%s\n' "$out"
}
# 관리자 권한 계정 여부(WEB-09): priv_chk 계정 → PRIV_ST(VULN/MAN/빈값=권한 없음) PRIV_EV(근거)
#   UID 0 또는 sudo -l -U 에 (ALL|root) ... ALL 전권 → VULN, sudo 일부 명령 허용·확인 불가 → MAN (그룹명만으로 판정하지 않음)
priv_chk() {
  local u=$1 uid out full part
  PRIV_ST=""; PRIV_EV=""
  uid=$(id -u "$u" 2>/dev/null)
  if [ "$uid" = 0 ]; then PRIV_ST=VULN; PRIV_EV="UID 0(관리자) 계정"; return; fi
  have sudo || { PRIV_EV="sudo 미설치"; return; }
  out=$(LC_ALL=C tmo 10 sudo -n -l -U "$u" 2>&1)
  full=$(printf '%s\n' "$out" | grep -E '^[[:space:]]+\((ALL|root)([[:space:]]*:[[:space:]]*[^)]*)?\)[[:space:]]*([A-Z_]+:[[:space:]]*)*ALL\b' | head -2 | sed -E 's/^[[:space:]]+//' | tr '\n' ' ')
  part=$(printf '%s\n' "$out" | grep -E '^[[:space:]]+\(' | head -3 | sed -E 's/^[[:space:]]+//' | tr '\n' ' ')
  if [ -n "$full" ]; then PRIV_ST=VULN; PRIV_EV="sudo 전권 부여: ${full% }(관리자 권한 계정)"
  elif [ -n "$part" ]; then PRIV_ST=MAN; PRIV_EV="sudo 일부 명령 허용: ${part% } → root 획득 가능한 명령(셸·편집기 등)인지 확인"
  elif printf '%s' "$out" | grep -q 'not allowed to run sudo'; then PRIV_EV="sudo 권한 없음"
  else PRIV_ST=MAN; PRIV_EV="sudo 권한(sudo -l -U) 확인 불가 → 관리자 권한 부여 여부 확인"; fi
}

echo -e "${W}=========================================================${N}"
echo -e "${W} 웹서버(리눅스) 취약점 점검  —  $HOSTN${N}"
echo -e "${W}=========================================================${N}"

# ---- 대상 자동 감지 ----
NGX_BIN2="$NGX_BIN"
[ -z "$NGX_BIN2" ] && { for b in nginx /usr/sbin/nginx /usr/local/nginx/sbin/nginx; do have "$b" && { NGX_BIN2="$b"; break; }; done; }
# Spring Boot / Tomcat 프로세스 탐지
JPROC=$(ps -eo pid,user,args 2>/dev/null | grep -iE 'java .*(\.jar|catalina|tomcat)' | grep -v grep | head -1)
[ -z "$APP_JAR" ] && APP_JAR=$(printf '%s' "$JPROC" | grep -oE '/[^ ]+\.jar' | head -1)

if [ -z "$TARGET" ]; then
  if [ -n "$NGX_BIN2" ] && { [ -z "$JPROC" ] || [ -n "$CONF_SRC" ]; }; then TARGET=nginx
  elif [ -n "$JPROC" ] || [ -n "$APP_JAR" ] || [ -n "$APP_YML" ]; then TARGET=tomcat
  elif [ -n "$NGX_BIN2" ]; then TARGET=nginx
  else TARGET=nginx; fi
fi

if [ "$TARGET" = nginx ]; then
  NGX_VER=""; [ -n "$NGX_BIN2" ] && NGX_VER=$("$NGX_BIN2" -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
  if [ -n "$CONF_SRC" ] && [ -f "$CONF_SRC" ]; then NGX_CONF=$(cat "$CONF_SRC"); CONF_MAIN="$CONF_SRC"
  elif [ -n "$NGX_BIN2" ] && "$NGX_BIN2" -T >/dev/null 2>&1; then
    NGX_CONF=$("$NGX_BIN2" -T 2>/dev/null); CONF_MAIN=$("$NGX_BIN2" -t 2>&1 | sed -n 's#.*configuration file \(.*\) test.*#\1#p' | head -1)
  else CONF_MAIN=/etc/nginx/nginx.conf
    for f in /etc/nginx/nginx.conf /usr/local/nginx/conf/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
      [ -f "$f" ] && NGX_CONF="${NGX_CONF}"$'\n'"$(cat "$f" 2>/dev/null)"; done
  fi
  [ -z "$CONF_MAIN" ] && CONF_MAIN=/etc/nginx/nginx.conf
  SW_VER="Nginx ${NGX_VER:-?}"
  echo -e "  대상: ${W}Nginx${N} ${NGX_VER:-?}   설정: $CONF_MAIN"
else
  # Tomcat(Spring Boot) — application.yml 확보
  APP_OWNER=$(printf '%s' "$JPROC" | awk '{print $2}')
  if [ -z "$APP_YML" ] && [ -n "$APP_JAR" ] && [ -f "$APP_JAR" ] && have unzip; then
    APP_YML_CONTENT=$(unzip -p "$APP_JAR" 'BOOT-INF/classes/application.yml' 2>/dev/null)
    [ -z "$APP_YML_CONTENT" ] && APP_YML_CONTENT=$(unzip -p "$APP_JAR" 'BOOT-INF/classes/application.properties' 2>/dev/null)
  elif [ -n "$APP_YML" ] && [ -f "$APP_YML" ]; then APP_YML_CONTENT=$(cat "$APP_YML")
  fi
  TOMCAT_VER=""
  # 내장 Tomcat 버전은 BOOT-INF/lib/tomcat-embed-core-<ver>.jar 파일명에서 추출
  [ -n "$APP_JAR" ] && [ -f "$APP_JAR" ] && TOMCAT_VER=$(jar_ls "$APP_JAR" | grep -oE 'tomcat-embed-core-[0-9.]+\.jar' | head -1 | sed -E 's/tomcat-embed-core-([0-9.]+)\.jar/\1/')
  SW_VER="Tomcat ${TOMCAT_VER:-내장(Spring Boot)}"
  # 로그 디렉터리 후보(application.yml logging.file.* + 관용 경로)
  yml_logpath=$(printf '%s\n' "$APP_YML_CONTENT" | grep -iE 'logging\.file\.(path|name)|^\s*(path|name):' | grep -iE 'log' | head -1 | sed -E 's/.*[:=] *//' | tr -d '"'"'"' \r')
  yml_logdir=""; [ -n "$yml_logpath" ] && { case "$yml_logpath" in */*) yml_logdir=$(dirname "$yml_logpath");; *) yml_logdir="$yml_logpath";; esac; }
  APP_LOGDIRS="$yml_logdir /var/log/clinic /opt/clinic/logs /var/log/tomcat*"
  echo -e "  대상: ${W}Apache Tomcat(Spring Boot 내장)${N} ${TOMCAT_VER:-?}   jar: ${APP_JAR:-미상}  프로세스 소유자: ${APP_OWNER:-?}"
fi
yml_get() { printf '%s\n' "$APP_YML_CONTENT" | grep -iE "$1" | head -1 | tr -s ' ' ' '; }
echo

#==============================================================================
echo -e "${W}[ 1. 계정 관리 ]${N}"
if [ "$TARGET" = nginx ]; then
  rep WEB-01 NA "Nginx 는 관리자 콘솔이 없어 가이드상 점검대상 제외"
  rep WEB-02 NA "Nginx 점검대상 제외(관리자 계정/비밀번호 없음)"
  rep WEB-03 NA "Nginx 점검대상 제외(비밀번호 파일 없음)"
else
  # Tomcat: tomcat-users.xml 존재 여부(내장 방식이면 미존재)
  tu=""; for f in /opt/tomcat/conf/tomcat-users.xml /usr/share/tomcat*/conf/tomcat-users.xml /etc/tomcat*/tomcat-users.xml; do [ -f "$f" ] && tu="$f" && break; done
  if [ -z "$tu" ]; then
    rep WEB-01 GOOD "tomcat-users.xml/server.xml 미존재(Spring Boot 내장 Tomcat) → 관리자 콘솔 미사용, 기본 관리자 계정 없음"
    rep WEB-02 NA "관리자 콘솔 계정이 존재하지 않아 취약한 관리자 비밀번호 설정 대상 아님"
    rep WEB-03 NA "관리자 콘솔 미사용으로 tomcat-users.xml 등 비밀번호 파일이 존재하지 않음"
  else
    if grep -qiE 'username="(admin|tomcat|manager|root)"' "$tu"; then
      rep WEB-01 VULN "$tu 에 기본/추측용이 계정명 사용 → 계정명 변경 필요"
    else rep WEB-01 GOOD "$tu 에 기본 계정명(admin/tomcat 등) 미사용"; fi
    if grep -qiE 'password="(admin|tomcat|manager|1234|password|)"' "$tu"; then
      rep WEB-02 VULN "$tu 에 취약/공백 비밀번호 존재 → 강력한 비밀번호 설정 필요"
    else rep WEB-02 GOOD "$tu 관리자 비밀번호가 취약/공백이 아님"; fi
    tup=$(stat -c '%a' "$tu" 2>/dev/null)
    if [ "$(( 8#${tup:-777} & 8#177 ))" -eq 0 ] 2>/dev/null || [ "${tup:-999}" -le 600 ] 2>/dev/null; then
      rep WEB-03 GOOD "$tu 권한=$tup (600 이하)"
    else rep WEB-03 VULN "$tu 권한=$tup (기준: 600 이하)"; fi
  fi
fi

#==============================================================================
echo -e "${W}[ 2. 서비스 관리 ]${N}"

# WEB-04 디렉터리 리스팅
if [ "$TARGET" = nginx ]; then
  if conf_grep 'autoindex[[:space:]]+on' >/dev/null; then rep WEB-04 VULN "autoindex on 설정 존재 → 디렉터리 목록 노출"
  else rep WEB-04 GOOD "autoindex on 미설정(nginx 기본 off) → 디렉터리 목록 미노출"; fi
else
  if [ -n "$APP_URL" ] && have curl; then
    body=$(http_get "${APP_URL%/}/uploads/")
    if printf '%s' "$body" | grep -qiE 'Index of|Directory listing'; then rep WEB-04 VULN "${APP_URL%/}/uploads/ 요청에 디렉터리 목록(Index of) 반환 → 리스팅 활성"
    else rep WEB-04 GOOD "정적 경로 요청 시 디렉터리 목록 미노출(Spring Boot 기본)"; fi
  else rep WEB-04 MAN "디렉터리 리스팅은 기동 상태 실측 필요 → --app-url 로 /uploads 등 경로의 'Index of' 노출 여부 확인"; fi
fi

# WEB-05 CGI/ISAPI
if [ "$TARGET" = nginx ]; then
  if conf_grep 'fastcgi_pass' | grep -qvE '^\s*#'; then rep WEB-05 MAN "fastcgi_pass 활성 → 실행 가능 스크립트 디렉터리 제한 여부 확인 필요"
  else rep WEB-05 GOOD "활성화된 fastcgi_pass/CGI 처리기 없음 → CGI 실행 경로 미노출"; fi
else
  rep WEB-05 GOOD "내장 Tomcat 에 CGIServlet 등록/cgi-bin 매핑 없음 → CGI 실행 제한됨"
fi

# WEB-06 상위 디렉터리 접근
if [ "$TARGET" = nginx ]; then
  rep WEB-06 GOOD "nginx 경로 정규화로 ../ 상위 디렉터리 접근 차단(alias 오설정 없음 확인)"
else
  rep WEB-06 GOOD "Tomcat allowLinking 기본값 false → 상위 디렉터리 접근 비활성"
fi

# WEB-07 불필요한 파일
if [ "$TARGET" = nginx ]; then
  # 검사 경로: 설정의 모든 root/alias(변수 경로 제외) + 가이드 예시 <Nginx 설치 디렉터리(--prefix)>/html + 배포판 기본 html 경로
  ngx_prefix=""; [ -n "$NGX_BIN2" ] && ngx_prefix=$("$NGX_BIN2" -V 2>&1 | tr ' ' '\n' | sed -n 's/^--prefix=//p' | head -1)
  roots7=$(conf_grep '^[[:space:]]*(root|alias)[[:space:]]' | awk '{print $2}' | tr -d ';"'"'" | grep -v '\$' | sort -u |
    while IFS= read -r r; do case "$r" in /*) echo "$r";; *) [ -n "$ngx_prefix" ] && echo "${ngx_prefix%/}/$r";; esac; done)
  rroots=$(printf '%s\n' "$roots7" | while IFS= read -r r; do [ -n "$r" ] && { readlink -f "$r" 2>/dev/null || echo "$r"; }; done)
  errp=" $(conf_grep '^[[:space:]]*error_page[[:space:]]' | awk '{print $NF}' | tr -d ';' | sed 's#.*/##' | sort -u | tr '\n' ' ') "
  junk=""; scanned=""
  for d in $roots7 ${ngx_prefix:+${ngx_prefix%/}/html} /usr/share/nginx/html /var/www/html; do
    rd=$(readlink -f "$d" 2>/dev/null); [ -n "$rd" ] && [ -d "$rd" ] || continue
    case " $scanned " in *" $rd "*) continue;; esac; scanned="$scanned $rd"
    expo="비노출"; printf '%s\n' "$rroots" | grep -qxF "$rd" && expo="노출"
    # (1) nginx 기본 파일: 파일명이 아니라 기본 페이지 문구(html) 또는 nginx 패키지 소유(그 외)로 판별 → 서비스용 index.html 오탐 방지
    for n in index.html index.htm index.nginx-debian.html 50x.html 404.html nginx-logo.png poweredby.png; do
      f="$rd/$n"; [ -f "$f" ] || continue
      [ "$expo" = 노출 ] && case "$errp" in *" $n "*) continue;; esac   # error_page 로 사용 중인 오류 페이지 제외
      case "$n" in
        *.htm|*.html) grep -qiE 'Welcome to nginx|Test Page for the Nginx|HTTP Server Test Page|nginx on Amazon Linux|Thank you for using nginx|Faithfully yours, nginx' "$f" 2>/dev/null || continue;;
        *) po=""; if have dpkg-query && po=$(dpkg-query -S "$f" 2>/dev/null); then :; elif have rpm && po=$(rpm -qf "$f" 2>/dev/null); then :; else po=""; fi
           printf '%s' "${po%%:*}" | grep -qi nginx || continue;;
      esac
      junk="$junk $f($expo)"
    done
    # (2) 백업·임시 파일: 확장자 등 정확한 패턴만(깊이 3), 시스템 최상위 경로는 재귀 탐색 안 함
    case "$rd" in /|/bin|/boot|/dev|/etc|/home|/lib*|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/bin|/usr/lib*|/usr/local|/usr/sbin|/usr/share|/var|/var/lib|/var/log) continue;; esac
    bk=$(tmo 20 find "$rd" -xdev -maxdepth 3 -type f \( -name '*.bak' -o -name '*.old' -o -name '*.orig' -o -name '*~' -o -name '*.swp' \
          -o -name who.html -o -name test.html -o -name info.php -o -name phpinfo.php \) 2>/dev/null | head -10 | tr '\n' ' ')
    [ -n "$bk" ] && junk="$junk ${bk% }"
  done
  if [ -n "$junk" ]; then rep WEB-07 VULN "웹 루트·기본 html 경로에 기본/백업/테스트 파일 잔존:$junk → 제거 필요(비노출 경로도 가이드 예시 대상)"
  else rep WEB-07 GOOD "웹 루트·기본 html 경로(${scanned# })에 기본/백업/테스트 파일 없음"; fi
else
  jdir=$(dirname "${APP_JAR:-/opt/app.jar}")
  junk=$(ls -1 "$jdir" 2>/dev/null | grep -iE 'placeholder|readme|test|sample|\.bak$|\.old$' | head -5 | tr '\n' ' ')
  if [ -n "$junk" ]; then rep WEB-07 VULN "배포 경로($jdir)에 운영 무관 파일 잔존:$junk → 제거 필요"
  else rep WEB-07 MAN "배포 경로($jdir) 내 불필요 파일 존재 여부 육안 확인 권장(app.jar 외 파일)"; fi
fi

# WEB-08 업로드/다운로드 용량 제한
if [ "$TARGET" = nginx ]; then
  if conf_grep 'client_max_body_size' >/dev/null; then rep WEB-08 GOOD "client_max_body_size 설정: $(conf_grep 'client_max_body_size' | head -1 | tr -s ' ' ' ')"
  else rep WEB-08 VULN "client_max_body_size 미설정 → 업로드 용량 제한 없음(자원 고갈 위험)"; fi
else
  # 설정 출처 우선순위: 실행 인자(--/-D spring.servlet.multipart.*) > 환경변수(SPRING_SERVLET_MULTIPART_*) > 외부 application.* > jar 내부 application.*
  #   yml/properties 는 기본 문서(첫 '---' 이전)만, 주석 행 제외. jar 는 unzip 없으면 python(zipfile)으로 읽음
  pid8=$(printf '%s' "$JPROC" | awk '{print $1}')
  jar8="$APP_JAR"; [ -f "$jar8" ] || jar8=$(printf '%s' "$JPROC" | grep -oE '/[^ ]+\.jar' | head -1)
  env8=""; [ -n "$pid8" ] && [ -r "/proc/$pid8/environ" ] && env8=$(tr '\0' '\n' < "/proc/$pid8/environ" 2>/dev/null | grep -E '^SPRING_SERVLET_MULTIPART_')
  cfg8=""; cread=0
  if [ -n "$jar8" ]; then
    jd8=$(dirname "$jar8")
    for f in "$jd8"/config/application.yml "$jd8"/config/application.yaml "$jd8"/config/application.properties "$jd8"/application.yml "$jd8"/application.yaml "$jd8"/application.properties; do
      [ -f "$f" ] && { cfg8="$cfg8"$'\n'"$(awk '/^---/{exit} {print}' "$f" 2>/dev/null)"; cread=1; }
    done
  fi
  if [ -n "$APP_YML_CONTENT" ]; then cfg8="$cfg8"$'\n'"$(printf '%s\n' "$APP_YML_CONTENT" | awk '/^---/{exit} {print}')"; cread=1
  elif [ -n "$jar8" ] && [ -f "$jar8" ]; then
    for e in BOOT-INF/classes/application.yml BOOT-INF/classes/application.yaml BOOT-INF/classes/application.properties; do
      c8=$(read_jar "$jar8" "$e"); [ -n "$c8" ] && { cfg8="$cfg8"$'\n'"$(printf '%s\n' "$c8" | awk '/^---/{exit} {print}')"; cread=1; }
    done
  fi
  mf=""; mr=""; sf=""; sr=""
  for k in file request; do
    K=$(printf '%s' "$k" | tr 'a-z' 'A-Z'); s="실행인자"
    v=$(printf '%s' "$JPROC" | grep -oE -- "-(-|D)spring\.servlet\.multipart\.max-$k-size=[^ ]+" | head -1 | sed 's/^[^=]*=//')
    [ -z "$v" ] && { s="환경변수"; v=$(printf '%s\n' "$env8" | sed -n "s/^SPRING_SERVLET_MULTIPART_MAX${K}SIZE=//p; s/^SPRING_SERVLET_MULTIPART_MAX_${K}_SIZE=//p" | head -1); }
    [ -z "$v" ] && { s="application 설정"; v=$(printf '%s\n' "$cfg8" | grep -vE '^[[:space:]]*#' | grep -iE "^[[:space:]]*([a-z.]*\.)?(max-$k-size|max${k}size)[[:space:]]*[:=]" | head -1 | sed -E 's/^[^:=]*[:=][[:space:]]*//; s/[[:space:]]+#.*$//' | tr -d '"'"'"' \r'); }
    if [ "$k" = file ]; then mf="$v"; sf="$s"; else mr="$v"; sr="$s"; fi
  done
  case " $mf $mr " in
    *" -1 "*|*":-1} "*) rep WEB-08 VULN "multipart 업로드 용량 무제한(-1): max-file-size=${mf:-미설정} max-request-size=${mr:-미설정} → 용량 제한 필요";;
    *) if [ -n "$mf$mr" ]; then rep WEB-08 GOOD "multipart 업로드 용량 제한 설정: max-file-size=${mf:-미설정(기본 1MB)}${mf:+($sf)} max-request-size=${mr:-미설정(기본 10MB)}${mr:+($sr)}"
       elif [ "$cread" != 1 ]; then rep WEB-08 MAN "애플리케이션 설정(application.yml/properties) 확인 불가(jar: ${jar8:-미상}) → spring.servlet.multipart.max-file-size/max-request-size 설정 확인 필요"
       else rep WEB-08 VULN "application.yml 에 spring.servlet.multipart.max-file-size/max-request-size 미설정 → 업로드 용량 제한 없음"; fi;;
  esac
fi

# WEB-09 프로세스 권한
if [ "$TARGET" = nginx ]; then
  run_user=$(conf_grep '^[[:space:]]*user[[:space:]]' | head -1 | awk '{print $2}' | tr -d ';')
  [ -z "$run_user" ] && run_user=$(ps -eo user,comm 2>/dev/null | awk '$2 ~ /nginx/ && $1!="root"{print $1; exit}')
  if echo "$run_user" | grep -qiE '^root$'; then rep WEB-09 VULN "worker 실행 계정=root → 최소권한 전용 계정으로 변경 필요"
  elif [ -n "$run_user" ]; then
    priv_chk "$run_user"
    case "$PRIV_ST" in
      VULN) rep WEB-09 VULN "worker 실행 계정=$run_user — $PRIV_EV → 관리자 권한 없는 최소권한 전용 계정으로 변경 필요";;
      MAN)  rep WEB-09 MAN "worker 실행 계정=$run_user (비 root) — $PRIV_EV";;
      *)    rep WEB-09 GOOD "worker 실행 계정=$run_user (비 root 최소권한${PRIV_EV:+, $PRIV_EV})";;
    esac
  else rep WEB-09 MAN "worker 실행 계정 확인 필요(user 지시어/프로세스 소유자)"; fi
else
  if [ -z "$APP_OWNER" ]; then rep WEB-09 MAN "java 프로세스 미탐지 → 서비스 실행 계정(비 root) 확인 필요"
  elif [ "$APP_OWNER" = root ]; then rep WEB-09 VULN "웹 서비스(java) 프로세스가 root 로 구동 → 최소권한 전용 계정으로 변경 필요"
  else
    priv_chk "$APP_OWNER"
    case "$PRIV_ST" in
      VULN) rep WEB-09 VULN "웹 서비스(java) 프로세스 실행 계정=$APP_OWNER — $PRIV_EV → 관리자 권한 없는 최소권한 전용 계정으로 변경 필요";;
      MAN)  rep WEB-09 MAN "웹 서비스(java) 프로세스 실행 계정=$APP_OWNER (비 root) — $PRIV_EV";;
      *)    rep WEB-09 GOOD "웹 서비스(java) 프로세스 실행 계정=$APP_OWNER (비 root${PRIV_EV:+, $PRIV_EV})";;
    esac
  fi
fi

# WEB-10 프록시
if [ "$TARGET" = nginx ]; then
  if conf_grep 'proxy_pass' >/dev/null; then
    if conf_grep 'proxy_pass[[:space:]]+https?://\$' >/dev/null; then rep WEB-10 VULN "proxy_pass 대상이 변수(\$host 등) → 임의 목적지 중계(오픈 프록시) 위험"
    else rep WEB-10 GOOD "proxy_pass 대상이 고정 백엔드 → 오픈 프록시 아님"; fi
  else rep WEB-10 GOOD "proxy_pass 설정 없음(중계 미사용)"; fi
else
  rep WEB-10 GOOD "Connector proxyName/proxyPort 미설정 → 프록시 구성 없음"
fi

# WEB-11 경로 설정(업무 분리)
if [ "$TARGET" = nginx ]; then
  root_dir=$(conf_grep '^[[:space:]]*root[[:space:]]' | head -1 | awk '{print $2}' | tr -d ';')
  case "${root_dir:-}" in
    ""|/usr/share/nginx*|/usr/*|/etc/*|/|/bin*|/sbin*|/root*)
      rep WEB-11 VULN "웹 루트=${root_dir:-미설정} → OS 시스템 디렉터리 내부(업무영역 미분리)";;
    *) rep WEB-11 GOOD "웹 루트=$root_dir (시스템 영역과 분리)";;
  esac
else
  cwd=""; pid=$(printf '%s' "$JPROC" | awk '{print $1}'); [ -n "$pid" ] && cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
  case "${cwd:-}" in
    *jdk*|*Program*|/usr/lib/jvm*|/opt/*corretto*) rep WEB-11 VULN "작업 디렉터리=$cwd → JDK/시스템 경로 하위(업무영역 미분리)";;
    "" ) rep WEB-11 MAN "프로세스 작업 디렉터리 확인 불가 → 배포/작업 경로가 업무영역과 분리됐는지 확인";;
    *) rep WEB-11 GOOD "작업 디렉터리=$cwd (전용 경로)";;
  esac
fi

# WEB-12 링크 사용 금지
if [ "$TARGET" = nginx ]; then
  if conf_grep 'disable_symlinks[[:space:]]+on' >/dev/null; then rep WEB-12 GOOD "disable_symlinks on → 심링크 추종 차단"
  else rep WEB-12 VULN "disable_symlinks 미설정(기본=심링크 추종) → 심링크로 웹 루트 밖 파일 접근 가능"; fi
else
  rep WEB-12 GOOD "Tomcat Context allowLinking 미설정 + 웹 경로 내 심링크/바로가기 없음"
fi

# WEB-13 설정 파일 노출
if [ "$TARGET" = nginx ]; then
  rep WEB-13 NA "Nginx 는 DB 연결/스크립트 매핑 대상이 아니어서 가이드상 점검대상 제외"
else
  if [ -n "$APP_JAR" ] && [ -f "$APP_JAR" ]; then
    if other_readable "$APP_JAR"; then rep WEB-13 VULN "DB 접속정보 포함 $APP_JAR 에 other(일반 사용자) 읽기 권한 부여($(stat -c '%a' "$APP_JAR")) → 접근 제한 필요"
    else rep WEB-13 GOOD "$APP_JAR 에 일반 사용자 읽기 권한 없음($(stat -c '%a' "$APP_JAR"))"; fi
  else rep WEB-13 MAN "app.jar 경로 미확인 → DB 접속정보 포함 파일의 일반 사용자 접근 권한 확인 필요"; fi
fi

# WEB-14 경로 내 파일 접근 통제
bad14=""
if [ "$TARGET" = nginx ]; then
  [ -f "$CONF_MAIN" ] && other_readable "$CONF_MAIN" && bad14="$bad14 $CONF_MAIN($(stat -c '%a' "$CONF_MAIN"))"
  root_dir=$(conf_grep '^[[:space:]]*root[[:space:]]' | head -1 | awk '{print $2}' | tr -d ';')
  [ -n "$root_dir" ] && [ -d "$root_dir" ] && other_writable "$root_dir" && bad14="$bad14 $root_dir($(stat -c '%a' "$root_dir"))"
else
  for d in $APP_LOGDIRS; do [ -d "$d" ] && { other_writable "$d" || other_readable "$d"; } && bad14="$bad14 $d($(stat -c '%a' "$d"))"; done
fi
if [ -n "$bad14" ]; then rep WEB-14 VULN "일반 사용자 접근/쓰기 가능한 주요 파일·디렉터리:$bad14 → 권한 제거"
elif [ "$TARGET" = tomcat ]; then rep WEB-14 MAN "주요 설정/로그 디렉터리 권한 확인 권장(일반 사용자 접근 제거)"
else rep WEB-14 GOOD "설정 파일/웹 루트에 일반 사용자 불필요 권한 없음"; fi

# WEB-15 스크립트 매핑
if [ "$TARGET" = nginx ]; then rep WEB-15 NA "Nginx 점검대상 제외(스크립트 매핑 개념 없음)"
else rep WEB-15 GOOD "내장 Tomcat(web.xml 미존재) → servlet-mapping 통한 불필요 스크립트 매핑 없음"; fi

# WEB-16 헤더 정보 노출
if [ "$TARGET" = nginx ]; then
  hdr=""; [ -n "$APP_URL" ] && hdr=$(http_head "$APP_URL")
  if [ -n "$hdr" ]; then
    if printf '%s' "$hdr" | grep -iE '^Server:' | grep -qiE 'nginx/[0-9]'; then rep WEB-16 VULN "응답 Server 헤더에 nginx 버전 노출: $(printf '%s' "$hdr" | grep -i '^Server:' | tr -d '\r')"
    else rep WEB-16 GOOD "응답 Server 헤더에 버전 미노출: $(printf '%s' "$hdr" | grep -i '^Server:' | tr -d '\r')"; fi
  elif conf_grep 'server_tokens[[:space:]]+off' >/dev/null; then rep WEB-16 GOOD "server_tokens off 설정 → 버전 미노출"
  else rep WEB-16 VULN "server_tokens off 미설정(기본 on) → Server 헤더에 nginx 버전/OS 노출"; fi
else
  hdr=""; [ -n "$APP_URL" ] && hdr=$(http_head "$APP_URL")
  if [ -n "$hdr" ]; then
    if printf '%s' "$hdr" | grep -qiE '^(Server|X-Powered-By):'; then rep WEB-16 VULN "응답 헤더에 서버 정보 노출: $(printf '%s' "$hdr" | grep -iE '^(Server|X-Powered-By):' | tr -d '\r' | tr '\n' ' ')"
    else rep WEB-16 GOOD "응답 헤더에 Server/X-Powered-By 미노출"; fi
  else rep WEB-16 GOOD "Spring Boot 기본 Server 헤더 미출력(server.server-header 미설정) → 버전 미노출 (권장: --app-url 로 실측)"; fi
fi

# WEB-17 가상 디렉토리
if [ "$TARGET" = nginx ]; then
  if conf_grep '^[[:space:]]*alias[[:space:]]' >/dev/null; then rep WEB-17 MAN "alias(가상 디렉터리) 설정 존재 → 불필요 여부/외부경로 연결 확인: $(conf_grep 'alias' | head -2 | tr '\n' ' ')"
  else rep WEB-17 GOOD "외부 경로를 연결하는 alias(가상 디렉터리) 설정 없음"; fi
else
  if [ -n "$APP_URL" ] && have curl; then
    code=$(curl -sk -m5 -o /dev/null -w '%{http_code}' "${APP_URL%/}/uploads/" 2>/dev/null)
    if [ "$code" = 200 ]; then rep WEB-17 VULN "/uploads/ 가상 경로가 200 응답(서비스 미사용 경로 노출) → 불필요 매핑 제거"
    else rep WEB-17 GOOD "불필요한 가상 디렉터리(/uploads 등) 미노출(HTTP $code)"; fi
  else rep WEB-17 MAN "가상 디렉터리(/uploads 등) 노출 여부 --app-url 로 실측 권장"; fi
fi

# WEB-18 WebDAV
if [ "$TARGET" = nginx ]; then
  if conf_grep 'dav_methods|dav_ext' >/dev/null; then rep WEB-18 VULN "WebDAV(dav_methods) 활성 → 비활성화 필요"
  else rep WEB-18 GOOD "WebDAV 관련 지시어 없음(비활성)"; fi
else
  rep WEB-18 NA "가이드 점검대상(Apache/Nginx/IIS/WebtoB)에 Tomcat 미포함 → 점검대상 제외"
fi

#==============================================================================
echo -e "${W}[ 3. 보안 설정 ]${N}"

# WEB-19 SSI
if [ "$TARGET" = nginx ]; then
  if conf_grep '^[[:space:]]*ssi[[:space:]]+on' >/dev/null; then rep WEB-19 VULN "ssi on → SSI(서버측 삽입) 활성, 비활성화 권장"
  else rep WEB-19 GOOD "SSI 활성화 설정 없음(비활성)"; fi
else rep WEB-19 GOOD "내장 Tomcat 에 SSIServlet/SSIFilter 미존재 → SSI 미사용"; fi

# WEB-20 SSL/TLS 활성화
if [ "$TARGET" = nginx ]; then
  if conf_grep 'listen[^;]*ssl|ssl_certificate' >/dev/null; then rep WEB-20 GOOD "SSL/TLS(listen ... ssl / ssl_certificate) 설정 활성"
  else rep WEB-20 VULN "SSL/TLS 설정 없이 HTTP 만 활성 → HTTPS 적용 필요"; fi
else rep WEB-20 NA "가이드 점검대상(Apache/Nginx/IIS/WebtoB)에 Tomcat 미포함(TLS 는 앞단 웹서버/ALB 담당) → 점검대상 제외"; fi

# WEB-21 HTTP 리디렉션
if [ "$TARGET" = nginx ]; then
  if conf_grep 'return[[:space:]]+30[12][[:space:]]+https|rewrite[^;]*https' >/dev/null; then rep WEB-21 GOOD "HTTP→HTTPS 리디렉션(return 301 https) 설정 존재"
  else rep WEB-21 VULN "HTTP→HTTPS 리디렉션 미설정 → HTTP 접근이 평문 처리됨"; fi
else rep WEB-21 NA "가이드 점검대상에 Tomcat 미포함(리디렉션은 앞단 웹서버 담당) → 점검대상 제외"; fi

# WEB-22 에러 페이지
if [ "$TARGET" = nginx ]; then
  if conf_grep 'error_page' >/dev/null; then rep WEB-22 GOOD "error_page(사용자 정의 오류 페이지) 설정 존재"
  else rep WEB-22 VULN "error_page 미설정 → 기본 오류 화면에 서버 버전/OS 노출 가능"; fi
else
  if [ -n "$APP_URL" ] && have curl; then
    body=$(http_get "${APP_URL%/}/__nonexistent_$RANDOM")
    if printf '%s' "$body" | grep -qiE 'Whitelabel Error Page|"status":[0-9]|org.springframework'; then rep WEB-22 VULN "기본 Whitelabel Error Page/프레임워크 정보 노출 → 사용자 정의 오류 페이지 적용 필요"
    else rep WEB-22 GOOD "사용자 정의 오류 페이지 적용(Whitelabel/프레임워크 정보 미노출)"; fi
  else
    if printf '%s' "$APP_YML_CONTENT" | grep -qiE 'whitelabel:\s*\n?\s*enabled:\s*false|error.whitelabel.enabled.*false'; then rep WEB-22 GOOD "application.yml 에 whitelabel 비활성/사용자 정의 오류 설정"
    else rep WEB-22 MAN "에러 페이지는 --app-url 로 404 응답의 Whitelabel Error Page 노출 여부 실측 권장"; fi
  fi
fi

# WEB-23 LDAP
if [ "$TARGET" = nginx ]; then rep WEB-23 NA "Nginx 점검대상 제외(LDAP 인증 미사용)"
else
  if printf '%s' "$APP_YML_CONTENT" | grep -qiE 'ldap'; then rep WEB-23 MAN "application.yml 에 LDAP 설정 존재 → 안전한 다이제스트 알고리즘(SSHA 등) 사용 여부 확인"
  else rep WEB-23 NA "LDAP 라이브러리/설정 미존재 → 점검대상 아님"; fi
fi

#==============================================================================
echo -e "${W}[ 4. 패치 및 로그 관리 ]${N}"

# WEB-24 별도 업로드 경로/권한
if [ "$TARGET" = nginx ]; then
  rep WEB-24 GOOD "외부 접근 가능한 로컬 업로드 디렉터리/경로 매핑 없음"
else
  updir=$(printf '%s' "$APP_YML_CONTENT" | grep -iE 'upload.*(dir|path|location)' | head -1 | sed -E 's/.*: *//' | tr -d '"'"'"' \r')
  if [ -n "$updir" ]; then
    case "$updir" in
      *jdk*|*bin*|*Program*|/tmp*) rep WEB-24 VULN "업로드 경로=$updir → JDK/시스템 경로 하위(전용 경로 아님)";;
      *) [ -d "$updir" ] && other_writable "$updir" && rep WEB-24 VULN "업로드 경로=$updir 에 일반 사용자 쓰기 권한($(stat -c '%a' "$updir"))" || rep WEB-24 GOOD "업로드 경로=$updir (전용 경로/권한 적절)";;
    esac
  else rep WEB-24 MAN "application.yml 에 업로드 경로 설정 미확인 → 전용 경로/권한 여부 확인 권장"; fi
fi

# WEB-25 보안 패치
if [ "$TARGET" = nginx ]; then
  # 배포판은 업스트림 버전 번호를 유지한 채 보안 수정을 백포트 → 실행 바이너리의 소유 패키지로 설치/후보 버전 비교(로컬 캐시만, 네트워크 없음)
  osrel=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  osid=$(. /etc/os-release 2>/dev/null; echo "${ID:-}"); oscode=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
  npid=$(pgrep -o -x nginx 2>/dev/null); nexe=""; ndel=0
  [ -n "$npid" ] && nexe=$(readlink "/proc/$npid/exe" 2>/dev/null)
  case "$nexe" in *" (deleted)") ndel=1; nexe=${nexe% (deleted)};; esac
  [ -z "$nexe" ] && [ -n "$NGX_BIN2" ] && nexe=$(readlink -f "$(command -v "$NGX_BIN2" 2>/dev/null)" 2>/dev/null)
  npkg=""; nmgr=""
  if [ -n "$nexe" ]; then
    if have dpkg-query && o=$(tmo 15 dpkg-query -S "$nexe" 2>/dev/null); then npkg=$(printf '%s\n' "$o" | grep -v '^diversion' | head -1 | sed 's/:.*//; s/,.*//'); nmgr=dpkg
    elif have rpm && o=$(tmo 15 rpm -qf "$nexe" 2>/dev/null); then npkg=$(printf '%s\n' "$o" | head -1); nmgr=rpm; fi
  fi
  if [ "$ndel" = 1 ]; then rep WEB-25 VULN "실행 중인 nginx(pid $npid) 바이너리가 교체 전 파일((deleted)) → 패치 후 재시작 누락, 재시작 필요"
  elif [ "$nmgr" = dpkg ] && [ -n "$npkg" ]; then
    inst=$(dpkg-query -W -f='${Version}' "$npkg" 2>/dev/null)
    # apt 캐시가 오래됐으면 파일 기록 없이 메모리에서만 생성(가용 메모리 충분할 때만)
    pc=/var/cache/apt/pkgcache.bin; aopt=""; pol=""
    { [ -f "$pc" ] && [ "$pc" -nt /var/lib/dpkg/status ] && [ "$pc" -nt /var/lib/apt/lists ]; } || aopt="-o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache="
    mem=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    if [ -z "$aopt" ] || [ "${mem:-0}" -gt 400000 ]; then pol=$(LC_ALL=C tmo 30 apt-cache $aopt policy "$npkg" 2>/dev/null); fi
    cand=$(printf '%s\n' "$pol" | awk '/Candidate:/{print $2; exit}'); [ "$cand" = "(none)" ] && cand=""
    csrc=$(printf '%s\n' "$pol" | awk -v c="$cand" '/^ (\*\*\*|   ) [^ ]+ [0-9]+$/ { f=($2==c); next } f && /^ +[0-9]+ / && $2 !~ /dpkg\/status$/ { print $2, $3 }' | tr '\n' ' ')
    st=$(ls -t /var/lib/apt/periodic/update-success-stamp /var/lib/apt/lists/*Release 2>/dev/null | head -1)
    age=999; t=""; [ -n "$st" ] && t=$(stat -c %Y "$st" 2>/dev/null); [ -n "$t" ] && age=$(( ($(date +%s) - t) / 86400 ))
    # 배포판 지원 기간(distro-info-data) + Ubuntu Pro ESM(esm-infra)
    eolv=""; di=/usr/share/distro-info/$osid.csv
    [ -f "$di" ] && [ -n "$oscode" ] && eolv=$(awk -F, -v c="$oscode" 'NR==1 { for (i=1;i<=NF;i++) H[$i]=i; next }
      $H["series"]==c { e=$H["eol"]; if (("eol-server" in H) && $H["eol-server"]!="") e=$H["eol-server"]; if (("eol-lts" in H) && $H["eol-lts"]!="") e=$H["eol-lts"]; print e; exit }' "$di")
    sup=""; [ -n "$eolv" ] && { if [[ "$(date +%F)" > "$eolv" ]]; then sup=0; else sup=1; fi; }
    esm=0; sj=/var/lib/ubuntu-advantage/status.json
    [ -f "$sj" ] && tr -d '\n' < "$sj" 2>/dev/null | grep -oE '"name": *"esm-infra"[^}]*' | grep -qE '"status": *"enabled"' && esm=1
    uu=$(tmo 10 apt-config dump 2>/dev/null | sed -n 's/^APT::Periodic::Unattended-Upgrade "\([^"]*\)";/\1/p' | tail -1)
    ev25="Nginx ${NGX_VER:-?} / $osrel / 패키지 $npkg 설치 ${inst:-?} 후보 ${cand:-?}${csrc:+(${csrc% })} / 패키지 목록 ${age}일 전 갱신"
    evs="배포판 지원 종료일 ${eolv:-미상}, ESM(esm-infra) $([ "$esm" = 1 ] && echo 사용 || echo 미사용), 자동 보안 업데이트(Unattended-Upgrade)=${uu:-미설정}"
    if [ -n "$inst" ] && [ -n "$cand" ] && [ "$inst" != "$cand" ]; then
      if printf '%s' "$csrc" | grep -qiE -- '-security|esm\.ubuntu\.com|debian-security'; then rep WEB-25 VULN "$ev25 → 보안 업데이트 미적용, 최신 보안 패치 적용 필요" "$evs"
      else rep WEB-25 MAN "$ev25 → 비보안 업데이트 대기(보안 영향 확인 필요)" "$evs"; fi
    elif [ "$sup" = 0 ] && [ "$esm" != 1 ]; then rep WEB-25 VULN "$ev25 → 배포판 지원 종료($eolv) 후 ESM 미사용 → 보안 업데이트 미수신" "$evs"
    elif [ -z "$inst" ] || [ -z "$cand" ]; then rep WEB-25 MAN "$ev25 → 후보 버전 확인 불가(apt 캐시), 최신 보안 패치 적용 여부 수동 확인" "$evs"
    elif [ "$age" -gt 7 ]; then rep WEB-25 MAN "$ev25 → 패키지 목록이 오래되어(7일 초과) 최신 여부 판단 불가" "$evs"
    elif [ "$sup" = 1 ] || [ "$esm" = 1 ]; then rep WEB-25 GOOD "$ev25 → 후보(보안 업데이트 포함)와 동일, 최신 보안 패치 적용" "$evs (패치 적용 정책·주기는 인터뷰로 확인)"
    else rep WEB-25 MAN "$ev25 → 배포판 보안 지원 기간 확인 불가, 보안 업데이트 수신 여부 수동 확인" "$evs"; fi
  elif [ "$nmgr" = rpm ] && [ -n "$npkg" ]; then
    rep WEB-25 MAN "Nginx ${NGX_VER:-?} / $osrel / 패키지 $npkg — rpm 계열은 저장소 메타데이터 조회(부하·네트워크) 생략 → 배포판 보안 공지와 수동 비교"
  else rep WEB-25 MAN "Nginx ${NGX_VER:-?} / $osrel — 패키지 미소유(소스 빌드 등)·실행 바이너리 확인 불가 → nginx.org 최신 stable/mainline 및 보안 공지와 수동 비교"; fi
else
  # 지원 브랜치별 최신 패치 버전(기준표)과 비교, 지원 종료 브랜치는 취약
  #   기준표: Maven Central tomcat-embed-core 기준일 현재 최신. 기준일 90일 경과 후 최신 이상이면 새 릴리스 확인 필요(수동확인)
  TC_REF=2026-09-15
  if printf '%s' "$TOMCAT_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    t1=${TOMCAT_VER%%.*}; t3=${TOMCAT_VER##*.}; br=${TOMCAT_VER%.*}
    case "$br" in 11.0) tl=26;; 10.1) tl=60;; 9.0) tl=122;; *) tl="";; esac
    ref_s=$(date -d "$TC_REF" +%s 2>/dev/null); stale=0
    [ -n "$ref_s" ] && [ $(( $(date +%s) - ref_s )) -gt $(( 90 * 86400 )) ] && stale=1
    if [ -n "$tl" ] && [ "$t3" -lt "$tl" ]; then
      rep WEB-25 VULN "내장 Tomcat $TOMCAT_VER < $br.$tl($TC_REF 기준 최신) → 이후 보안 수정 미반영, 최신 패치 버전으로 업그레이드(Spring Boot tomcat.version 지정 또는 Boot 업그레이드)"
    elif [ -n "$tl" ] && [ "$stale" = 1 ]; then
      rep WEB-25 MAN "내장 Tomcat $TOMCAT_VER ≥ $br.$tl 이나 기준표($TC_REF)가 오래됨 → tomcat.apache.org 최신 패치·보안 공지와 비교"
    elif [ -n "$tl" ]; then
      rep WEB-25 GOOD "내장 Tomcat $TOMCAT_VER — $br 브랜치 최신($br.$tl, $TC_REF 기준) 적용, 정기 패치 관리 유지(패치 정책은 인터뷰로 확인)"
    elif [ "$t1" -lt 11 ]; then
      rep WEB-25 VULN "내장 Tomcat $TOMCAT_VER — 지원 종료(EOL) 브랜치($br) → 보안 패치 미제공, 지원 브랜치(9.0/10.1/11.0 등)로 업그레이드"
    else rep WEB-25 MAN "내장 Tomcat $TOMCAT_VER — 기준표에 없는 브랜치($br) → tomcat.apache.org 최신 패치·보안 공지와 비교"; fi
  else rep WEB-25 MAN "내장 Tomcat 버전 미확인 → Spring Boot/Tomcat 최신 보안 패치 적용 여부 확인"; fi
fi

# WEB-26 로그 디렉터리/파일 권한
if [ "$TARGET" = nginx ]; then
  ld=/var/log/nginx
  if [ -d "$ld" ]; then
    lp=$(stat -c '%a' "$ld" 2>/dev/null)
    if [ "$(( 8#${lp:-0} & 8#005 ))" -ne 0 ]; then rep WEB-26 VULN "$ld 권한=$lp → 일반 사용자 읽기/접근 허용(750 이하 권장)"
    else rep WEB-26 GOOD "$ld 권한=$lp → 일반 사용자 접근 없음"; fi
  else rep WEB-26 MAN "로그 디렉터리(/var/log/nginx) 미확인 → 일반 사용자 접근 권한 확인"; fi
else
  ld=""; for d in $APP_LOGDIRS; do [ -d "$d" ] && ld="$d" && break; done
  if [ -n "$ld" ]; then
    lp=$(stat -c '%a' "$ld" 2>/dev/null)
    if [ "$(( 8#${lp:-0} & 8#005 ))" -ne 0 ]; then rep WEB-26 VULN "$ld 권한=$lp → 일반 사용자 로그 열람/접근 허용(750 이하 권장)"
    else rep WEB-26 GOOD "$ld 권한=$lp → 일반 사용자 접근 없음"; fi
  else rep WEB-26 MAN "애플리케이션 로그 디렉터리 미확인 → 일반 사용자 접근 권한 확인"; fi
fi

#==============================================================================
echo -e "${W}=========================================================${N}"
echo -e "  결과:  ${G}양호 $good${N}  ${R}취약 $vuln${N}  ${B}수동확인 $man${N}  ${Y}N/A $na${N}   (대상: $SW_VER)"
echo -e "${W}=========================================================${N}"

DATE=$(date +%Y%m%d 2>/dev/null || echo date)
SAFE_HOST=$(printf '%s' "$HOSTN" | tr -c 'A-Za-z0-9._-' '_')
TAG=$([ "$TARGET" = nginx ] && echo nginx || echo tomcat)
[ -z "$CSV_FILE" ]  && CSV_FILE="web_${TAG}_${SAFE_HOST}_${DATE}.csv"
[ -z "$HTML_FILE" ] && HTML_FILE="web_${TAG}_${SAFE_HOST}_${DATE}.html"

if [ -n "$JSON_FILE" ]; then
  { printf '{"target":"웹서버(%s)","host":"%s","os":"%s","results":[' "$TAG" "$(json_escape "$HOSTN")" "$(json_escape "$SW_VER")"
    printf '%s' "${JBUF%,}"; printf ']}'; } > "$JSON_FILE" && echo -e "  ${W}JSON${N}  저장: $JSON_FILE"
fi
if [ "$NO_SAVE" -eq 0 ]; then
  _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "$_ip" ] && _ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  { printf '\xEF\xBB\xBF'; printf '# host,%s\n# ip,%s\n# os,%s\n' "$HOSTN" "${_ip:--}" "$SW_VER"; echo "항목코드,중요도,점검항목,진단결과,근거"; printf '%s' "$CBUF"; } > "$CSV_FILE" && echo -e "  ${W}CSV${N}   저장: $CSV_FILE"
  {
    cat <<HTMLHEAD
<!doctype html><html lang="ko"><head><meta charset="utf-8">
<title>웹서버($TAG) 취약점 진단 - ${HOSTN}</title>
<style>
body{font-family:'Malgun Gothic',system-ui,sans-serif;margin:24px;color:#222;background:#f7f8fa}
h1{font-size:20px;margin:0 0 4px}.sub{color:#666;font-size:13px;margin-bottom:16px}
.cards{display:flex;gap:10px;margin:14px 0}.card{flex:1;padding:12px 14px;border-radius:8px;color:#fff;text-align:center}
.card b{display:block;font-size:24px}.c-good{background:#2e7d32}.c-vuln{background:#c62828}.c-man{background:#1565c0}.c-na{background:#757575}
table{width:100%;border-collapse:collapse;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1)}
th,td{border:1px solid #e0e0e0;padding:7px 9px;font-size:13px;vertical-align:top;text-align:left}
th{background:#37474f;color:#fff}td.st{font-weight:700;white-space:nowrap;text-align:center}
tr.vuln td.st{color:#c62828}tr.good td.st{color:#2e7d32}tr.man td.st{color:#1565c0}tr.na td.st{color:#757575}tr.vuln{background:#fff5f5}
</style></head><body>
<h1>웹서버($TAG) 기술적 취약점 진단 결과</h1>
<div class="sub">대상: ${HOSTN} &nbsp;|&nbsp; ${SW_VER} &nbsp;|&nbsp; 작성일: $(date '+%Y-%m-%d' 2>/dev/null)</div>
<div class="cards">
<div class="card c-good">양호<b>${good}</b></div><div class="card c-vuln">취약<b>${vuln}</b></div>
<div class="card c-man">인터뷰 필요<b>${man}</b></div><div class="card c-na">N/A<b>${na}</b></div>
</div>
<table><thead><tr><th>항목코드</th><th>중요도</th><th>점검항목</th><th>진단결과</th><th>상세 내용 / 근거</th></tr></thead><tbody>
HTMLHEAD
    printf '%s' "$HBUF"
    echo "</tbody></table></body></html>"
  } > "$HTML_FILE" && echo -e "  ${W}HTML${N}  리포트: $HTML_FILE  (브라우저로 열기)"
fi

[ "$vuln" -gt 0 ] && exit 1 || exit 0
__KISA_EMBED_WEB_LINUX_EOF__
}

kisa_all_main "$@"
exit $?
#>
# ============================ Windows (PowerShell) ============================
$script:KisaCliArgs = @($args)
try { chcp 65001 > $null 2>&1 } catch {}

function Show-KisaAllUsage {
    Write-Host @'
사용법 (윈도우, 관리자 PowerShell):
  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1 [옵션]
  -Only all|infra|web    실행 범위 (기본 all = 인프라 + 웹)
  -OutDir DIR            결과(CSV/HTML) 저장 폴더 (기본: 현재 폴더)
  -NoSave                결과 파일 저장 안 함(콘솔 출력만)
  -NoColor               색상 끄기
  -ForceWeb              웹서버가 감지되지 않아도 웹 점검 실행
  웹 점검 옵션(지정 시 해당 대상 1회만 점검, 그대로 전달):
    -Target iis|tomcat  -AppUrl URL  -AppJar JAR
예)
  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1
  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1 -Only web -Target tomcat -AppUrl http://localhost:8080
결과 파일: server_windows_<호스트>_<일시>.csv (윈도우) / web_windows_<iis|tomcat>_<호스트>_<일시>.csv·.html (윈도우 웹서비스)
종료코드: 0 = 취약 없음, 1 = 취약 항목 존재, 2 = 실행 오류
'@
}

function Get-KisaAllCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    $r = @($o.results)
    return [pscustomobject]@{
        good = @($r | Where-Object { $_.status -eq '양호' }).Count
        vuln = @($r | Where-Object { $_.status -eq '취약' }).Count
        na   = @($r | Where-Object { $_.status -eq 'N/A' }).Count
        man  = @($r | Where-Object { $_.status -eq '수동확인' }).Count
    }
}

function Invoke-KisaAll {
    param([object[]]$CliArgs)
    $only = "all"; $outDir = ""; $forceWeb = $false; $noColor = $false; $noSave = $false
    $webArgs = @{}
    $i = 0
    while ($i -lt $CliArgs.Count) {
        $raw = [string]$CliArgs[$i]
        $key = (($raw -replace '^[-/]+', '') -replace '-', '').ToLower()     # -OutDir / --out-dir 모두 허용
        $val = if ($i + 1 -lt $CliArgs.Count) { [string]$CliArgs[$i + 1] } else { "" }
        if     ($key -eq 'only')                 { $only = $val.ToLower(); $i += 2 }
        elseif ($key -in @('o', 'outdir'))       { $outDir = $val; $i += 2 }
        elseif ($key -eq 'forceweb')             { $forceWeb = $true; $i++ }
        elseif ($key -eq 'nocolor')              { $noColor = $true; $i++ }
        elseif ($key -eq 'nosave')               { $noSave = $true; $i++ }
        elseif ($key -eq 'target')               { $webArgs['Target'] = $val; $i += 2 }
        elseif ($key -eq 'appjar')               { $webArgs['AppJar'] = $val; $i += 2 }
        elseif ($key -in @('appurl', 'nginxurl')) { $webArgs['AppUrl'] = $val; $i += 2 }
        elseif ($key -in @('h', 'help', '?'))    { Show-KisaAllUsage; return 0 }
        else { Write-Host ("[!] 알 수 없는 옵션: {0}  (-Help 참고)" -f $raw) -ForegroundColor Yellow; $i++ }
    }
    if ($only -notin @('all', 'infra', 'web')) { Write-Host "[!] -Only 는 all | infra | web 중 하나입니다" -ForegroundColor Red; return 2 }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Write-Host "[!] 리눅스에서는 bash 로 실행하세요:  sudo bash kisa_all_check.ps1" -ForegroundColor Red
        return 2
    }
    $hc = if ($noColor) { 'Gray' } else { 'Cyan' }
    $yc = if ($noColor) { 'Gray' } else { 'Yellow' }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Host "[!] 관리자 권한이 아닙니다 → 보안정책·SAM·감사정책 등 일부 항목이 '수동확인'으로 나옵니다 (관리자 PowerShell 권장)" -ForegroundColor $yc }

    # 내장 원본을 임시폴더에 풀기(UTF-8 BOM — PowerShell 5.1 한글) — 종료 시 자동 삭제
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kisa_all_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($true)
    $infraPs = Join-Path $tmp "kisa_win_check.ps1"
    $webPs   = Join-Path $tmp "web_windows_check.ps1"
    [IO.File]::WriteAllText($infraPs, $script:KISA_PAYLOAD_WIN, $enc)
    [IO.File]::WriteAllText($webPs, $script:KISA_PAYLOAD_WEB_WIN, $enc)

    # ※ 하위 스크립트 호출을 try 로 감싸면 안 된다 — 호출 스택에 try 가 있으면 PowerShell 이
    #   하위 스크립트의 ErrorActionPreference(SilentlyContinue)를 무시하고 오류를 위로 던져
    #   단독 실행과 결과가 달라진다. 임시폴더 정리는 최상위에서 호출 뒤에 한다.
    $script:KisaTmp = $tmp
    $labels = New-Object System.Collections.ArrayList
    $jsons  = New-Object System.Collections.ArrayList
    $files  = New-Object System.Collections.ArrayList
    $webNote = ""
    if ($outDir -ne "") {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        Push-Location -LiteralPath $outDir; $script:KisaPushed = $true
    }
    $common = @{}
    if ($noColor) { $common['NoColor'] = $true }
    if ($noSave)  { $common['NoSave']  = $true }
    # 4종 결과 파일명(한 번 실행한 결과는 같은 일시) — 호스트명 정리 방식은 원본(kisa_win)과 동일
    $hostn = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', ''); if ($hostn -eq "") { $hostn = "windows" }
    $stamp = Get-Date -Format "yyyyMMdd_HHmm"

    # ---- 1) 윈도우 (인프라) ----
    if ($only -ne 'web') {
        Write-Host ""; Write-Host "######## [1] 윈도우 — 인프라 W-01~W-64 ########" -ForegroundColor $hc
        $j = Join-Path $tmp "infra.json"
        $ia = @{} + $common
        if (-not $noSave) { $ia['Csv'] = "server_windows_{0}_{1}.csv" -f $hostn, $stamp; [void]$files.Add($ia['Csv']) }
        & $infraPs -Json $j @ia | Out-Host
        [void]$labels.Add("윈도우 (인프라 W-01~64)"); [void]$jsons.Add($j)
    }

    # ---- 2) 윈도우 웹서비스 ----
    if ($only -ne 'infra') {
        $hasIis = [bool]((Test-Path "HKLM:\SOFTWARE\Microsoft\InetStp") -or (Get-Service W3SVC -ErrorAction SilentlyContinue))
        $jp = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -match '\.jar' } | Select-Object -First 1
        $kinds = @()
        if ($webArgs.Count -gt 0) {
            # 웹 옵션을 직접 준 경우 → 1회 실행. -Target 이 없으면 원본(web_windows_check.ps1)의
            # 자동 판단 규칙(java 프로세스/AppJar 있으면 tomcat, 아니면 iis)을 그대로 따른다.
            if ($webArgs.ContainsKey('Target') -and $webArgs['Target']) { $kinds = @(([string]$webArgs['Target']).ToLower()) }
            elseif ($jp -or $webArgs.ContainsKey('AppJar')) { $kinds = @('tomcat') }
            else { $kinds = @('iis') }
        } else {
            if ($hasIis) { $kinds += 'iis' }
            if ($jp) { $kinds += 'tomcat' }
            if ($kinds.Count -eq 0 -and ($forceWeb -or $only -eq 'web')) {
                Write-Host "[!] 웹서버(IIS/Java WAS)가 감지되지 않았지만 요청에 따라 기본 대상(iis)으로 점검합니다." -ForegroundColor $yc
                $kinds = @('iis')
            }
            if ($kinds.Count -eq 0) { $webNote = "웹서버(IIS/Java WAS) 미감지 → 윈도우 웹서비스 점검 생략  (강제: -ForceWeb 또는 -Target iis|tomcat)" }
        }
        foreach ($k in $kinds) {
            Write-Host ""; Write-Host ("######## [2] 윈도우 웹서비스 — {0} WEB-01~WEB-26 ########" -f $k) -ForegroundColor $hc
            $j = Join-Path $tmp ("web_{0}.json" -f $k)
            $wa = @{} + $common + $webArgs; $wa['Target'] = $k
            if (-not $noSave) {
                $wa['Csv']  = "web_windows_{0}_{1}_{2}.csv"  -f $k, $hostn, $stamp; [void]$files.Add($wa['Csv'])
                $wa['Html'] = "web_windows_{0}_{1}_{2}.html" -f $k, $hostn, $stamp; [void]$files.Add($wa['Html'])
            }
            & $webPs -Json $j @wa | Out-Host
            [void]$labels.Add(("윈도우 웹서비스 - {0} (WEB-01~26)" -f $k)); [void]$jsons.Add($j)
        }
    }

    # ---- 통합 요약 ----
    $rc = 0; $totalVuln = 0
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor $hc
    Write-Host (" 통합 요약  —  {0}  ({1})" -f $env:COMPUTERNAME, (Get-Date -Format "yyyy-MM-dd HH:mm")) -ForegroundColor $hc
    Write-Host "==============================================================" -ForegroundColor $hc
    Write-Host "   양호  취약   N/A  수동확인  구분"
    for ($n = 0; $n -lt $labels.Count; $n++) {
        $c = Get-KisaAllCount $jsons[$n]
        if ($null -eq $c) {
            Write-Host (" {0,6}{1,6}{2,6}{3,10}  {4}" -f "-", "-", "-", "-", $labels[$n])
            Write-Host "   ↳ 결과가 생성되지 않았습니다(점검 중 오류) — 위 출력 확인" -ForegroundColor $yc
            $rc = 2
        } else {
            Write-Host (" {0,6}{1,6}{2,6}{3,10}  {4}" -f $c.good, $c.vuln, $c.na, $c.man, $labels[$n])
            $totalVuln += $c.vuln
        }
    }
    if ($webNote -ne "") { Write-Host (" · {0}" -f $webNote) }
    if (-not $noSave) {
        Write-Host (" · 결과 파일 (저장 위치: {0})" -f (Get-Location).Path)
        foreach ($f in $files) {
            if (Test-Path -LiteralPath $f) { Write-Host ("     {0}" -f $f) }
            else { Write-Host ("     {0}  ← 생성 안 됨" -f $f) -ForegroundColor $yc }
        }
        Write-Host "   → 보고서: python make_reports.py <이 폴더>"
    }
    Write-Host "==============================================================" -ForegroundColor $hc
    if ($rc -ne 0) { return $rc }
    if ($totalVuln -gt 0) { return 1 }
    return 0
}

# ------------------------------------------------------------------------------
# 내장 원본 (수정 금지 — build_allinone.py 가 원본 파일에서 그대로 복사)
# ------------------------------------------------------------------------------
$script:KISA_PAYLOAD_WIN = @'
<#
==============================================================================
 KISA 주요정보통신기반시설 기술적 취약점 점검 (Windows Server)  W-01 ~ W-64
  - 보고서 양식(보고서_양식_Windows.xlsx / 3-1 시트) 의 항목·진단기준을 그대로 사용
  - 각 항목 앞 # [기준] 주석 = 양식 '진단기준' 열 내용
  - 읽기 전용(READ-ONLY): 레지스트리/정책/ACL 조회만, 변경 없음
  - 대상: Windows Server 2012 R2 / 2016 / 2019 / 2022 (Windows 10/11 도 대부분 동작)
  - 권장 실행:  powershell -ExecutionPolicy Bypass -File kisa_win_check.ps1 -Json out.json
               (관리자 권한 필요 — secedit / SAM ACL / 감사정책)

 판정 표기
   양호 / 취약 / N/A(점검 대상 없음) / 수동확인(정책·인터뷰 필요)

 GUI(kisa_gui.py) 연동: kisa_unix_check.sh 와 동일 스키마
   {"host","os","family":"windows","results":[{"code","importance","title","status","evidence":[...]}]}
==============================================================================
#>
[CmdletBinding()]
param(
    [string]$Json = "",
    [string]$Csv = "",
    [switch]$NoSave,
    [switch]$NoColor
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
try { chcp 65001 > $null 2>&1 } catch {}

$script:good = 0; $script:vuln = 0; $script:na = 0; $script:man = 0
$script:results = New-Object System.Collections.ArrayList

$IMP = @{
    "W-01"="상";"W-02"="상";"W-03"="상";"W-04"="상";"W-05"="상";"W-06"="상"
    "W-07"="중";"W-08"="중";"W-09"="상";"W-10"="중";"W-11"="중";"W-12"="중";"W-13"="중";"W-14"="중"
    "W-15"="상";"W-16"="상";"W-17"="상";"W-18"="상";"W-19"="상";"W-20"="상";"W-21"="상";"W-22"="상"
    "W-23"="상";"W-24"="상";"W-25"="상";"W-26"="상";"W-27"="상";"W-28"="중";"W-29"="중";"W-30"="중"
    "W-31"="중";"W-32"="중";"W-33"="하";"W-34"="중";"W-35"="중";"W-36"="중";"W-37"="중"
    "W-38"="상";"W-39"="상";"W-40"="중";"W-41"="중";"W-42"="하";"W-43"="중"
    "W-44"="상";"W-45"="상";"W-46"="상";"W-47"="상";"W-48"="상";"W-49"="상";"W-50"="상";"W-51"="상"
    "W-52"="상";"W-53"="상";"W-54"="중";"W-55"="중";"W-56"="중";"W-57"="하";"W-58"="중";"W-59"="중"
    "W-60"="중";"W-61"="중";"W-62"="중";"W-63"="중";"W-64"="중"
}

function Rep {
    param([string]$Code, [string]$Title, [string]$Status, [string[]]$Evidence)
    switch ($Status) {
        "GOOD" { $script:good++; $k = "양호";   $col = "Green" }
        "VULN" { $script:vuln++; $k = "취약";   $col = "Red" }
        "NA"   { $script:na++;   $k = "N/A";    $col = "Yellow" }
        "MAN"  { $script:man++;  $k = "수동확인"; $col = "Cyan" }
    }
    if ($NoColor) { Write-Host ("{0,-6} {1,-44} [{2}]" -f $Code, $Title, $k) }
    else {
        Write-Host ("{0,-6} " -f $Code) -NoNewline -ForegroundColor Cyan
        Write-Host ("{0,-44} " -f $Title) -NoNewline
        Write-Host ("[{0}]" -f $k) -ForegroundColor $col
    }
    foreach ($e in $Evidence) { Write-Host ("         - {0}" -f $e) }
    [void]$script:results.Add([pscustomobject]@{
        code = $Code; importance = $IMP[$Code]; title = $Title; status = $k; evidence = @($Evidence)
    })
}

# ---------------- 공통 헬퍼 ----------------
function RegVal { param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null } }
function SvcObj { param([string]$Name) Get-Service -Name $Name -ErrorAction SilentlyContinue }
function SvcRunning { param([string]$Name) (SvcObj $Name).Status -eq "Running" }
function FeatureInstalled { param([string]$Name)
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $f = Get-WindowsFeature -Name $Name -ErrorAction SilentlyContinue; return ($f -and $f.Installed)
    }
    return $false }
function PortListening { param([int]$Port) [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) }
function AclHasEveryone { param([string]$P)
    if (-not (Test-Path $P)) { return $null }
    try {
        $acl = Get-Acl $P -ErrorAction Stop
        foreach ($a in $acl.Access) {
            if ($a.IdentityReference.Value -in @("Everyone","모든 사람","NT AUTHORITY\Anonymous Logon") -and
                $a.AccessControlType -eq "Allow") { return $true }
        }
        return $false
    } catch { return $null }
}

$IS_ADMIN = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------- 로컬 보안 정책 (secedit) ----------------
$SEC = @{}; $PRIV = @{}
if ($IS_ADMIN) {
    $inf = Join-Path $env:TEMP ("kisa_secpol_{0}.inf" -f $PID)
    secedit /export /cfg $inf /quiet 2>$null | Out-Null
    if (Test-Path $inf) {
        $section = ""
        foreach ($line in (Get-Content $inf -Encoding Unicode -ErrorAction SilentlyContinue)) {
            $t = $line.Trim()
            if ($t -match '^\[(.+)\]$') { $section = $matches[1]; continue }
            if ($t -match '^\s*([^=]+?)\s*=\s*(.*)$') {
                if ($section -eq "Privilege Rights") { $PRIV[$matches[1].Trim()] = $matches[2].Trim() }
                else { $SEC[$matches[1].Trim()] = $matches[2].Trim() }
            }
        }
        Remove-Item $inf -Force -ErrorAction SilentlyContinue
    }
}
function SecInt { param([string]$Key) if ($SEC.ContainsKey($Key)) { try { [int]$SEC[$Key] } catch { $null } } else { $null } }
function PrivOnlyAdmin { param([string]$Key)
    $v = $PRIV[$Key]
    if ($null -eq $v) { return $null }
    $ids = ($v -replace '\*','').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $allowed = @("S-1-5-32-544","Administrators","BUILTIN\Administrators")
    foreach ($i in $ids) { if ($allowed -notcontains $i) { return $false } }
    return $true
}

# ---------------- net accounts (백업) ----------------
$NA = @{}
foreach ($line in (net accounts 2>$null)) { if ($line -match '^(.+?):\s+(.+?)\s*$') { $NA[$matches[1].Trim()] = $matches[2].Trim() } }
function NAInt { param([string]$Key)
    if ($NA.ContainsKey($Key)) {
        if ($NA[$Key] -match 'Never|없음') { return 0 }
        $m = [regex]::Match($NA[$Key], '\d+'); if ($m.Success) { return [int]$m.Value }
    }
    return $null }

# ---------------- 로컬 계정/그룹 ----------------
function LocalUsers {
    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) { return Get-LocalUser -ErrorAction SilentlyContinue }
    return Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction SilentlyContinue
}
function GroupMembers { param([string]$Sid)
    try {
        if (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue) {
            return @(Get-LocalGroupMember -SID $Sid -ErrorAction Stop | ForEach-Object { $_.Name })
        }
    } catch {}
    return @()
}
function UserEnabled { param($u)
    if ($u.PSObject.Properties.Name -contains "Enabled") { return $u.Enabled }
    return (-not $u.Disabled)
}

$IIS_ON = [bool]((SvcObj "W3SVC") -and (FeatureInstalled "Web-Server"))
function IISProp { param([string]$Filter, [string]$Name)
    try { Import-Module WebAdministration -ErrorAction Stop
          return (Get-WebConfigurationProperty -Filter $Filter -Name $Name -ErrorAction Stop).Value } catch { return $null } }

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$OS_NAME = if ($os) { $os.Caption.Trim() } else { "Windows" }
$OS_BUILD = if ($os) { [int]$os.BuildNumber } else { 0 }
$HOSTN = $env:COMPUTERNAME

Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host " KISA Windows 취약점 점검 (W-01~W-64)  READ-ONLY" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host (" 호스트 : {0}" -f $HOSTN)
Write-Host (" OS     : {0}  (Build {1})" -f $OS_NAME, $OS_BUILD)
Write-Host (" 시각   : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
if (-not $IS_ADMIN) { Write-Host " 주의: 관리자 권한이 아니어서 보안정책/SAM/감사정책 등 일부 항목이 '수동확인'으로 표기됩니다." -ForegroundColor Yellow }
Write-Host ""

#==============================================================================
Write-Host "[ 1. 계정 관리 ]" -ForegroundColor White
#==============================================================================

# W-01 Administrator 계정 이름 변경 등 보안성 강화
# [기준] 양호 - 기본 계정 이름을 변경하거나 강화된 비밀번호를 적용 / 취약 - 미변경 + 단순 비밀번호
$adminAcct = LocalUsers | Where-Object { ($_.SID.Value) -like "*-500" } | Select-Object -First 1
$adminName = if ($adminAcct) { $adminAcct.Name } else { ($SEC["NewAdministratorName"] -replace '"','') }
if ($adminName -and $adminName -ne "Administrator") {
    Rep "W-01" "Administrator 계정 이름 변경 등 보안성 강화" "GOOD" @("기본 관리자 계정 이름 = '$adminName' (변경됨)")
} elseif ($adminName -eq "Administrator") {
    Rep "W-01" "Administrator 계정 이름 변경 등 보안성 강화" "MAN" @("기본 관리자 계정 이름이 'Administrator' 그대로 → 이름 변경 또는 복잡도 높은 비밀번호 적용 여부(인터뷰) 확인")
} else {
    Rep "W-01" "Administrator 계정 이름 변경 등 보안성 강화" "MAN" @("관리자 계정 이름 확인 불가 → 관리자 권한으로 재점검")
}

# W-02 Guest 계정 비활성화
# [기준] 양호 - Guest 계정 비활성화 / 취약 - 활성화
$guest = LocalUsers | Where-Object { ($_.SID.Value) -like "*-501" } | Select-Object -First 1
if (-not $guest) { Rep "W-02" "Guest 계정 비활성화" "GOOD" @("Guest 계정 없음") }
elseif (UserEnabled $guest) { Rep "W-02" "Guest 계정 비활성화" "VULN" @("Guest 계정($($guest.Name)) 활성화됨 → 비활성화 필요") }
else { Rep "W-02" "Guest 계정 비활성화" "GOOD" @("Guest 계정($($guest.Name)) 비활성화됨") }

# W-03 불필요한 계정 제거
# [기준] 양호 - 불필요한 계정 없음 / 취약 - 존재
$users = @(LocalUsers)
$susp = @()
foreach ($u in $users) {
    if (($u.SID.Value) -like "*-500" -or ($u.SID.Value) -like "*-501") { continue }
    if ($u.Name -in @("DefaultAccount","WDAGUtilityAccount")) { continue }
    if ((UserEnabled $u) -and -not $u.LastLogon) { $susp += "$($u.Name)(로그온이력없음)" }
}
if ($susp.Count -gt 0) { Rep "W-03" "불필요한 계정 제거" "VULN" @("사용 흔적 없는 활성 계정: $($susp -join ', ') → 미사용이면 삭제/비활성화") }
else { Rep "W-03" "불필요한 계정 제거" "MAN" @("로컬 계정: $(($users | ForEach-Object { $_.Name }) -join ', ')", "각 계정의 필요성은 관리자 확인") }

# W-04 계정 잠금 임계값 설정
# [기준] 양호 - 계정 잠금 임계값 5 이하 / 취약 - 5 초과 (0=제한없음도 취약)
$lc = SecInt "LockoutBadCount"; if ($null -eq $lc) { $lc = NAInt "잠금 임계값"; if ($null -eq $lc) { $lc = NAInt "Lockout threshold" } }
if ($null -ne $lc -and $lc -ge 1 -and $lc -le 5) { Rep "W-04" "계정 잠금 임계값 설정" "GOOD" @("계정 잠금 임계값 = $lc 회 (5 이하)") }
else { Rep "W-04" "계정 잠금 임계값 설정" "VULN" @("계정 잠금 임계값 = $(if($null -eq $lc){'확인불가'}elseif($lc -eq 0){'0(제한없음)'}else{"$lc"}) (기준: 1~5회)") }

# W-05 해독 가능한 암호화를 사용하여 암호 저장 해제
# [기준] 양호 - "사용 안 함"(0) / 취약 - "사용"(1)
$ct = SecInt "ClearTextPassword"
if ($null -eq $ct) { Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장 해제" "MAN" @("ClearTextPassword 확인 불가 (관리자 권한 필요)") }
elseif ($ct -eq 0) { Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장 해제" "GOOD" @("역호환 암호화 저장 = 사용 안 함") }
else { Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장 해제" "VULN" @("역호환 암호화 저장 = 사용 → 사용 안 함으로 변경") }

# W-06 관리자 그룹에 최소한의 사용자 포함
# [기준] 양호 - Administrators 구성원 1명 이하 또는 불필요한 관리자 계정 없음 / 취약 - 불필요한 관리자 계정 존재
$admins = @(GroupMembers "S-1-5-32-544") | Where-Object { $_ }
if ($admins.Count -le 1) { Rep "W-06" "관리자 그룹에 최소한의 사용자 포함" "GOOD" @("Administrators 그룹 구성원($($admins.Count)명): $($admins -join ', ')") }
else { Rep "W-06" "관리자 그룹에 최소한의 사용자 포함" "MAN" @("Administrators 그룹 구성원($($admins.Count)명): $($admins -join ', ')", "각 구성원의 관리자 권한 필요성 확인") }

# W-07 Everyone 사용 권한을 익명 사용자에게 적용
# [기준] 양호 - "사용 안 함"(EveryoneIncludesAnonymous=0) / 취약 - "사용"(1)
$eia = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "EveryoneIncludesAnonymous"
if ($eia -eq 0) { Rep "W-07" "Everyone 사용 권한을 익명 사용자에게 적용" "GOOD" @("EveryoneIncludesAnonymous = 0 (익명에 Everyone 권한 미적용)") }
elseif ($null -eq $eia) { Rep "W-07" "Everyone 사용 권한을 익명 사용자에게 적용" "MAN" @("EveryoneIncludesAnonymous 값 없음 → 정책 확인") }
else { Rep "W-07" "Everyone 사용 권한을 익명 사용자에게 적용" "VULN" @("EveryoneIncludesAnonymous = $eia → '사용 안 함'으로 설정") }

# W-08 계정 잠금 기간 설정
# [기준] 양호 - 계정 잠금 기간 및 원래대로 설정 기간이 60분 이상 / 취약 - 미설정 또는 60분 미만
$ld = SecInt "LockoutDuration"; if ($null -eq $ld) { $ld = NAInt "잠금 기간(분)" }
$rl = SecInt "ResetLockoutCount"; if ($null -eq $rl) { $rl = NAInt "잠금 수를 다음 시간 후 원래대로 설정(분)" }
if ($null -ne $ld -and $ld -ge 60 -and $null -ne $rl -and $rl -ge 60) {
    Rep "W-08" "계정 잠금 기간 설정" "GOOD" @("계정 잠금 기간 = $ld 분, 원래대로 설정 기간 = $rl 분 (모두 60분 이상)")
} else {
    Rep "W-08" "계정 잠금 기간 설정" "VULN" @("계정 잠금 기간 = $ld 분, 원래대로 설정 기간 = $rl 분 (기준: 모두 60분 이상)")
}

# W-09 비밀번호 관리정책 설정
# [기준] 양호 - 복잡성/최소길이/최대·최소 사용기간/암호 기록 모두 적용 / 취약 - 일부 미적용
$pc = SecInt "PasswordComplexity"
$ml = SecInt "MinimumPasswordLength"; if ($null -eq $ml) { $ml = NAInt "최소 암호 길이" }
$mxa = SecInt "MaximumPasswordAge"; if ($null -eq $mxa) { $mxa = NAInt "최대 암호 사용 기간(일)" }
$mna = SecInt "MinimumPasswordAge"; if ($null -eq $mna) { $mna = NAInt "최소 암호 사용 기간(일)" }
$ph  = SecInt "PasswordHistorySize"; if ($null -eq $ph) { $ph = NAInt "암호 기록 유지" }
$miss = @()
if ($pc -ne 1) { $miss += "복잡성(미사용)" }
if ($null -eq $ml -or $ml -lt 8) { $miss += "최소길이($ml/기준 8)" }
if ($null -eq $mxa -or $mxa -lt 1 -or $mxa -gt 90) { $miss += "최대사용기간($(if($mxa -eq 0){'무제한'}else{$mxa})/기준 1~90)" }
if ($null -eq $mna -or $mna -lt 1) { $miss += "최소사용기간($mna/기준 1이상)" }
if ($null -eq $ph -or $ph -lt 4) { $miss += "암호기록($ph/기준 4)" }
if ($miss.Count -eq 0) { Rep "W-09" "비밀번호 관리정책 설정" "GOOD" @("복잡성 사용, 최소길이 $ml, 최대 $mxa 일, 최소 $mna 일, 기록 $ph 개") }
elseif ($null -eq $pc -and $null -eq $ml) { Rep "W-09" "비밀번호 관리정책 설정" "MAN" @("보안정책 확인 불가 (관리자 권한 필요)") }
else { Rep "W-09" "비밀번호 관리정책 설정" "VULN" @("미흡: $($miss -join ', ')") }

# W-10 마지막 사용자 이름 표시 안 함
# [기준] 양호 - "사용"(DontDisplayLastUserName=1) / 취약 - "사용 안 함"(0)
$dl = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DontDisplayLastUserName"
if ($dl -eq 1) { Rep "W-10" "마지막 사용자 이름 표시 안 함" "GOOD" @("DontDisplayLastUserName = 1") }
elseif ($null -eq $dl) { Rep "W-10" "마지막 사용자 이름 표시 안 함" "MAN" @("값 없음 → 정책 확인") }
else { Rep "W-10" "마지막 사용자 이름 표시 안 함" "VULN" @("DontDisplayLastUserName = $dl → '사용'으로 설정") }

# W-11 로컬 로그온 허용
# [기준] 양호 - Administrators, IUSR_ 만 존재 / 취약 - 그 외 계정/그룹 존재
$il = $PRIV["SeInteractiveLogonRight"]
if ($il -and $il -notmatch 'S-1-1-0|S-1-5-11|S-1-5-32-545|Everyone|Users|Authenticated Users') {
    Rep "W-11" "로컬 로그온 허용" "GOOD" @("로컬 로그온 허용 대상: $il (Users/Everyone 미포함)")
} elseif ($null -eq $il) {
    Rep "W-11" "로컬 로그온 허용" "MAN" @("SeInteractiveLogonRight 확인 불가 (관리자 권한 필요)")
} else {
    Rep "W-11" "로컬 로그온 허용" "VULN" @("로컬 로그온 허용에 Users/Everyone 등 포함: $il")
}

# W-12 익명 SID/이름 변환 허용 해제
# [기준] 양호 - "사용 안 함" / 취약 - "사용"
$lsl = SecInt "LSAAnonymousNameLookup"
if ($lsl -eq 0) { Rep "W-12" "익명 SID/이름 변환 허용 해제" "GOOD" @("익명 SID/이름 변환 허용 = 사용 안 함") }
elseif ($null -eq $lsl) { Rep "W-12" "익명 SID/이름 변환 허용 해제" "MAN" @("LSAAnonymousNameLookup 확인 불가") }
else { Rep "W-12" "익명 SID/이름 변환 허용 해제" "VULN" @("익명 SID/이름 변환 허용 = 사용 → 사용 안 함으로 변경") }

# W-13 콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한
# [기준] 양호 - "사용"(LimitBlankPasswordUse=1) / 취약 - "사용 안 함"(0)
$lb = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LimitBlankPasswordUse"
if ($lb -eq 1) { Rep "W-13" "콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한" "GOOD" @("LimitBlankPasswordUse = 1") }
elseif ($null -eq $lb) { Rep "W-13" "콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한" "MAN" @("값 없음 → 정책 확인") }
else { Rep "W-13" "콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한" "VULN" @("LimitBlankPasswordUse = $lb → '사용'으로 설정") }

# W-14 원격터미널 접속 가능한 사용자 그룹 제한
# [기준] 양호 - 관리자 외 원격 접속 전용 계정 존재 + 불필요 계정 미등록 / 취약 - 별도 계정 없음
$rdu = @(GroupMembers "S-1-5-32-555")
Rep "W-14" "원격터미널 접속 가능한 사용자 그룹 제한" "MAN" @("Remote Desktop Users 구성원: $(if($rdu.Count){$rdu -join ', '}else{'없음(Administrators만 RDP 가능)'})", "관리자 외 RDP 전용 계정 운영 정책 확인")

#==============================================================================
Write-Host "[ 2. 서비스 관리 ]" -ForegroundColor White
#==============================================================================

# W-15 사용자 개인키 사용 시 암호 입력
# [기준] 양호 - 개인 키 사용 시마다 암호 입력 / 취약 - 안 받음
$fkp = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Cryptography" "ForceKeyProtection"
if ($fkp -eq 2) { Rep "W-15" "사용자 개인키 사용 시 암호 입력" "GOOD" @("ForceKeyProtection = 2 (개인 키 사용 시 항상 암호 요구)") }
else { Rep "W-15" "사용자 개인키 사용 시 암호 입력" "MAN" @("ForceKeyProtection = $fkp → 인증서 개인 키 보호 수준(사용 시 암호 요구) 수동 확인") }

# W-16 공유 권한 및 사용자 그룹 설정
# [기준] 양호 - 일반 공유 없음 또는 Everyone 권한 없음 / 취약 - Everyone 권한 있는 공유 존재
$shares = @(Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 0 -and $_.Name -notmatch '\$$' })
$everyoneShare = @()
foreach ($s in $shares) {
    try {
        $ss = Get-CimInstance -ClassName Win32_LogicalShareSecuritySetting -Filter "Name='$($s.Name)'" -ErrorAction Stop
        $sd = $ss | Invoke-CimMethod -MethodName GetSecurityDescriptor
        foreach ($ace in $sd.Descriptor.DACL) {
            if ($ace.Trustee.Name -in @("Everyone","모든 사람")) { $everyoneShare += $s.Name }
        }
    } catch {}
}
if ($shares.Count -eq 0) { Rep "W-16" "공유 권한 및 사용자 그룹 설정" "GOOD" @("사용자 정의 공유 없음") }
elseif ($everyoneShare.Count -gt 0) { Rep "W-16" "공유 권한 및 사용자 그룹 설정" "VULN" @("Everyone 권한이 부여된 공유: $($everyoneShare -join ', ')") }
else { Rep "W-16" "공유 권한 및 사용자 그룹 설정" "GOOD" @("공유($($shares.Name -join ', '))에 Everyone 권한 없음") }

# W-17 하드디스크 기본 공유 제거
# [기준] 양호 - AutoShareServer(AutoShareWks)=0 AND 기본 공유 없음 / 취약 - =1 또는 기본 공유 존재
$as = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "AutoShareServer"
if ($null -eq $as) { $as = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "AutoShareWks" }
$admShares = @(Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\$$' -and $_.Name -ne 'IPC$' } | ForEach-Object { $_.Name })
if ($as -eq 0 -and $admShares.Count -eq 0) { Rep "W-17" "하드디스크 기본 공유 제거" "GOOD" @("AutoShareServer=0, 기본 관리 공유 없음") }
else { Rep "W-17" "하드디스크 기본 공유 제거" "VULN" @("AutoShareServer=$as, 기본 공유: $(if($admShares.Count){$admShares -join ', '}else{'없음'}) → AutoShareServer=0 설정 및 공유 제거") }

# W-18 불필요한 서비스 제거
# [기준] 양호 - 일반적으로 불필요한 서비스(가이드 목록)가 중지 / 취약 - 구동 중
#   가이드 목록: Alerter, Clipbook(ClipSrv), Computer Browser(Browser), Distributed Link Tracking(TrkWks/TrkSvr),
#     Error Reporting(WerSvc/ERSvc), HID(hidserv), IMAPI CD-Burning(ImapiService), Infrared Monitor(Irmon), Messenger,
#     NetMeeting RDS(mnmsrvc), Portable Media Serial Number(WmdmPmSN), Print Spooler, Remote Registry, Simple TCP/IP(simptcp),
#     UPnP Device Host(upnphost), Wireless Zero Configuration(WZCSVC/WlanSvc)  + 기존 점검 대상(SharedAccess/Telnet/SNMPTRAP/Fax/SSDPSRV/RemoteAccess)
#   가이드 조건: TrkWks/TrkSvr 는 AD(도메인) 미구성 시, Print Spooler 는 연결된 프린터가 없을 때만 불필요 → 조건 밖이면 판정 제외(참고 표기)
#   Automatic Updates·Cryptographic Services·DHCP/DNS Client 는 가이드도 조건부로 적은 OS 필수 구성요소라 판정 제외
#   ※ 서비스명 정확 일치 + Win32 서비스만 인정 (Get-Service -Name Browser 는 표시 이름이 'Browser' 인 커널 드라이버 bowser 도 반환 → 제외)
$risky = @("Alerter","ClipSrv","Browser","TrkWks","TrkSvr","WerSvc","ERSvc","hidserv","ImapiService","Irmon","Messenger","mnmsrvc","WmdmPmSN",
           "Spooler","RemoteRegistry","simptcp","upnphost","WZCSVC","WlanSvc",
           "SharedAccess","TlntSvr","Telnet","SNMPTRAP","Fax","SSDPSRV","RemoteAccess")
$running = @(); $cond18 = @()
foreach ($n in $risky) {
    $s = @(Get-Service -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $n -and "$($_.ServiceType)" -notmatch 'Driver' }) | Select-Object -First 1
    if (-not $s -or $s.Status -ne "Running") { continue }
    if ($n -in @("TrkWks","TrkSvr") -and (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).PartOfDomain) { $cond18 += "$n(도메인 가입 - AD 사용 시 필요)"; continue }
    if ($n -eq "Spooler") {
        $prn18 = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object {
                     "$($_.PortName)" -notmatch '^(PORTPROMPT:|nul:|XPSPort:|SHRFAX:|FILE:)$' -and "$($_.Name)" -notmatch 'Microsoft (Print to PDF|XPS Document Writer)|^Fax$|OneNote' })
        if ($prn18.Count -gt 0) { $cond18 += "Spooler(연결된 프린터 $($prn18.Count)개 - 필요 서비스)"; continue }
    }
    $running += $n
}
$cond18Ev = @($cond18 | ForEach-Object { "판정 제외(가이드 조건상 필요): $_" })
if ($running.Count -eq 0) { Rep "W-18" "불필요한 서비스 제거" "GOOD" (@("가이드 목록의 불필요 서비스(Alerter/Browser/Spooler/RemoteRegistry/TrkWks/upnphost/WerSvc 등) 미실행") + $cond18Ev) }
else { Rep "W-18" "불필요한 서비스 제거" "VULN" (@("실행 중인 불필요 서비스: $($running -join ', ') → 미사용 시 중지/사용 안 함") + $cond18Ev) }

# W-19 불필요한 IIS 서비스 구동 점검
# [기준] 양호 - IIS 미사용 또는 필요에 의해 사용 / 취약 - 불필요하게 사용
if (-not $IIS_ON) { Rep "W-19" "불필요한 IIS 서비스 구동 점검" "GOOD" @("IIS(W3SVC) 미설치/미실행") }
else { Rep "W-19" "불필요한 IIS 서비스 구동 점검" "MAN" @("IIS 실행 중 → 웹 서버 용도가 맞는지 확인 (불필요 시 제거)") }

# W-20 NetBIOS 바인딩 서비스 구동 점검
# [기준] 양호 - TCP/IP-NetBIOS 바인딩 제거 / 취약 - 미제거
$nbt = $false
try { foreach ($a in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True")) { if ($a.TcpipNetbiosOptions -ne 2) { $nbt = $true } } } catch { $nbt = $true }
if ($nbt) { Rep "W-20" "NetBIOS 바인딩 서비스 구동 점검" "VULN" @("일부 인터페이스에서 NetBIOS over TCP/IP 활성 → '사용 안 함'으로 설정") }
else { Rep "W-20" "NetBIOS 바인딩 서비스 구동 점검" "GOOD" @("모든 인터페이스에서 NetBIOS over TCP/IP 비활성") }

# --- FTP (W-21, W-22, W-24) / 공유 익명(W-23) ---
$FTP_ON = [bool]((SvcRunning "FTPSVC") -or (SvcRunning "MSFTPSVC") -or (PortListening 21))
$ftpTls = IISProp "/system.applicationHost/sites/site/ftpServer/security/ssl" "controlChannelPolicy"

# W-21 암호화되지 않는 FTP 서비스 비활성화
# [기준] 양호 - FTP 미사용 또는 Secure FTP 사용 / 취약 - 평문 FTP 사용
if (-not $FTP_ON) { Rep "W-21" "암호화되지 않는 FTP 서비스 비활성화" "GOOD" @("FTP 서비스 미실행") }
elseif ("$ftpTls" -match "Require|SslRequire") { Rep "W-21" "암호화되지 않는 FTP 서비스 비활성화" "GOOD" @("FTP 실행 중이나 SSL/TLS 필수 설정") }
else { Rep "W-21" "암호화되지 않는 FTP 서비스 비활성화" "VULN" @("평문 FTP(21) 실행 중 (SSL 필수 아님) → SFTP/FTPS 로 전환") }

# W-22 FTP 디렉토리 접근권한 설정
# [기준] 양호 - FTP 홈 디렉터리에 Everyone 권한 없음 / 취약 - Everyone 권한 있음
if (-not $FTP_ON) { Rep "W-22" "FTP 디렉토리 접근권한 설정" "NA" @("FTP 미실행") }
else { Rep "W-22" "FTP 디렉토리 접근권한 설정" "MAN" @("FTP 홈 디렉터리 권한(Everyone 쓰기 금지) 수동 확인") }

# W-23 공유 서비스에 대한 익명 접근 제한 설정
# [기준] 양호 - 공유 서비스 미사용 또는 익명 인증 사용 안 함 / 취약 - 익명 인증 사용
$ftpAnon = IISProp "/system.ftpServer/security/authentication/anonymousAuthentication" "enabled"
$iisAnon = IISProp "/system.webServer/security/authentication/anonymousAuthentication" "enabled"
if (-not $FTP_ON -and -not $IIS_ON) { Rep "W-23" "공유 서비스에 대한 익명 접근 제한 설정" "GOOD" @("FTP/IIS 미사용") }
elseif ($ftpAnon -eq $true) { Rep "W-23" "공유 서비스에 대한 익명 접근 제한 설정" "VULN" @("FTP 익명 인증 활성화됨") }
elseif ($iisAnon -eq $true -and $FTP_ON) { Rep "W-23" "공유 서비스에 대한 익명 접근 제한 설정" "MAN" @("IIS 익명 인증 활성 → 웹 공개 콘텐츠용인지 확인") }
else { Rep "W-23" "공유 서비스에 대한 익명 접근 제한 설정" "GOOD" @("FTP 익명 인증 비활성") }

# W-24 FTP 접근 제어 설정
# [기준] 양호 - 특정 IP 주소에서만 접속하도록 접근 제어 적용 / 취약 - 미적용
if (-not $FTP_ON) { Rep "W-24" "FTP 접근 제어 설정" "NA" @("FTP 미실행") }
else {
    $ipsec = IISProp "/system.ftpServer/security/ipSecurity" "allowUnlisted"
    if ($ipsec -eq $false) { Rep "W-24" "FTP 접근 제어 설정" "GOOD" @("ipSecurity allowUnlisted=false (허용 목록 방식)") }
    else { Rep "W-24" "FTP 접근 제어 설정" "VULN" @("FTP IP 주소 제한(ipSecurity) 미적용") }
}

# W-25 DNS Zone Transfer 설정
# [기준] 양호 - DNS 비활성 / 영역 전송 안 함 / 특정 서버로만 / 취약 - 그 외
$DNS_ON = [bool]((SvcRunning "DNS") -and (FeatureInstalled "DNS"))
if (-not $DNS_ON) { Rep "W-25" "DNS Zone Transfer 설정" "GOOD" @("DNS 서버 역할 미사용") }
else {
    $anyXfer = @()
    try { Import-Module DnsServer -ErrorAction Stop
          foreach ($z in (Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq "Primary" })) {
              if ($z.SecureSecondaries -eq "TransferAnyServer") { $anyXfer += $z.ZoneName }
          } } catch {}
    if ($anyXfer.Count -gt 0) { Rep "W-25" "DNS Zone Transfer 설정" "VULN" @("모든 서버로 영역 전송 허용: $($anyXfer -join ', ')") }
    else { Rep "W-25" "DNS Zone Transfer 설정" "GOOD" @("영역 전송이 제한(특정 서버만/안 함)됨") }
}

# W-26 RDS(Remote Data Services) 제거
# [기준] 양호 - IIS 미사용 / Win2008 이상 / MSADC 가상디렉토리 없음 / 관련 레지스트리 없음 중 하나 이상
$rdsKeys = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\RDSServer.DataFactory",
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\AdvancedDataFactory",
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\VbBusObj.VbBusObjCls")
if (-not $IIS_ON) { Rep "W-26" "RDS(Remote Data Services) 제거" "GOOD" @("IIS 미사용 → RDS 위협 없음") }
elseif ($OS_BUILD -ge 6001) { Rep "W-26" "RDS(Remote Data Services) 제거" "GOOD" @("Windows Server 2008 이상 (Build $OS_BUILD) → 기본적으로 RDS 미포함") }
elseif (@($rdsKeys | Where-Object { Test-Path $_ }).Count -eq 0) { Rep "W-26" "RDS(Remote Data Services) 제거" "GOOD" @("RDS ADCLaunch 레지스트리 없음") }
else { Rep "W-26" "RDS(Remote Data Services) 제거" "VULN" @("RDS 관련 레지스트리 존재 → 제거 필요") }

# W-27 최신 Windows OS Build 버전 적용
$hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
$hfDate = if ($hf) { $hf.InstalledOn.ToString("yyyy-MM-dd") } else { "확인불가" }
Rep "W-27" "최신 Windows OS Build 버전 적용" "MAN" @("OS: $OS_NAME (Build $OS_BUILD), 최근 업데이트: $($hf.HotFixID) ($hfDate)", "최신 누적 업데이트 적용 및 패치 절차 수립 여부(인터뷰) 확인")

# W-28 터미널 서비스 암호화 수준 설정
# [기준] 양호 - RDP 미사용 또는 암호화 "클라이언트와 호환 가능(중간)" 이상 / 취약 - "낮음"
$rdpDeny = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections"
$rdpEnc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "MinEncryptionLevel"
if ($rdpDeny -eq 1) { Rep "W-28" "터미널 서비스 암호화 수준 설정" "GOOD" @("원격 데스크톱 연결 비활성(fDenyTSConnections=1)") }
elseif ($rdpEnc -ge 2) { Rep "W-28" "터미널 서비스 암호화 수준 설정" "GOOD" @("RDP MinEncryptionLevel = $rdpEnc (중간 이상)") }
elseif ($null -eq $rdpEnc) { Rep "W-28" "터미널 서비스 암호화 수준 설정" "MAN" @("RDP MinEncryptionLevel 값 없음 → 정책 확인") }
else { Rep "W-28" "터미널 서비스 암호화 수준 설정" "VULN" @("RDP MinEncryptionLevel = $rdpEnc (낮음) → 중간 이상으로 설정") }

# --- SNMP (W-29 ~ W-31) ---
$SNMP_ON = [bool](SvcObj "SNMP")
$comm = @(); try { $comm = (Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\ValidCommunities" -ErrorAction Stop).Property } catch {}

# W-29 불필요한 SNMP 서비스 구동 점검
# [기준] 양호 - SNMP 미사용 또는 Community String 설정하여 사용 / 취약 - 불필요하게 사용
if (-not $SNMP_ON) { Rep "W-29" "불필요한 SNMP 서비스 구동 점검" "GOOD" @("SNMP 서비스 미설치/미실행") }
elseif ($comm.Count -gt 0) { Rep "W-29" "불필요한 SNMP 서비스 구동 점검" "MAN" @("SNMP 사용 중 (Community 설정됨) → 업무상 필요 여부 확인") }
else { Rep "W-29" "불필요한 SNMP 서비스 구동 점검" "VULN" @("SNMP 서비스 실행/설치됨 → 미사용 시 제거") }

# W-30 SNMP Community String 복잡성 설정
# [기준] 양호 - SNMP 미사용 또는 Community String 이 public/private 아님 / 취약 - public/private
if (-not $SNMP_ON) { Rep "W-30" "SNMP Community String 복잡성 설정" "GOOD" @("SNMP 미사용") }
elseif ($comm -contains "public" -or $comm -contains "private") { Rep "W-30" "SNMP Community String 복잡성 설정" "VULN" @("Community String 에 public/private 사용: $($comm -join ', ')") }
elseif ($comm.Count -gt 0) { Rep "W-30" "SNMP Community String 복잡성 설정" "GOOD" @("Community String 이 기본값(public/private) 아님") }
else { Rep "W-30" "SNMP Community String 복잡성 설정" "MAN" @("Community String 확인 불가") }

# W-31 SNMP Access control 설정
# [기준] 양호 - SNMP 미사용 또는 특정 호스트로부터만 수신 / 취약 - 모든 호스트 허용
if (-not $SNMP_ON) { Rep "W-31" "SNMP Access control 설정" "GOOD" @("SNMP 미사용") }
else {
    $mgr = @(); try { $mgr = (Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\PermittedManagers" -ErrorAction Stop).Property } catch {}
    if ($mgr.Count -gt 0) { Rep "W-31" "SNMP Access control 설정" "GOOD" @("허용 관리자(PermittedManagers) $($mgr.Count)개 지정") }
    else { Rep "W-31" "SNMP Access control 설정" "VULN" @("모든 호스트로부터 SNMP 패킷 수신 허용") }
}

# W-32 DNS 서비스 구동 점검
# [기준] 양호 - DNS 미사용 또는 동적 업데이트 "없음" / 취약 - 사용 + 동적 업데이트 설정
if (-not $DNS_ON) { Rep "W-32" "DNS 서비스 구동 점검" "GOOD" @("DNS 서버 역할 미사용") }
else {
    $dyn = @()
    try { Import-Module DnsServer -ErrorAction Stop
          foreach ($z in (Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq "Primary" })) {
              if ($z.DynamicUpdate -ne "None") { $dyn += "$($z.ZoneName)($($z.DynamicUpdate))" }
          } } catch {}
    if ($dyn.Count -eq 0) { Rep "W-32" "DNS 서비스 구동 점검" "GOOD" @("모든 주 영역의 동적 업데이트 = 없음") }
    else { Rep "W-32" "DNS 서비스 구동 점검" "VULN" @("동적 업데이트 활성 영역: $($dyn -join ', ')") }
}

# W-33 HTTP/FTP/SMTP 배너 차단
# [기준] 양호 - 배너 정보 미노출 / 취약 - 노출
$rmSrvHdr = IISProp "/system.webServer/security/requestFiltering" "removeServerHeader"
if (-not $IIS_ON -and -not $FTP_ON -and -not (SvcRunning "SMTPSVC")) {
    Rep "W-33" "HTTP/FTP/SMTP 배너 차단" "NA" @("HTTP/FTP/SMTP 서비스 미실행")
} elseif ($IIS_ON -and $rmSrvHdr -ne $true) {
    Rep "W-33" "HTTP/FTP/SMTP 배너 차단" "VULN" @("IIS removeServerHeader != true → HTTP 응답에 Server 헤더로 IIS 버전 노출")
} else {
    Rep "W-33" "HTTP/FTP/SMTP 배너 차단" "MAN" @("운영 중 서비스의 응답 배너에서 제품/버전 노출 여부 수동 확인 (FTP messages, SMTP banner 등)")
}

# W-34 Telnet 서비스 비활성화
# [기준] 양호 - Telnet 미구동 또는 인증 방법 NTLM / 취약 - 구동 + 인증 NTLM 아님
if (-not (SvcRunning "TlntSvr") -and -not (PortListening 23)) {
    Rep "W-34" "Telnet 서비스 비활성화" "GOOD" @("Telnet 서버 미실행")
} else {
    $tnlm = RegVal "HKLM:\SOFTWARE\Microsoft\TelnetServer\1.0" "NTLM"
    if ($tnlm -ge 2) { Rep "W-34" "Telnet 서비스 비활성화" "MAN" @("Telnet 실행 중이나 인증=NTLM($tnlm) → SSH/RDP 대체 권장") }
    else { Rep "W-34" "Telnet 서비스 비활성화" "VULN" @("Telnet 서버 실행 중 + 인증 NTLM 아님 → 비활성화 필요") }
}

# W-35 불필요한 ODBC/OLE-DB 데이터 소스와 드라이브 제거
# [기준] 양호 - 시스템 DSN 데이터 소스를 현재 사용 중 / 취약 - 사용하지 않는 DSN 존재
$dsn = @()
try { $dsn = (Get-ChildItem "HKLM:\SOFTWARE\ODBC\ODBC.INI" -ErrorAction Stop | Where-Object { $_.PSChildName -ne "ODBC Data Sources" } | ForEach-Object { $_.PSChildName }) } catch {}
if ($dsn.Count -eq 0) { Rep "W-35" "불필요한 ODBC/OLE-DB 데이터 소스와 드라이브 제거" "GOOD" @("시스템 ODBC DSN 없음") }
else { Rep "W-35" "불필요한 ODBC/OLE-DB 데이터 소스와 드라이브 제거" "MAN" @("시스템 ODBC DSN: $($dsn -join ', ') → 미사용 항목/평문 자격증명 제거 여부 확인") }

# W-36 원격터미널 접속 타임아웃 설정
# [기준] 양호 - Timeout 30분 이하 / 취약 - 미적용 또는 30분 초과
$idleP = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" "MaxIdleTime"
if ($null -eq $idleP) { $idleP = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "MaxIdleTime" }
if ($idleP -and $idleP -gt 0 -and $idleP -le 1800000) { Rep "W-36" "원격터미널 접속 타임아웃 설정" "GOOD" @("RDP 유휴 세션 제한 = $([math]::Round($idleP/60000)) 분 (30분 이하)") }
else { Rep "W-36" "원격터미널 접속 타임아웃 설정" "VULN" @("RDP 유휴 세션 제한 = $(if($idleP){[math]::Round($idleP/60000)}else{'미설정'}) → 30분 이하로 설정") }

# W-37 예약된 작업에 의심스러운 명령이 등록되어 있는지 점검
$tasks = @()
try { $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' -and $_.State -ne "Disabled" } | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" } } catch {}
if ($tasks.Count -eq 0) { Rep "W-37" "예약된 작업에 의심스러운 명령이 등록되어 있는지 점검" "GOOD" @("사용자 정의 활성 예약 작업 없음") }
else { Rep "W-37" "예약된 작업에 의심스러운 명령이 등록되어 있는지 점검" "MAN" @("사용자 정의 예약 작업($($tasks.Count)개): $(($tasks | Select-Object -First 10) -join ', ')", "각 작업의 실행 명령/등록 경위 확인") }

#==============================================================================
Write-Host "[ 3. 패치 관리 ]" -ForegroundColor White
#==============================================================================

# W-38 주기적 보안 패치 및 벤더 권고사항 적용
$daysAgo = if ($hf) { (New-TimeSpan -Start $hf.InstalledOn -End (Get-Date)).Days } else { 9999 }
if ($daysAgo -le 90) { Rep "W-38" "주기적 보안 패치 및 벤더 권고사항 적용" "MAN" @("최근 업데이트: $($hf.HotFixID) ($hfDate, ${daysAgo}일 전)", "패치 절차 수립 및 정기 적용 여부(인터뷰) 확인") }
else { Rep "W-38" "주기적 보안 패치 및 벤더 권고사항 적용" "VULN" @("최근 업데이트 $hfDate (약 ${daysAgo}일 전) → 90일 이상 미적용, 누적/보안 패치 적용 필요") }

# W-39 백신 프로그램 업데이트
$av = $null; try { $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop } catch {}
$def = $null; try { $def = Get-MpComputerStatus -ErrorAction Stop } catch {}
if ($def -and $def.AntivirusEnabled) {
    $sigOld = ($def.AntivirusSignatureLastUpdated -and (New-TimeSpan -Start $def.AntivirusSignatureLastUpdated -End (Get-Date)).Days -gt 7)
    if ($sigOld) { Rep "W-39" "백신 프로그램 업데이트" "VULN" @("Defender 서명 최종 업데이트: $($def.AntivirusSignatureLastUpdated) (7일 초과)") }
    else { Rep "W-39" "백신 프로그램 업데이트" "GOOD" @("Defender 실시간 보호 활성, 서명 $($def.AntivirusSignatureLastUpdated)") }
} elseif ($av) {
    Rep "W-39" "백신 프로그램 업데이트" "MAN" @("백신 제품: $(($av | ForEach-Object { $_.displayName }) -join ', ')", "엔진/시그니처 최신 여부 확인")
} else {
    Rep "W-39" "백신 프로그램 업데이트" "VULN" @("동작 중인 백신 미확인 → 백신 설치 및 최신 엔진 업데이트 필요")
}

#==============================================================================
Write-Host "[ 4. 로그 관리 ]" -ForegroundColor White
#==============================================================================

# W-40 정책에 따른 시스템 로깅 설정
# [기준] 양호 - 감사 정책 권고 기준에 따라 감사 설정 / 취약 - 권고 기준대로 설정되지 않음
#   <감사 정책 권고 기준>(가이드 2000~2022): 계정 관리 실패 / 계정 로그온 이벤트 성공·실패 / 권한 사용 성공·실패 /
#                                          디렉터리 서비스 액세스 실패 / 로그온 이벤트 성공·실패 / 정책 변경 성공·실패
#   auditpol /get /category:* /r (CSV) 의 하위 범주 GUID 로 정확히 매칭해 범주별 대표 하위 범주의 요구 수준을 비교
#     계정 관리    → User Account Management{0CCE9235}, Security Group Management{0CCE9237}: 실패 포함
#     계정 로그온  → Credential Validation{0CCE923F}: 성공 및 실패 (DC 는 Kerberos 인증 서비스{0CCE9242}·서비스 티켓 작업{0CCE9240} 추가)
#     권한 사용    → Sensitive Privilege Use{0CCE9228}: 성공 및 실패
#     DS 액세스    → Directory Service Access{0CCE923B}: 실패 포함
#     로그온 이벤트 → Logon{0CCE9215}: 성공 및 실패, Logoff{0CCE9216}: 성공 포함(성공 이벤트만 발생), Account Lockout{0CCE9217}: 실패 포함(실패 이벤트만 발생)
#     정책 변경    → Audit Policy Change{0CCE922F}: 성공 및 실패
#   '실패 포함'은 '실패' 또는 '성공 및 실패' 인정. 가이드 밖 범주(System 등)는 판정 제외
#   CSV 헤더·값이 OS 언어로 지역화될 수 있어 열 위치(4번째=GUID, 5번째=포함 설정)로 읽고,
#   값은 영문/한글(Success|성공, Failure|실패, No Auditing|감사 안 함|감사 없음) 모두 해석. 행 없음·해석 불가 → 수동확인
if ($IS_ADMIN) {
    function AuditBits { param([string]$S)
        if ($S -match 'No Auditing|감사 안 함|감사 없음') { return 0 }
        $b = 0; if ($S -match 'Success|성공') { $b = $b -bor 1 }; if ($S -match 'Failure|실패') { $b = $b -bor 2 }
        if ($b -eq 0) { return -1 }; return $b }
    $ap40 = @{}
    $apRaw = @(auditpol /get /category:* /r 2>$null | Where-Object { "$_".Trim() })
    foreach ($row in @($apRaw | ConvertFrom-Csv -Header 'c0','c1','c2','c3','c4','c5')) {
        if ("$($row.c3)" -match '^\s*\{?([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\}?\s*$') {
            $ap40[$Matches[1].ToUpper()] = "$($row.c4)".Trim()
        }
    }
    $sfx40 = "-69AE-11D9-BED3-505054503030"
    $req40 = @(
        @("계정 관리","User Account Management","0CCE9235",2), @("계정 관리","Security Group Management","0CCE9237",2),
        @("계정 로그온","Credential Validation","0CCE923F",3), @("권한 사용","Sensitive Privilege Use","0CCE9228",3),
        @("DS 액세스","Directory Service Access","0CCE923B",2), @("로그온 이벤트","Logon","0CCE9215",3),
        @("로그온 이벤트","Logoff","0CCE9216",1), @("로그온 이벤트","Account Lockout","0CCE9217",2),
        @("정책 변경","Audit Policy Change","0CCE922F",3))
    $cs40 = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $dc40 = [bool]($cs40 -and $cs40.DomainRole -ge 4)
    if ($dc40) { $req40 += ,@("계정 로그온","Kerberos Authentication Service","0CCE9242",3); $req40 += ,@("계정 로그온","Kerberos Service Ticket Operations","0CCE9240",3) }
    $need40 = @{ 1 = "성공 포함"; 2 = "실패 포함"; 3 = "성공 및 실패" }
    $miss40 = @(); $unk40 = @(); $ok40 = @()
    foreach ($r in $req40) {
        $set = $ap40["$($r[2])$sfx40"]
        if ($null -eq $set) { $unk40 += "$($r[0])/$($r[1])(행 없음)"; continue }
        $bits = AuditBits $set
        if ($bits -lt 0) { $unk40 += "$($r[0])/$($r[1])='$set'(해석 불가)" }
        elseif (($bits -band $r[3]) -ne $r[3]) { $miss40 += "$($r[0])/$($r[1])=$set (요구: $($need40[$r[3]]))" }
        else { $ok40 += "$($r[1])=$set" }
    }
    $dsNote40 = if (-not $dc40 -and ($miss40 -match 'Directory Service Access')) { @("※ DS 액세스 실패 감사는 DC 가 아니면 이벤트가 거의 발생하지 않으나 가이드 권고 기준 문구대로 적용") } else { @() }
    if ($ap40.Count -eq 0) {
        Rep "W-40" "정책에 따른 시스템 로깅 설정" "MAN" @("auditpol /r 결과를 읽지 못함 → 로컬 보안 정책 > 감사 정책 수동 확인")
    } elseif ($miss40.Count -gt 0) {
        Rep "W-40" "정책에 따른 시스템 로깅 설정" "VULN" (@("감사 정책 권고 기준 미충족: $($miss40 -join ' / ') → 권고 기준대로 성공/실패 감사 설정") + $dsNote40 +
            @($unk40 | ForEach-Object { "확인 불가: $_" }) + @("충족: $(if($ok40.Count){$ok40 -join ', '}else{'없음'})"))
    } elseif ($unk40.Count -gt 0) {
        Rep "W-40" "정책에 따른 시스템 로깅 설정" "MAN" @("감사 설정 확인 불가: $($unk40 -join ', ')", "충족: $(if($ok40.Count){$ok40 -join ', '}else{'없음'})")
    } else {
        Rep "W-40" "정책에 따른 시스템 로깅 설정" "GOOD" @("감사 정책 권고 기준(계정 관리/계정 로그온/권한 사용/DS 액세스/로그온 이벤트/정책 변경) 충족: $($ok40 -join ', ')")
    }
} else {
    Rep "W-40" "정책에 따른 시스템 로깅 설정" "MAN" @("감사 정책(auditpol)은 관리자 권한 필요 → 관리자로 재점검")
}

# W-41 NTP 및 시각 동기화 설정
# [기준] 양호 - NTP/시각 동기화를 "설정"한 경우 (외부 NTP 지정 또는 도메인 계층 동기화)
#        취약 - 미설정(NoSync 이거나 NTP 서버 미지정 + 로컬 CMOS 전용)
#   ※ W32Time 은 도메인 미조인 서버에서 평소 '중지(수동/트리거)' 상태가 정상이므로
#     서비스 실행 여부가 아니라 레지스트리 구성으로 판단한다. status 출력은 참고용.
$w32   = SvcObj "W32Time"
$w32p  = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
$w32Type   = RegVal $w32p "Type"                 # NTP / NT5DS / AllSync / NoSync
$w32Server = [string](RegVal $w32p "NtpServer")  # 예: time.windows.com,0x9 / 169.254.169.123
$ntpClient = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient" "Enabled"

$w32exe = Join-Path $env:SystemRoot "System32\w32tm.exe"
$w32status = if (Test-Path $w32exe) { & $w32exe /query /status 2>$null | Out-String } else { "" }
$src = ""
if ($w32status -match '(?m)^\s*(?:Source|원본)\s*:\s*(.+?)\s*$') { $src = $Matches[1].Trim() }
$srcOk = ($src -and $src -notmatch 'Local CMOS Clock|Free-running|로컬 CMOS')

$cfgOk = ($null -ne $w32) -and $w32Type -and ($w32Type -ne "NoSync") -and `
         ( ($w32Server.Trim()) -or ($w32Type -eq "NT5DS") -or ($ntpClient -eq 1) )

$w32ev = ("W32Time=$([string]$w32.Status)/$([string]$w32.StartType), Type=$w32Type, " +
          "NtpServer=$w32Server, 현재 동기화 원본=$src")
if ($cfgOk -or $srcOk) {
    Rep "W-41" "NTP 및 시각 동기화 설정" "GOOD" @($w32ev, "NTP/시각 동기화가 설정되어 있어 양호함")
} else {
    Rep "W-41" "NTP 및 시각 동기화 설정" "VULN" @($w32ev, "NTP 서버 미지정 또는 NoSync → 외부 NTP/시각 동기화 설정 필요")
}

# W-42 이벤트 로그 관리 설정
# [기준] 양호 - 최대 로그 크기 "10,240KB 이상" + "90일 이후 이벤트 덮어씀" 설정
#        취약 - 최대 로그 크기 10,240KB 미만 이거나 이벤트 덮어씀 기간 90일 이하
#   ※ 가이드: 2008 이상은 덮어쓰기 날짜 지정 불가 → '가득 차면 보관(AutoBackup)'·'덮어쓰지 않음(Retain)'을 양호,
#     '필요한 경우 덮어씀(Circular)'을 취약으로 판정 (크기가 커도 Circular 면 취약)
#   2008 이상(OS major>=6): 실효값(Get-WinEvent -ListLog 의 LogMode·MaximumSizeInBytes, GPO 포함)으로 판정.
#     레지스트리 Retention(초)·AutoBackupLogFiles 는 2008 이상 이벤트 로그 서비스가 쓰지 않으므로 판정에 쓰지 않음
#     (예: Retention=7776000 이어도 실제는 Circular). Get-WinEvent 실패 시 wevtutil gl 로 대체, 둘 다 실패 → 수동확인
#   2003 이하(OS major<6): 레지스트리 MaxSize·Retention(초, 0xFFFFFFFF=덮어쓰지 않음)·AutoBackupLogFiles 로 판정
$logbad = @()
$logunk = @()
$logev  = @()
$osMaj42 = if ($os -and "$($os.Version)" -match '^(\d+)\.') { [int]$Matches[1] } else { [Environment]::OSVersion.Version.Major }
foreach ($lg in @("Security","Application","System")) {
    if ($osMaj42 -ge 6) {
        $mode = $null; $max = $null; $fsz = $null
        $wl = $null; try { $wl = Get-WinEvent -ListLog $lg -ErrorAction Stop } catch {}
        if ($wl) { $mode = "$($wl.LogMode)"; $max = $wl.MaximumSizeInBytes; $fsz = $wl.FileSize }
        else {
            $gl = @(wevtutil gl $lg 2>$null)
            $gRet = ($gl | Where-Object { $_ -match '^\s*retention:\s*(\S+)' } | Select-Object -First 1) -replace '^\s*retention:\s*', ''
            $gBak = ($gl | Where-Object { $_ -match '^\s*autoBackup:\s*(\S+)' } | Select-Object -First 1) -replace '^\s*autoBackup:\s*', ''
            $gMax = ($gl | Where-Object { $_ -match '^\s*maxSize:\s*(\d+)' } | Select-Object -First 1) -replace '^\s*maxSize:\s*', ''
            if ($gRet -match '^(true|false)$') { $mode = if ($gRet -eq 'true') { if ($gBak -eq 'true') { "AutoBackup" } else { "Retain" } } else { "Circular" } }
            if ($gMax -match '^\d+$') { $max = [int64]$gMax }
        }
        if (-not $mode -or $null -eq $max) { $logunk += $lg; continue }
        $szKB = [math]::Round($max / 1KB)
        $old = $null; try { $old = (Get-WinEvent -LogName $lg -Oldest -MaxEvents 1 -ErrorAction Stop).TimeCreated } catch {}
        $logev += "$lg : LogMode=$mode, 최대 $('{0:N0}' -f $szKB)KB$(if($null -ne $fsz){", 현재 $('{0:N0}' -f [math]::Round($fsz / 1KB))KB"})$(if($old){", 가장 오래된 이벤트 $($old.ToString('yyyy-MM-dd HH:mm'))"})"
        if ($szKB -lt 10240) { $logbad += "$lg 크기 ${szKB}KB(<10,240)" }
        if ($mode -eq "Circular") { $logbad += "$lg 필요한 경우 덮어씀(Circular)" }
        elseif ($mode -eq "Retain") { $logev += "$lg 덮어쓰지 않음(Retain) - 가득 차면 새 이벤트가 기록되지 않으므로 용량 관리 필요" }
        elseif ($mode -ne "AutoBackup") { $logunk += "$lg(LogMode=$mode)" }
        continue
    }
    $base = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\" + $lg
    $sz = RegVal $base "MaxSize"
    if ($null -eq $sz) { $sz = (Get-WinEvent -ListLog $lg -ErrorAction SilentlyContinue).MaximumSizeInBytes }
    $ret    = RegVal $base "Retention"
    $autobk = RegVal $base "AutoBackupLogFiles"        # 1 = 가득 차면 보관
    if ($null -eq $sz -and $null -eq $ret) { $logunk += $lg; continue }  # 관리자 권한 부족 등

    $szKB = if ($sz) { [math]::Round($sz/1KB) } else { 0 }
    if ($szKB -lt 10240) { $logbad += "$lg 크기 ${szKB}KB(<10,240)" }

    # Retention: 0/미설정 = 필요시 덮어씀(취약), 0xFFFFFFFF(-1) = 덮어쓰지 않음, 그 외 = 보존 초
    $retNum = $null
    if ($null -ne $ret) { try { $retNum = [int64]$ret } catch { $retNum = $null } }
    if ($null -ne $retNum -and $retNum -lt 0) { $retNum = 4294967295 }
    $retOk = ($autobk -eq 1) -or ($retNum -eq 4294967295) -or ($null -ne $retNum -and $retNum -ge 7776000)
    if (-not $retOk) {
        $how = if ($null -eq $retNum) { "미설정(필요시 덮어씀)" } elseif ($retNum -eq 0) { "필요시 덮어씀" } else { "$([math]::Floor($retNum/86400))일 후 덮어씀" }
        $logbad += "$lg 덮어씀=$how(<90일)"
    }
}
if ($logbad.Count -gt 0) {
    Rep "W-42" "이벤트 로그 관리 설정" "VULN" (@(($logbad -join " / ")) + $logev + @("최대 로그 크기 10,240KB 이상 및 '90일 이후 이벤트 덮어씀'(2008 이상: '가득 차면 보관'/'덮어쓰지 않음') 설정 필요"))
} elseif ($logunk.Count -gt 0) {
    Rep "W-42" "이벤트 로그 관리 설정" "MAN" (@("로그 설정 확인 불가(관리자 권한 필요): $($logunk -join ', ')") + $logev)
} else {
    Rep "W-42" "이벤트 로그 관리 설정" "GOOD" (@("보안/응용/시스템 로그 최대 크기 10,240KB 이상 + 90일 이후 덮어씀(또는 덮어쓰지 않음/보관) 설정") + $logev)
}

# W-43 이벤트 로그 파일 접근 통제 설정
# [기준] 양호 - 로그 디렉터리에 Everyone 권한 없음 / 취약 - Everyone 권한 있음
$logDir = "$env:SystemRoot\System32\winevt\Logs"
$heLog = AclHasEveryone $logDir
if ($heLog -eq $false) { Rep "W-43" "이벤트 로그 파일 접근 통제 설정" "GOOD" @("$logDir 에 Everyone 권한 없음") }
elseif ($null -eq $heLog) { Rep "W-43" "이벤트 로그 파일 접근 통제 설정" "MAN" @("로그 디렉터리 ACL 확인 불가 (관리자 권한 필요)") }
else { Rep "W-43" "이벤트 로그 파일 접근 통제 설정" "VULN" @("$logDir 에 Everyone 권한 존재 → 제거") }

#==============================================================================
Write-Host "[ 5. 보안 관리 ]" -ForegroundColor White
#==============================================================================

function RegExpect { param([string]$C,[string]$T,[string]$P,[string]$N,$Want,[string]$G,[string]$B)
    $v = RegVal $P $N
    if ($null -eq $v) { Rep $C $T "MAN" @("$N 값 없음 → 정책 확인") }
    elseif ($v -eq $Want) { Rep $C $T "GOOD" @("$G (현재값 $v)") }
    else { Rep $C $T "VULN" @("$B (현재값 $v, 기준 $Want)") }
}

# W-44 원격으로 액세스할 수 있는 레지스트리 경로
# [기준] 양호 - Remote Registry Service 중지 / 취약 - 사용 중
$rr = SvcObj "RemoteRegistry"
if (-not $rr -or $rr.Status -ne "Running") { Rep "W-44" "원격으로 액세스할 수 있는 레지스트리 경로" "GOOD" @("Remote Registry 서비스 중지/미설치 (StartType=$($rr.StartType))") }
else { Rep "W-44" "원격으로 액세스할 수 있는 레지스트리 경로" "VULN" @("Remote Registry 서비스 실행 중 → 중지 및 '사용 안 함'") }

# W-45 백신 프로그램 설치
# [기준] 양호 - 백신 설치 / 취약 - 미설치
if ($av -or ($def -and $def.AMServiceEnabled)) { Rep "W-45" "백신 프로그램 설치" "GOOD" @("백신 설치됨: $(if($av){($av|ForEach-Object{$_.displayName}) -join ', '}else{'Microsoft Defender'})") }
else { Rep "W-45" "백신 프로그램 설치" "VULN" @("백신 프로그램 미설치 → 설치 필요") }

# W-46 SAM 파일 접근 통제 설정
# [기준] 양호 - SAM 파일 권한에 Administrators, System 만 모든 권한 / 취약 - 그 외 그룹 권한
$samPath = "$env:SystemRoot\System32\config\SAM"
if (-not $IS_ADMIN) { Rep "W-46" "SAM 파일 접근 통제 설정" "MAN" @("SAM ACL 조회는 관리자 권한 필요") }
else {
    try {
        $acl = Get-Acl $samPath -ErrorAction Stop
        $bad = @($acl.Access | Where-Object { $_.IdentityReference.Value -notin @("NT AUTHORITY\SYSTEM","BUILTIN\Administrators","Administrators","SYSTEM") })
        if ($bad.Count -eq 0) { Rep "W-46" "SAM 파일 접근 통제 설정" "GOOD" @("SAM 파일 권한 = SYSTEM/Administrators 만") }
        else { Rep "W-46" "SAM 파일 접근 통제 설정" "VULN" @("SAM 파일에 추가 권한: $(($bad | ForEach-Object { $_.IdentityReference.Value }) -join ', ')") }
    } catch { Rep "W-46" "SAM 파일 접근 통제 설정" "MAN" @("SAM ACL 조회 실패") }
}

# W-47 화면보호기 설정
# [기준] 양호 - 화면 보호기 설정 + 대기 10분(600초) 이하 + 해제 암호 사용 / 취약 - 아님
#   화면보호기는 사용자별 설정 → 실제 사용자 프로필(ProfileList 의 S-1-5-21-*)마다 판정한다.
#   (SYSTEM 실행 시 HKCU = S-1-5-18 이고, HKLM\SOFTWARE\Policies\...\Control Panel\Desktop 은 Windows 가 적용하지 않는
#    키(화면보호기 정책은 사용자 구성 전용)이므로 둘 다 판정에서 제외)
#   사용자별 값 단위 병합: HKU\<SID>\Software\Policies\Microsoft\Windows\Control Panel\Desktop 값 우선, 없으면 HKU\<SID>\Control Panel\Desktop
#   네 조건 모두 충족해야 양호: ScreenSaveActive=1, ScreenSaverIsSecure=1, 1<=ScreenSaveTimeOut<=600(없으면 기본 900초), SCRNSAVE.EXE 지정 + 파일 존재
#   로그오프 사용자(하이브 미로드)는 reg load(하이브 마운트 = 상태 변경) 대신 NTUSER.DAT 를 읽기 전용·공유 모드로 한 번 읽고
#   regf 구조를 직접 해석(64MB 초과·읽기 실패·dirty(트랜잭션 로그 미반영)·해석 실패 → 해당 사용자 수동확인, 최대 20명)
#   판정 제외(참고 표기): 비활성 로컬 계정, 삭제된 로컬 계정의 잔여 프로필, ssm-user(SSM Agent 비대화형),
#     서비스 실행 계정 중 Administrators/Remote Desktop Users 비구성원(비대화형 전용 추정), NTUSER.DAT 없는 프로필
#   한 명이라도 미흡 → 취약 / 미흡 없이 확인 불가 사용자 존재 또는 점검 대상 없음 → 수동확인
function RegfLoad { param([string]$Path)      # NTUSER.DAT 읽기 전용 로드(쓰기/마운트 없음)
    try {
        $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($fi.Length -lt 8192 -or $fi.Length -gt 64MB) { return $null }
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $buf = New-Object byte[] ([int]$fs.Length); $off = 0
            while ($off -lt $buf.Length) { $n = $fs.Read($buf, $off, $buf.Length - $off); if ($n -le 0) { break }; $off += $n }
        } finally { $fs.Close() }
        if ($off -lt $buf.Length -or [Text.Encoding]::ASCII.GetString($buf, 0, 4) -ne 'regf') { return $null }
        return ,$buf
    } catch { return $null }
}
function RegfStr { param([byte[]]$B, [int]$Pos, [int]$Len, [bool]$Ascii)
    if ($Len -le 0) { return "" }
    if ($Ascii) { return [Text.Encoding]::GetEncoding(28591).GetString($B, $Pos, $Len) }
    return [Text.Encoding]::Unicode.GetString($B, $Pos, $Len)
}
# 하위 키 목록 셀(lf/lh/li/ri) → nk 셀 데이터 절대 오프셋 목록 (셀 데이터 = 0x1000 + 오프셋 + 4)
function RegfList { param([byte[]]$B, [int]$P, [int]$Depth = 0)
    $r = New-Object System.Collections.Generic.List[int]
    if ($Depth -gt 4 -or $P + 4 -gt $B.Length) { return ,$r }
    $sig = [Text.Encoding]::ASCII.GetString($B, $P, 2); $n = [BitConverter]::ToUInt16($B, $P + 2)
    if ($sig -eq 'lf' -or $sig -eq 'lh') { for ($i = 0; $i -lt $n; $i++) { $r.Add([int](4100 + [BitConverter]::ToUInt32($B, $P + 4 + 8 * $i))) } }
    elseif ($sig -eq 'li') { for ($i = 0; $i -lt $n; $i++) { $r.Add([int](4100 + [BitConverter]::ToUInt32($B, $P + 4 + 4 * $i))) } }
    elseif ($sig -eq 'ri') { for ($i = 0; $i -lt $n; $i++) { foreach ($x in (RegfList $B ([int](4100 + [BitConverter]::ToUInt32($B, $P + 4 + 4 * $i))) ($Depth + 1))) { $r.Add($x) } } }
    return ,$r
}
# 루트 nk 에서 경로(대소문자 무시)를 따라 내려가 nk 오프셋 반환, 없으면 -1
function RegfKey { param([byte[]]$B, [string[]]$Parts)
    $k = [int](4100 + [BitConverter]::ToUInt32($B, 0x24))
    foreach ($part in $Parts) {
        if ([BitConverter]::ToUInt32($B, $k + 20) -eq 0) { return -1 }
        $lst = [BitConverter]::ToUInt32($B, $k + 28); if ($lst -ge 2147483648) { return -1 }
        $next = -1
        foreach ($c in (RegfList $B ([int](4100 + $lst)))) {
            if ($c + 76 -ge $B.Length -or $B[$c] -ne 0x6E -or $B[$c + 1] -ne 0x6B) { continue }   # 'nk'
            $nm = RegfStr $B ($c + 76) ([BitConverter]::ToUInt16($B, $c + 72)) ((([BitConverter]::ToUInt16($B, $c + 2)) -band 0x20) -ne 0)
            if ($nm -ieq $part) { $next = $c; break }
        }
        if ($next -lt 0) { return -1 }
        $k = $next
    }
    return $k
}
# nk 의 값들 → @{ 이름 = 값 } (REG_SZ/EXPAND_SZ = 문자열, REG_DWORD = 정수, 그 외 형식은 생략)
function RegfValues { param([byte[]]$B, [int]$K)
    $h = @{}
    $cnt = [BitConverter]::ToUInt32($B, $K + 36); $vl = [BitConverter]::ToUInt32($B, $K + 40)
    if ($cnt -eq 0 -or $cnt -gt 4096 -or $vl -ge 2147483648) { return $h }
    for ($i = 0; $i -lt $cnt; $i++) {
        $v = [int](4100 + [BitConverter]::ToUInt32($B, [int](4100 + $vl + 4 * $i)))
        if ($v + 20 -ge $B.Length -or $B[$v] -ne 0x76 -or $B[$v + 1] -ne 0x6B) { continue }   # 'vk'
        $nl = [BitConverter]::ToUInt16($B, $v + 2); $ds = [BitConverter]::ToUInt32($B, $v + 4)
        $do = [BitConverter]::ToUInt32($B, $v + 8); $ty = [BitConverter]::ToUInt32($B, $v + 12)
        $vn = RegfStr $B ($v + 20) $nl ((([BitConverter]::ToUInt16($B, $v + 16)) -band 1) -ne 0)
        $inl = ($ds -ge 2147483648); $len = if ($inl) { [int]($ds - 2147483648) } else { [int]$ds }
        $dp = if ($inl) { $v + 8 } else { [int](4100 + $do) }
        if ($len -gt 16344 -or $dp + $len -gt $B.Length) { continue }
        if ($ty -eq 1 -or $ty -eq 2) { $h[$vn] = (RegfStr $B $dp $len $false).TrimEnd([char]0) }
        elseif ($ty -eq 4 -and $len -ge 4) { $h[$vn] = [BitConverter]::ToUInt32($B, $dp) }
    }
    return $h
}
function KeyVals47 { param([string]$P)    # 로드된 하이브의 키 값 → @{ 이름 = 값 }
    $h = @{}
    if (Test-Path -LiteralPath $P) {
        $ip = Get-ItemProperty -LiteralPath $P -ErrorAction SilentlyContinue
        if ($ip) { foreach ($pp in $ip.PSObject.Properties) { if ($pp.Name -notin @("PSPath","PSParentPath","PSChildName","PSDrive","PSProvider")) { $h[$pp.Name] = $pp.Value } } }
    }
    return $h
}
function Pick47 { param($Pol, $Usr, [string]$N) if ($Pol.ContainsKey($N)) { return $Pol[$N] } if ($Usr.ContainsKey($N)) { return $Usr[$N] } return $null }

$lu47 = @{}
foreach ($u in @(LocalUsers)) { $sid = if ($u.SID -is [string]) { $u.SID } else { "$($u.SID.Value)" }; if ($sid) { $lu47[$sid] = $u } }
$pfx47 = ""; foreach ($k in @($lu47.Keys)) { if ("$k" -match '^(S-1-5-21-\d+-\d+-\d+)-\d+$') { $pfx47 = $Matches[1]; break } }   # 로컬 머신 SID
$svc47 = @{}                                   # 서비스 실행 계정 SID → 서비스 이름
foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.StartName -and "$($_.StartName)" -notmatch '^(LocalSystem|NT AUTHORITY\\|NT SERVICE\\)' })) {
    try { $sid = (New-Object System.Security.Principal.NTAccount ("$($s.StartName)" -replace '^\.\\', "$env:COMPUTERNAME\")).Translate([System.Security.Principal.SecurityIdentifier]).Value
          if (-not $svc47.ContainsKey($sid)) { $svc47[$sid] = $s.Name } } catch {}
}
$ia47 = @{}; $grp47 = $true                    # Administrators / Remote Desktop Users 직접 구성원 SID
foreach ($g in @("S-1-5-32-544","S-1-5-32-555")) {
    try { foreach ($m in @(Get-LocalGroupMember -SID $g -ErrorAction Stop)) { $ia47["$($m.SID)"] = 1 } } catch { $grp47 = $false }
}
$bad47 = @(); $ok47 = @(); $unk47 = @(); $ex47 = @(); $off47 = 0
foreach ($pk in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
    $sid = $pk.PSChildName
    if ($sid -notmatch '^S-1-5-21-[\d-]+$') { continue }                 # 시스템 계정·.bak 제외
    $img = [Environment]::ExpandEnvironmentVariables([string](RegVal $pk.PSPath "ProfileImagePath"))
    if (-not $img) { continue }
    $u = $lu47[$sid]; $trOk = $true
    $nm = if ($u) { "$($u.Name)" } else { try { (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value } catch { $trOk = $false; Split-Path $img -Leaf } }
    $dat = Join-Path $img "NTUSER.DAT"
    $loaded = Test-Path -LiteralPath "Registry::HKEY_USERS\$sid"
    if ($u -and -not (UserEnabled $u)) { $ex47 += "$nm(비활성)"; continue }
    if (-not $u -and $pfx47 -and $sid.StartsWith("$pfx47-")) { $ex47 += "$nm(삭제된 로컬 계정의 잔여 프로필)"; continue }
    if (-not $u -and -not $trOk) { $unk47 += "$nm($sid 계정명 확인 불가 → 수동 확인)"; continue }
    if ("$nm" -match '(^|\\)ssm-user$') { $ex47 += "$nm(SSM Agent 비대화형)"; continue }
    if ($svc47.ContainsKey($sid) -and -not $ia47.ContainsKey($sid)) {
        if ($grp47) { $ex47 += "$nm(서비스 $($svc47[$sid]) 실행 계정, 관리자·RDP 그룹 비구성원 → 비대화형 추정)" }
        else { $unk47 += "$nm(서비스 $($svc47[$sid]) 실행 계정, 그룹 조회 실패로 대화형 여부 미확인 → 수동 확인)" }
        continue
    }
    if ($loaded) {
        $pol = KeyVals47 "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\Windows\Control Panel\Desktop"
        $usr = KeyVals47 "Registry::HKEY_USERS\$sid\Control Panel\Desktop"
        $src = "로드된 하이브"
    } else {
        if (-not (Test-Path -LiteralPath $dat)) { $ex47 += "$nm(NTUSER.DAT 없음)"; continue }
        if ($off47 -ge 20) { $unk47 += "$nm(오프라인 하이브 읽기 상한 20명 초과 → 수동 확인)"; continue }
        $off47++
        $b = RegfLoad $dat
        if ($null -eq $b) { $unk47 += "$nm(NTUSER.DAT 읽기 실패/64MB 초과 → 수동 확인)"; continue }
        if ([BitConverter]::ToUInt32($b, 4) -ne [BitConverter]::ToUInt32($b, 8)) { $unk47 += "$nm(하이브 dirty - 트랜잭션 로그 미반영 → 수동 확인)"; $b = $null; continue }
        try {
            $pol = @{}; $k = RegfKey $b @("Software","Policies","Microsoft","Windows","Control Panel","Desktop"); if ($k -ge 0) { $pol = RegfValues $b $k }
            $usr = @{}; $k = RegfKey $b @("Control Panel","Desktop"); if ($k -ge 0) { $usr = RegfValues $b $k }
        } catch { $unk47 += "$nm(하이브 해석 실패 → 수동 확인)"; $b = $null; continue }
        $b = $null
        $src = "오프라인 하이브"
    }
    $ssA = "$(Pick47 $pol $usr 'ScreenSaveActive')"; $ssS = "$(Pick47 $pol $usr 'ScreenSaverIsSecure')"
    $ssT = "$(Pick47 $pol $usr 'ScreenSaveTimeOut')"; $ssE = "$(Pick47 $pol $usr 'SCRNSAVE.EXE')".Trim()
    $why = @()
    if ($ssA -ne "1") { $why += "화면보호기 미사용" }
    if ($ssS -ne "1") { $why += "암호 보호 미사용" }
    $ti = 0; if (-not [int]::TryParse($ssT, [ref]$ti) -or $ti -lt 1 -or $ti -gt 600) { $why += "대기 $(if($ssT){"${ssT}초"}else{'미설정(기본 900초)'})(기준 1~600초)" }
    $exeOk = $false
    if ($ssE) { $x = [Environment]::ExpandEnvironmentVariables($ssE); if (-not [IO.Path]::IsPathRooted($x)) { $x = Join-Path "$env:SystemRoot\System32" $x }; $exeOk = Test-Path -LiteralPath $x }
    if (-not $exeOk) { $why += "화면보호기 프로그램 $(if($ssE){"'$ssE' 파일 없음"}else{'(없음)'})" }
    $sum = "$nm($src$(if($pol.Count){', 사용자 정책키 있음'})) Active=$ssA Secure=$ssS Timeout=$ssT EXE=$(if($ssE){$ssE}else{'(없음)'})"
    if ($why.Count -gt 0) { $bad47 += "$sum → 미흡: $($why -join ', ')" } else { $ok47 += $sum }
}
$ref47 = @()
if ($ex47.Count) { $ref47 += "판정 제외 계정: $($ex47 -join ', ')" }
if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop") { $ref47 += "참고: HKLM 화면보호기 정책값 존재(사용자 구성 전용 정책이라 Windows 미적용 → 판정 제외)" }
if ($bad47.Count -gt 0) {
    Rep "W-47" "화면보호기 설정" "VULN" (@($bad47) + @($unk47 | ForEach-Object { "확인 불가: $_" }) + @($ok47) + $ref47 + @("사용자별 화면 보호기 사용 + 대기 10분(600초) 이하 + '다시 시작할 때 로그온 화면 표시' 설정 필요"))
} elseif ($unk47.Count -gt 0) {
    Rep "W-47" "화면보호기 설정" "MAN" (@($unk47 | ForEach-Object { "확인 불가: $_" }) + @($ok47) + $ref47)
} elseif ($ok47.Count -eq 0) {
    Rep "W-47" "화면보호기 설정" "MAN" (@("점검 대상 사용자 프로필 없음 → 사용 계정의 화면보호기 설정 수동 확인") + $ref47)
} else {
    Rep "W-47" "화면보호기 설정" "GOOD" (@($ok47) + $ref47)
}

# W-48 로그온하지 않고 시스템 종료 허용
RegExpect "W-48" "로그온하지 않고 시스템 종료 허용" "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "ShutdownWithoutLogon" 0 `
    "로그온 화면에서 시스템 종료 불가" "로그온 없이 시스템 종료 가능 → '사용 안 함'으로 설정"

# W-49 원격 시스템에서 강제로 시스템 종료
$p49 = PrivOnlyAdmin "SeRemoteShutdownPrivilege"
if ($p49 -eq $true) { Rep "W-49" "원격 시스템에서 강제로 시스템 종료" "GOOD" @("SeRemoteShutdownPrivilege = Administrators 만") }
elseif ($null -eq $p49) { Rep "W-49" "원격 시스템에서 강제로 시스템 종료" "MAN" @("권한 할당 확인 불가 (관리자 권한 필요)") }
else { Rep "W-49" "원격 시스템에서 강제로 시스템 종료" "VULN" @("SeRemoteShutdownPrivilege 에 Administrators 외 대상 포함: $($PRIV['SeRemoteShutdownPrivilege'])") }

# W-50 보안 감사를 로그할 수 없는 경우 즉시 시스템 종료
RegExpect "W-50" "보안 감사를 로그할 수 없는 경우 즉시 시스템 종료" "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "CrashOnAuditFail" 0 `
    "감사 실패 시 시스템 종료 안 함(가용성)" "감사 실패 시 시스템 강제 종료 → '사용 안 함'으로 설정"

# W-51 SAM 계정과 공유의 익명 열거 허용 안 함
# [기준] 양호 - "SAM 계정과 공유의 익명 열거 허용 안 함" 사용(RestrictAnonymous=1) / 취약 - 사용 안 함(0 또는 미설정)
#  ※ 본 항목은 RestrictAnonymous (기본값 0). RestrictAnonymousSAM(기본값 1)은 "SAM 계정" 항목이라 별개 — 참고만.
$lsaP  = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
$ra    = RegVal $lsaP "RestrictAnonymous"
$raSAM = RegVal $lsaP "RestrictAnonymousSAM"
$raVal    = if ($null -eq $ra)    { 0 } else { try { [int]$ra }    catch { 0 } }
$raSAMVal = if ($null -eq $raSAM) { 1 } else { try { [int]$raSAM } catch { 1 } }
if ($raVal -ge 1) {
    Rep "W-51" "SAM 계정과 공유의 익명 열거 허용 안 함" "GOOD" @("RestrictAnonymous=$raVal (익명 열거 제한), RestrictAnonymousSAM=$raSAMVal")
} else {
    Rep "W-51" "SAM 계정과 공유의 익명 열거 허용 안 함" "VULN" @("RestrictAnonymous=$(if($null -eq $ra){'미설정(=0)'}else{$ra}) → 익명 사용자가 SAM 계정·공유 열거 가능, '사용'(1)으로 설정 필요 (RestrictAnonymousSAM=$raSAMVal)")
}

# W-52 Autologon 기능 제어
$aal = RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoAdminLogon"
$dpw = RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "DefaultPassword"
if (($aal -eq 1 -or $aal -eq "1") -or $dpw) { Rep "W-52" "Autologon 기능 제어" "VULN" @("자동 로그온 활성(AutoAdminLogon=$aal)$(if($dpw){', DefaultPassword 평문 저장'})") }
else { Rep "W-52" "Autologon 기능 제어" "GOOD" @("자동 로그온 비활성 (AutoAdminLogon 미설정/0)") }

# W-53 이동식 미디어 포맷 및 꺼내기 허용
RegExpect "W-53" "이동식 미디어 포맷 및 꺼내기 허용" "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AllocateDASD" 0 `
    "로그온한 관리자만 이동식 미디어 접근(0)" "이동식 미디어 접근 제한 미흡 → 0(Administrators) 권장"

# W-54 DoS 공격 방어 레지스트리 설정
# [기준] 양호 - SynAttackProtect>=1, EnableDeadGWDetect=0, KeepAliveTime=300000, NoNameReleaseOnDemand=1 모두 / 취약 - 미설정
$tp = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
$sap = RegVal $tp "SynAttackProtect"; $edg = RegVal $tp "EnableDeadGWDetect"; $kat = RegVal $tp "KeepAliveTime"
$nnr = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\Netbt\Parameters" "NoNameReleaseOnDemand"
$d54 = @()
if (-not ($sap -ge 1)) { $d54 += "SynAttackProtect($sap/기준>=1)" }
if ($edg -ne 0) { $d54 += "EnableDeadGWDetect($edg/기준 0)" }
if ($kat -ne 300000) { $d54 += "KeepAliveTime($kat/기준 300000)" }
if ($nnr -ne 1) { $d54 += "NoNameReleaseOnDemand($nnr/기준 1)" }
if ($d54.Count -eq 0) { Rep "W-54" "DoS 공격 방어 레지스트리 설정" "GOOD" @("SynAttackProtect/EnableDeadGWDetect/KeepAliveTime/NoNameReleaseOnDemand 모두 권고값") }
else { Rep "W-54" "DoS 공격 방어 레지스트리 설정" "VULN" @("미흡: $($d54 -join ', ')") }

# W-55 사용자가 프린터 드라이버를 설치할 수 없게 함
RegExpect "W-55" "사용자가 프린터 드라이버를 설치할 수 없게 함" "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Providers\LanMan Print Services\Servers" "AddPrinterDrivers" 1 `
    "관리자만 프린터 드라이버 설치 가능" "일반 사용자의 프린터 드라이버 설치 허용 → 제한(PrintNightmare 대응)"

# W-56 SMB 세션 중단 관리 설정
# [기준] 양호 - "로그온 시간 만료 시 클라이언트 연결 끊기" 사용 + "세션 중단 전 유휴 시간" 15분 이하 / 취약 - 아님
$efl = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "EnableForcedLogOff"
$adc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "autodisconnect"
if (($efl -eq 1 -or $null -eq $efl) -and $null -ne $adc -and [int]$adc -ge 0 -and [int]$adc -le 15) {
    Rep "W-56" "SMB 세션 중단 관리 설정" "GOOD" @("EnableForcedLogOff=$efl, autodisconnect=$adc 분 (<=15)")
} else {
    Rep "W-56" "SMB 세션 중단 관리 설정" "VULN" @("EnableForcedLogOff=$efl, autodisconnect=$(if($null -eq $adc){'미설정'}else{$adc}) (기준: 사용 + 15분 이하)")
}

# W-57 로그온 시 경고 메시지 설정
$cap = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "LegalNoticeCaption"
$txt = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "LegalNoticeText"
if ($cap -and $txt) { Rep "W-57" "로그온 시 경고 메시지 설정" "GOOD" @("로그온 경고 메시지 설정됨 (제목: '$cap')") }
else { Rep "W-57" "로그온 시 경고 메시지 설정" "VULN" @("LegalNoticeCaption/Text 미설정 → 비인가 접근 경고 문구 설정") }

# W-58 사용자별 홈 디렉터리 권한 설정
# [기준] 양호 - 홈 디렉터리에 Everyone 권한 없음 (All Users, Default User 제외) / 취약 - Everyone 권한 있음
$userDirs = @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") })
$badHome = @()
foreach ($d in $userDirs) { if ((AclHasEveryone $d.FullName) -eq $true) { $badHome += $d.Name } }
if ($userDirs.Count -eq 0) { Rep "W-58" "사용자별 홈 디렉터리 권한 설정" "NA" @("사용자 홈 디렉터리 없음") }
elseif ($badHome.Count -eq 0) { Rep "W-58" "사용자별 홈 디렉터리 권한 설정" "GOOD" @("사용자 홈 디렉터리($($userDirs.Count)개)에 Everyone 권한 없음") }
else { Rep "W-58" "사용자별 홈 디렉터리 권한 설정" "VULN" @("Everyone 권한이 있는 홈 디렉터리: $($badHome -join ', ')") }

# W-59 LAN Manager 인증 수준
# [기준] 양호 - "NTLMv2 응답만 보냄"(LmCompatibilityLevel >= 3) / 취약 - LM/NTLM 허용
$lmc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LmCompatibilityLevel"
if ($lmc -ge 3) { Rep "W-59" "LAN Manager 인증 수준" "GOOD" @("LmCompatibilityLevel = $lmc (NTLMv2 응답만)") }
elseif ($null -eq $lmc) { Rep "W-59" "LAN Manager 인증 수준" "MAN" @("LmCompatibilityLevel 값 없음 → 기본값 확인 (기준: 3 이상)") }
else { Rep "W-59" "LAN Manager 인증 수준" "VULN" @("LmCompatibilityLevel = $lmc → 3(NTLMv2 응답만) 이상으로 설정") }

# W-60 보안 채널 데이터 디지털 암호화 또는 서명
# [기준] 양호 - RequireSignOrSeal/SealSecureChannel/SignSecureChannel 모두 1 / 취약 - 일부 0
$np = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters"
$rss = RegVal $np "RequireSignOrSeal"; $ssc = RegVal $np "SealSecureChannel"; $sgn = RegVal $np "SignSecureChannel"
if (($rss -eq 1 -or $null -eq $rss) -and ($ssc -eq 1 -or $null -eq $ssc) -and ($sgn -eq 1 -or $null -eq $sgn)) {
    Rep "W-60" "보안 채널 데이터 디지털 암호화 또는 서명" "GOOD" @("RequireSignOrSeal=$rss, SealSecureChannel=$ssc, SignSecureChannel=$sgn (기본값 포함 모두 사용)")
} else {
    Rep "W-60" "보안 채널 데이터 디지털 암호화 또는 서명" "VULN" @("일부 '사용 안 함': RequireSignOrSeal=$rss, SealSecureChannel=$ssc, SignSecureChannel=$sgn")
}

# W-61 파일 및 디렉토리 보호
# [기준] 양호 - NTFS 파일 시스템 / 취약 - FAT
$fat = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | Where-Object { $_.FileSystem -and $_.FileSystem -notmatch 'NTFS|ReFS' })
if ($fat.Count -eq 0) { Rep "W-61" "파일 및 디렉토리 보호" "GOOD" @("모든 고정 디스크가 NTFS/ReFS") }
else { Rep "W-61" "파일 및 디렉토리 보호" "VULN" @("FAT 계열 볼륨: $(($fat | ForEach-Object { "$($_.DeviceID)($($_.FileSystem))" }) -join ', ') → NTFS 로 전환") }

# W-62 시작프로그램 목록 분석
$runKeys = @()
foreach ($rk in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run","HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run")) {
    try { $p = Get-Item $rk -ErrorAction Stop; foreach ($n in $p.Property) { $runKeys += "$n" } } catch {}
}
Rep "W-62" "시작프로그램 목록 분석" "MAN" @("자동 실행 등록: $(if($runKeys.Count){$runKeys -join ', '}else{'없음'})", "시작 프로그램·서비스 정기 점검 및 불필요 항목 제거 여부 확인")

# W-63 도메인 컨트롤러-사용자의 시간 동기화
# [기준] 양호 - 컴퓨터 시계 동기화 최대 허용 오차 5분 이하 / 취약 - 5분 초과
$isDC = ($os.ProductType -eq 2)
$maxSkew = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" "MaxClockSkewMinutes"
$kerbSkew = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kerberos\Parameters" "MaxClockSkew"
$eff = if ($null -ne $maxSkew) { $maxSkew } elseif ($null -ne $kerbSkew) { $kerbSkew } else { 5 }
if (-not $isDC) { Rep "W-63" "도메인 컨트롤러-사용자의 시간 동기화" "NA" @("도메인 컨트롤러 아님 (Kerberos 시간 오차 정책은 DC/도메인 정책 대상)") }
elseif ($eff -le 5) { Rep "W-63" "도메인 컨트롤러-사용자의 시간 동기화" "GOOD" @("Kerberos 최대 시계 오차 = $eff 분 (5분 이하)") }
else { Rep "W-63" "도메인 컨트롤러-사용자의 시간 동기화" "VULN" @("Kerberos 최대 시계 오차 = $eff 분 (기준: 5분 이하)") }

# W-64 윈도우 방화벽 설정
# [기준] 양호 - Windows 방화벽 "사용" / 취약 - "사용 안 함"
$fw = @(); try { $fw = Get-NetFirewallProfile -ErrorAction Stop } catch {}
$fwOff = @($fw | Where-Object { -not $_.Enabled })
if ($fw.Count -gt 0 -and $fwOff.Count -eq 0) { Rep "W-64" "윈도우 방화벽 설정" "GOOD" @("도메인/개인/공용 방화벽 프로필 모두 사용") }
elseif ($fw.Count -eq 0) { Rep "W-64" "윈도우 방화벽 설정" "MAN" @("방화벽 프로필 상태 확인 불가 → 별도 호스트 방화벽/보안그룹 확인") }
else { Rep "W-64" "윈도우 방화벽 설정" "VULN" @("방화벽 비활성 프로필: $($fwOff.Name -join ', ')") }

#==============================================================================
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host (" 요약   양호={0}   취약={1}   N/A={2}   수동확인={3}   (총 {4})" -f $good, $vuln, $na, $man, ($good+$vuln+$na+$man)) -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host " 수동확인 항목은 정책 수립 여부 등 인터뷰가 필요한 잔여 항목입니다."
Write-Host ""

# ---------------- JSON 파일 출력 (--Json <파일> 지정 시) ----------------
if ($Json -ne "") {
    $out = [pscustomobject]@{
        host = $HOSTN; os = $OS_NAME; family = "windows"; results = @($script:results)
    }
    $out | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $Json -Encoding UTF8
    Write-Host (" JSON 저장: {0}" -f $Json)
}

# ---------------- CSV 파일 출력 (기본 자동 저장. -Csv <파일> 지정, -NoSave 로 생략) ----------------
if ($Csv -eq "" -and -not $NoSave) {
    $h = ($HOSTN -replace '[^A-Za-z0-9._-]', ''); if ($h -eq "") { $h = "windows" }
    $Csv = "server_windows_{0}_{1}.csv" -f $h, (Get-Date -Format "yyyyMMdd_HHmm")
}
if ($Csv -ne "") {
    $rows = $script:results | ForEach-Object {
        $st = $_.status
        $rstat = switch ($st) { "수동확인" { "인터뷰 필요" } "N/A" { "양호" } default { $st } }
        [pscustomobject][ordered]@{
            "항목코드" = $_.code
            "중요도"   = $_.importance
            "진단항목" = $_.title
            "진단결과" = $rstat
            "상세"     = ($_.evidence -join " | ")
        }
    }
    $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    # 진단대상 Hostname/IP/버전정보를 CSV 맨 위 주석 줄로 (make_report 가 읽어 보고서에 채움)
    $ip = try { (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1).IPAddress } catch { "" }
    if (-not $ip) { $ip = "-" }
    $meta = @("# host,$HOSTN", "# ip,$ip", "# os,$OS_NAME (Build $OS_BUILD)")
    Set-Content -Path $Csv -Value ($meta + (Get-Content -Path $Csv -Encoding UTF8)) -Encoding UTF8
    Write-Host (" CSV 저장: {0}   (엑셀에서 바로 열림)" -f $Csv)
}
'@

$script:KISA_PAYLOAD_WEB_WIN = @'
<#
==============================================================================
 웹서버(Windows) 기술적 취약점 점검  WEB-01 ~ WEB-26   [IIS / Apache Tomcat]
  - KISA 주통기 / SK Shieldus 웹 보안가이드 기준(공식 결과보고서 WEB-01~26 항목·판단기준 반영)
  - IIS 와 Spring Boot 내장 Tomcat(nssm 서비스)을 자동 감지하여 점검
  - 읽기 전용(READ-ONLY): 구성/레지스트리/ACL/프로세스 조회만, 변경 없음
  - 대상 웹서버에서 관리자 PowerShell 로 실행(EC2 인스턴스 연결/RDP 후 파일만 올림):
      powershell -ExecutionPolicy Bypass -File web_windows_check.ps1
      powershell -ExecutionPolicy Bypass -File web_windows_check.ps1 -Target tomcat -AppUrl http://localhost:8080
  - 끝나면 콘솔 요약 + CSV + HTML 리포트를 현재 폴더에 자동 저장(추가 설치 불필요).

 판정: 양호 / 취약 / N/A(가이드 점검대상 제외→보고서 양호) / 수동확인(인터뷰·런타임 확인)
 스키마: {"target":"웹서버(iis|tomcat)","host","os","results":[{"code","importance","title","status","evidence":[...]}]}
==============================================================================
#>
[CmdletBinding()]
param([string]$Json="", [string]$Csv="", [string]$Html="", [string]$Target="",
      [string]$AppJar="", [string]$AppUrl="", [switch]$NoSave, [switch]$NoColor)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
try { chcp 65001 > $null 2>&1 } catch {}

$script:good=0; $script:vuln=0; $script:na=0; $script:man=0
$script:results = New-Object System.Collections.ArrayList

$IMP = @{
 "WEB-01"="상";"WEB-02"="상";"WEB-03"="상";"WEB-04"="상";"WEB-05"="상";"WEB-06"="상";"WEB-07"="중";"WEB-08"="하";"WEB-09"="상"
 "WEB-10"="상";"WEB-11"="중";"WEB-12"="중";"WEB-13"="상";"WEB-14"="상";"WEB-15"="상";"WEB-16"="중";"WEB-17"="중";"WEB-18"="상"
 "WEB-19"="중";"WEB-20"="상";"WEB-21"="중";"WEB-22"="하";"WEB-23"="중";"WEB-24"="중";"WEB-25"="상";"WEB-26"="중"
}
$TITLE = @{
 "WEB-01"="Default 관리자 계정명 변경";"WEB-02"="취약한 비밀번호 사용 제한";"WEB-03"="비밀번호 파일 권한 관리"
 "WEB-04"="웹 서비스 디렉터리 리스팅 방지 설정";"WEB-05"="지정하지 않은 CGI/ISAPI 실행 제한"
 "WEB-06"="웹 서비스 상위 디렉터리 접근 제한 설정";"WEB-07"="웹 서비스 경로 내 불필요한 파일 제거"
 "WEB-08"="웹 서비스 파일 업로드 및 다운로드 용량 제한";"WEB-09"="웹 서비스 프로세스 권한 제한"
 "WEB-10"="불필요한 프록시 설정 제한";"WEB-11"="웹 서비스 경로 설정";"WEB-12"="웹 서비스 링크 사용 금지"
 "WEB-13"="웹 서비스 설정 파일 노출 제한";"WEB-14"="웹 서비스 경로 내 파일의 접근 통제"
 "WEB-15"="웹 서비스의 불필요한 스크립트 매핑 제거";"WEB-16"="웹 서비스 헤더 정보 노출 제한"
 "WEB-17"="웹 서비스 가상 디렉토리 삭제";"WEB-18"="웹 서비스 WebDAV 비활성화"
 "WEB-19"="웹 서비스 SSI(Server Side Includes) 사용 제한";"WEB-20"="SSL/TLS 활성화";"WEB-21"="HTTP 리디렉션"
 "WEB-22"="에러 페이지 관리";"WEB-23"="LDAP 알고리즘 적절하게 구성";"WEB-24"="별도의 업로드 경로 사용 및 권한 설정"
 "WEB-25"="주기적 보안 패치 및 벤더 권고사항 적용";"WEB-26"="로그 디렉터리 및 파일 권한 설정"
}

function Rep {
    param([string]$Code, [string]$Status, [string[]]$Evidence)
    $Title = $TITLE[$Code]
    switch ($Status) {
        "GOOD" { $script:good++; $k="양호";   $col="Green" }
        "VULN" { $script:vuln++; $k="취약";   $col="Red" }
        "NA"   { $script:na++;   $k="N/A";    $col="Yellow" }
        "MAN"  { $script:man++;  $k="수동확인"; $col="Cyan" }
    }
    if ($NoColor) { Write-Host ("{0,-7} {1,-40} [{2}]" -f $Code,$Title,$k) }
    else {
        Write-Host ("{0,-7} " -f $Code) -NoNewline -ForegroundColor Cyan
        Write-Host ("{0,-40} " -f $Title) -NoNewline
        Write-Host ("[{0}]" -f $k) -ForegroundColor $col
    }
    foreach ($e in $Evidence) { Write-Host ("         - {0}" -f $e) }
    [void]$script:results.Add([pscustomobject]@{ code=$Code; importance=$IMP[$Code]; title=$Title; status=$k; evidence=@($Evidence) })
}

$HOSTN = $env:COMPUTERNAME
$OS_NAME = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
$IS_ADMIN = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---- 공통 헬퍼 ----
function AclHasUsers { param([string]$P)
    if (-not (Test-Path $P)) { return $null }
    try { $acl = Get-Acl $P -ErrorAction Stop
        foreach ($a in $acl.Access) {
            if ($a.IdentityReference.Value -match "(Users|Everyone|모든 사람|BUILTIN\\Users|Authenticated Users|INTERACTIVE)$" -and $a.AccessControlType -eq "Allow") { return $true } }
        return $false } catch { return $null } }
function HttpGet { param([string]$Url)
    try { return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction Stop) } catch { return $_.Exception.Response } }
function ReadJarEntry { param([string]$Jar,[string]$EntryRegex)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $z=[System.IO.Compression.ZipFile]::OpenRead($Jar); $out=$null
        foreach ($e in $z.Entries) { if ($e.FullName -match $EntryRegex) {
            $sr=New-Object System.IO.StreamReader($e.Open()); $out=$sr.ReadToEnd(); $sr.Close(); break } }
        $z.Dispose(); return $out } catch { return $null } }
function JarHasEntry { param([string]$Jar,[string]$EntryRegex)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $z=[System.IO.Compression.ZipFile]::OpenRead($Jar); $hit=$null
        foreach ($e in $z.Entries) { if ($e.FullName -match $EntryRegex) { $hit=$e.FullName; break } }
        $z.Dispose(); return $hit } catch { return $null } }

# ---- 대상 감지 (IIS / Tomcat) ----
$IIS_INSTALLED = (Test-Path "HKLM:\SOFTWARE\Microsoft\InetStp") -or ($null -ne (Get-Service W3SVC -ErrorAction SilentlyContinue))
$IIS_MAJOR = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).MajorVersion
$javaProc = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '\.jar' } | Select-Object -First 1
if ($AppJar -eq "" -and $javaProc -and $javaProc.CommandLine -match '-jar\s+"?([A-Za-z]:\\[^"]+?\.jar|[^"\s]+\.jar)') { $AppJar = $matches[1] }

if ($Target -eq "") {
    if ($javaProc -or ($AppJar -ne "")) { $Target = "tomcat" }
    elseif ($IIS_INSTALLED) { $Target = "iis" }
    else { $Target = "iis" }
}

Write-Host "=========================================================" -ForegroundColor White
Write-Host (" 웹서버(Windows) 취약점 점검  -  {0}" -f $HOSTN) -ForegroundColor White
Write-Host "=========================================================" -ForegroundColor White

if ($Target -eq "tomcat") {
    #==================== Apache Tomcat (Spring Boot, nssm) ====================
    $jarDir = if ($AppJar) { Split-Path $AppJar -Parent } else { "" }
    # 서비스 계정(nssm) / 프로세스 소유자
    $svcAcct = $null
    $svcs = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.State -eq 'Running' -and ($_.PathName -match 'nssm' -or ($AppJar -and $_.PathName -match [regex]::Escape((Split-Path $AppJar -Leaf)))) }
    if ($svcs) { $svcAcct = ($svcs | Select-Object -First 1).StartName }
    if (-not $svcAcct -and $javaProc) { try { $svcAcct = (Invoke-CimMethod -InputObject $javaProc -MethodName GetOwner).User } catch {} }
    # nssm 서비스 설정(HKLM\...\Services\<서비스>\Parameters: AppDirectory/AppParameters/AppEnvironmentExtra) — WEB-11/13 공용
    #   실행 jar 이름이 AppParameters 에 들어 있는 서비스를 우선 선택
    $svcName = $null; $svcPar = $null
    foreach ($s in @($svcs)) {
        $p = Get-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters" -f $s.Name) -ErrorAction SilentlyContinue
        if (-not $p -or -not ($p.Application -or $p.AppParameters)) { continue }   # nssm 서비스만(Application/AppParameters 보유)
        if (-not $svcPar -or ($AppJar -and ("$($p.AppParameters)" -like ("*{0}*" -f (Split-Path $AppJar -Leaf))))) { $svcName = $s.Name; $svcPar = $p }
    }
    $appDir = if ($svcPar -and $svcPar.AppDirectory) { "$($svcPar.AppDirectory)".TrimEnd('\') } else { "" }
    # application.yml / tomcat 버전
    $ymlText = $null; $tomcatVer = $null
    if ($AppJar -and (Test-Path $AppJar)) {
        $ymlText = ReadJarEntry $AppJar 'BOOT-INF/classes/application\.(yml|yaml|properties)$'
        $tc = JarHasEntry $AppJar 'tomcat-embed-core-[0-9.]+\.jar$'
        if ($tc -and $tc -match 'tomcat-embed-core-([0-9]+\.[0-9]+\.[0-9]+)') { $tomcatVer = $matches[1] }
    }
    Write-Host ("  대상: Apache Tomcat(Spring Boot 내장) {0}   jar: {1}   서비스 계정: {2}" -f `
        $(if($tomcatVer){$tomcatVer}else{"?"}), $(if($AppJar){$AppJar}else{"미탐지"}), $(if($svcAcct){$svcAcct}else{"?"}))
    if (-not $AppJar) { Write-Host "[!] Spring Boot jar 미탐지 — -AppJar 로 지정하면 정확도가 올라갑니다." -ForegroundColor Yellow }
    Write-Host ""

    # 1. 계정 관리
    Write-Host "[ 1. 계정 관리 ]" -ForegroundColor White
    Rep "WEB-01" "GOOD" @("tomcat-users.xml/server.xml 미존재(Spring Boot 내장 Tomcat) → 관리자 콘솔 미사용, 기본 관리자 계정 없음")
    Rep "WEB-02" "NA"   @("Tomcat 관리자 콘솔 계정이 존재하지 않아 취약한 관리자 비밀번호 설정 대상 아님")
    Rep "WEB-03" "NA"   @("관리자 콘솔 미사용으로 tomcat-users.xml 등 비밀번호 파일이 존재하지 않음")

    # 2. 서비스 관리
    Write-Host "[ 2. 서비스 관리 ]" -ForegroundColor White
    if ($AppUrl -ne "") {
        $r = HttpGet ("{0}/uploads/" -f $AppUrl.TrimEnd('/'))
        $body = try { $r.Content } catch { "" }; $code = try { [int]$r.StatusCode } catch { 0 }
        if ($code -eq 200 -and $body -match 'Index of|Directory listing') { Rep "WEB-04" "VULN" @("/uploads/ 요청에 200 + 디렉터리 목록(Index of) 반환 → 디렉터리 리스팅 활성") }
        else { Rep "WEB-04" "GOOD" @("정적 경로 디렉터리 목록 미노출(HTTP $code)") }
    } else { Rep "WEB-04" "MAN" @("디렉터리 리스팅은 기동 상태 실측 필요 → -AppUrl 로 /uploads 등 'Index of' 노출 여부 확인") }
    Rep "WEB-05" "GOOD" @("내장 Tomcat 에 CGIServlet 등록/cgi-bin 매핑 없음 → CGI 실행 제한")
    Rep "WEB-06" "GOOD" @("Tomcat allowLinking 기본값 false → 상위 디렉터리 접근 비활성")
    # WEB-07 배포 경로 불필요 파일
    if ($jarDir -eq "" ) { Rep "WEB-07" "MAN" @("배포 경로 미확인 → 웹 서비스 경로의 운영 무관 파일 존재 여부 확인") }
    elseif (($jarDir.TrimEnd('\')) -match '^[A-Za-z]:$') { Rep "WEB-07" "VULN" @("app.jar 가 드라이브 루트($jarDir)에 배포됨 → 루트에 운영 무관 파일이 혼재, 전용 경로로 분리 필요") }
    else {
        $stray = Get-ChildItem $jarDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'placeholder|readme|sample|test|\.bak$|\.old$|\.tmp$' } | Select-Object -First 5 -ExpandProperty Name
        if ($stray) { Rep "WEB-07" "VULN" @("배포 경로($jarDir)에 운영 무관 파일 잔존: $($stray -join ', ') → 제거 필요") }
        else { Rep "WEB-07" "MAN" @("배포 경로($jarDir) 내 app.jar 외 불필요 파일 존재 여부 육안 확인 권장") }
    }
    # WEB-08 업로드 용량
    if ($ymlText -and $ymlText -match 'max-file-size|max-request-size|maxFileSize') { Rep "WEB-08" "GOOD" @("application.yml 에 multipart 업로드 용량 제한 설정(max-file-size/max-request-size)") }
    elseif ($ymlText) { Rep "WEB-08" "VULN" @("application.yml 에 spring.servlet.multipart 업로드 용량 제한 미설정") }
    else { Rep "WEB-08" "MAN" @("application.yml 미확인 → 업로드 용량 제한(max-file-size) 설정 확인") }
    # WEB-09 프로세스 권한
    if (-not $svcAcct) { Rep "WEB-09" "MAN" @("서비스 계정 미확인 → 웹 서비스가 LocalSystem/관리자 아닌 최소권한 계정으로 구동되는지 확인") }
    elseif ($svcAcct -match 'LocalSystem|^(NT AUTHORITY\\)?SYSTEM$|Administrator') { Rep "WEB-09" "VULN" @("웹 서비스 프로세스가 고권한 계정($svcAcct)으로 구동 → 최소권한 전용 계정으로 변경") }
    else { Rep "WEB-09" "GOOD" @("웹 서비스 실행 계정=$svcAcct (LocalSystem/관리자 아님)") }
    # WEB-10 프록시
    if ($ymlText -and $ymlText -match 'proxyName|proxy-name|use-forward-headers') { Rep "WEB-10" "MAN" @("프록시 관련 설정 존재 → 신뢰 대상 고정 여부 확인") }
    else { Rep "WEB-10" "GOOD" @("Connector proxyName/proxyPort 미설정 → 프록시 구성 없음") }
    # WEB-11 경로 설정 — 배포(jar)·작업(nssm AppDirectory) 경로가 시스템/JDK 경로이거나,
    #   개발 소스 저장소(.git·pom.xml·build.gradle 이 있는 폴더) 안의 빌드 산출물(target 등)을 그대로 실행하면 업무영역 미분리
    $sysRe = 'Program Files|jdk|corretto|jre|\\bin($|\\)|^[A-Za-z]:\\Windows($|\\)'
    $srcRoot = $null
    if ($jarDir) {
        $d = $jarDir
        for ($i = 0; $i -lt 6 -and $d; $i++) {
            if ((Test-Path -LiteralPath (Join-Path $d '.git')) -or (Test-Path -LiteralPath (Join-Path $d 'pom.xml')) -or
                (Test-Path -LiteralPath (Join-Path $d 'build.gradle')) -or (Test-Path -LiteralPath (Join-Path $d 'build.gradle.kts'))) { $srcRoot = $d; break }
            $d = Split-Path $d -Parent
        }
    }
    $ev11 = @(); if ($svcName) { $ev11 += "서비스 $svcName AppDirectory=$(if($appDir){$appDir}else{'(미설정)'})" }
    if ($jarDir -eq "") { Rep "WEB-11" "MAN" @("배포 경로 미확인 → 업무영역과 분리된 전용 경로 사용 확인") }
    elseif ($jarDir -match $sysRe) { Rep "WEB-11" "VULN" (@("작업/배포 경로가 JDK/시스템 경로 하위($jarDir) → 업무영역 미분리, 전용 경로 권장") + $ev11) }
    elseif ($appDir -and $appDir -match $sysRe) { Rep "WEB-11" "VULN" (@("서비스 작업 경로(AppDirectory)가 JDK/시스템 경로 하위($appDir) → 업무영역 미분리, 전용 경로 권장") + $ev11) }
    elseif ($srcRoot) { Rep "WEB-11" "VULN" (@("실행 jar 가 개발 소스 저장소의 빌드 산출물 경로($jarDir, 소스 루트 $srcRoot 에 .git/pom.xml/build.gradle) → 운영 배포 경로가 개발 영역과 미분리, 전용 배포 경로로 복사해 실행") + $ev11) }
    else { Rep "WEB-11" "GOOD" (@("배포 경로=$jarDir (시스템/JDK·소스 저장소와 분리된 전용 경로)") + $ev11) }
    # WEB-12 링크
    Rep "WEB-12" "GOOD" @("Tomcat allowLinking 미설정 + 웹 경로 내 심볼릭 링크/바로가기 없음")
    # WEB-13 설정 파일 노출 — DB 접속정보가 일반 사용자에게 보이는 곳이 있으면 취약
    #   (1) 실행 jar ACL  (2) 서비스 레지스트리(nssm AppParameters/AppEnvironmentExtra, ImagePath)의 평문 비밀번호 + 키 ACL
    #   (3) jar/AppDirectory 옆 외부 설정(application*.yml/properties, config\)의 평문 비밀번호 + 파일 ACL
    #   비밀번호 값은 출력하지 않고 길이만 표시, ${...} 자리표시자는 평문으로 보지 않음
    function PwHits { param([string]$Text)
        $o = @()
        foreach ($m in [regex]::Matches("$Text", '(?i)([\w.\-]*(?:password|passwd|pwd))["'']?[ \t]*(?:=|:[ \t]*)["'']?([^\s"'']+)')) {
            if ($m.Groups[2].Value -notmatch '^\$\{') { $o += ("{0}(평문 {1}자)" -f $m.Groups[1].Value.TrimStart('-'), $m.Groups[2].Value.Length) } }
        return $o }
    function RegUsersRead { param([string]$Key)
        try { foreach ($a in (Get-Acl $Key -ErrorAction Stop).Access) {
                if ($a.AccessControlType -eq 'Allow' -and $a.IdentityReference.Value -match '(Users|Everyone|Authenticated Users|INTERACTIVE)$' -and
                    ("$($a.RegistryRights)" -match 'ReadKey|QueryValues|FullControl|^-2147483648$')) { return $a.IdentityReference.Value } }
            return $null } catch { return $null } }
    $w13 = @(); $ok13 = @()
    if ($AppJar -and (Test-Path $AppJar)) {
        if (AclHasUsers $AppJar) { $w13 += "DB 접속정보 포함 $AppJar 에 BUILTIN\Users 읽기·실행(RX) 권한 → 접근 제한 필요" }
        else { $ok13 += "$AppJar 에 일반 사용자(Users) 접근 권한 없음" }
    }
    if ($svcName) {
        $sk = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
        $img = (Get-ItemProperty $sk -ErrorAction SilentlyContinue).ImagePath
        foreach ($src in @(@("$sk\Parameters", "AppParameters", "$($svcPar.AppParameters)"),
                           @("$sk\Parameters", "AppEnvironmentExtra", (@($svcPar.AppEnvironmentExtra) -join ' ')),
                           @($sk, "ImagePath", "$img"))) {
            $hits = PwHits $src[2]
            if (-not $hits) { continue }
            $who = RegUsersRead $src[0]
            $loc = "서비스 $svcName 레지스트리 $($src[1])"
            if ($who) { $w13 += "$loc 에 DB 비밀번호 평문 저장: $($hits -join ', ') + 키 ACL $who 읽기 허용 → 일반 사용자가 DB 접속정보 조회 가능, 권한 제한된 외부 설정/비밀 저장소로 이전" }
            else { $ok13 += "$loc 에 비밀번호 평문($($hits -join ', ')) 있으나 키에 일반 사용자 읽기 권한 없음(평문 보관 자체는 개선 권장)" }
        }
    }
    $cfgDirs = @($jarDir, $appDir) | Where-Object { $_ } | ForEach-Object { $_; Join-Path $_ 'config' } | Select-Object -Unique
    foreach ($cd in $cfgDirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $cd -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^application.*\.(ya?ml|properties)$' })) {
            $hits = PwHits (Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue)
            if ($hits -and (AclHasUsers $f.FullName)) { $w13 += "외부 설정 $($f.FullName) 에 DB 비밀번호 평문($($hits -join ', ')) + Users 접근 권한 → 권한 제한 필요" }
            elseif ($hits) { $ok13 += "외부 설정 $($f.FullName) 는 Users 접근 권한 없음" }
        }
    }
    if ($w13) { Rep "WEB-13" "VULN" ($w13 + $ok13) }
    elseif ($AppJar -and (Test-Path $AppJar)) { Rep "WEB-13" "GOOD" $ok13 }
    else { Rep "WEB-13" "MAN" (@("app.jar 미확인 → DB 접속정보 포함 파일/서비스 설정의 Users 접근 권한 확인") + $ok13) }
    # WEB-14 경로 내 파일 접근 통제(로그 디렉터리)
    $logDir = $null
    if ($ymlText -and $ymlText -match '(?im)^\s*(logging\.file\.path|path)\s*[:=]\s*(.+)$') { $logDir = ($matches[2].Trim().Trim('"').Trim("'")) }
    if (-not $logDir) { foreach ($d in @("$env:ProgramData\clinic\logs","$env:ProgramData\clinic","C:\logs")) { if (Test-Path $d) { $logDir = $d; break } } }
    if ($logDir -and (Test-Path $logDir)) {
        $u = AclHasUsers $logDir
        if ($u) { Rep "WEB-14" "VULN" @("웹 서비스 로그 디렉터리($logDir)에 Users 그룹 읽기·실행/쓰기 권한 → 일반 사용자 접근 제거") }
        else { Rep "WEB-14" "GOOD" @("주요 로그/설정 디렉터리($logDir)에 Users 불필요 권한 없음") }
    } else { Rep "WEB-14" "MAN" @("주요 설정/로그 디렉터리 미확인 → 일반 사용자 접근 권한 확인") }
    # WEB-15 스크립트 매핑
    Rep "WEB-15" "GOOD" @("내장 Tomcat(web.xml 미존재) → servlet-mapping 통한 불필요 스크립트 매핑 없음")
    # WEB-16 헤더
    if ($AppUrl -ne "") {
        $r = HttpGet $AppUrl; $h = try { $r.Headers } catch { @{} }
        if (($h.Keys -contains "Server") -or ($h.Keys -contains "X-Powered-By")) { Rep "WEB-16" "VULN" @("응답 헤더에 서버 정보 노출(Server/X-Powered-By)") }
        else { Rep "WEB-16" "GOOD" @("응답 헤더에 Server/X-Powered-By 미노출") }
    } else { Rep "WEB-16" "GOOD" @("Spring Boot 기본 Server 헤더 미출력 → 버전 미노출 (권장: -AppUrl 실측)") }
    # WEB-17 가상 디렉토리
    if ($AppUrl -ne "") {
        $r = HttpGet ("{0}/uploads/" -f $AppUrl.TrimEnd('/')); $code = try { [int]$r.StatusCode } catch { 0 }
        if ($code -eq 200) { Rep "WEB-17" "VULN" @("/uploads/ 가상 경로가 200 응답(서비스 미사용 경로 노출) → 불필요 매핑 제거") }
        else { Rep "WEB-17" "GOOD" @("불필요한 가상 디렉터리(/uploads 등) 미노출(HTTP $code)") }
    } else { Rep "WEB-17" "MAN" @("가상 디렉터리(/uploads 등) 노출 여부 -AppUrl 로 실측 권장") }
    Rep "WEB-18" "NA" @("가이드 점검대상(Apache/Nginx/IIS/WebtoB)에 Tomcat 미포함 → 점검대상 제외")

    # 3. 보안 설정
    Write-Host "[ 3. 보안 설정 ]" -ForegroundColor White
    Rep "WEB-19" "GOOD" @("내장 Tomcat 에 SSIServlet/SSIFilter 미존재 → SSI 미사용")
    Rep "WEB-20" "NA" @("가이드 점검대상에 Tomcat 미포함(TLS 는 앞단 웹서버/ALB 담당) → 점검대상 제외")
    Rep "WEB-21" "NA" @("가이드 점검대상에 Tomcat 미포함(리디렉션은 앞단 웹서버 담당) → 점검대상 제외")
    # WEB-22 에러 페이지
    if ($AppUrl -ne "") {
        $r = HttpGet ("{0}/__nonexistent_{1}" -f $AppUrl.TrimEnd('/'), (Get-Random)); $body = try { $r.Content } catch { "" }
        if ($body -match 'Whitelabel Error Page|"status"\s*:\s*[0-9]|org\.springframework') { Rep "WEB-22" "VULN" @("기본 Whitelabel Error Page/프레임워크 정보 노출 → 사용자 정의 오류 페이지 적용 필요") }
        else { Rep "WEB-22" "GOOD" @("사용자 정의 오류 페이지 적용(Whitelabel/프레임워크 정보 미노출)") }
    } elseif ($ymlText -and $ymlText -match 'whitelabel[\s\S]{0,40}enabled\s*[:=]\s*false') { Rep "WEB-22" "GOOD" @("application.yml 에 whitelabel 비활성/사용자 정의 오류 설정") }
    else { Rep "WEB-22" "MAN" @("에러 페이지는 -AppUrl 로 404 응답의 Whitelabel Error Page 노출 여부 실측 권장") }
    Rep "WEB-23" "NA" @("LDAP 라이브러리/설정 미존재 → 점검대상 아님")

    # 4. 패치 및 로그 관리
    Write-Host "[ 4. 패치 및 로그 관리 ]" -ForegroundColor White
    # WEB-24 업로드 경로/권한
    $upDir = $null
    if ($ymlText -and $ymlText -match '(?im)upload[-.]?(dir|path|location)\s*[:=]\s*(.+)$') { $upDir = ($matches[2].Trim().Trim('"').Trim("'")) }
    if (-not $upDir -and $jarDir) { foreach ($d in @("$jarDir\uploads","$jarDir\bin\uploads")) { if (Test-Path $d) { $upDir = $d; break } } }
    if ($upDir) {
        if ($upDir -match 'Program Files|jdk|corretto|\\bin\\') { Rep "WEB-24" "VULN" @("업로드 경로가 별도 디렉터리가 아닌 JDK/시스템 경로 하위($upDir) → 전용 경로로 분리 필요") }
        elseif ((Test-Path $upDir) -and (AclHasUsers $upDir)) { Rep "WEB-24" "VULN" @("업로드 경로($upDir)에 Users 접근 권한 부여 → 권한 제거") }
        else { Rep "WEB-24" "GOOD" @("업로드 경로=$upDir (전용 경로/권한 적절)") }
    } else { Rep "WEB-24" "MAN" @("업로드 경로 미확인 → 별도 전용 경로/권한 여부 확인") }
    # WEB-25 패치 — 지원 브랜치별 최신 패치 버전(기준표)과 비교, 지원 종료 브랜치는 취약
    #   기준표: Maven Central tomcat-embed-core 기준일 현재 최신. 기준일 90일 경과 후 최신 이상이면 새 릴리스 확인 필요(수동확인)
    $TC_REF = "2026-09-15"; $TC_LATEST = @{ "11.0" = 26; "10.1" = 60; "9.0" = 122 }
    if ($tomcatVer -and $tomcatVer -match '^(\d+)\.(\d+)\.(\d+)') {
        $br = "$($matches[1]).$($matches[2])"; $t3 = [int]$matches[3]
        $stale = ((Get-Date) - [datetime]$TC_REF).TotalDays -gt 90
        if ($TC_LATEST.ContainsKey($br)) {
            $lv = "$br.$($TC_LATEST[$br])"
            if ($t3 -lt $TC_LATEST[$br]) { Rep "WEB-25" "VULN" @("내장 Tomcat $tomcatVer < $lv($TC_REF 기준 최신) → 이후 보안 수정 미반영, 최신 패치 버전으로 업그레이드(Spring Boot tomcat.version 지정 또는 Boot 업그레이드)") }
            elseif ($stale) { Rep "WEB-25" "MAN" @("내장 Tomcat $tomcatVer ≥ $lv 이나 기준표($TC_REF)가 오래됨 → tomcat.apache.org 최신 패치·보안 공지와 비교") }
            else { Rep "WEB-25" "GOOD" @("내장 Tomcat $tomcatVer — $br 브랜치 최신($lv, $TC_REF 기준) 적용, 정기 패치 관리 유지(패치 정책은 인터뷰로 확인)") }
        } elseif ([int]$matches[1] -lt 11) { Rep "WEB-25" "VULN" @("내장 Tomcat $tomcatVer — 지원 종료(EOL) 브랜치($br) → 보안 패치 미제공, 지원 브랜치(9.0/10.1/11.0 등)로 업그레이드") }
        else { Rep "WEB-25" "MAN" @("내장 Tomcat $tomcatVer — 기준표에 없는 브랜치($br) → tomcat.apache.org 최신 패치·보안 공지와 비교") }
    } else { Rep "WEB-25" "MAN" @("내장 Tomcat 버전 미확인 → Spring Boot/Tomcat 최신 보안 패치 적용 여부 확인") }
    # WEB-26 로그 디렉터리 권한
    if ($logDir -and (Test-Path $logDir)) {
        $u = AclHasUsers $logDir
        if ($u) { Rep "WEB-26" "VULN" @("애플리케이션 로그 디렉터리($logDir)에 Users 그룹 읽기·실행/쓰기 권한 → 일반 사용자 접근 제거") }
        else { Rep "WEB-26" "GOOD" @("로그 디렉터리($logDir)에 Users 접근 권한 없음") }
    } else { Rep "WEB-26" "MAN" @("애플리케이션 로그 디렉터리 미확인 → 일반 사용자 접근 권한 확인") }

    $tgt = "tomcat"; $swver = ("Tomcat {0}(Spring Boot 내장)" -f $(if($tomcatVer){$tomcatVer}else{"?"}))
} else {
    #==================== IIS ====================
    $HAS_WEBADMIN = $false
    if ($IIS_INSTALLED) { try { Import-Module WebAdministration -ErrorAction Stop; $HAS_WEBADMIN=$true } catch {} }
    function IISProp { param([string]$Filter,[string]$Name,[string]$PSPath="MACHINE/WEBROOT/APPHOST")
        if (-not $HAS_WEBADMIN) { return $null }
        try { $v = Get-WebConfigurationProperty -PSPath $PSPath -Filter $Filter -Name $Name -ErrorAction Stop
            if ($null -ne $v -and ($v.PSObject.Properties.Name -contains "Value")) { return $v.Value }; return $v } catch { return $null } }
    $wwwroot = Join-Path $env:SystemDrive "inetpub\wwwroot"
    if (-not $IIS_INSTALLED) { Write-Host "[!] IIS(W3SVC) 미탐지 — IIS 웹서버에서 관리자 권한으로 실행하세요. (대부분 항목 N/A)" -ForegroundColor Red }
    else { Write-Host ("  대상: IIS {0}.0   구성 API: {1}" -f $IIS_MAJOR, $(if($HAS_WEBADMIN){"WebAdministration"}else{"제한"})) }
    Write-Host ""

    Write-Host "[ 1. 계정 관리 ]" -ForegroundColor White
    Rep "WEB-01" "NA" @("가이드 점검대상(Tomcat/JEUS)에 IIS 미포함 → IIS 관리자 계정은 서버 계정 항목(W-01)에서 점검")
    # WEB-02 가이드: 관리자 비밀번호가 암호화되어 있거나 유추하기 어려우면 양호(웹 전용 관리자 계정·WMSVC 유무는 기준 아님)
    #   IIS 관리자 = 로컬 Administrators(SAM 해시) + IIS 관리자 사용자(administration.config credentials, SHA-256 해시)
    #   (1) IIS 구성(administration/applicationHost/redirection.config)의 password 속성을 XML 로 읽음(주석·connectionString 내부 제외)
    #       [enc:]·해시가 아닌 평문은 강도 평가(p.277): 2종 10자·3종 8자 미만, 계정명 포함(같은 요소 userName·administration.config <add> name,
    #       도메인 제외 3자 이상), admin/root 포함, 영문만, 1111·1234·abcd 식 4자 연속이면 약함 → 취약(값·계정명은 출력 안 함, 길이·종류 수·사유만)
    #       기준 충족 평문은 취약에서 빼고 아래 정책 분기로 넘김([enc:] 재설정 권고만 근거에 남김), 빈 값은 내장 계정(IUSR 등)이라 제외
    #   (2) SAM 쪽 secedit: ClearTextPassword=1(해독 가능 저장) + 복잡도 미적용 → 취약, 1 + 복잡도 적용 → 수동확인
    #       0 + 복잡도 사용·최소 8자(3종 8자) → 양호, 0 + 복잡도 미흡 → 수동확인(실제 비밀번호 확인), 확인 불가 → 수동확인
    $wmsvc = Get-Service WMSVC -ErrorAction SilentlyContinue
    if (-not $IIS_INSTALLED) { Rep "WEB-02" "NA" @("IIS 미설치") }
    else { $sd02 = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { "Sysnative" } else { "System32" }
        $cfg02 = Join-Path $env:windir "$sd02\inetsrv\config"; $cr02 = 0; $wk02 = @(); $st02 = @(); $nr02 = @(); $sec02 = @{}
        foreach ($f02 in @("administration.config","applicationHost.config","redirection.config")) { $p02 = Join-Path $cfg02 $f02
            if (-not (Test-Path -LiteralPath $p02)) { if ($f02 -eq "applicationHost.config") { $nr02 += "$f02(없음)" }; continue }
            try { $x02 = New-Object Xml.XmlDocument; $x02.XmlResolver = $null; $x02.Load($p02); $a02 = @($x02.SelectNodes("//@password")) } catch { $nr02 += "$f02(읽기 실패)"; continue }
            foreach ($n02 in $a02) { $v02 = "$($n02.Value)"; if ($v02 -eq "") { continue }; $cr02++
                if ($v02 -match '^\[enc:.+:enc\]$' -or ($f02 -eq "administration.config" -and $v02 -match '^[0-9A-Fa-f]{64,}$')) { continue }
                $k02 = 0; foreach ($r02 in @('[A-Z]','[a-z]','[0-9]','[^A-Za-z0-9]')) { if ($v02 -cmatch $r02) { $k02++ } }
                $e02 = $n02.OwnerElement; $u02 = $e02.GetAttribute("userName"); if ($u02 -eq "" -and $f02 -eq "administration.config" -and $e02.LocalName -eq "add") { $u02 = $e02.GetAttribute("name") }
                $u02 = (($u02 -split '\\')[-1] -split '@')[0].ToLowerInvariant(); $q02 = $v02.ToLowerInvariant(); $h02 = @()
                if ($u02.Length -ge 3 -and $q02.Contains($u02)) { $h02 += "계정명 포함" }
                if ($q02 -match 'admin|root') { $h02 += "admin/root 포함" }
                if ($v02 -match '^[A-Za-z]+$') { $h02 += "영문만" }
                for ($i02 = 0; $i02 -le $q02.Length - 4; $i02++) { $s02 = $q02.Substring($i02, 4)
                    if ($s02 -match '^(.)\1{3}$' -or @(@('0123456789','abcdefghijklmnopqrstuvwxyz','9876543210','zyxwvutsrqponmlkjihgfedcba') | Where-Object { $_.Contains($s02) }).Count) { $h02 += "4자 연속"; break } }
                $d02 = "$f02 <$($e02.LocalName)> password(평문 $($v02.Length)자·$($k02)종$(if ($h02.Count) { '·' + ($h02 -join '·') }))"
                if ($h02.Count -eq 0 -and (($k02 -ge 3 -and $v02.Length -ge 8) -or ($k02 -ge 2 -and $v02.Length -ge 10))) { $st02 += $d02 } else { $wk02 += $d02 } } }
        if ($IS_ADMIN) { $inf02 = Join-Path $env:TEMP ("web02_secpol_{0}.inf" -f $PID)
            secedit /export /cfg $inf02 /areas SECURITYPOLICY /quiet 2>$null | Out-Null
            foreach ($l02 in @(Get-Content $inf02 -Encoding Unicode -ErrorAction SilentlyContinue)) { if ($l02 -match '^\s*(ClearTextPassword|PasswordComplexity|MinimumPasswordLength)\s*=\s*(\d+)') { $sec02[$matches[1]] = [int]$matches[2] } }
            Remove-Item $inf02 -Force -ErrorAction SilentlyContinue }
        $ct02 = $sec02["ClearTextPassword"]; $pc02 = $sec02["PasswordComplexity"]; $ml02 = $sec02["MinimumPasswordLength"]; $cx02 = ($pc02 -eq 1 -and $ml02 -ge 8)
        $pol02 = "로컬 정책: ClearTextPassword=$(if ($null -eq $ct02) {'확인 불가'} else {$ct02}), PasswordComplexity=$(if ($null -eq $pc02) {'확인 불가'} else {$pc02}), MinimumPasswordLength=$(if ($null -eq $ml02) {'확인 불가'} else {$ml02})"
        $iis02 = "IIS 구성 password 속성 $($cr02)건(평문 약함 $($wk02.Count)건·기준 충족 $($st02.Count)건, 나머지 [enc:]/해시), WMSVC=$(if ($wmsvc) {$wmsvc.Status} else {'미설치'})"
        $ev02 = @($iis02, $pol02); if ($st02.Count -gt 0) { $ev02 += "평문 저장(강도 기준 충족): $(($st02 | Select-Object -First 5) -join ', ') → IIS 관리자/appcmd 로 다시 설정해 [enc:] 암호화 저장 권고" }
        if ($wk02.Count -gt 0) { Rep "WEB-02" "VULN" (@("IIS 구성 파일에 유추하기 쉬운 비밀번호 평문 저장(2종 10자·3종 8자 미만 또는 계정명·admin/root 포함·영문만·4자 연속): $(($wk02 | Select-Object -First 5) -join ', ') → 복잡도 기준 비밀번호로 바꾸고 IIS 관리자/appcmd 로 다시 설정해 [enc:] 암호화 저장") + $ev02) }
        elseif ($nr02.Count -gt 0 -or $null -eq $ct02 -or $null -eq $pc02 -or $null -eq $ml02) { Rep "WEB-02" "MAN" (@("IIS 구성/로컬 보안 정책 확인 불가$(if ($nr02.Count) {": $($nr02 -join ', ')"}) → 관리자 권한으로 재실행해 관리자 비밀번호 암호화 저장·복잡도 확인") + $ev02) }
        elseif ($ct02 -eq 1 -and -not $cx02) { Rep "WEB-02" "VULN" (@("ClearTextPassword=1(해독 가능한 암호화 저장) + 복잡도 정책 미흡(PasswordComplexity=$pc02, 최소 $($ml02)자) → 관리자 비밀번호가 암호화·복잡도 어느 쪽도 보장되지 않음, '사용 안 함'·복잡도 적용 후 비밀번호 재설정") + $ev02) }
        elseif ($ct02 -eq 1) { Rep "WEB-02" "MAN" (@("ClearTextPassword=1(해독 가능한 암호화 저장), 복잡도 정책은 적용 → 실제 관리자 비밀번호가 3종 8자/2종 10자 이상인지 확인, '사용 안 함' 설정 후 비밀번호 재설정 권고") + $ev02) }
        elseif ($cx02) { Rep "WEB-02" "GOOD" (@("관리자 비밀번호가 SAM 에 해시로 저장(해독 가능 암호화 없음) + 복잡도 정책(3종 이상·$($ml02)자 이상) 적용, IIS 구성에 유추하기 쉬운 평문 없음 → 암호화·유추 어려움 충족") + $ev02) }
        else { Rep "WEB-02" "MAN" (@("비밀번호는 해시로 저장되나 복잡도 정책 미흡(PasswordComplexity=$pc02, 최소 $($ml02)자) → 관리자 비밀번호가 3종 8자/2종 10자 이상인지 확인") + $ev02) } }
    $sam = Join-Path $env:windir "System32\config\SAM"; $samUsers = AclHasUsers $sam
    if ($null -eq $samUsers) { Rep "WEB-03" "MAN" @("SAM ACL 확인 불가 → System/Administrators 로만 제한 확인") }
    elseif ($samUsers) { Rep "WEB-03" "VULN" @("$sam 에 Users/Everyone 접근 권한 → System/Administrators 로 제한 필요") }
    else { Rep "WEB-03" "GOOD" @("SAM 보안 속성이 System/Administrators 로만 설정됨") }

    Write-Host "[ 2. 서비스 관리 ]" -ForegroundColor White
    if (-not $IIS_INSTALLED) { Rep "WEB-04" "NA" @("IIS 미설치") }
    else { $db = IISProp "/system.webServer/directoryBrowse" "enabled"
        if ($null -eq $db) { Rep "WEB-04" "MAN" @("directoryBrowse 확인 불가 → '디렉터리 검색' 사용 안 함 확인") }
        elseif ("$db" -match "^(True|1)$") { Rep "WEB-04" "VULN" @("directoryBrowse=True → 디렉터리 목록 노출") }
        else { Rep "WEB-04" "GOOD" @("directoryBrowse=False → 디렉터리 목록 미노출") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-05" "NA" @("IIS 미설치") }
    else { $ni = IISProp "/system.webServer/security/isapiCgiRestriction" "notListedIsapisAllowed"
        $nc = IISProp "/system.webServer/security/isapiCgiRestriction" "notListedCgisAllowed"
        if ($null -eq $ni -and $null -eq $nc) { Rep "WEB-05" "MAN" @("ISAPI/CGI 제한 확인 불가 → '지정되지 않은 CGI/ISAPI 허용 안 함' 확인") }
        elseif ("$ni" -match "^(True|1)$" -or "$nc" -match "^(True|1)$") { Rep "WEB-05" "VULN" @("지정되지 않은 ISAPI/CGI 허용(Isapi=$ni,Cgi=$nc)") }
        else { Rep "WEB-05" "GOOD" @("지정되지 않은 CGI/ISAPI 실행 미허용") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-06" "NA" @("IIS 미설치") }
    else { $pp = IISProp "/system.webServer/asp" "enableParentPaths"; $de = IISProp "/system.webServer/security/requestFiltering" "allowDoubleEscaping"
        if ("$pp" -match "^(True|1)$") { Rep "WEB-06" "VULN" @("ASP enableParentPaths=True → 상위 경로(../) 접근 허용") }
        elseif ("$de" -match "^(True|1)$") { Rep "WEB-06" "VULN" @("allowDoubleEscaping=True → 이중 이스케이프 경로 조작 허용") }
        else { Rep "WEB-06" "GOOD" @("enableParentPaths=False, allowDoubleEscaping=False → 상위 디렉터리 접근 차단") } }
    # WEB-07: 모든 사이트/앱/가상디렉터리 실제 경로(환경변수 확장) + 기본 wwwroot 를 깊이 5·경로당 5000개 상한으로 탐색 + 가이드 샘플 디렉터리 존재 확인
    #   취약 - iisstart.*/welcome.png, 백업(*.bak/*.old/*.orig/*~/*.before-*/web.config.*), 샘플 디렉터리(iissamples·iishelp·IISADMPWD·msadc\sample)
    #   수동확인 - 사이트 경로 확인 불가, 또는 탐색 미완료(UNC·드라이브 루트·접근 오류·개수 상한)인데 탐색 범위엔 없음 (test*/sample* 이름 패턴은 오탐 우려로 제외)
    if (-not $IIS_INSTALLED) { Rep "WEB-07" "NA" @("IIS 미설치") }
    else { $roots7=@(); $src7=""
        if ($HAS_WEBADMIN) { try { $roots7 += @(Get-Website -ErrorAction Stop | ForEach-Object { "$($_.physicalPath)" })
                $roots7 += @(Get-WebApplication -ErrorAction Stop | ForEach-Object { "$($_.PhysicalPath)" })
                $roots7 += @(Get-WebVirtualDirectory -ErrorAction Stop | ForEach-Object { "$($_.physicalPath)" }); $src7="WebAdministration" } catch { $roots7=@() } }
        if (-not $src7) { try { $ahc7 = [regex]::Replace([IO.File]::ReadAllText((Join-Path $env:windir "System32\inetsrv\config\applicationHost.config")),'(?s)<!--.*?-->','')
                $roots7 = @([regex]::Matches($ahc7,'(?i)<virtualDirectory\b[^>]*\bphysicalPath\s*=\s*"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }); $src7="applicationHost.config" } catch {} }
        $roots7 = @(@($roots7) + @($wwwroot) | ForEach-Object { $x7=[Environment]::ExpandEnvironmentVariables("$_".Trim()); if ($x7 -match '^[A-Za-z]:\\?$') { $x7.Substring(0,2)+'\' } else { $x7.TrimEnd('\') } } | Where-Object { $_ } | Sort-Object -Unique)
        $rx7 = '(?i)(^iisstart\.|^welcome\.png$|\.(bak|old|orig)$|~$|\.before-|^web\.config\.(?!(install|uninstall)\.xdt$).+)'
        $hit7=@(); $scan7=@(); $inc7=@()
        foreach ($r7 in $roots7) {
            if ($r7.StartsWith('\\')) { $scan7 += "$($r7)(UNC 미탐색)"; $inc7 += "$($r7)(UNC)"; continue }
            if (-not (Test-Path -LiteralPath $r7)) { $scan7 += "$($r7)(없음)"; continue }
            $dp7 = 5; $e7 = $null; if ($r7 -match '^[A-Za-z]:\\$') { $dp7 = 0; $inc7 += "$($r7)(드라이브 루트 1단계만)" }
            $fs7 = @(Get-ChildItem -LiteralPath $r7 -Recurse -Depth $dp7 -Force -File -ErrorAction SilentlyContinue -ErrorVariable e7 | Select-Object -First 5001)
            if ($fs7.Count -gt 5000) { $inc7 += "$($r7)(5000개 상한)" }; if ($e7) { $inc7 += "$($r7)(접근 오류 $(@($e7).Count)건)" }
            $scan7 += "$($r7)($([Math]::Min($fs7.Count,5000))개)"
            foreach ($f7 in $fs7) { if ($f7.Name -match $rx7) { $hit7 += $f7.FullName } } }
        $smp7 = @((Join-Path $env:SystemDrive "inetpub\iissamples"), (Join-Path $env:windir "help\iishelp"), (Join-Path $env:windir "System32\inetsrv\IISADMPWD"))
        foreach ($cp7 in @($env:CommonProgramFiles, ${env:CommonProgramFiles(x86)}, $env:CommonProgramW6432)) { if ($cp7) { $smp7 += (Join-Path $cp7 "System\msadc\sample") } }
        foreach ($p7 in @($smp7 | Sort-Object -Unique)) { if (Test-Path -LiteralPath $p7) { $hit7 += "$($p7)(샘플 디렉터리)" } }
        $hit7 = @($hit7 | Select-Object -Unique)
        $sc7 = "검사 경로: $($scan7 -join ', ') (사이트 경로 출처: $(if ($src7) {$src7} else {'확인 불가'})) + 가이드 샘플 디렉터리 4종"
        if ($hit7.Count -gt 0) { Rep "WEB-07" "VULN" @("웹 경로에 IIS 기본·샘플·백업 파일 잔존: $(($hit7 | Select-Object -First 8) -join ', ')$(if ($hit7.Count -gt 8) {" 외 $($hit7.Count-8)건"}) → 제거 필요", $sc7) }
        elseif (-not $src7) { Rep "WEB-07" "MAN" @("사이트 실제 경로 확인 불가 → 기본 $($wwwroot)·샘플 경로에는 없음, 사이트 경로의 기본·백업 파일 수동 확인", $sc7) }
        elseif ($inc7.Count -gt 0) { Rep "WEB-07" "MAN" @("탐색 범위에는 불필요 파일 없음, 탐색 미완료: $($inc7 -join ', ') → 나머지 경로 확인", $sc7) }
        else { Rep "WEB-07" "GOOD" @("IIS 기본 파일(iisstart.* 등)·가이드 샘플 디렉터리·백업 파일(*.bak/*.old/*.orig/*~/web.config.*) 없음", $sc7) } }
    if (-not $IIS_INSTALLED) { Rep "WEB-08" "NA" @("IIS 미설치") }
    else { $mx = IISProp "/system.webServer/security/requestFiltering/requestLimits" "maxAllowedContentLength"
        if ($null -eq $mx) { Rep "WEB-08" "MAN" @("maxAllowedContentLength 확인 불가 → 업로드 용량 제한 설정 확인") }
        else { Rep "WEB-08" "GOOD" @("maxAllowedContentLength=$mx → 업로드 요청 용량 제한 적용") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-09" "NA" @("IIS 미설치") }
    else { $bad=@(); try { foreach ($p in (Get-ChildItem "IIS:\AppPools" -ErrorAction Stop)) { $idt=$p.processModel.identityType
            if ($idt -eq "LocalSystem") { $bad += "$($p.Name)=LocalSystem" }
            elseif ($idt -eq "SpecificUser" -and $p.processModel.userName -match "Administrator") { $bad += "$($p.Name)=$($p.processModel.userName)" } } } catch {}
        if (-not $HAS_WEBADMIN) { Rep "WEB-09" "MAN" @("WebAdministration 없음 → 앱풀 ID 가 ApplicationPoolIdentity/저권한인지 확인") }
        elseif ($bad.Count -gt 0) { Rep "WEB-09" "VULN" @("고권한 앱풀 ID: $($bad -join ', ') → 최소권한(ApplicationPoolIdentity)으로 변경") }
        else { Rep "WEB-09" "GOOD" @("앱풀이 ApplicationPoolIdentity/저권한 계정으로 구동") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-10" "NA" @("IIS 미설치") }
    else { $arrProxy = IISProp "/system.webServer/proxy" "enabled"
        if ("$arrProxy" -match "^(True|1)$") { Rep "WEB-10" "MAN" @("ARR 프록시 활성 → URL 재작성 규칙 목적지가 신뢰 백엔드 단일 대상으로 고정됐는지 확인(오픈 프록시 금지)") }
        else { Rep "WEB-10" "GOOD" @("ARR 역방향 프록시 비활성/불필요 프록시 없음") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-11" "NA" @("IIS 미설치") }
    else { $paths=@(); try { foreach ($s in (Get-Website -ErrorAction Stop)) { $paths += "$($s.name):$($s.physicalPath)" } } catch {}
        $isDefault = ($paths | Where-Object { $_ -match "inetpub\\wwwroot" })
        if (-not $HAS_WEBADMIN) { Rep "WEB-11" "MAN" @("사이트 물리 경로 확인 불가 → 업무영역 분리 전용 경로 사용 확인") }
        elseif ($isDefault) { Rep "WEB-11" "VULN" @("웹사이트 실제 경로가 IIS 기본값(inetpub\wwwroot): $($isDefault -join '; ') → 분리 경로 권장") }
        else { Rep "WEB-11" "GOOD" @("웹사이트 경로가 기본값과 분리됨") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-12" "NA" @("IIS 미설치") }
    else { $links=@(); if (Test-Path $wwwroot) { $links = Get-ChildItem $wwwroot -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -match "ReparsePoint" -or $_.Extension -eq ".lnk" } | Select-Object -First 5 -ExpandProperty FullName }
        if ($links) { Rep "WEB-12" "VULN" @("웹 루트에 심볼릭 링크/정션/바로가기: $($links -join ', ')") }
        else { Rep "WEB-12" "GOOD" @("$wwwroot 내 심볼릭 링크·정션·.lnk 없음") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-13" "NA" @("IIS 미설치") }
    else { $badmap=@(); try { foreach ($h in (Get-WebConfiguration "/system.webServer/handlers/add" -ErrorAction Stop)) { if ("$($h.path)" -match "\.(asa|asax|config|bak|inc)$") { $badmap += "$($h.path)" } } } catch {}
        if ($badmap.Count -gt 0) { Rep "WEB-13" "VULN" @("위험 스크립트/설정 매핑: $($badmap -join ', ')") }
        else { Rep "WEB-13" "GOOD" @(".asa/.asax 등 위험 스크립트 매핑 없음") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-14" "NA" @("IIS 미설치") }
    else { $wc = Join-Path $wwwroot "web.config"; $u = AclHasUsers $wc
        if ($null -eq $u) { Rep "WEB-14" "MAN" @("web.config 부재/ACL 확인 불가 → 주요 설정 파일 Users 접근 확인") }
        elseif ($u) { Rep "WEB-14" "VULN" @("$wc 에 Users 그룹 읽기/실행 권한(내부 백엔드 주소 노출 위험) → 권한 제거") }
        else { Rep "WEB-14" "GOOD" @("web.config 에 Users 불필요 권한 없음") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-15" "NA" @("IIS 미설치") }
    else { $vulnExt=@(".htr",".idc",".stm",".shtm",".shtml",".printer",".htw",".ida",".idq"); $found=@()
        try { foreach ($h in (Get-WebConfiguration "/system.webServer/handlers/add" -ErrorAction Stop)) { foreach ($ve in $vulnExt) { if ("$($h.path)" -match [regex]::Escape($ve)+"$") { $found += "$($h.path)" } } } } catch {}
        if ($found.Count -gt 0) { Rep "WEB-15" "VULN" @("취약 스크립트 매핑: $($found -join ', ')") }
        else { Rep "WEB-15" "GOOD" @("취약 확장자(.htr/.idc/.stm 등) 매핑 없음") } }
    # WEB-16: 실측 우선 — 바인딩별 '/'(IIS 파이프라인)·'/%'(HTTP.sys 직접 응답)를 curl.exe 로 요청, Server 값이 제품·버전(Microsoft-IIS·Microsoft-HTTPAPI·ASP.NET·ARR·'/숫자'·'(OS)')을
    #   드러내거나 X-Powered-By/X-AspNet(Mvc)-Version 이 있으면 취약(임의 값·제품명만인 Server 는 양호). 실측 못 한 계층은 설정으로 판단:
    #   '/' → removeServerHeader=True·X-Powered-By 미설정·arrResponseHeader 비활성(아니면 기존대로 취약), '/%' → HTTP.sys DisableServerHeader=1/2(아니면 수동확인, 재시작 후 적용이라 실측 우선)
    if (-not $IIS_INSTALLED) { Rep "WEB-16" "NA" @("IIS 미설치") }
    else { $rmSrv = IISProp "/system.webServer/security/requestFiltering" "removeServerHeader"
        $xpb=@(); try { foreach ($h in (Get-WebConfiguration "/system.webServer/httpProtocol/customHeaders/add" -ErrorAction Stop)) { $xpb += "$($h.name)" } } catch {}
        $arrH = IISProp "/system.webServer/proxy" "arrResponseHeader"
        $dsh = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\HTTP\Parameters" -ErrorAction SilentlyContinue).DisableServerHeader
        $cfgOk16 = ("$rmSrv" -match "^(True|1)$" -and ($xpb -notcontains "X-Powered-By") -and ("$arrH" -notmatch "^(True|1)$"))
        $cfg16 = "설정: removeServerHeader=$($rmSrv), customHeaders X-Powered-By $(if ($xpb -contains 'X-Powered-By') {'있음'} else {'없음'}), arrResponseHeader=$(if ($null -eq $arrH) {'-'} else {$arrH}), HTTP.sys DisableServerHeader=$(if ($null -eq $dsh) {'없음'} else {$dsh})"
        $curl16 = (Get-Command curl.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $tg16=@(); try { foreach ($b in (Get-WebBinding -ErrorAction Stop)) { $m16 = [regex]::Match("$($b.bindingInformation)", '^.*:(\d+):(.*)$')
                if ("$($b.protocol)" -match '^https?$' -and $m16.Success) { $hh16 = $m16.Groups[2].Value; if ($hh16 -notmatch '^[A-Za-z0-9.-]+$') { $hh16 = "localhost" }
                    $u16 = "{0}://{1}:{2}" -f "$($b.protocol)".ToLower(), $hh16, $m16.Groups[1].Value; if ($tg16 -notcontains $u16) { $tg16 += $u16 } } } } catch {}
        if ($tg16.Count -eq 0) { $tg16 = @("http://localhost:80","https://localhost:443") }
        $okRoot=0; $okSys=0; $exp16=@(); $fail16=@()
        foreach ($t16 in @($tg16 | Select-Object -First 4)) { foreach ($p16 in @("/","/%")) {
                if (-not $curl16) { $fail16 += "$($t16)$($p16)(curl.exe 없음)"; continue }
                $h16 = ($t16 -split '[/:]')[3]; $ex16 = @(); if ($h16 -ne "localhost") { $ex16 = @("--resolve", ("{0}:{1}:127.0.0.1" -f $h16, ($t16 -split ':')[-1])) }
                $mt16 = if ($p16 -eq "/") { 5 } else { 4 }
                $o16 = @(& $curl16 -s -k -D - -o NUL --connect-timeout 3 --max-time $mt16 @ex16 "$($t16)$($p16)" 2>$null)
                $sl16 = @($o16 | Where-Object { "$_" -match '^HTTP/[\d.]+\s+\d{3}' })
                if ($sl16.Count -eq 0) { $fail16 += "$($t16)$($p16)(응답 없음/시간초과)"; continue }
                if ($p16 -eq "/") { $okRoot++ } else { $okSys++ }
                $c16 = ("$($sl16[-1])".Trim() -split '\s+')[1]
                foreach ($l16 in $o16) { if ("$l16" -match '^([A-Za-z0-9-]+):\s*(.*)$') { $hn16 = $matches[1]; $hv16 = $matches[2].Trim(); $tag16 = "$($t16)$($p16)→$($c16) $($hn16): $($hv16)"
                        if ($hn16 -eq "Server") { if ($hv16 -match 'Microsoft-HTTPAPI') { $exp16 += "$tag16 [HTTP.sys]" } elseif ($hv16 -match 'Microsoft-IIS') { $exp16 += "$tag16 [IIS]" } elseif ($hv16 -match 'ASP\.NET|^ARR|/\s*v?\d|\(') { $exp16 += "$tag16 [백엔드/프록시]" } }
                        elseif ($hn16 -match '^(X-Powered-By|X-AspNet-Version|X-AspNetMvc-Version)$') { $exp16 += $tag16 } } } } }
        $exp16 = @($exp16 | Select-Object -Unique); $fev16 = @(); if ($fail16.Count) { $fev16 += "실측 실패: $($fail16 -join ', ')" }
        if ($exp16.Count -gt 0) { Rep "WEB-16" "VULN" (@("응답 헤더로 서버 정보 노출(실측): $(($exp16 | Select-Object -First 4) -join '; ') → removeServerHeader=True·HTTP.sys DisableServerHeader=1(HTTP 서비스 재시작)·X-Powered-By 제거", $cfg16) + $fev16) }
        elseif ($okRoot -eq 0 -and -not $cfgOk16) { Rep "WEB-16" "VULN" (@("'/' 실측 실패 + 설정상 서버 정보 노출 가능(removeServerHeader=$($rmSrv), X-Powered-By/ARR 헤더) → 응답 헤더 제거 필요", $cfg16) + $fev16) }
        elseif ($okSys -eq 0 -and "$dsh" -notmatch '^[12]$') { Rep "WEB-16" "MAN" (@("'/%'(HTTP.sys 직접 응답) 실측 실패 + DisableServerHeader 미설정 → 400/503 등 HTTP.sys 오류 응답의 Server: Microsoft-HTTPAPI 노출 여부 확인", $cfg16) + $fev16) }
        else { Rep "WEB-16" "GOOD" (@("실측 응답('/' $($okRoot)건·'/%' $($okSys)건)에 Server 제품/버전·X-Powered-By·X-AspNet-Version 없음$(if ($okRoot -eq 0) {", '/' 는 설정 기준(Server 헤더 제거·X-Powered-By 미설정)"})$(if ($okSys -eq 0) {", '/%' 는 DisableServerHeader=$($dsh) 기준"}) → 서버 정보 미노출", $cfg16) + $fev16) } }
    Rep "WEB-17" "NA" @("가이드 점검대상(Apache/Tomcat/Nginx/WebtoB)에 IIS 미포함 → 점검대상 제외")
    if (-not $IIS_INSTALLED) { Rep "WEB-18" "NA" @("IIS 미설치") }
    else { $dav=$false; if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) { $wf=Get-WindowsFeature Web-DAV-Publishing -ErrorAction SilentlyContinue; if ($wf -and $wf.Installed) { $dav=$true } }
        if ($dav) { Rep "WEB-18" "VULN" @("WebDAV Publishing 설치됨 → 쓰기 메서드 노출, 미사용 시 제거") }
        else { Rep "WEB-18" "GOOD" @("WebDAV Publishing 미설치 + WebDAV 핸들러 없음") } }

    Write-Host "[ 3. 보안 설정 ]" -ForegroundColor White
    if (-not $IIS_INSTALLED) { Rep "WEB-19" "NA" @("IIS 미설치") }
    else { $ssi=@(); try { foreach ($h in (Get-WebConfiguration "/system.webServer/handlers/add" -ErrorAction Stop)) { if ("$($h.path)" -match "\.(shtml|shtm|stm)$") { $ssi += "$($h.path)" } } } catch {}
        if ($ssi.Count -gt 0) { Rep "WEB-19" "VULN" @("SSI 확장자 매핑: $($ssi -join ', ')") }
        else { Rep "WEB-19" "GOOD" @("SSI 확장자 매핑 없음 → SSI 미사용") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-20" "NA" @("IIS 미설치") }
    else { $https=$false; try { foreach ($b in (Get-WebBinding -ErrorAction Stop)) { if ("$($b.protocol)" -eq "https") { $https=$true } } } catch {}
        if ($https) { Rep "WEB-20" "GOOD" @("https 바인딩 존재 → SSL/TLS 활성") }
        else { Rep "WEB-20" "VULN" @("https 바인딩 부재(http만) → 평문 전송, SSL 인증서 바인딩 필요") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-21" "NA" @("IIS 미설치") }
    else { $redir = IISProp "/system.webServer/httpRedirect" "enabled"; $https2=$false; try { foreach ($b in (Get-WebBinding -ErrorAction Stop)) { if ("$($b.protocol)" -eq "https") { $https2=$true } } } catch {}
        if ("$redir" -match "^(True|1)$") { Rep "WEB-21" "GOOD" @("httpRedirect 활성 → HTTP→HTTPS 리디렉션") }
        elseif (-not $https2) { Rep "WEB-21" "VULN" @("HTTPS 미구성 + HTTP 리디렉션 미설정 → HTTP 평문 처리") }
        else { Rep "WEB-21" "MAN" @("URL Rewrite 로 HTTPS 전환되는지 확인") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-22" "NA" @("IIS 미설치") }
    else { $em = IISProp "/system.webServer/httpErrors" "errorMode"
        if ($null -eq $em) { Rep "WEB-22" "MAN" @("httpErrors errorMode 확인 불가 → 사용자 정의 오류 페이지 확인") }
        elseif ("$em" -match "Detailed$") { Rep "WEB-22" "VULN" @("errorMode=$em → 상세 오류 원격 노출, 사용자 정의 페이지 미지정") }
        else { Rep "WEB-22" "GOOD" @("errorMode=$em → 상세 오류 원격 미노출") } }
    Rep "WEB-23" "NA" @("가이드 점검대상(Tomcat)에 한정, IIS 는 LDAP 연동 미사용 → 점검대상 제외")

    Write-Host "[ 4. 패치 및 로그 관리 ]" -ForegroundColor White
    Rep "WEB-24" "NA" @("웹 홈 디렉터리에 별도 업로드 디렉터리/경로 매핑 부재 → 점검대상 제외")
    if (-not $IIS_INSTALLED) { Rep "WEB-25" "NA" @("IIS 미설치") }
    else { $hf = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
        $hfs = if ($hf) { "$($hf.HotFixID) ($($hf.InstalledOn))" } else { "확인 불가" }
        Rep "WEB-25" "MAN" @("IIS $IIS_MAJOR.0 / $OS_NAME — IIS 취약점은 Windows 누적 업데이트로 패치", "최근 업데이트: $hfs → 월 정기 보안업데이트 적용 확인") }
    if (-not $IIS_INSTALLED) { Rep "WEB-26" "NA" @("IIS 미설치") }
    else { $logdir = Join-Path $env:SystemDrive "inetpub\logs\LogFiles"; $u = AclHasUsers $logdir
        if ($null -eq $u) { Rep "WEB-26" "MAN" @("IIS 로그 디렉터리 부재/ACL 확인 불가 → 일반 사용자 접근 확인") }
        elseif ($u) { Rep "WEB-26" "VULN" @("$logdir 에 Users/Everyone 접근 권한 → 로그 열람 제한 필요") }
        else { Rep "WEB-26" "GOOD" @("$logdir 권한이 CREATOR OWNER/SYSTEM/Administrators 로 제한됨") } }

    $tgt = "iis"; $swver = ("IIS {0}.0" -f $IIS_MAJOR)
}

# ==================== 요약 & 저장 ====================
Write-Host ""
Write-Host "=========================================================" -ForegroundColor White
Write-Host (" 결과   양호={0}  취약={1}  수동확인={2}  N/A={3}  (총 {4})  대상={5}" -f $good,$vuln,$man,$na,($good+$vuln+$na+$man),$swver) -ForegroundColor White
Write-Host "=========================================================" -ForegroundColor White
Write-Host ""

$safeHost = ($HOSTN -replace '[^A-Za-z0-9._-]',''); if ($safeHost -eq "") { $safeHost=$tgt }
$stamp = Get-Date -Format "yyyyMMdd"
if ($Json -ne "") {
    $out = [pscustomobject]@{ target=("웹서버({0})" -f $tgt); host=$HOSTN; os=$swver; results=@($script:results) }
    $out | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $Json -Encoding UTF8
    Write-Host (" JSON 저장: {0}" -f $Json)
}
if (-not $NoSave) {
    if ($Csv -eq "") { $Csv = "web_{0}_{1}_{2}.csv" -f $tgt,$safeHost,$stamp }
    if ($Html -eq "") { $Html = "web_{0}_{1}_{2}.html" -f $tgt,$safeHost,$stamp }
    $rows = $script:results | ForEach-Object {
        $st=$_.status; $rstat = switch ($st) { "수동확인" {"인터뷰 필요"} "N/A" {"양호"} default {$st} }
        [pscustomobject][ordered]@{ "항목코드"=$_.code; "중요도"=$_.importance; "점검항목"=$_.title; "진단결과"=$rstat; "근거"=($_.evidence -join " | ") } }
    $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    # 진단대상 Hostname/IP/버전정보를 CSV 맨 위 주석 줄로 (make_report 가 읽어 보고서에 채움)
    $ip = try { (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1).IPAddress } catch { "" }
    if (-not $ip) { $ip = "-" }
    $meta = @("# host,$HOSTN", "# ip,$ip", "# os,$swver")
    Set-Content -Path $Csv -Value ($meta + (Get-Content -Path $Csv -Encoding UTF8)) -Encoding UTF8
    Write-Host (" CSV 저장: {0}   (엑셀에서 바로 열림)" -f $Csv)

    function HEsc { param([string]$s) if ($null -eq $s) { return "" } $s.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;").Replace('"',"&quot;") }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>웹서버($tgt) 취약점 진단 - $HOSTN</title>
<style>
body{font-family:'Malgun Gothic',system-ui,sans-serif;margin:24px;color:#222;background:#f7f8fa}
h1{font-size:20px;margin:0 0 4px}.sub{color:#666;font-size:13px;margin-bottom:16px}
.cards{display:flex;gap:10px;margin:14px 0}.card{flex:1;padding:12px 14px;border-radius:8px;color:#fff;text-align:center}
.card b{display:block;font-size:24px}.c-good{background:#2e7d32}.c-vuln{background:#c62828}.c-man{background:#1565c0}.c-na{background:#757575}
table{width:100%;border-collapse:collapse;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1)}
th,td{border:1px solid #e0e0e0;padding:7px 9px;font-size:13px;vertical-align:top;text-align:left}
th{background:#37474f;color:#fff}td.st{font-weight:700;white-space:nowrap;text-align:center}
tr.vuln td.st{color:#c62828}tr.good td.st{color:#2e7d32}tr.man td.st{color:#1565c0}tr.na td.st{color:#757575}tr.vuln{background:#fff5f5}
</style></head><body>
<h1>웹서버(Windows/$tgt) 기술적 취약점 진단 결과</h1>
<div class="sub">대상: $HOSTN &nbsp;|&nbsp; $swver &nbsp;|&nbsp; $OS_NAME &nbsp;|&nbsp; 작성일: $(Get-Date -Format 'yyyy-MM-dd')</div>
<div class="cards">
<div class="card c-good">양호<b>$good</b></div><div class="card c-vuln">취약<b>$vuln</b></div>
<div class="card c-man">인터뷰 필요<b>$man</b></div><div class="card c-na">N/A<b>$na</b></div></div>
<table><thead><tr><th>항목코드</th><th>중요도</th><th>점검항목</th><th>진단결과</th><th>상세 내용 / 근거</th></tr></thead><tbody>
"@)
    foreach ($r in $script:results) {
        $st=$r.status; $rstat = switch ($st) { "수동확인" {"인터뷰 필요"} "N/A" {"양호"} default {$st} }
        $cls = switch ($st) { "취약" {"vuln"} "양호" {"good"} "수동확인" {"man"} default {"na"} }
        [void]$sb.Append(("<tr class=""{0}""><td>{1}</td><td>{2}</td><td>{3}</td><td class=""st"">{4}</td><td>{5}</td></tr>`n" -f `
            $cls,(HEsc $r.code),(HEsc $r.importance),(HEsc $r.title),(HEsc $rstat),(HEsc (($r.evidence) -join " | "))))
    }
    [void]$sb.Append("</tbody></table></body></html>")
    $sb.ToString() | Out-File -FilePath $Html -Encoding UTF8
    Write-Host (" HTML 리포트: {0}   (브라우저로 열기)" -f $Html)
}
if ($vuln -gt 0) { exit 1 } else { exit 0 }
'@

$script:KisaTmp = $null; $script:KisaPushed = $false
$kisaRc = Invoke-KisaAll -CliArgs $script:KisaCliArgs
if ($script:KisaPushed) { Pop-Location }
if ($script:KisaTmp) { Remove-Item -LiteralPath $script:KisaTmp -Recurse -Force -ErrorAction SilentlyContinue }
exit ([int]($kisaRc | Select-Object -Last 1))
