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
#   내장 원본: kisa_unix_check.sh(11c4352e), kisa_win_check.ps1(54b7c537), web_linux_check.sh(4a81af91), web_windows_check.ps1(7fc9f660)
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

# 그룹/기타 권한이 기준을 넘지 않으면 참(소유자 권한은 무시).
#   "권한 640 이하" 의 올바른 해석 — 숫자 크기가 아니라 그룹/기타 비트가 기준의 부분집합인지로 판단.
#   예) 700 은 그룹/기타 권한이 없으므로 640 보다 제한적 → 참(perm_le 의 700>640 오판 보정).
perm_go_le() {  # $1=파일권한  $2=기준(기본 640)
  local p m
  p=$(( 8#${1:-777} )) 2>/dev/null || return 1
  m=$(( 8#${2:-640} ))
  [ $(( (p & 8#070) & ~(m & 8#070) )) -eq 0 ] && [ $(( (p & 8#007) & ~(m & 8#007) )) -eq 0 ]
}

# find 미사용 파일 순회 — 지정한 디렉터리들을 순수 bash(globstar)로 재귀 순회하며
#   "일반 파일" 경로만 한 줄씩 출력한다. (find 명령을 쓰지 않기 위한 대체 구현)
#   * 전체 파일시스템(/) 이 아니라 범위가 한정된 디렉터리에만 사용할 것(메모리·성능).
#   * 심볼릭 링크는 대상이 일반 파일이면 포함(find -L -type f 와 동일한 취지).
walk_reg_files() {
  local d f
  ( shopt -s nullglob dotglob globstar 2>/dev/null
    for d in "$@"; do
      [ -d "$d" ] || continue
      for f in "$d"/**; do
        [ -f "$f" ] && printf '%s\n' "$f"
      done
    done )
}

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
susp=$( shopt -s nullglob dotglob
  for f in /tmp/.* /var/tmp/.* /dev/shm/.* /tmp/*/.* /var/tmp/*/.* /dev/shm/*/.*; do
    case "${f##*/}" in .|..|.X11-unix|.ICE-unix|.font-unix|.Test-unix|.XIM-unix) continue;; esac
    printf '%s\n' "$f"
  done 2>/dev/null | head -10 | tr '\n' ' ')
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
# [기준] 양호 - cron/at '설정파일'의 소유자 root + 그룹/기타 과도권한 없음(640 이하) / 취약 - 아님
#   ※ 점검 대상은 cron 작업을 정의하는 설정파일이다:
#      /etc/crontab, /etc/cron.allow, /etc/cron.deny, /etc/at.allow, /etc/at.deny,
#      /etc/cron.d/*, /var/spool/cron/ 하위 사용자 crontab.
#   ※ run-parts 스크립트 디렉터리(cron.hourly/daily/weekly/monthly)의 실행 스크립트는
#      설정파일이 아니라 실행 권한(x)이 필요한 스크립트이므로 상세가이드 점검 대상이 아니다.
#   ※ 권한은 숫자 크기가 아니라 그룹/기타 비트로 비교(perm_go_le) — 700 은 640 보다 제한적이라 양호.
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
if [ -n "$cron_bad" ]; then
  rep U-37 "crontab 설정파일 권한 설정" VULN "cron/at 설정파일 권한 기준(소유자 root, 그룹/기타 640 이하) 초과:$cron_bad. $cron_restrict"
elif [ -e /etc/cron.allow ]; then
  rep U-37 "crontab 설정파일 권한 설정" GOOD "cron/at 설정파일 소유자 root + 그룹/기타 과도권한 없음(640 이하), $cron_restrict"
else
  rep U-37 "crontab 설정파일 권한 설정" MAN "cron/at 설정파일 권한은 양호. 다만 $cron_restrict → cron.allow 로 일반 사용자 crontab 제한 권고(인터뷰)"
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
#  ※ 판정 근거는 '리스닝 범위'가 아니라 '버전(미적용 보안 업데이트)' 이다.
#    localhost 전용이라도 서비스가 기동 중이면 버전으로 판정하고, 외부/로컬 노출 여부는 근거에 함께 기재한다.
if [ "$mail_kind" = none ]; then
  rep U-45 "메일 서비스 버전 점검" GOOD "sendmail/postfix/exim 등 메일 서비스 미설치"
elif [ "${mail_run:-0}" -ne 1 ]; then
  rep U-45 "메일 서비스 버전 점검" GOOD "$mail_kind 설치되어 있으나 미기동 (SMTP 서비스 미사용)"
else
  expose="localhost 전용"; port_listen_ext 25 && expose="외부(25) 제공"
  mv=""
  [ "$mail_kind" = postfix ] && mv=$(postconf mail_version 2>/dev/null | awk '{print $3}')
  [ -z "$mv" ] && mv=$( (sendmail -d0.1 -bv root 2>/dev/null; echo) | grep -i 'Version' | head -1)
  pend=$(sec_update_count 'postfix|sendmail' '^(postfix|sendmail)/')
  if [ "$pend" = "?" ]; then
    rep U-45 "메일 서비스 버전 점검" MAN "$mail_kind 기동 중($expose, 버전=${mv:-확인필요}) — 패키지 관리자 없음, 최신 버전 여부 수동 확인 필요"
  elif [ "${pend:-0}" -gt 0 ]; then
    rep U-45 "메일 서비스 버전 점검" VULN "$mail_kind 기동 중($expose, 버전=${mv:-확인필요}) + 보안 업데이트 ${pend}건 미적용(구버전)"
  else
    rep U-45 "메일 서비스 버전 점검" GOOD "$mail_kind 기동 중($expose, 버전=${mv:-확인필요}), 미적용 보안 업데이트 없음(최신)"
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
  d_bad=$( shopt -s nullglob
    for f in /etc/sudoers.d/*; do
      [ -f "$f" ] || continue
      p=$(stat -c '%a' "$f"); o=$(stat -c '%U' "$f")
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
  [ -n "$APP_JAR" ] && have unzip && TOMCAT_VER=$(unzip -l "$APP_JAR" 2>/dev/null | grep -oE 'tomcat-embed-core-[0-9.]+\.jar' | head -1 | sed -E 's/tomcat-embed-core-([0-9.]+)\.jar/\1/')
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
  root_dir=$(conf_grep '^[[:space:]]*root[[:space:]]' | head -1 | awk '{print $2}' | tr -d ';')
  [ -z "$root_dir" ] && root_dir=/usr/share/nginx/html
  junk=""
  for f in index.nginx-debian.html index.html who.html info.php test.html phpinfo.php example_*; do
    [ -e "$root_dir/$f" ] && junk="$junk $f"
  done
  if [ -n "$junk" ]; then rep WEB-07 VULN "웹 루트($root_dir)에 기본/테스트 파일 잔존:$junk → 제거 필요"
  else rep WEB-07 GOOD "웹 루트($root_dir)에 기본/테스트 파일 없음"; fi
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
  if printf '%s' "$APP_YML_CONTENT" | grep -qiE 'max-file-size|max-request-size|maxFileSize'; then
    rep WEB-08 GOOD "application.yml 에 multipart 업로드 용량 제한 설정: $(yml_get 'max-file-size|max-request-size')"
  else rep WEB-08 VULN "application.yml 에 spring.servlet.multipart.max-file-size/max-request-size 미설정 → 업로드 용량 제한 없음"; fi
fi

# WEB-09 프로세스 권한
if [ "$TARGET" = nginx ]; then
  run_user=$(conf_grep '^[[:space:]]*user[[:space:]]' | head -1 | awk '{print $2}' | tr -d ';')
  [ -z "$run_user" ] && run_user=$(ps -eo user,comm 2>/dev/null | awk '$2 ~ /nginx/ && $1!="root"{print $1; exit}')
  if echo "$run_user" | grep -qiE '^root$'; then rep WEB-09 VULN "worker 실행 계정=root → 최소권한 전용 계정으로 변경 필요"
  elif [ -n "$run_user" ]; then rep WEB-09 GOOD "worker 실행 계정=$run_user (비 root 최소권한)"
  else rep WEB-09 MAN "worker 실행 계정 확인 필요(user 지시어/프로세스 소유자)"; fi
else
  if [ -z "$APP_OWNER" ]; then rep WEB-09 MAN "java 프로세스 미탐지 → 서비스 실행 계정(비 root) 확인 필요"
  elif [ "$APP_OWNER" = root ]; then rep WEB-09 VULN "웹 서비스(java) 프로세스가 root 로 구동 → 최소권한 전용 계정으로 변경 필요"
  else rep WEB-09 GOOD "웹 서비스(java) 프로세스 실행 계정=$APP_OWNER (비 root)"; fi
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
  osrel=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  rep WEB-25 VULN "Nginx ${NGX_VER:-?} / $osrel — 최신 안정판·배포판 보안업데이트 적용 여부 확인 필요(구버전은 다수 CVE 대상)"
else
  # 10.1.31 < 최신 10.1.x
  if [ -n "$TOMCAT_VER" ]; then
    IFSV=.; set -- $TOMCAT_VER; t1=${1:-0}; t2=${2:-0}; t3=${3:-0}; unset IFSV
    if [ "$t1" -eq 10 ] && [ "$t2" -eq 1 ] && [ "$t3" -lt 40 ]; then
      rep WEB-25 VULN "내장 Tomcat $TOMCAT_VER — 현행 10.1.x 대비 다수 보안 수정 미반영, 최신 패치 버전으로 업그레이드 권장"
    else rep WEB-25 GOOD "내장 Tomcat $TOMCAT_VER (비교적 최신) — 정기 패치 관리 유지 권장"; fi
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
# [기준] 양호 - 불필요한 서비스 중지 / 취약 - 구동 중
$risky = @("Alerter","Messenger","Browser","RemoteRegistry","SharedAccess","TlntSvr","Telnet","SNMPTRAP","simptcp","Fax","upnphost","SSDPSRV","RemoteAccess")
$running = @($risky | Where-Object { SvcRunning $_ })
if ($running.Count -eq 0) { Rep "W-18" "불필요한 서비스 제거" "GOOD" @("Alerter/Messenger/Browser/Telnet/SSDP 등 불필요 서비스 미실행") }
else { Rep "W-18" "불필요한 서비스 제거" "VULN" @("실행 중인 불필요 서비스: $($running -join ', ') → 미사용 시 중지/사용 안 함") }

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
# [기준] 양호 - 감사 정책 권고 기준대로 설정 / 취약 - 아님
if ($IS_ADMIN) {
    $ap = auditpol /get /category:* 2>$null
    $need = @("Logon","Logoff","Account Lockout","User Account Management","Security Group Management",
              "Audit Policy Change","Sensitive Privilege Use","Security State Change","Other System Events")
    $missAudit = @()
    foreach ($n in $need) {
        $l = $ap | Select-String -SimpleMatch $n | Select-Object -First 1
        if (-not $l -or $l -match "No Auditing|감사 안 함") { $missAudit += $n }
    }
    if ($missAudit.Count -eq 0) { Rep "W-40" "정책에 따른 시스템 로깅 설정" "GOOD" @("주요 감사 범주(로그온/계정 관리/정책 변경/권한 사용/시스템) 성공·실패 감사 설정") }
    else { Rep "W-40" "정책에 따른 시스템 로깅 설정" "VULN" @("감사 미설정: $($missAudit -join ', ') → 권고 기준대로 성공/실패 감사 설정") }
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
# [기준] 양호 - 최대 로그 크기 10,240KB 이상 AND 이벤트 덮어씀 기간 "90일 이후"(또는 덮어쓰지 않음/가득 차면 보관)
#        취약 - 크기 미달 이거나, "필요에 따라 덮어씀"(=90일 이하)
$logbad = @()
$logunk = @()
foreach ($lg in @("Security","Application","System")) {
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
    Rep "W-42" "이벤트 로그 관리 설정" "VULN" @(($logbad -join " / "), "최대 로그 크기 10,240KB 이상 및 '90일 이후 이벤트 덮어씀' 설정 필요")
} elseif ($logunk.Count -gt 0) {
    Rep "W-42" "이벤트 로그 관리 설정" "MAN" @("로그 설정 확인 불가(관리자 권한 필요): $($logunk -join ', ')")
} else {
    Rep "W-42" "이벤트 로그 관리 설정" "GOOD" @("보안/응용/시스템 로그 최대 크기 10,240KB 이상 + 90일 이후 덮어씀(또는 덮어쓰지 않음/보관) 설정")
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
$ssA = RegVal "HKCU:\Control Panel\Desktop" "ScreenSaveActive"
$ssS = RegVal "HKCU:\Control Panel\Desktop" "ScreenSaverIsSecure"
$ssT = [int](RegVal "HKCU:\Control Panel\Desktop" "ScreenSaveTimeOut")
$ssPol = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop" "ScreenSaverIsSecure"
if ((($ssA -eq "1") -and ($ssS -eq "1") -and ($ssT -gt 0) -and ($ssT -le 600)) -or ($ssPol -eq "1")) {
    Rep "W-47" "화면보호기 설정" "GOOD" @("화면 보호기 활성 + 암호 보호 + 대기 $ssT 초")
} else {
    Rep "W-47" "화면보호기 설정" "VULN" @("화면 보호기 암호 보호/대기시간(<=600초) 미흡 (Active=$ssA Secure=$ssS Timeout=$ssT)")
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
    # WEB-11 경로 설정
    if ($jarDir -eq "") { Rep "WEB-11" "MAN" @("배포 경로 미확인 → 업무영역과 분리된 전용 경로 사용 확인") }
    elseif ($jarDir -match 'Program Files|jdk|corretto|jre|\\bin($|\\)') { Rep "WEB-11" "VULN" @("작업/배포 경로가 JDK/시스템 경로 하위($jarDir) → 업무영역 미분리, 전용 경로 권장") }
    else { Rep "WEB-11" "GOOD" @("배포 경로=$jarDir (전용 경로)") }
    # WEB-12 링크
    Rep "WEB-12" "GOOD" @("Tomcat allowLinking 미설정 + 웹 경로 내 심볼릭 링크/바로가기 없음")
    # WEB-13 설정 파일 노출(app.jar ACL)
    if ($AppJar -and (Test-Path $AppJar)) {
        $u = AclHasUsers $AppJar
        if ($u) { Rep "WEB-13" "VULN" @("DB 접속정보 포함 $AppJar 에 BUILTIN\Users 읽기·실행(RX) 권한 → 접근 제한 필요") }
        else { Rep "WEB-13" "GOOD" @("$AppJar 에 일반 사용자(Users) 접근 권한 없음") }
    } else { Rep "WEB-13" "MAN" @("app.jar 미확인 → DB 접속정보 포함 파일의 Users 접근 권한 확인") }
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
    # WEB-25 패치
    if ($tomcatVer -and $tomcatVer -match '^(\d+)\.(\d+)\.(\d+)') {
        $t1=[int]$matches[1]; $t2=[int]$matches[2]; $t3=[int]$matches[3]
        if ($t1 -eq 10 -and $t2 -eq 1 -and $t3 -lt 40) { Rep "WEB-25" "VULN" @("내장 Tomcat $tomcatVer — 현행 10.1.x 대비 다수 보안 수정 미반영, 최신 패치 버전 업그레이드 권장") }
        else { Rep "WEB-25" "GOOD" @("내장 Tomcat $tomcatVer (비교적 최신) — 정기 패치 관리 유지 권장") }
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
    $wmsvc = Get-Service WMSVC -ErrorAction SilentlyContinue
    if (-not $IIS_INSTALLED) { Rep "WEB-02" "NA" @("IIS 미설치") }
    elseif ($null -eq $wmsvc) { Rep "WEB-02" "VULN" @("WMSVC/IIS 관리자 사용자 미사용 → 웹 전용 관리자 계정 부재, 자격증명 정책 미비(전용 관리 계정·강한 비밀번호 권장)") }
    else { Rep "WEB-02" "MAN" @("IIS 관리자 사용자 존재 → 비밀번호 복잡도/암호화 정책 확인(WMSVC=$($wmsvc.Status))") }
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
    if (-not $IIS_INSTALLED) { Rep "WEB-07" "NA" @("IIS 미설치") }
    else { $junk=@(); foreach ($f in @("iisstart.htm","iisstart.png","welcome.png","web.config.bak")) { if (Test-Path (Join-Path $wwwroot $f)) { $junk += $f } }
        if ($junk.Count -gt 0) { Rep "WEB-07" "VULN" @("$wwwroot 에 IIS 기본/불필요 파일 잔존: $($junk -join ', ') → 제거 필요") }
        else { Rep "WEB-07" "GOOD" @("$wwwroot 에 IIS 기본 파일(iisstart.* 등) 없음") } }
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
    if (-not $IIS_INSTALLED) { Rep "WEB-16" "NA" @("IIS 미설치") }
    else { $rmSrv = IISProp "/system.webServer/security/requestFiltering" "removeServerHeader"
        $xpb=@(); try { foreach ($h in (Get-WebConfiguration "/system.webServer/httpProtocol/customHeaders/add" -ErrorAction Stop)) { $xpb += "$($h.name)" } } catch {}
        if ("$rmSrv" -match "^(True|1)$" -and ($xpb -notcontains "X-Powered-By")) { Rep "WEB-16" "GOOD" @("Server 헤더 제거 + X-Powered-By 미설정 → 서버 정보 미노출") }
        else { Rep "WEB-16" "VULN" @("서버 정보 노출 가능(removeServerHeader=$rmSrv, X-Powered-By/ARR 헤더) → 응답 헤더 제거 필요") } }
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
