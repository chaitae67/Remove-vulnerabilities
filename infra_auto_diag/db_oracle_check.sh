#!/usr/bin/env bash
#==============================================================================
# DBMS(Oracle) 기술적 취약점 점검  D-01 ~ D-26
#  - KISA 주통기 / SK Shieldus DB 보안가이드 기준(공식 결과보고서 D-01~26 항목·판단기준 반영)
#  - 읽기 전용(READ-ONLY): SELECT 및 설정파일 조회만, 변경 없음
#  - 대상: Oracle Database (XE 포함) 11g~21c
#  - 실행(대상 DB 서버/컨테이너에서 sqlplus 필요):
#       bash db_oracle_check.sh --conn "sys/비밀번호@//localhost:1521/XEPDB1 as sysdba"
#       # 컨테이너 내부에서 oracle 계정 OS 인증 시:  bash db_oracle_check.sh   (기본 '/ as sysdba')
#  - MSSQL 전용 항목(D-13/16/23/24)은 Oracle 대상에서 N/A 처리.
#  - 끝나면 콘솔 요약 + CSV + HTML 리포트를 현재 폴더에 자동 저장.
# 판정: 양호 / 취약 / N/A(대상 아님→양호) / 수동확인(인터뷰 필요)
#==============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
  echo "이 스크립트는 bash 로 실행해야 합니다:  bash $0" >&2; exit 1
fi

JSON_FILE=""; CSV_FILE=""; HTML_FILE=""; NO_SAVE=0; NOCOLOR=0
CONN=""; O_USER=""; O_PASS=""; O_HOST="localhost"; O_PORT="1521"; O_SVC=""; SYSDBA=0; TNS_ADMIN_IN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --conn) CONN="${2:-}"; shift 2 ;; --user) O_USER="${2:-}"; shift 2 ;; --pass) O_PASS="${2:-}"; shift 2 ;;
    --host) O_HOST="${2:-}"; shift 2 ;; --port) O_PORT="${2:-}"; shift 2 ;; --service) O_SVC="${2:-}"; shift 2 ;;
    --sysdba) SYSDBA=1; shift ;; --tns-admin) TNS_ADMIN_IN="${2:-}"; shift 2 ;;
    --json) JSON_FILE="${2:-}"; shift 2 ;; --csv) CSV_FILE="${2:-}"; shift 2 ;; --html) HTML_FILE="${2:-}"; shift 2 ;;
    --no-save) NO_SAVE=1; shift ;; --no-color) NOCOLOR=1; shift ;;
    -h|--help) cat <<'USAGE'
사용법:
  bash db_oracle_check.sh --conn "sys/pw@//localhost:1521/XEPDB1 as sysdba"
  bash db_oracle_check.sh --user system --pass pw --service XEPDB1 [--host h --port 1521]
  bash db_oracle_check.sh                # oracle OS 인증(기본 '/ as sysdba')
옵션: --csv f --html f --json f --no-save --no-color --sysdba --tns-admin DIR
환경변수 ORACLE_CONN / ORACLE_HOME / TNS_ADMIN 인식.
USAGE
      exit 0 ;;
    *) shift ;;
  esac
done

[ -z "$CONN" ] && [ -n "${ORACLE_CONN:-}" ] && CONN="$ORACLE_CONN"
if [ -z "$CONN" ]; then
  if [ -n "$O_USER" ]; then
    CONN="$O_USER/$O_PASS@//$O_HOST:$O_PORT/${O_SVC:-XE}"; [ "$SYSDBA" -eq 1 ] && CONN="$CONN as sysdba"
    echo "$O_USER" | grep -qiE '^sys$' && CONN="$O_USER/$O_PASS@//$O_HOST:$O_PORT/${O_SVC:-XE} as sysdba"
  else CONN="/ as sysdba"; fi
fi

if [ -t 1 ] && [ "$NOCOLOR" -eq 0 ]; then
  G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; B='\033[1;34m'; C='\033[1;36m'; W='\033[1m'; N='\033[0m'
else G=''; R=''; Y=''; B=''; C=''; W=''; N=''; fi

good=0; vuln=0; na=0; man=0
HOSTN=$(hostname 2>/dev/null || echo db)

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
run_sql() {
  local q="$1" tmp; tmp=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/ora_$$_$RANDOM.sql")
  { echo "set heading off feedback off pagesize 0 linesize 400 trimspool on echo off verify off long 400 newpage none"
    echo "whenever sqlerror exit sql.sqlcode"; echo "$q"; echo "exit"; } > "$tmp"
  sqlplus -S -L "$CONN" @"$tmp" 2>/dev/null; local rc=$?; rm -f "$tmp"; return $rc
}
first_tok() { awk 'NF{print $1; exit}' | tr -d '\r'; }
count_rows() { grep -cE '[A-Za-z0-9]'; }
is_unlimited() { case "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" in UNLIMITED) return 0;; *) return 1;; esac; }
upper() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }
prof_limit() { run_sql "SELECT limit FROM dba_profiles WHERE profile='DEFAULT' AND resource_name='$1';" | first_tok; }
param_val()  { run_sql "SELECT value FROM v\$parameter WHERE name='$1';" | first_tok; }

echo -e "${W}=========================================================${N}"
echo -e "${W} DBMS(Oracle) 취약점 점검  —  $HOSTN${N}"
echo -e "${W}=========================================================${N}"
if ! have sqlplus; then
  echo -e "${R}[!] sqlplus 미탐지. Oracle 이 설치된 DB 서버/컨테이너에서 실행하세요.${N}" >&2
  echo -e "${R}    (컨테이너: docker exec -it <c> bash → oracle 계정에서 실행)${N}" >&2; exit 2
fi
PROBE=$(run_sql "SELECT 'CONN_OK' FROM dual;" | first_tok)
if [ "$PROBE" != "CONN_OK" ]; then
  echo -e "${R}[!] Oracle 접속 실패(${CONN%% as *}...). 계정/서비스명/권한 확인.${N}" >&2; exit 2
fi
DB_VER=$(run_sql "SELECT version_full FROM product_component_version WHERE product LIKE 'Oracle%' AND rownum=1;" | first_tok)
[ -z "$DB_VER" ] && DB_VER=$(run_sql "SELECT version FROM product_component_version WHERE product LIKE 'Oracle%' AND rownum=1;" | first_tok)
CON_NAME=$(run_sql "SELECT sys_context('USERENV','CON_NAME') FROM dual;" | first_tok)
# TNS_ADMIN(네트워크 설정 파일 위치)
TNSADM="${TNS_ADMIN_IN:-${TNS_ADMIN:-}}"
[ -z "$TNSADM" ] && [ -n "${ORACLE_HOME:-}" ] && TNSADM="$ORACLE_HOME/network/admin"
echo -e "  버전: ${DB_VER:-미상}   PDB: ${CON_NAME:-N/A}   접속: ${CONN%% as *}   TNS_ADMIN: ${TNSADM:-미상}"
echo

#==============================================================================
echo -e "${W}[ 1. 계정 관리 ]${N}"

# D-01 기본 계정 비밀번호/정책 변경
defpwd=$(run_sql "SELECT d.username FROM dba_users_with_defpwd d JOIN dba_users u ON d.username=u.username WHERE u.account_status LIKE '%OPEN%';")
dc=$(printf '%s\n' "$defpwd" | count_rows)
if [ "${dc:-0}" -eq 0 ]; then rep D-01 GOOD "기본 비밀번호를 사용하는 OPEN 계정 없음(기본계정 비번 변경/잠금 완료)"
else rep D-01 VULN "기본 비밀번호 사용 중인 OPEN 계정 ${dc}개: $(printf '%s ' $defpwd | cut -c1-140) → 변경/잠금 필요"; fi

# D-02 불필요 계정 제거/잠금 (샘플 + EXTERNAL 인증 OPEN)
sample=$(run_sql "SELECT username||'('||account_status||')' FROM dba_users WHERE (username IN ('SCOTT','HR','OE','SH','PM','IX','BI','DEMO','ADAMS','JONES','CLARK','BLAKE') OR authentication_type='EXTERNAL') AND account_status LIKE '%OPEN%';")
sc=$(printf '%s\n' "$sample" | count_rows)
if [ "${sc:-0}" -eq 0 ]; then rep D-02 GOOD "OPEN 상태의 샘플/외부인증(불필요) 계정 없음"
else rep D-02 VULN "불필요(샘플/EXTERNAL) OPEN 계정 ${sc}개: $(printf '%s ' $sample | cut -c1-160) → 제거/잠금"; fi

# D-03 비밀번호 사용기간 및 복잡도
plt=$(prof_limit PASSWORD_LIFE_TIME); pvf=$(prof_limit PASSWORD_VERIFY_FUNCTION)
if is_unlimited "$plt" || [ "$(upper "$pvf")" = "NULL" ] || [ -z "$pvf" ]; then
  rep D-03 VULN "DEFAULT 프로파일 PASSWORD_LIFE_TIME=$plt, VERIFY_FUNCTION=${pvf:-NULL} → 사용기간/복잡도 미흡(기간 제한+검증함수 적용 필요)"
else rep D-03 GOOD "PASSWORD_LIFE_TIME=$plt, VERIFY_FUNCTION=$pvf 적용"; fi

# D-04 DBA 권한 최소 부여
dbarole=$(run_sql "SELECT grantee FROM dba_role_privs WHERE granted_role='DBA' AND grantee NOT IN ('SYS','SYSTEM');")
gc=$(printf '%s\n' "$dbarole" | count_rows)
if [ "${gc:-0}" -eq 0 ]; then rep D-04 GOOD "SYS/SYSTEM 외 DBA 롤 부여 계정 없음"
else rep D-04 VULN "SYS/SYSTEM 외 DBA 롤 보유 ${gc}개: $(printf '%s ' $dbarole | cut -c1-140) → 불필요 시 회수"; fi

# D-05 비밀번호 재사용 제약
prm=$(prof_limit PASSWORD_REUSE_MAX); prt=$(prof_limit PASSWORD_REUSE_TIME)
if is_unlimited "$prm" && is_unlimited "$prt"; then
  rep D-05 VULN "PASSWORD_REUSE_MAX/TIME 모두 UNLIMITED → 이전 비밀번호 즉시 재사용 가능(제약 설정 필요)"
else rep D-05 GOOD "비밀번호 재사용 제약 설정(REUSE_MAX=$prm, REUSE_TIME=$prt)"; fi

# D-06 계정 개별 부여
openaccts=$(run_sql "SELECT COUNT(*) FROM dba_users WHERE account_status LIKE '%OPEN%' AND username NOT IN ('SYS','SYSTEM','SYSMAN','DBSNMP');" | first_tok)
rep D-06 MAN "OPEN 사용자 계정(기본계정 제외) ${openaccts:-?}개 → 사용자별·응용별 개별 계정 부여 여부 인터뷰 확인"

# D-07 root 권한 구동 제한
if [ -r /proc ]; then
  pmon_uid=$(for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$p/comm" 2>/dev/null); case "$c" in *pmon*|*tnslsnr*) awk '/^Uid:/{print $2}' "$p/status" 2>/dev/null; break;; esac; done)
  if [ -z "$pmon_uid" ]; then rep D-07 MAN "Oracle/리스너 프로세스 소유자 확인 불가 → root 가 아닌 별도 계정 구동 확인"
  elif [ "$pmon_uid" = 0 ]; then rep D-07 VULN "Oracle 백그라운드/리스너 프로세스가 root(uid 0)로 구동 → 전용 계정 권장"
  else rep D-07 GOOD "Oracle/리스너 프로세스 소유 UID=$pmon_uid (root 아님)"; fi
else rep D-07 MAN "/proc 조회 불가 → DBMS 가 root 아닌 계정으로 구동되는지 확인"; fi

# D-08 안전한 암호화 알고리즘(PASSWORD_VERSIONS)
weakpv=$(run_sql "SELECT username||'('||password_versions||')' FROM dba_users WHERE authentication_type='PASSWORD' AND password_versions IS NOT NULL AND password_versions NOT LIKE '%12C%';")
wc_=$(printf '%s\n' "$weakpv" | count_rows)
if [ "${wc_:-0}" -eq 0 ]; then rep D-08 GOOD "비밀번호 인증 계정이 12C(SHA-2) 검증자 사용 → 안전한 해시"
else rep D-08 VULN "12C(SHA-2) 미적용 계정 ${wc_}개: $(printf '%s ' $weakpv | cut -c1-140) → SEC_CASE_SENSITIVE_LOGON 및 비밀번호 재설정으로 12C 적용"; fi

# D-09 로그인 실패 잠금정책
fla=$(prof_limit FAILED_LOGIN_ATTEMPTS)
if is_unlimited "$fla"; then rep D-09 VULN "FAILED_LOGIN_ATTEMPTS=UNLIMITED → 로그인 실패 잠금 미설정(임계값 설정 필요)"
elif [ -n "$fla" ] && printf '%s' "$fla" | grep -qE '^[0-9]+$'; then rep D-09 GOOD "FAILED_LOGIN_ATTEMPTS=$fla (잠금 임계값 설정)"
else rep D-09 VULN "FAILED_LOGIN_ATTEMPTS=$fla → 잠금 임계값 미설정/과다"; fi

#==============================================================================
echo -e "${W}[ 2. 접근 관리 ]${N}"

# D-10 원격 접속 제한 (sqlnet.ora VALIDNODE_CHECKING)
if [ -n "$TNSADM" ] && [ -f "$TNSADM/sqlnet.ora" ]; then
  if grep -qiE 'TCP.VALIDNODE_CHECKING\s*=\s*yes' "$TNSADM/sqlnet.ora"; then rep D-10 GOOD "sqlnet.ora TCP.VALIDNODE_CHECKING=yes → 지정 IP만 접근 허용"
  else rep D-10 VULN "sqlnet.ora 에 VALIDNODE_CHECKING 미설정 → 접속 IP 제한 없음(INVITED_NODES 설정 권장)"; fi
elif [ -n "$TNSADM" ]; then rep D-10 VULN "$TNSADM 에 sqlnet.ora 없음 → 접속 노드 제한 미적용(sqlnet.ora INVITED_NODES 설정 권장)"
else rep D-10 MAN "TNS_ADMIN 미확인 → sqlnet.ora 의 TCP.VALIDNODE_CHECKING/INVITED_NODES(지정 IP 접근 제한) 확인 필요"; fi

# D-11 시스템 테이블 접근 제한
systab=$(run_sql "SELECT COUNT(*) FROM dba_tab_privs WHERE (owner='SYS' OR table_name LIKE 'DBA\_%' ESCAPE '\\') AND grantee NOT IN ('SYS','SYSTEM','DBA','SELECT_CATALOG_ROLE','EXP_FULL_DATABASE','IMP_FULL_DATABASE','DATAPUMP_EXP_FULL_DATABASE','DATAPUMP_IMP_FULL_DATABASE','ORACLE_OCM','GSMADMIN_INTERNAL','AUDIT_ADMIN','EM_EXPRESS_ALL') AND grantee NOT LIKE '%\_CATALOG\_%' ESCAPE '\\';" | first_tok)
if [ "${systab:-0}" = "0" ]; then rep D-11 GOOD "시스템 테이블(SYS/DBA_*)에 DBA 외 일반 계정 접근 권한 없음"
else rep D-11 MAN "SYS/DBA_* 객체에 비-DBA 부여 ${systab}건 → 카탈로그 롤 외 불필요 접근 여부 검토"; fi

# D-12 리스너 비밀번호
if [ -n "$TNSADM" ] && [ -f "$TNSADM/listener.ora" ]; then
  if grep -qiE 'PASSWORDS_' "$TNSADM/listener.ora"; then rep D-12 GOOD "listener.ora 에 리스너 비밀번호(PASSWORDS_) 설정"
  else rep D-12 MAN "listener.ora 에 PASSWORDS_ 미설정 — Oracle 10g 이후 로컬 OS 인증이 기본이라 원격 관리 미허용 시 위험 낮음, 원격 관리 정책 확인"; fi
else rep D-12 MAN "listener.ora 미확인 → 리스너 원격 관리 허용 시 비밀번호 설정 여부 확인(로컬 인증만 사용 시 해당 없음)"; fi

# D-13 ODBC/OLE-DB (Windows 전용)
rep D-13 NA "점검 대상이 Windows OS(제어판 ODBC 데이터 원본)로 한정 → Oracle/리눅스 대상 아님"

# D-14 주요 설정/비밀번호 파일 권한
bad14=""
if [ -n "$TNSADM" ]; then
  for f in "$TNSADM/listener.ora" "$TNSADM/sqlnet.ora"; do
    [ -f "$f" ] || continue; p=$(stat -c '%a' "$f" 2>/dev/null); [ "$(( 8#${p:-0} & 8#022 ))" -ne 0 ] && bad14="$bad14 $(basename "$f")($p)"
  done
fi
if [ -n "${ORACLE_HOME:-}" ]; then
  for f in "$ORACLE_HOME"/dbs/orapw* "$ORACLE_HOME"/dbs/spfile*; do
    [ -f "$f" ] || continue; p=$(stat -c '%a' "$f" 2>/dev/null); [ "$(( 8#${p:-0} & 8#077 ))" -ne 0 ] && bad14="$bad14 $(basename "$f")($p)"
  done
fi
if [ -z "$TNSADM" ] && [ -z "${ORACLE_HOME:-}" ]; then rep D-14 MAN "ORACLE_HOME/TNS_ADMIN 미확인 → orapw/spfile/listener.ora 권한(640 이하, 일반사용자 수정 불가) 확인"
elif [ -n "$bad14" ]; then rep D-14 VULN "일반 사용자 접근 가능한 주요 파일:$bad14 → 권한 축소(orapw/spfile 640 이하)"
else rep D-14 GOOD "주요 설정/비밀번호 파일(orapw/spfile/listener.ora) 권한 적절(일반 사용자 수정 불가)"; fi

# D-15 리스너 admin_restrictions
if [ -n "$TNSADM" ] && [ -f "$TNSADM/listener.ora" ]; then
  if grep -qiE 'ADMIN_RESTRICTIONS_[A-Za-z0-9]*\s*=\s*ON' "$TNSADM/listener.ora"; then rep D-15 GOOD "listener.ora ADMIN_RESTRICTIONS=ON → 리스너 런타임 파라미터 변경 제한"
  else rep D-15 VULN "listener.ora 에 ADMIN_RESTRICTIONS=ON 미설정 → lsnrctl 로 파라미터 변경 가능(ON 설정 권장)"; fi
else rep D-15 MAN "listener.ora 미확인 → ADMIN_RESTRICTIONS_LISTENER=ON 설정 여부 확인"; fi

# D-16 Windows 인증 모드 (MSSQL 전용)
rep D-16 NA "Windows 인증 모드/ sa 계정 점검은 MSSQL 대상 → Oracle 해당 없음"

#==============================================================================
echo -e "${W}[ 3. 옵션 관리 ]${N}"

# D-17 Audit Table 접근 제한 (SYS.AUD$)
audpub=$(run_sql "SELECT COUNT(*) FROM dba_tab_privs WHERE table_name='AUD\$' AND grantee IN ('PUBLIC');" | first_tok)
if [ "${audpub:-0}" = "0" ]; then rep D-17 GOOD "SYS.AUD\$ 감사 테이블에 PUBLIC 권한 없음(DBA 접근 제한)"
else rep D-17 VULN "SYS.AUD\$ 에 PUBLIC 권한 부여 → 감사 테이블 접근을 DBA로 제한 필요"; fi

# D-18 DBA Role Public 미설정
rolepub=$(run_sql "SELECT COUNT(*) FROM dba_role_privs WHERE grantee='PUBLIC' AND granted_role IN ('DBA','IMP_FULL_DATABASE','EXP_FULL_DATABASE');" | first_tok)
if [ "${rolepub:-0}" = "0" ]; then rep D-18 GOOD "PUBLIC 에 DBA/FULL_DATABASE 롤 부여 없음"
else rep D-18 VULN "PUBLIC 에 DBA 계열 롤 부여 → 즉시 회수 필요"; fi

# D-19 OS_ROLES / REMOTE_OS_AUTHENT / REMOTE_OS_ROLES
osr=$(param_val os_roles); roa=$(param_val remote_os_authent); ror=$(param_val remote_os_roles)
if [ "$(upper "${osr:-FALSE}")" = "FALSE" ] && [ "$(upper "${roa:-FALSE}")" = "FALSE" ] && [ "$(upper "${ror:-FALSE}")" = "FALSE" ]; then
  rep D-19 GOOD "os_roles=${osr:-FALSE}, remote_os_authent=${roa:-FALSE}, remote_os_roles=${ror:-FALSE} (모두 FALSE)"
else rep D-19 VULN "os_roles=$osr, remote_os_authent=$roa, remote_os_roles=$ror → TRUE 항목 존재(모두 FALSE 필요)"; fi

# D-20 Object owner 제한
objown=$(run_sql "SELECT COUNT(DISTINCT owner) FROM dba_objects WHERE owner NOT IN ('SYS','SYSTEM','OUTLN','DBSNMP','APPQOSSYS','GSMADMIN_INTERNAL','XDB','WMSYS','CTXSYS','MDSYS','ORDSYS','ORDDATA','OLAPSYS','LBACSYS','DVSYS','AUDSYS','DBSFWUSER','REMOTE_SCHEDULER_AGENT','SYS\$UMF','GGSYS','ANONYMOUS','SYSRAC','SYSKM','SYSDG','SYSBACKUP','ORACLE_OCM','PDBADMIN');" | first_tok)
rep D-20 MAN "시스템 계정 외 객체 소유자 ${objown:-?}종 → 애플리케이션 전용 계정 외 일반 사용자 소유 객체 없는지 검토"

# D-21 GRANT OPTION 제한
grantopt=$(run_sql "SELECT COUNT(*) FROM dba_tab_privs WHERE grantable='YES' AND grantee NOT IN ('SYS','SYSTEM','DBA') AND grantor NOT IN ('SYS','SYSTEM');" | first_tok)
if [ "${grantopt:-0}" = "0" ]; then rep D-21 GOOD "일반 계정에 부여된 WITH GRANT OPTION 객체 권한 없음"
else rep D-21 MAN "GRANT OPTION 부여 객체 권한 ${grantopt}건(기본 관리자 제외) → 권한 재부여 위험 검토"; fi

# D-22 RESOURCE_LIMIT
rl=$(param_val resource_limit)
if [ "$(upper "${rl:-FALSE}")" = "TRUE" ]; then rep D-22 GOOD "resource_limit=TRUE → 프로파일 자원 제한 활성"
else rep D-22 VULN "resource_limit=${rl:-FALSE} → 프로파일 자원 제한 기능 비활성(TRUE 설정 권장)"; fi

# D-23 / D-24 MSSQL 전용
rep D-23 NA "xp_cmdshell 은 MSSQL 확장 프로시저 → Oracle 해당 없음"
rep D-24 NA "Registry(확장 저장) 프로시저 권한 점검은 MSSQL 대상 → Oracle 해당 없음"

#==============================================================================
echo -e "${W}[ 4. 패치 관리 ]${N}"

# D-25 보안 패치
patch=$(run_sql "SELECT description FROM dba_registry_sqlpatch WHERE rownum=1 ORDER BY action_time DESC;" 2>/dev/null | tr '\n' ' ' | cut -c1-100)
rep D-25 MAN "DB 버전=${DB_VER:-미상}${patch:+, 최근 패치: $patch} → 분기 Release Update(RU/CPU) 최신 적용 여부 확인"

# D-26 감사 기록 정책
atrail=$(param_val audit_trail); ua=$(run_sql "SELECT value FROM v\$option WHERE parameter='Unified Auditing';" | first_tok)
uapol=$(run_sql "SELECT COUNT(*) FROM audit_unified_enabled_policies;" | first_tok)
if [ "$(upper "$ua")" = "TRUE" ] && [ -n "$uapol" ] && [ "${uapol:-0}" != "0" ]; then rep D-26 GOOD "Unified Auditing=TRUE, 활성 감사정책 ${uapol}개"
elif [ -n "$atrail" ] && [ "$(upper "$atrail")" != "NONE" ]; then rep D-26 GOOD "audit_trail=$atrail → 감사 로깅 활성"
else rep D-26 VULN "audit_trail=${atrail:-NONE}, Unified 정책 ${uapol:-0}개 → 감사 미설정(주요 이벤트 감사 활성화 필요)"; fi

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
  { printf '\xEF\xBB\xBF'; echo "항목코드,중요도,점검항목,진단결과,근거"; printf '%s' "$CBUF"; } > "$CSV_FILE" && echo -e "  ${W}CSV${N}   저장: $CSV_FILE"
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
