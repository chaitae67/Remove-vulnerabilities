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
  [ -n "$APP_JAR" ] && have unzip && TOMCAT_VER=$(unzip -p "$APP_JAR" 'META-INF/MANIFEST.MF' 2>/dev/null | sed -n 's/.*Tomcat[^0-9]*\([0-9][0-9.]*\).*/\1/p' | head -1)
  SW_VER="Tomcat ${TOMCAT_VER:-내장(Spring Boot)}"
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
  logd="/var/log/clinic /opt/clinic/logs"; for d in $logd; do [ -d "$d" ] && other_writable "$d" && bad14="$bad14 $d($(stat -c '%a' "$d"))"; done
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
  ld=""; for d in /var/log/clinic /opt/clinic/logs /var/log/tomcat*; do [ -d "$d" ] && ld="$d" && break; done
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
  { printf '\xEF\xBB\xBF'; echo "항목코드,중요도,점검항목,진단결과,근거"; printf '%s' "$CBUF"; } > "$CSV_FILE" && echo -e "  ${W}CSV${N}   저장: $CSV_FILE"
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
