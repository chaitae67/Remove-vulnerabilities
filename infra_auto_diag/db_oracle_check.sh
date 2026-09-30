#!/usr/bin/env bash
#==============================================================================
# DBMS(Oracle) 기술적 취약점 점검  D-01 ~ D-26
#  - KISA 주통기 / SK Shieldus DB 보안가이드 기준(공식 결과보고서 D-01~26 항목·판단기준 반영)
#  - 읽기 전용(READ-ONLY): SELECT 및 설정파일 조회만, 변경 없음
#  - 대상: Oracle Database (XE 포함) 11g~23ai
#  - 실행(대상 DB 서버/컨테이너에서 sqlplus 필요):
#       bash db_oracle_check.sh --conn "sys/비밀번호@//localhost:1521/XEPDB1 as sysdba"
#       # 컨테이너 내부에서 oracle 계정 OS 인증 시:  bash db_oracle_check.sh   (기본 '/ as sysdba')
#       # 호스트에 sqlplus 가 없고 Oracle 이 도커 컨테이너에서 돌면 자동 감지 → 컨테이너 안(oracle 계정, OS 인증)에서
#       #   점검 후 결과 파일만 꺼내 온다(root 로 실행, 비밀번호 불필요). 컨테이너 지정: --container <이름|ID>
#  - CDB 루트에 접속하면 루트 + 열린 PDB 를 모두 점검한다(특정 컨테이너만: --pdb XEPDB1).
#  - 대상 아님(N/A): D-13(Windows OS), D-16/23/24(MSSQL). D-12 는 12c R2 이상이면 N/A(가이드 p.636).
#  - 끝나면 콘솔 요약 + CSV + HTML 리포트를 현재 폴더에 자동 저장.
# 판정: 양호 / 취약 / N/A(대상 아님→양호) / 수동확인(인터뷰 필요)
#   조회 권한이 없거나 오류(ORA-/SP2-)가 나면 그 결과로 판정하지 않고 수동확인으로 표시한다.
#==============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
  echo "이 스크립트는 bash 로 실행해야 합니다:  bash $0" >&2; exit 1
fi

JSON_FILE=""; CSV_FILE=""; HTML_FILE=""; NO_SAVE=0; NOCOLOR=0
CONN=""; O_USER=""; O_PASS=""; O_HOST="localhost"; O_HOST_SET=0; O_PORT="1521"; O_SVC=""; SYSDBA=0; TNS_ADMIN_IN=""
DB_CT_IN=""; PDB_IN=""
# 기관 정책 기준값(가이드: 기관 정책에 맞게) — 옵션으로 조정
PW_LIFE_MAX=90; LOGIN_FAIL_MAX=10; REUSE_MAX_MIN=10; REUSE_TIME_MIN=365
while [ $# -gt 0 ]; do
  case "$1" in
    --conn) CONN="${2:-}"; shift 2 ;; --user) O_USER="${2:-}"; shift 2 ;; --pass) O_PASS="${2:-}"; shift 2 ;;
    --host) O_HOST="${2:-}"; O_HOST_SET=1; shift 2 ;; --port) O_PORT="${2:-}"; shift 2 ;; --service) O_SVC="${2:-}"; shift 2 ;;
    --sysdba) SYSDBA=1; shift ;; --tns-admin) TNS_ADMIN_IN="${2:-}"; shift 2 ;;
    --container) DB_CT_IN="${2:-}"; shift 2 ;; --pdb) PDB_IN="${2:-}"; shift 2 ;;
    --pw-life-max) PW_LIFE_MAX="${2:-90}"; shift 2 ;; --login-fail-max) LOGIN_FAIL_MAX="${2:-10}"; shift 2 ;;
    --reuse-max-min) REUSE_MAX_MIN="${2:-10}"; shift 2 ;; --reuse-time-min) REUSE_TIME_MIN="${2:-365}"; shift 2 ;;
    --json) JSON_FILE="${2:-}"; shift 2 ;; --csv) CSV_FILE="${2:-}"; shift 2 ;; --html) HTML_FILE="${2:-}"; shift 2 ;;
    --no-save) NO_SAVE=1; shift ;; --no-color) NOCOLOR=1; shift ;;
    -h|--help) cat <<'USAGE'
사용법:
  bash db_oracle_check.sh --conn "sys/pw@//localhost:1521/XEPDB1 as sysdba"
  bash db_oracle_check.sh --user system --pass pw --service XEPDB1 [--host h --port 1521]
  bash db_oracle_check.sh                # oracle OS 인증(기본 '/ as sysdba')
  sudo bash db_oracle_check.sh           # 호스트에 sqlplus 없고 Oracle 이 도커 컨테이너면 자동으로 컨테이너 안에서 점검
옵션: --csv f --html f --json f --no-save --no-color --sysdba --tns-admin DIR
      --container <이름|ID>   Oracle 도커 컨테이너 지정(기본: ora_pmon 프로세스가 있는 컨테이너 자동 감지)
      --pdb <이름>            CDB 루트 접속 시 이 컨테이너만 점검(기본: 루트 + 열린 PDB 전체)
      기관 정책 기준값: --pw-life-max 90  --login-fail-max 10  --reuse-max-min 10  --reuse-time-min 365
환경변수 ORACLE_CONN / ORACLE_HOME / TNS_ADMIN 인식.
USAGE
      exit 0 ;;
    *) shift ;;
  esac
done
for _v in PW_LIFE_MAX LOGIN_FAIL_MAX REUSE_MAX_MIN REUSE_TIME_MIN; do
  case "${!_v}" in ''|*[!0-9]*) echo "[!] $_v 는 숫자여야 합니다: ${!_v}" >&2; exit 2;; esac
done

[ -z "$CONN" ] && [ -n "${ORACLE_CONN:-}" ] && CONN="$ORACLE_CONN"
if [ -z "$CONN" ]; then
  if [ -n "$O_USER" ]; then
    CONN="$O_USER/$O_PASS@//$O_HOST:$O_PORT/${O_SVC:-XE}"; [ "$SYSDBA" -eq 1 ] && CONN="$CONN as sysdba"
    echo "$O_USER" | grep -qiE '^sys$' && CONN="$O_USER/$O_PASS@//$O_HOST:$O_PORT/${O_SVC:-XE} as sysdba"
  else CONN="/ as sysdba"; fi
fi
# 화면 표시용 접속 정보(비밀번호 가림)
if [ "$CONN" = "/ as sysdba" ]; then CONN_DISP="OS 인증(/ as sysdba)"
else CONN_DISP="${CONN%%/*}/****"; case "$CONN" in *@*) CONN_DISP="$CONN_DISP@${CONN#*@}";; esac; fi

if [ -t 1 ] && [ "$NOCOLOR" -eq 0 ]; then
  G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; B='\033[1;34m'; C='\033[1;36m'; W='\033[1m'; N='\033[0m'
else G=''; R=''; Y=''; B=''; C=''; W=''; N=''; fi

good=0; vuln=0; na=0; man=0
HOSTN=${KISA_HOSTN:-$(hostname 2>/dev/null || echo db)}

# ---- Oracle 이 도커 컨테이너 안에만 있는 경우(호스트에 sqlplus 없음) ----
#   ora_pmon 프로세스가 있는 컨테이너를 찾아, 그 안의 oracle 계정으로 이 스크립트를 다시 실행하고 결과 파일만 꺼내 온다.
#   접속 정보는 환경변수로 넘긴다(docker exec -e ORACLE_CONN → 호스트 프로세스 인자에 비밀번호 미노출).
if [ -z "${KISA_IN_CONTAINER:-}" ] && ! command -v sqlplus >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
  ct="$DB_CT_IN"
  if [ -z "$ct" ]; then
    for _c in $(docker ps -q 2>/dev/null); do
      docker top "$_c" 2>/dev/null | grep -qE 'ora_pmon_|tnslsnr' && { ct="$_c"; break; }
    done
  fi
  if [ -n "$ct" ]; then
    ctn=$(docker inspect -f '{{.Name}}' "$ct" 2>/dev/null | tr -d '/'); ctn=${ctn:-$ct}
    self="$0"
    [ -f "$self" ] || { echo -e "${R}[!] 스크립트 파일 경로를 알 수 없어 컨테이너로 복사할 수 없습니다(bash <파일> 로 실행).${N}" >&2; exit 2; }
    cu=oracle; docker exec -u oracle "$ct" true >/dev/null 2>&1 || cu=""
    rdir="/tmp/kisa_db_$$"
    if ! { docker exec ${cu:+-u "$cu"} "$ct" mkdir -p "$rdir" && docker cp "$self" "$ct:$rdir/db_oracle_check.sh" >/dev/null; }; then
      echo -e "${R}[!] 컨테이너($ctn)로 점검 스크립트 복사 실패${N}" >&2; exit 2
    fi
    _d=$(date +%Y%m%d 2>/dev/null || echo date); _h=$(printf '%s' "$HOSTN" | tr -c 'A-Za-z0-9._-' '_')
    [ -z "$CSV_FILE" ]  && CSV_FILE="db_oracle_${_h}_${_d}.csv"
    [ -z "$HTML_FILE" ] && HTML_FILE="db_oracle_${_h}_${_d}.html"
    iargs=(--csv "$rdir/out.csv" --html "$rdir/out.html" --pw-life-max "$PW_LIFE_MAX" --login-fail-max "$LOGIN_FAIL_MAX"
           --reuse-max-min "$REUSE_MAX_MIN" --reuse-time-min "$REUSE_TIME_MIN")
    [ -n "$JSON_FILE" ] && iargs+=(--json "$rdir/out.json")
    [ "$NO_SAVE" -eq 1 ] && iargs+=(--no-save)
    [ "$NOCOLOR" -eq 1 ] && iargs+=(--no-color)
    [ -n "$TNS_ADMIN_IN" ] && iargs+=(--tns-admin "$TNS_ADMIN_IN")
    [ -n "$PDB_IN" ] && iargs+=(--pdb "$PDB_IN")
    echo -e "[*] Oracle 이 도커 컨테이너(${ctn})에서 실행 중 → 컨테이너 안에서 점검 (실행 계정: ${cu:-컨테이너 기본}, 접속: ${CONN_DISP})"
    ORACLE_CONN="$CONN" KISA_IN_CONTAINER=1 KISA_HOSTN="$HOSTN" KISA_HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" \
      docker exec -e ORACLE_CONN -e KISA_IN_CONTAINER -e KISA_HOSTN -e KISA_HOST_IP ${cu:+-u "$cu"} -w "$rdir" "$ct" \
      bash "$rdir/db_oracle_check.sh" "${iargs[@]}"
    rc=$?
    if [ "$NO_SAVE" -eq 0 ]; then
      docker cp "$ct:$rdir/out.csv" "$CSV_FILE" >/dev/null 2>&1 && echo -e "  ${W}CSV${N}   회수: $CSV_FILE"
      docker cp "$ct:$rdir/out.html" "$HTML_FILE" >/dev/null 2>&1 && echo -e "  ${W}HTML${N}  회수: $HTML_FILE"
    fi
    [ -n "$JSON_FILE" ] && docker cp "$ct:$rdir/out.json" "$JSON_FILE" >/dev/null 2>&1 && echo -e "  ${W}JSON${N}  회수: $JSON_FILE"
    docker exec ${cu:+-u "$cu"} "$ct" rm -rf "$rdir" >/dev/null 2>&1
    exit "$rc"
  fi
fi

declare -A IMP=(
  [D-01]=상 [D-02]=상 [D-03]=상 [D-04]=상 [D-05]=중 [D-06]=중 [D-07]=중 [D-08]=상 [D-09]=중 [D-10]=상 [D-11]=상 [D-12]=상 [D-13]=중
  [D-14]=중 [D-15]=하 [D-16]=하 [D-17]=하 [D-18]=상 [D-19]=상 [D-20]=하 [D-21]=중 [D-22]=하 [D-23]=상 [D-24]=상 [D-25]=상 [D-26]=상
)
declare -A TITLE=(
  [D-01]="기본 계정의 비밀번호·정책 변경" [D-02]="불필요 계정 제거 또는 잠금" [D-03]="비밀번호 사용기간 및 복잡도 설정"
  [D-04]="DBA 권한 최소 계정·그룹 부여" [D-05]="비밀번호 재사용 제약 설정" [D-06]="DB 사용자 계정 개별 부여"
  [D-07]="root 권한 서비스 구동 제한" [D-08]="안전한 암호화 알고리즘 사용" [D-09]="로그인 실패 잠금정책 설정"
  [D-10]="원격 DB 접속 제한" [D-11]="시스템 테이블 접근을 DBA로 제한" [D-12]="안전한 리스너 비밀번호 설정"
  [D-13]="불필요한 ODBC/OLE-DB 제거" [D-14]="주요 설정·비밀번호 파일 접근권한" [D-15]="리스너 로그/trace 변경 제한"
  [D-16]="Windows 인증 모드 사용" [D-17]="Audit Table 관리자 접근 제한" [D-18]="DBA Role Public 미설정"
  [D-19]="OS_ROLES/REMOTE_OS_* FALSE 설정" [D-20]="인가되지 않은 Object owner 제한" [D-21]="인가되지 않은 GRANT OPTION 제한"
  [D-22]="자원 제한(RESOURCE_LIMIT) TRUE" [D-23]="xp_cmdshell 사용 제한" [D-24]="Registry Procedure 권한 제한"
  [D-25]="주기적 보안 패치 적용" [D-26]="감사 기록 정책 적용"
)

JBUF=""; CBUF=""; HBUF=""
json_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\r'/ }; s=${s//$'\n'/ }; printf '%s' "$s"; }
csv_escape()  { local s=$1; s=${s//$'\r'/ }; s=${s//$'\n'/ }; case "$s" in *[,\"]*) s=${s//\"/\"\"}; s="\"$s\"";; esac; printf '%s' "$s"; }
html_escape() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; printf '%s' "$s"; }

rep() {
  local code="$1" status="$2"; shift 2
  local title="${TITLE[$code]}" tag kstat cls
  case "$status" in
    GOOD) good=$((good+1)); tag="${G}양호${N}"; kstat="양호"; cls="good";;
    VULN) vuln=$((vuln+1)); tag="${R}취약${N}"; kstat="취약"; cls="vuln";;
    NA)   na=$((na+1));     tag="${Y}N/A${N}";  kstat="N/A";  cls="na";;
    MAN)  man=$((man+1));   tag="${B}수동확인${N}"; kstat="수동확인"; cls="man";;
  esac
  printf "${C}%-6s${N} %-42s [%b]\n" "$code" "$title" "$tag"
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
# SQL 실행(읽기 전용) — 비밀번호가 프로세스 인자(ps)에 보이지 않도록 /nolog 로 띄우고 표준입력으로 connect.
#   SQL_CON 이 있으면(CDB 루트 접속 시) 그 컨테이너로 전환 후 실행('-' 또는 현재 컨테이너면 전환 안 함).
#   ORA-/SP2- 오류 출력은 판정값으로 쓰지 않도록 '__ERR__:<오류코드>' 한 줄로 바꿔 반환 → 호출부에서 수동확인 처리
run_sql() {
  local out rc
  out=$( { printf 'connect %s\n' "$CONN"
           echo "set heading off feedback off pagesize 0 linesize 400 trimspool on echo off verify off long 400 newpage none"
           echo "whenever sqlerror exit sql.sqlcode"
           case "${SQL_CON:--}" in -|"${CON_NAME:-}") ;; *) echo "alter session set container=$SQL_CON;";; esac
           printf '%s\n' "$1" | sed -e 's/ AND /\n AND /g; s/ OR /\n OR /g; s/ UNION /\n UNION /g'   # SQL*Plus 한 줄 2499자 제한 회피
           echo "exit"; } | sqlplus -S -L /nolog 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ] || printf '%s\n' "$out" | grep -qE '(ORA|SP2)-[0-9]{4,5}|ERROR at line'; then
    printf '__ERR__:%s\n' "$(printf '%s\n' "$out" | grep -oE '(ORA|SP2)-[0-9]{4,5}' | head -1)"; return 1
  fi
  printf '%s\n' "$out" | grep -v '^Connected\.$'
}
first_tok() { awk 'NF{print $1; exit}' | tr -d '\r'; }
first_line() { tr -d '\r' | awk 'NF{print; exit}'; }
qerr() { case "$1" in __ERR__*) return 0;; esac; return 1; }
errc() { local c=${1#__ERR__:}; c=${c%%$'\n'*}; printf '%s' "${c:-오류}"; }
short() { local s="$1"; [ "${#s}" -gt 240 ] && s="${s:0:240}…"; printf '%s' "$s"; }
upper() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }
# 설정 파일(주석 줄 제외) 검사/값 읽기
conf_has() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -qiE "$2"; }
conf_val() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -iE "^[[:space:]]*$2[[:space:]]*=" | tail -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r'; }
# 대상 컨테이너 전체에 같은 조회(위반 행만 반환하는 SQL) → V_ROWS(위반 행, 여러 컨테이너면 '컨테이너:' 표시), V_NROW, V_ERR(실패 컨테이너)
viol() {
  V_ROWS=""; V_NROW=0; V_ERR=""; local c out l pre
  for c in $CONS; do
    pre=""; [ "$NCONS" -gt 1 ] && pre="$c:"
    out=$(SQL_CON="$c" run_sql "$1")
    if qerr "$out"; then V_ERR="${V_ERR:+$V_ERR, }${pre}$(errc "$out")"; continue; fi
    while IFS= read -r l; do
      l=$(printf '%s' "$l" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -n "$l" ] || continue
      V_NROW=$((V_NROW+1)); V_ROWS="${V_ROWS:+$V_ROWS, }${pre}$l"
    done <<EOF
$out
EOF
  done
}
# viol 결과로 판정: 위반 행 있으면 취약, 없는데 조회 실패가 있으면 수동확인, 둘 다 없으면 양호
verdict() {
  local code=$1 ok_ev=$2 bad_ev=$3
  if [ "$V_NROW" -gt 0 ]; then rep "$code" VULN "$bad_ev ${V_NROW}건: $(short "$V_ROWS")" ${V_ERR:+"조회 실패: $V_ERR"}
  elif [ -n "$V_ERR" ]; then rep "$code" MAN "조회 실패($V_ERR) → 권한(SYSDBA 또는 SELECT ANY DICTIONARY) 있는 계정으로 재점검하거나 수동 확인"
  else rep "$code" GOOD "$ok_ev"; fi
}
# 계정 u 에 실제 적용되는 프로파일 값(프로파일 값이 DEFAULT 면 DEFAULT 프로파일 값)
eff() { printf "(SELECT CASE WHEN p.limit='DEFAULT' THEN d.limit ELSE p.limit END FROM dba_profiles p, dba_profiles d WHERE p.profile=u.profile AND p.resource_name='%s' AND d.profile='DEFAULT' AND d.resource_name='%s')" "$1" "$1"; }
ver_ge() { [ -n "$DB_MAJOR" ] && { [ "$DB_MAJOR" -gt "$1" ] || { [ "$DB_MAJOR" -eq "$1" ] && [ "${DB_MINOR:-0}" -ge "$2" ]; }; }; }

echo -e "${W}=========================================================${N}"
echo -e "${W} DBMS(Oracle) 취약점 점검  —  $HOSTN${N}"
echo -e "${W}=========================================================${N}"
if ! have sqlplus && [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/bin/sqlplus" ]; then PATH="$ORACLE_HOME/bin:$PATH"; fi
if ! have sqlplus; then
  echo -e "${R}[!] sqlplus 미탐지. Oracle 이 설치된 DB 서버/컨테이너에서 실행하세요.${N}" >&2
  echo -e "${R}    (도커 컨테이너의 Oracle 은 호스트에서 root 로 실행하면 자동 감지 — docker 명령 필요, 또는 --container 지정)${N}" >&2; exit 2
fi
PROBE=$(run_sql "SELECT 'CONN_OK' FROM dual;" | first_tok)
if [ "$PROBE" != "CONN_OK" ]; then
  echo -e "${R}[!] Oracle 접속 실패(${CONN_DISP}${PROBE:+, $(errc "$PROBE")}). 계정/서비스명/권한 확인.${N}" >&2; exit 2
fi
DB_VER=$(run_sql "SELECT version_full FROM product_component_version WHERE product LIKE 'Oracle%' AND rownum=1;" | first_tok)
{ [ -z "$DB_VER" ] || qerr "$DB_VER"; } && DB_VER=$(run_sql "SELECT version FROM product_component_version WHERE product LIKE 'Oracle%' AND rownum=1;" | first_tok)
qerr "$DB_VER" && DB_VER=""
DB_MAJOR=${DB_VER%%.*}; DB_MINOR=$(printf '%s' "$DB_VER" | cut -d. -f2)
case "$DB_MAJOR" in ''|*[!0-9]*) DB_MAJOR="";; esac; case "$DB_MINOR" in ''|*[!0-9]*) DB_MINOR=0;; esac
BANNER=$(run_sql "SELECT banner FROM v\$version WHERE banner LIKE 'Oracle%' AND rownum=1;" | first_line); qerr "$BANNER" && BANNER=""
CON_NAME=$(run_sql "SELECT sys_context('USERENV','CON_NAME') FROM dual;" | first_tok); qerr "$CON_NAME" && CON_NAME=""
# 점검 대상 컨테이너: CDB 루트 접속이면 루트 + 열린 PDB(시드 제외), 그 밖에는 현재 컨테이너('-')
CONS="-"
if [ "$CON_NAME" = 'CDB$ROOT' ]; then
  _p=$(run_sql "SELECT name FROM v\$pdbs WHERE open_mode LIKE 'READ%' AND name<>'PDB\$SEED' ORDER BY con_id;")
  qerr "$_p" || CONS="CDB\$ROOT $(printf '%s\n' "$_p" | tr -d '\r' | awk 'NF{printf "%s ", $1}')"
fi
[ -n "$PDB_IN" ] && CONS="$PDB_IN"
set -- $CONS; NCONS=$#
# Oracle 이 관리하는(설치 시 생성) 계정·롤 — 12c 이상은 ORACLE_MAINTAINED, 11g 는 기본 목록
if [ "${DB_MAJOR:-12}" -ge 12 ]; then
  MU="(SELECT username FROM dba_users WHERE oracle_maintained='Y')"
  MR="(SELECT role FROM dba_roles WHERE oracle_maintained='Y')"
else
  MU="('SYS','SYSTEM','OUTLN','DBSNMP','APPQOSSYS','XDB','WMSYS','CTXSYS','MDSYS','MDDATA','ORDSYS','ORDDATA','ORDPLUGINS','OLAPSYS','EXFSYS','LBACSYS','SI_INFORMTN_SCHEMA','SPATIAL_WFS_ADMIN_USR','SPATIAL_CSW_ADMIN_USR','ANONYMOUS','XS\$NULL','DIP','ORACLE_OCM','MGMT_VIEW','SYSMAN','FLOWS_FILES','APEX_PUBLIC_USER','OWBSYS','OWBSYS_AUDIT')"
  MR="('CONNECT','RESOURCE','DBA','SELECT_CATALOG_ROLE','EXECUTE_CATALOG_ROLE','DELETE_CATALOG_ROLE','EXP_FULL_DATABASE','IMP_FULL_DATABASE','AQ_ADMINISTRATOR_ROLE','AQ_USER_ROLE','SCHEDULER_ADMIN','HS_ADMIN_ROLE','GATHER_SYSTEM_STATISTICS','LOGSTDBY_ADMINISTRATOR','RECOVERY_CATALOG_OWNER','OEM_MONITOR','OEM_ADVISOR','XDBADMIN','XDB_SET_INVOKER','XDB_WEBSERVICES','AUTHENTICATEDUSER','JAVA_ADMIN','JAVA_DEPLOY','JAVADEBUGPRIV','JAVAIDPRIV','JAVASYSPRIV','JAVAUSERPRIV','EJBCLIENT','CTXAPP','OLAP_DBA','OLAP_USER','OLAP_XS_ADMIN','WM_ADMIN_ROLE','MGMT_USER','CWM_USER','DATAPUMP_EXP_FULL_DATABASE','DATAPUMP_IMP_FULL_DATABASE','ADM_PARALLEL_EXECUTE_TASK','DBFS_ROLE','HS_ADMIN_SELECT_ROLE','HS_ADMIN_EXECUTE_ROLE')"
fi
DBAH="(SELECT grantee FROM dba_role_privs WHERE granted_role='DBA')"
# 네트워크 설정 파일 위치: --tns-admin > \$TNS_ADMIN > orabasehome(21c 읽기 전용 홈) > \$ORACLE_HOME 중 파일이 있는 곳
TNSADM="$TNS_ADMIN_IN"
if [ -z "$TNSADM" ]; then
  _obh=""; [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/bin/orabasehome" ] && _obh=$("$ORACLE_HOME/bin/orabasehome" 2>/dev/null)
  for _d in "${TNS_ADMIN:-}" "${_obh:+$_obh/network/admin}" "${ORACLE_HOME:+$ORACLE_HOME/network/admin}"; do
    [ -n "$_d" ] || continue
    if [ -f "$_d/sqlnet.ora" ] || [ -f "$_d/listener.ora" ]; then TNSADM="$_d"; break; fi
  done
  [ -z "$TNSADM" ] && TNSADM="${TNS_ADMIN:-${ORACLE_HOME:+$ORACLE_HOME/network/admin}}"
fi
# 원격 접속(@//다른호스트 또는 --host 지정)이면 파일·프로세스 점검은 이 서버가 아니므로 수동확인
IS_REMOTE=0
_rh=""; case "$CONN" in *@//*) _rh=$(printf '%s' "${CONN#*@//}" | sed -E 's#[:/ ].*##');; esac
[ -z "$_rh" ] && [ "$O_HOST_SET" = 1 ] && _rh="$O_HOST"
if [ -n "$_rh" ]; then
  case "$_rh" in localhost|127.*|::1|"$(hostname 2>/dev/null)") ;;
    *) printf ' %s ' "$(hostname -I 2>/dev/null)" | grep -q " $_rh " || IS_REMOTE=1;; esac
fi
echo -e "  버전: ${DB_VER:-미상}${BANNER:+ ($BANNER)}"
echo -e "  접속: ${CONN_DISP}   컨테이너: ${CON_NAME:-N/A}   점검 대상: $( [ "$CONS" = "-" ] && echo "${CON_NAME:-현재 DB}" || echo "$CONS")"
echo -e "  TNS_ADMIN: ${TNSADM:-미상}$( [ "$IS_REMOTE" = 1 ] && echo "   (원격 접속 — 파일/프로세스 항목은 수동확인)")"
echo

#==============================================================================
echo -e "${W}[ 1. 계정 관리 ]${N}"

# D-01 기본 계정 비밀번호/정책 변경 — 기본(초기) 비밀번호인데 잠기지 않은 계정(OPEN·EXPIRED 포함)
viol "SELECT d.username||'('||u.account_status||')' FROM dba_users_with_defpwd d JOIN dba_users u ON u.username=d.username WHERE u.account_status NOT LIKE '%LOCKED%' ORDER BY 1;"
verdict D-01 "기본(초기) 비밀번호를 쓰는 잠금 해제 계정 없음(기본 계정 비밀번호 변경 또는 잠금)" \
  "기본(초기) 비밀번호를 쓰면서 잠기지 않은 계정 → 비밀번호 변경 또는 잠금 필요,"

# D-02 불필요 계정 — 샘플/테스트 계정은 취약, 그 외 잠금 해제된 일반 계정은 목록으로 인가 여부 확인
viol "SELECT username||'('||account_status||')' FROM dba_users WHERE account_status NOT LIKE '%LOCKED%' AND (username IN ('SCOTT','HR','OE','SH','PM','IX','BI','DEMO','ADAMS','JONES','CLARK','BLAKE') OR REGEXP_LIKE(username,'(^|_)(TEST|TST|DEMO|SAMPLE|TMP|TEMP|GUEST)([0-9_]|\$)')) ORDER BY 1;"
r2="$V_ROWS"; n2=$V_NROW; e2="$V_ERR"
viol "SELECT username||DECODE(authentication_type,'PASSWORD','','['||authentication_type||']') FROM dba_users WHERE account_status NOT LIKE '%LOCKED%' AND username NOT IN $MU ORDER BY 1;"
ACCTS="$V_ROWS"; NACCT=$V_NROW; EACCT="$V_ERR"          # D-06 에서도 사용
if [ "$n2" -gt 0 ]; then rep D-02 VULN "잠기지 않은 샘플/테스트 계정 ${n2}건: $(short "$r2") → 삭제 또는 잠금" ${ACCTS:+"잠금 해제된 일반 계정: $(short "$ACCTS")"}
elif [ "$NACCT" -gt 0 ]; then rep D-02 MAN "잠금 해제된 일반(Oracle 관리 외) 계정 ${NACCT}개: $(short "$ACCTS") → 퇴직자·테스트·미사용 계정이 없는지 용도 확인(불필요 시 삭제/잠금)"
elif [ -n "$e2$EACCT" ]; then rep D-02 MAN "조회 실패(${e2:-$EACCT}) → 권한 있는 계정으로 재점검하거나 수동 확인"
else rep D-02 GOOD "Oracle 관리 계정 외 잠금 해제된 계정 없음(샘플/테스트 계정 없음)"; fi

# D-03 비밀번호 사용기간·복잡도 — 잠기지 않은 비밀번호 계정에 실제 적용되는 프로파일 기준
_lt=$(eff PASSWORD_LIFE_TIME); _vf=$(eff PASSWORD_VERIFY_FUNCTION)
viol "SELECT username||'('||profile||': LIFE_TIME='||lt||', VERIFY_FUNCTION='||NVL(vf,'NULL')||')' FROM (SELECT u.username, u.profile, $_lt lt, $_vf vf FROM dba_users u WHERE u.account_status NOT LIKE '%LOCKED%' AND u.authentication_type='PASSWORD') WHERE lt='UNLIMITED' OR NVL(CASE WHEN REGEXP_LIKE(lt,'^[0-9]+\$') THEN TO_NUMBER(lt) END,0) > $PW_LIFE_MAX OR NVL(vf,'NULL') IN ('NULL','UNLIMITED') ORDER BY 1;"
verdict D-03 "잠기지 않은 비밀번호 계정 모두 사용기간 ${PW_LIFE_MAX}일 이하 + 복잡도 검증함수(PASSWORD_VERIFY_FUNCTION) 적용" \
  "사용기간(${PW_LIFE_MAX}일 이하, --pw-life-max 로 기관 기준 조정) 또는 복잡도 검증함수 미적용 계정 → 프로파일 설정 필요,"

# D-04 관리자 권한 최소화 — 가이드 쿼리: DBA 롤 없이 SYSDBA 또는 WITH ADMIN OPTION 시스템 권한 보유(나오면 취약)
viol "SELECT username||'(SYSDBA)' FROM v\$pwfile_users WHERE sysdba='TRUE' AND username NOT IN ('SYS','INTERNAL') AND username NOT IN $DBAH UNION ALL SELECT grantee||'('||privilege||' WITH ADMIN OPTION)' FROM dba_sys_privs WHERE admin_option='YES' AND grantee NOT IN ('SYS','SYSTEM') AND grantee NOT IN $MU AND grantee NOT IN $MR AND grantee NOT IN $DBAH ORDER BY 1;"
r4="$V_ROWS"; n4=$V_NROW; e4="$V_ERR"
viol "SELECT grantee FROM dba_role_privs WHERE granted_role='DBA' AND grantee NOT IN ('SYS','SYSTEM') AND grantee NOT IN $MU AND grantee NOT IN $MR ORDER BY 1;"
if [ "$n4" -gt 0 ]; then rep D-04 VULN "DBA 롤 없이 관리자 권한(SYSDBA/WITH ADMIN OPTION) 보유 ${n4}건: $(short "$r4") → 불필요 권한 회수" ${V_ROWS:+"DBA 롤 보유 일반 계정: $(short "$V_ROWS")"}
elif [ "$V_NROW" -gt 0 ]; then rep D-04 MAN "DBA 롤 보유 일반 계정 ${V_NROW}개: $(short "$V_ROWS") → 관리자 권한이 꼭 필요한 계정인지 확인(불필요 시 REVOKE DBA)"
elif [ -n "$e4$V_ERR" ]; then rep D-04 MAN "조회 실패(${e4:-$V_ERR}) → 권한 있는 계정으로 재점검하거나 수동 확인"
else rep D-04 GOOD "SYS/SYSTEM·Oracle 관리 계정 외 관리자 권한(DBA 롤·SYSDBA·WITH ADMIN OPTION) 보유 계정 없음"; fi

# D-05 비밀번호 재사용 제약 — 둘 다 UNLIMITED(제약 없음) 또는 둘 다 숫자인데 가이드 최소값(REUSE_MAX 10회·REUSE_TIME 365일) 미만
#   (한쪽만 UNLIMITED 이면 Oracle 에서는 재사용 자체가 불가 → 제약 적용으로 봄)
_rm=$(eff PASSWORD_REUSE_MAX); _rt=$(eff PASSWORD_REUSE_TIME)
viol "SELECT username||'('||profile||': REUSE_MAX='||rm||', REUSE_TIME='||rt||')' FROM (SELECT u.username, u.profile, $_rm rm, $_rt rt FROM dba_users u WHERE u.account_status NOT LIKE '%LOCKED%' AND u.authentication_type='PASSWORD') WHERE (rm='UNLIMITED' AND rt='UNLIMITED') OR (rm<>'UNLIMITED' AND rt<>'UNLIMITED' AND (NVL(CASE WHEN REGEXP_LIKE(rm,'^[0-9]*[.]?[0-9]+\$') THEN TO_NUMBER(rm) END,0) < $REUSE_MAX_MIN OR NVL(CASE WHEN REGEXP_LIKE(rt,'^[0-9]*[.]?[0-9]+\$') THEN TO_NUMBER(rt) END,0) < $REUSE_TIME_MIN)) ORDER BY 1;"
verdict D-05 "잠기지 않은 비밀번호 계정 모두 재사용 제약 적용(REUSE_MAX ${REUSE_MAX_MIN}회·REUSE_TIME ${REUSE_TIME_MIN}일 이상 또는 재사용 불가)" \
  "비밀번호 재사용 제약 없음/미흡(기준 REUSE_MAX ${REUSE_MAX_MIN}회·REUSE_TIME ${REUSE_TIME_MIN}일 이상) 계정 → ALTER PROFILE ... PASSWORD_REUSE_TIME/MAX 설정,"

# D-06 계정 개별 부여 — 공용 계정 여부는 인터뷰(계정 목록 제시)
if [ -n "$EACCT" ] && [ "$NACCT" -eq 0 ]; then rep D-06 MAN "계정 조회 실패($EACCT) → 사용자별·응용별 개별 계정 부여 여부 인터뷰 확인"
else rep D-06 MAN "잠금 해제된 일반 계정 ${NACCT}개${ACCTS:+: $(short "$ACCTS")} → 사용자별·응용별 개별 계정 사용(공용 계정 없음) 여부 인터뷰 확인"; fi

# D-07 root 권한 구동 제한 — pmon/리스너 프로세스 전부 확인
if [ "$IS_REMOTE" = 1 ]; then rep D-07 MAN "원격 접속 점검 → DB 서버에서 Oracle/리스너 프로세스가 root 가 아닌 계정으로 구동되는지 확인"
elif [ -r /proc ]; then
  u7=""; r7=""
  for p in /proc/[0-9]*; do
    c=$(cat "$p/comm" 2>/dev/null); case "$c" in *pmon*|*tnslsnr*) ;; *) continue;; esac
    uid=$(awk '/^Uid:/{print $2}' "$p/status" 2>/dev/null); u7="$u7 $c(uid=$uid)"; [ "$uid" = 0 ] && r7="$r7 $c"
  done
  if [ -z "$u7" ]; then rep D-07 MAN "Oracle/리스너 프로세스 소유자 확인 불가 → root 가 아닌 별도 계정 구동 확인"
  elif [ -n "$r7" ]; then rep D-07 VULN "root(uid 0)로 구동 중인 Oracle/리스너 프로세스:$r7 → 전용 계정(oracle)으로 구동"
  else rep D-07 GOOD "Oracle/리스너 프로세스 모두 root 아닌 계정으로 구동:$u7"; fi
else rep D-07 MAN "/proc 조회 불가 → DBMS 가 root 아닌 계정으로 구동되는지 확인"; fi

# D-08 안전한 암호화 알고리즘 — 잠기지 않은 계정의 12C(SHA-2) 검증자 + sqlnet.ora ALLOWED_LOGON_VERSION_SERVER
viol "SELECT username||'('||password_versions||')' FROM dba_users WHERE authentication_type='PASSWORD' AND account_status NOT LIKE '%LOCKED%' AND password_versions IS NOT NULL AND password_versions NOT LIKE '%12C%' ORDER BY 1;"
alv=""; [ "$IS_REMOTE" = 0 ] && [ -n "$TNSADM" ] && alv=$(conf_val "$TNSADM/sqlnet.ora" 'SQLNET\.ALLOWED_LOGON_VERSION_SERVER')
ev8="sqlnet.ora SQLNET.ALLOWED_LOGON_VERSION_SERVER=${alv:-미설정(12c R2 이상 기본 12)}"
weak8=0; case "$alv" in [0-9]|1[01]) weak8=1;; esac
if [ "$V_NROW" -gt 0 ] || [ "$weak8" = 1 ]; then
  rep D-08 VULN "$( [ "$V_NROW" -gt 0 ] && echo "12C(SHA-2) 검증자 없는 잠금 해제 계정 ${V_NROW}건: $(short "$V_ROWS")" || echo "구 버전 해시(10G/11G) 로그온 허용")" "$ev8 → ALLOWED_LOGON_VERSION_SERVER=12 이상 설정 후 비밀번호 재설정"
elif [ -n "$V_ERR" ]; then rep D-08 MAN "조회 실패($V_ERR) → 권한 있는 계정으로 재점검" "$ev8"
else rep D-08 GOOD "잠금 해제된 비밀번호 계정 모두 12C(SHA-2) 검증자 사용" "$ev8"; fi

# D-09 로그인 실패 잠금 — 실제 적용 프로파일의 FAILED_LOGIN_ATTEMPTS 가 UNLIMITED 또는 기준 초과
_fa=$(eff FAILED_LOGIN_ATTEMPTS)
viol "SELECT username||'('||profile||': FAILED_LOGIN_ATTEMPTS='||fa||')' FROM (SELECT u.username, u.profile, $_fa fa FROM dba_users u WHERE u.account_status NOT LIKE '%LOCKED%' AND u.authentication_type='PASSWORD') WHERE fa='UNLIMITED' OR NVL(CASE WHEN REGEXP_LIKE(fa,'^[0-9]+\$') THEN TO_NUMBER(fa) END,0) > $LOGIN_FAIL_MAX ORDER BY 1;"
verdict D-09 "잠금 해제된 비밀번호 계정 모두 로그인 실패 ${LOGIN_FAIL_MAX}회 이하에서 잠금(FAILED_LOGIN_ATTEMPTS)" \
  "로그인 실패 잠금 미설정(UNLIMITED) 또는 기준(${LOGIN_FAIL_MAX}회, --login-fail-max 로 조정) 초과 계정 → FAILED_LOGIN_ATTEMPTS 설정,"

#==============================================================================
echo -e "${W}[ 2. 접근 관리 ]${N}"

# D-10 원격 접속 제한 — sqlnet.ora(주석 제외) TCP.VALIDNODE_CHECKING=yes + TCP.INVITED_NODES
if [ "$IS_REMOTE" = 1 ]; then rep D-10 MAN "원격 접속 점검 → DB 서버의 sqlnet.ora TCP.VALIDNODE_CHECKING/INVITED_NODES 직접 확인"
elif [ -z "$TNSADM" ]; then rep D-10 MAN "TNS_ADMIN 미확인 → sqlnet.ora 의 TCP.VALIDNODE_CHECKING/INVITED_NODES(지정 IP 접근 제한) 확인 필요"
elif [ -f "$TNSADM/sqlnet.ora" ]; then
  vn10=0; conf_has "$TNSADM/sqlnet.ora" '^[[:space:]]*TCP\.VALIDNODE_CHECKING[[:space:]]*=[[:space:]]*YES' && vn10=1
  inv10=$(conf_val "$TNSADM/sqlnet.ora" 'TCP\.INVITED_NODES')
  if [ "$vn10" = 1 ] && [ -n "$inv10" ]; then rep D-10 GOOD "sqlnet.ora TCP.VALIDNODE_CHECKING=yes + INVITED_NODES=$(short "$inv10") → 지정 IP만 접속 허용"
  elif [ "$vn10" = 1 ]; then rep D-10 VULN "sqlnet.ora TCP.VALIDNODE_CHECKING=yes 이나 TCP.INVITED_NODES 미설정 → 허용 IP 목록 없음(EXCLUDED_NODES 만으로는 지정 IP만 허용이 아님)"
  else rep D-10 VULN "$TNSADM/sqlnet.ora 에 TCP.VALIDNODE_CHECKING=yes 미설정(주석 제외) → DB 접속 IP 제한 없음(INVITED_NODES 설정 권장, 방화벽/보안그룹 제한은 별도 확인)"; fi
else rep D-10 VULN "$TNSADM 에 sqlnet.ora 없음 → 접속 노드 제한 미적용(sqlnet.ora INVITED_NODES 설정 권장, 방화벽/보안그룹 제한은 별도 확인)"; fi

# D-11 시스템 테이블 접근 제한 — 가이드 쿼리(EXECUTE 제외·PUBLIC·기본 롤·DBA 보유자 제외) + Oracle 관리 계정/롤 제외, 나오면 취약
viol "SELECT grantee||':'||privilege||' ON '||owner||'.'||table_name FROM dba_tab_privs WHERE (owner='SYS' OR table_name LIKE 'DBA\_%' ESCAPE '\\') AND privilege<>'EXECUTE' AND grantee NOT IN ('PUBLIC','AQ_ADMINISTRATOR_ROLE','AQ_USER_ROLE','AURORA\$JIS\$UTILITY\$','OSE\$HTTP\$ADMIN','TRACESVR','CTXSYS','DBA','DELETE_CATALOG_ROLE','EXECUTE_CATALOG_ROLE','EXP_FULL_DATABASE','GATHER_SYSTEM_STATISTICS','HS_ADMIN_ROLE','IMP_FULL_DATABASE','LOGSTDBY_ADMINISTRATOR','MDSYS','ODM','OEM_MONITOR','OLAPSYS','ORDSYS','OUTLN','RECOVERY_CATALOG_OWNER','SELECT_CATALOG_ROLE','SNMPAGENT','SYSTEM','WKSYS','WKUSER','WMSYS','WM_ADMIN_ROLE','XDB','LBACSYS','PERFSTAT','XDBADMIN') AND grantee NOT IN $MU AND grantee NOT IN $MR AND grantee NOT IN $DBAH ORDER BY 1;"
verdict D-11 "시스템 테이블(SYS 소유·DBA_*)에 DBA 외 일반 계정의 접근 권한 없음" \
  "시스템 테이블(SYS 소유·DBA_*) 접근 권한을 가진 일반 계정/롤 → REVOKE 필요,"

# D-12 리스너 비밀번호 — 12c R2 이후는 리스너 비밀번호 미지원 → 해당사항 없음(가이드 p.636)
if ver_ge 12 2; then rep D-12 NA "Oracle ${DB_VER} — 12c Release 2 이후 리스너 비밀번호 설정을 지원하지 않아 가이드상 해당사항 없음(로컬 OS 인증으로 관리)"
elif [ "$IS_REMOTE" = 1 ]; then rep D-12 MAN "원격 접속 점검 → DB 서버의 listener.ora 리스너 비밀번호(PASSWORDS_) 설정 확인"
elif [ -n "$TNSADM" ] && [ -f "$TNSADM/listener.ora" ]; then
  if conf_has "$TNSADM/listener.ora" '^[[:space:]]*PASSWORDS_'; then rep D-12 GOOD "listener.ora 에 리스너 비밀번호(PASSWORDS_) 설정"
  else rep D-12 MAN "listener.ora 에 PASSWORDS_ 미설정 — Oracle 10g 이후 로컬 OS 인증이 기본이라 원격 관리 미허용 시 위험 낮음, 원격 관리 정책 확인"; fi
else rep D-12 MAN "listener.ora 미확인 → 리스너 원격 관리 허용 시 비밀번호 설정 여부 확인(로컬 인증만 사용 시 해당 없음)"; fi

# D-13 ODBC/OLE-DB (Windows 전용)
rep D-13 NA "점검 대상이 Windows OS(제어판 ODBC 데이터 원본)로 한정 → Oracle/리눅스 대상 아님"

# D-14 주요 설정·비밀번호·데이터 파일 및 디렉터리 — 일반 사용자(그룹/기타) 쓰기 권한 없어야 양호(심볼릭 링크는 대상 권한)
if [ "$IS_REMOTE" = 1 ]; then rep D-14 MAN "원격 접속 점검 → DB 서버의 orapw/spfile/init.ora/listener.ora/데이터 파일 권한(일반 사용자 쓰기 불가) 확인"
else
  _dbs=""; [ -n "${ORACLE_HOME:-}" ] && _dbs="$ORACLE_HOME/dbs"
  if [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/bin/orabaseconfig" ]; then _obc=$("$ORACLE_HOME/bin/orabaseconfig" 2>/dev/null); [ -n "$_obc" ] && _dbs="$_dbs $_obc/dbs"; fi
  _dbf=$(run_sql "SELECT value FROM v\$parameter WHERE name='spfile' AND value IS NOT NULL UNION SELECT name FROM v\$controlfile UNION SELECT member FROM v\$logfile UNION SELECT name FROM v\$datafile;")
  qerr "$_dbf" && _dbf=""
  _dbf=$(printf '%s\n' "$_dbf" | tr -d '\r' | sed "s#^?#${ORACLE_HOME:-?}#" | grep '^/')
  _list=$( { [ -n "$TNSADM" ] && printf '%s\n' "$TNSADM" "$TNSADM/listener.ora" "$TNSADM/sqlnet.ora" "$TNSADM/tnsnames.ora"
             for _d in $_dbs; do printf '%s\n' "$_d"; for _f in "$_d"/orapw* "$_d"/spfile*.ora "$_d"/init*.ora; do printf '%s\n' "$_f"; done; done
             printf '%s\n' "$_dbf"; printf '%s\n' "$_dbf" | while IFS= read -r _f; do [ -n "$_f" ] && dirname "$_f"; done; } | awk 'NF' | sort -u )
  n14=0; bad14=""
  while IFS= read -r _f; do
    [ -e "$_f" ] || continue
    _p=$(stat -L -c '%a' "$_f" 2>/dev/null) || continue
    n14=$((n14+1)); [ $(( 8#$_p & 8#022 )) -ne 0 ] && bad14="$bad14 $_f($_p)"
  done <<EOF
$_list
EOF
  if [ "$n14" -eq 0 ]; then rep D-14 MAN "주요 파일 경로 확인 불가(ORACLE_HOME/TNS_ADMIN/SQL 조회) → orapw·spfile·init.ora·listener.ora·데이터 파일 권한(일반 사용자 쓰기 불가) 확인"
  elif [ -n "$bad14" ]; then rep D-14 VULN "일반 사용자(그룹/기타) 쓰기 권한이 있는 주요 파일/디렉터리:$(short "$bad14") → 쓰기 권한 제거(orapw·spfile·init.ora 640, 디렉터리 755 이하)"
  else rep D-14 GOOD "주요 설정·비밀번호·데이터 파일/디렉터리 ${n14}개 점검: 일반 사용자 쓰기 권한 없음"; fi
fi

# D-15 리스너 설정 변경 제한 — listener.ora 권한(일반 사용자 쓰기 불가) + ADMIN_RESTRICTIONS_<리스너>=ON(주석 제외)
if [ "$IS_REMOTE" = 1 ]; then rep D-15 MAN "원격 접속 점검 → DB 서버 listener.ora 권한과 ADMIN_RESTRICTIONS_<리스너>=ON 확인"
elif [ -n "$TNSADM" ] && [ -f "$TNSADM/listener.ora" ]; then
  on15=0; conf_has "$TNSADM/listener.ora" '^[[:space:]]*ADMIN_RESTRICTIONS_[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*ON' && on15=1
  lp15=$(stat -L -c '%a %U' "$TNSADM/listener.ora" 2>/dev/null); w15=0
  [ -n "$lp15" ] && [ $(( 8#${lp15%% *} & 8#022 )) -ne 0 ] && w15=1
  if [ "$on15" = 1 ] && [ "$w15" = 0 ]; then rep D-15 GOOD "listener.ora(${lp15:-?}) 일반 사용자 쓰기 권한 없음 + ADMIN_RESTRICTIONS=ON → 리스너 파라미터 변경 제한"
  else rep D-15 VULN "$( [ "$on15" = 0 ] && echo "listener.ora 에 ADMIN_RESTRICTIONS_<리스너>=ON 미설정 → lsnrctl 로 파라미터(로그/trace 경로 등) 변경 가능")$( [ "$on15" = 0 ] && [ "$w15" = 1 ] && echo " / ")$( [ "$w15" = 1 ] && echo "listener.ora 권한 ${lp15} → 일반 사용자 쓰기 가능")"; fi
else rep D-15 MAN "listener.ora 미확인 → ADMIN_RESTRICTIONS_LISTENER=ON 설정 여부 확인"; fi

# D-16 Windows 인증 모드 (MSSQL 전용)
rep D-16 NA "Windows 인증 모드/ sa 계정 점검은 MSSQL 대상 → Oracle 해당 없음"

#==============================================================================
echo -e "${W}[ 3. 옵션 관리 ]${N}"

# D-17 Audit Table 접근 제한 — 감사 테이블 권한(또는 DELETE_CATALOG_ROLE)을 가진 PUBLIC/일반 계정·롤
viol "SELECT grantee||':'||privilege||' ON '||owner||'.'||table_name FROM dba_tab_privs WHERE ((owner='SYS' AND table_name IN ('AUD\$','FGA_LOG\$')) OR (owner='AUDSYS' AND table_name LIKE 'AUD\$UNIFIED%')) AND (grantee='PUBLIC' OR (grantee NOT IN $MU AND grantee NOT IN $MR AND grantee NOT IN $DBAH)) UNION ALL SELECT grantee||':DELETE_CATALOG_ROLE' FROM dba_role_privs WHERE granted_role='DELETE_CATALOG_ROLE' AND grantee NOT IN $MU AND grantee NOT IN $MR AND grantee NOT IN $DBAH ORDER BY 1;"
verdict D-17 "감사 테이블(SYS.AUD\$·FGA_LOG\$·AUDSYS.AUD\$UNIFIED) 접근 권한이 관리자(DBA·Oracle 관리 계정/롤)로 한정" \
  "감사 테이블 접근 권한(또는 DELETE_CATALOG_ROLE)을 가진 PUBLIC/일반 계정 → 권한 회수,"

# D-18 PUBLIC 에 부여된 롤(가이드 쿼리) — 하나라도 있으면 취약
viol "SELECT granted_role FROM dba_role_privs WHERE grantee='PUBLIC' ORDER BY 1;"
verdict D-18 "PUBLIC 에 부여된 롤 없음(DBA·응용 롤이 PUBLIC 으로 설정되지 않음)" \
  "PUBLIC 에 부여된 롤(전 사용자에게 권한이 열림) → REVOKE <롤> FROM PUBLIC,"

# D-19 OS_ROLES / REMOTE_OS_AUTHENT / REMOTE_OS_ROLES 모두 FALSE
viol "SELECT name||'='||value FROM v\$parameter WHERE name IN ('os_roles','remote_os_authent','remote_os_roles') AND UPPER(NVL(value,'FALSE'))<>'FALSE' ORDER BY 1;"
cur19=$(run_sql "SELECT name||'='||value FROM v\$parameter WHERE name IN ('os_roles','remote_os_authent','remote_os_roles') ORDER BY 1;")
qerr "$cur19" && cur19=""; cur19=$(printf '%s\n' "$cur19" | tr -d '\r' | awk 'NF{printf "%s%s", s, $0; s=", "}')
verdict D-19 "${cur19:-os_roles/remote_os_authent/remote_os_roles} (모두 FALSE)" "TRUE 로 설정된 파라미터 → FALSE 로 변경,"

# D-20 Object owner 제한 — 가이드 쿼리 기준(SYS·SYSTEM·Oracle 관리 계정·DBA 보유자 외 소유자), 인가 여부는 확인 필요
viol "SELECT DISTINCT owner FROM dba_objects WHERE owner<>'PUBLIC' AND owner NOT IN $MU AND owner NOT IN $DBAH ORDER BY 1;"
if [ "$V_NROW" -gt 0 ]; then rep D-20 MAN "일반 계정 소유 객체 스키마 ${V_NROW}개: $(short "$V_ROWS") → 인가된 응용 스키마인지 확인(인가되지 않은 소유자면 취약, 객체 이관/권한 회수)"
elif [ -n "$V_ERR" ]; then rep D-20 MAN "조회 실패($V_ERR) → 권한 있는 계정으로 재점검하거나 수동 확인"
else rep D-20 GOOD "객체 소유자가 SYS·SYSTEM·Oracle 관리 계정·DBA 계정으로 한정"; fi

# D-21 GRANT OPTION 제한 — 가이드 쿼리(grantable=YES, 기본 스키마 소유 제외, DBA 보유자 제외): 나오면 취약
viol "SELECT grantee||':'||privilege||' ON '||owner||'.'||table_name FROM dba_tab_privs WHERE grantable='YES' AND owner NOT IN ('SYS','MDSYS','ORDPLUGINS','ORDSYS','SYSTEM','WMSYS','SDB','LBACSYS') AND owner NOT IN $MU AND grantee NOT IN $DBAH ORDER BY 1;"
verdict D-21 "일반 계정에 WITH GRANT OPTION 으로 부여된 객체 권한 없음" \
  "WITH GRANT OPTION 객체 권한을 가진 비 DBA 계정 → 회수 후 롤로 부여,"

# D-22 RESOURCE_LIMIT (컨테이너별)
viol "SELECT 'resource_limit='||value FROM v\$parameter WHERE name='resource_limit' AND UPPER(NVL(value,'FALSE'))<>'TRUE';"
verdict D-22 "resource_limit=TRUE → 프로파일 자원 제한 활성" "resource_limit 비활성 → ALTER SYSTEM SET RESOURCE_LIMIT=TRUE,"

# D-23 / D-24 MSSQL 전용
rep D-23 NA "xp_cmdshell 은 MSSQL 확장 프로시저 → Oracle 해당 없음"
rep D-24 NA "Registry(확장 저장) 프로시저 권한 점검은 MSSQL 대상 → Oracle 해당 없음"

#==============================================================================
echo -e "${W}[ 4. 패치 관리 ]${N}"

# D-25 보안 패치 — 보안 패치가 나오지 않는 버전/에디션(XE, 지원 종료 릴리스)은 취약(가이드: 보안 패치가 적용되지 않는 버전)
lastp=$(run_sql "SELECT * FROM (SELECT TO_CHAR(action_time,'YYYY-MM-DD')||' '||description FROM dba_registry_sqlpatch WHERE status='SUCCESS' ORDER BY action_time DESC) WHERE rownum=1;" | first_line)
qerr "$lastp" && lastp=""
ev25="버전 ${DB_VER:-미상}${BANNER:+ ($BANNER)}, 최근 적용 패치: ${lastp:-없음/확인 불가}"
if printf '%s' "$BANNER" | grep -qi 'Express Edition'; then
  rep D-25 VULN "$ev25" "Express Edition(XE)은 RU/보안 패치가 제공되지 않는 에디션 → 보안 패치가 제공되는 릴리스/에디션으로 이관"
elif case "$DB_MAJOR" in 11|12|18|21) true;; *) false;; esac; then
  rep D-25 VULN "$ev25" "Oracle ${DB_MAJOR} 릴리스는 지원(보안 패치) 종료(2026-09 기준) → 지원 중인 릴리스(19c·23ai 등)로 업그레이드"
elif printf '%s' "$BANNER" | grep -qi 'Free'; then
  rep D-25 MAN "$ev25" "Free 에디션은 새 릴리스로만 보안 수정 제공 → 최신 릴리스 사용 여부와 패치 정책 확인"
else rep D-25 MAN "$ev25" "지원 중인 릴리스 → 최신 분기 RU(Release Update) 적용 여부와 패치 정책 확인"; fi

# D-26 감사 기록 정책 — 컨테이너별: Unified 활성 정책 1개 이상 또는 (audit_trail≠NONE + 전통 감사 옵션 1개 이상)
if [ "${DB_MAJOR:-12}" -ge 12 ]; then _uq="(SELECT COUNT(*) FROM audit_unified_enabled_policies)"; else _uq="0"; fi
q26="SELECT ${_uq}||' '||NVL((SELECT REPLACE(UPPER(value),' ','') FROM v\$parameter WHERE name='audit_trail'),'NONE')||' '||((SELECT COUNT(*) FROM dba_stmt_audit_opts)+(SELECT COUNT(*) FROM dba_priv_audit_opts)) FROM dual;"
ok26=""; bad26=""; err26=""
for _c in $CONS; do
  _pre=""; [ "$NCONS" -gt 1 ] && _pre="$_c: "
  _r=$(SQL_CON="$_c" run_sql "$q26" | first_line)
  if [ -z "$_r" ] || qerr "$_r"; then err26="${err26:+$err26, }${_pre}$(errc "$_r")"; continue; fi
  read -r _up _tr _op <<EOF
$_r
EOF
  case "$_up:$_op" in *[!0-9:]*|:*|*:) err26="${err26:+$err26, }${_pre}예상 밖 출력"; continue;; esac
  _d="${_pre}Unified 활성 정책 ${_up:-?}개, audit_trail=${_tr:-?}, 전통 감사 옵션 ${_op:-?}개"
  if { [ "${_up:-0}" -gt 0 ] 2>/dev/null; } || { [ "${_tr:-NONE}" != NONE ] && [ "${_op:-0}" -gt 0 ] 2>/dev/null; }; then ok26="${ok26:+$ok26 / }$_d"
  else bad26="${bad26:+$bad26 / }$_d"; fi
done
if [ -n "$ok26" ] && [ -z "$bad26" ] && [ -z "$err26" ]; then rep D-26 GOOD "$ok26" "감사 로그 보관·백업 정책 수립 여부는 인터뷰로 확인"
elif [ -n "$bad26" ] && [ -z "$ok26" ] && [ -z "$err26" ]; then rep D-26 VULN "감사 설정 없음: $bad26 → AUDIT SESSION WHENEVER NOT SUCCESSFUL 또는 Unified 감사 정책(ORA_LOGON_FAILURES 등) 활성화"
else rep D-26 MAN ${ok26:+"감사 적용: $ok26"} ${bad26:+"감사 없음: $bad26"} ${err26:+"조회 실패: $err26"} "→ 컨테이너별 감사 정책 적용 여부 확인"; fi

#==============================================================================
echo -e "${W}=========================================================${N}"
echo -e "  결과:  ${G}양호 $good${N}  ${R}취약 $vuln${N}  ${B}수동확인 $man${N}  ${Y}N/A $na${N}"
echo -e "${W}=========================================================${N}"

DATE=$(date +%Y%m%d 2>/dev/null || echo date)
SAFE_HOST=$(printf '%s' "$HOSTN" | tr -c 'A-Za-z0-9._-' '_')
[ -z "$CSV_FILE" ]  && CSV_FILE="db_oracle_${SAFE_HOST}_${DATE}.csv"
[ -z "$HTML_FILE" ] && HTML_FILE="db_oracle_${SAFE_HOST}_${DATE}.html"
if [ -n "$JSON_FILE" ]; then
  { printf '{"target":"DBMS(Oracle)","host":"%s","os":"Oracle %s","results":[' "$(json_escape "$HOSTN")" "$(json_escape "${DB_VER:-?}")"
    printf '%s' "${JBUF%,}"; printf ']}'; } > "$JSON_FILE" && echo -e "  ${W}JSON${N}  저장: $JSON_FILE"
fi
if [ "$NO_SAVE" -eq 0 ]; then
  _ip=${KISA_HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}
  [ -z "$_ip" ] && _ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  { printf '\xEF\xBB\xBF'; printf '# host,%s\n# ip,%s\n# os,Oracle %s\n' "$HOSTN" "${_ip:--}" "${DB_VER:-?}"; echo "항목코드,중요도,점검항목,진단결과,근거"; printf '%s' "$CBUF"; } > "$CSV_FILE" && echo -e "  ${W}CSV${N}   저장: $CSV_FILE"
  {
    cat <<HTMLHEAD
<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>DBMS(Oracle) 취약점 진단 - ${HOSTN}</title>
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
<h1>DBMS(Oracle) 기술적 취약점 진단 결과</h1>
<div class="sub">대상: ${HOSTN} &nbsp;|&nbsp; Oracle ${DB_VER:-?} &nbsp;|&nbsp; PDB: ${CON_NAME:-N/A} &nbsp;|&nbsp; 작성일: $(date '+%Y-%m-%d' 2>/dev/null)</div>
<div class="cards">
<div class="card c-good">양호<b>${good}</b></div><div class="card c-vuln">취약<b>${vuln}</b></div>
<div class="card c-man">인터뷰 필요<b>${man}</b></div><div class="card c-na">N/A<b>${na}</b></div></div>
<table><thead><tr><th>항목코드</th><th>중요도</th><th>점검항목</th><th>진단결과</th><th>상세 내용 / 근거</th></tr></thead><tbody>
HTMLHEAD
    printf '%s' "$HBUF"
    echo "</tbody></table></body></html>"
  } > "$HTML_FILE" && echo -e "  ${W}HTML${N}  리포트: $HTML_FILE  (브라우저로 열기)"
fi
[ "$vuln" -gt 0 ] && exit 1 || exit 0
