#!/usr/bin/env bash
# 서버에서 한 방에: 취약점 점검 → CSV 를 S3 에 업로드 → S3 의 전체 CSV 취합
# → 결과보고서(xlsx) 생성 → S3 의 보고서에 병합(누적·버전)해서 다시 업로드.
#
# 사용(리눅스 서버·DB·클라우드 어디서든):
#   bash s3report.sh                      # 인프라+웹 점검 후 보고서까지 S3 에 병합
#   bash s3report.sh --dbms --user oraadmin --pass '***' --service FREEPDB1
#   bash s3report.sh --cloud aws          # 클라우드(자격증명은 환경/역할)
#   bash s3report.sh --only web --target tomcat --app-url http://localhost:8080
#   bash s3report.sh --merge-only         # 점검 없이 S3 CSV 만 모아 보고서 재생성
#   bash s3report.sh --no-report          # 점검+CSV 업로드만(파이썬 없는 서버)
#
# 전제: aws CLI + (보고서 생성 시) python3 + lxml. S3 접근 권한(IAM 역할/키).
set -u

S3="${S3_BASE:-s3://vuln-lab-backup/infra-auto-diag}"
WORK="${WORK:-$HOME/kisa_work}"
MODE="server"           # server | cloud | dbms
CSP="aws"
DO_SCAN=1; DO_REPORT=1
SCAN_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cloud)       MODE="cloud"; CSP="${2:-aws}"; shift 2 ;;
    --dbms)        MODE="dbms"; shift ;;
    --merge-only)  DO_SCAN=0; shift ;;
    --no-report)   DO_REPORT=0; shift ;;
    --work)        WORK="${2:?}"; shift 2 ;;
    --)            shift; while [ $# -gt 0 ]; do SCAN_ARGS+=("$1"); shift; done ;;
    *)             SCAN_ARGS+=("$1"); shift ;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "[!] aws CLI 가 없습니다. 먼저 설치하세요."; exit 1; }
mkdir -p "$WORK/scan" "$WORK/allcsv" "$WORK/out"
cd "$WORK" || exit 1

# 1) 도구 내려받기(보고서 생성용 단일 파일 + 점검 스크립트)
[ "$DO_REPORT" = 1 ] && aws s3 cp "$S3/tools/makereport_all.py" makereport_all.py --quiet
if [ "$DO_SCAN" = 1 ]; then
  case "$MODE" in
    server) aws s3 cp "$S3/tools/kisa_all_check.ps1" kisa_all_check.ps1 --quiet ;;
    cloud)  aws s3 cp "$S3/tools/cloudscan_all.py"  cloudscan_all.py  --quiet ;;
    dbms)   aws s3 cp "$S3/tools/db_oracle_check.sh" db_oracle_check.sh --quiet ;;
  esac
fi

# 2) 점검 → scan/ 에 CSV
if [ "$DO_SCAN" = 1 ]; then
  rm -f scan/*.csv scan/*.html 2>/dev/null
  echo "[*] 점검 시작($MODE)…"
  case "$MODE" in
    server) sudo bash kisa_all_check.ps1 -o scan $( [ ${#SCAN_ARGS[@]} -gt 0 ] && printf '%s ' "${SCAN_ARGS[@]}" ) ;;
    cloud)  ( cd scan && python3 ../cloudscan_all.py "$CSP" --no-excel $( [ ${#SCAN_ARGS[@]} -gt 0 ] && printf '%s ' "${SCAN_ARGS[@]}" ) ) ;;
    dbms)   ( cd scan && bash ../db_oracle_check.sh $( [ ${#SCAN_ARGS[@]} -gt 0 ] && printf '%s ' "${SCAN_ARGS[@]}" ) ) ;;
  esac
  ls scan/*.csv >/dev/null 2>&1 || { echo "[!] 생성된 CSV 가 없습니다. 점검 로그를 확인하세요."; exit 1; }
  # 3) 내 CSV 를 S3 에(같은 호스트 재스캔 CSV 는 취합 때 최신만 반영됨)
  aws s3 cp scan/ "$S3/results/" --recursive --exclude "*" --include "*.csv"
  echo "[*] CSV 업로드 완료 → $S3/results/"
fi

[ "$DO_REPORT" = 1 ] || { echo "[*] 완료(보고서 생성 생략)."; exit 0; }

# 4) 전 서버 CSV + 현재 버전기록 취합
aws s3 sync "$S3/results/" allcsv --exclude "*" --include "*.csv" --quiet
aws s3 cp "$S3/reports/.report_version.json" "out/.report_version.json" --quiet 2>/dev/null || true

# 5) 병합 보고서 생성(python3 + lxml)
if ! python3 -c 'import lxml.etree' 2>/dev/null; then
  echo "[*] lxml 설치 시도…"; pip3 install --user lxml --quiet 2>/dev/null || true
fi
if ! python3 -c 'import lxml.etree' 2>/dev/null; then
  echo "[!] lxml 이 없어 보고서 생성을 건너뜁니다(CSV 는 이미 S3 에 있음). python 되는 곳에서 --merge-only 로 병합하세요."
  exit 0
fi
python3 makereport_all.py allcsv -o out || { echo "[!] 보고서 생성 실패"; exit 1; }

# 6) 병합 결과(xlsx + 버전기록)를 S3 보고서에
aws s3 cp out/ "$S3/reports/" --recursive --exclude "*" --include "*.xlsx"
aws s3 cp "out/.report_version.json" "$S3/reports/.report_version.json" --quiet
echo "[*] 완료 → $S3/reports/ 에 병합 결과보고서 갱신됨"
