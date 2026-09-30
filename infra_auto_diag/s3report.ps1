# s3report.ps1 — 윈도우 서버에서 한 방에:
#   취약점 점검(인프라+웹) → CSV 를 S3 업로드 → S3 의 전체 CSV 취합
#   → 결과보고서(xlsx) 생성 → S3 의 보고서에 병합(누적·버전)해서 다시 업로드.
#
# 사용(관리자 PowerShell):
#   powershell -ExecutionPolicy Bypass -File s3report.ps1
#   powershell -ExecutionPolicy Bypass -File s3report.ps1 -Only web -Target iis
#   powershell -ExecutionPolicy Bypass -File s3report.ps1 -MergeOnly     # 점검 없이 S3 CSV 만 병합
#   powershell -ExecutionPolicy Bypass -File s3report.ps1 -NoReport      # 점검+업로드만
#
# 전제: aws CLI + (보고서 생성 시) python + lxml. S3 접근 권한(IAM 역할/키).
param(
  [string]$S3Base = "s3://vuln-lab-backup/infra-auto-diag",
  [string]$Work   = "$env:USERPROFILE\kisa_work",
  [switch]$MergeOnly,
  [switch]$NoReport,
  [Parameter(ValueFromRemainingArguments = $true)] $ScanArgs
)
$ErrorActionPreference = "Stop"
function Have($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }
if (-not (Have aws)) { Write-Host "[!] aws CLI 가 없습니다. 먼저 설치하세요."; exit 1 }

$py = if (Have python) { "python" } elseif (Have py) { "py" } else { $null }
New-Item -ItemType Directory -Force -Path "$Work\scan","$Work\allcsv","$Work\out" | Out-Null
Set-Location $Work

# 1) 도구 내려받기
if (-not $NoReport) { aws s3 cp "$S3Base/tools/makereport_all.py" makereport_all.py --quiet }
if (-not $MergeOnly) { aws s3 cp "$S3Base/tools/kisa_all_check.ps1" kisa_all_check.ps1 --quiet }

# 2) 점검 → scan\ 에 CSV
if (-not $MergeOnly) {
  Get-ChildItem "$Work\scan" -Include *.csv,*.html -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Write-Host "[*] 점검 시작…"
  $a = @("-ExecutionPolicy","Bypass","-File","kisa_all_check.ps1","-OutDir","$Work\scan")
  if ($ScanArgs) { $a += $ScanArgs }
  & powershell @a
  if (-not (Get-ChildItem "$Work\scan\*.csv" -ErrorAction SilentlyContinue)) {
    Write-Host "[!] 생성된 CSV 가 없습니다. 점검 로그를 확인하세요."; exit 1
  }
  # 3) 내 CSV 를 S3 에
  aws s3 cp "$Work\scan\" "$S3Base/results/" --recursive --exclude "*" --include "*.csv"
  Write-Host "[*] CSV 업로드 완료 → $S3Base/results/"
}

if ($NoReport) { Write-Host "[*] 완료(보고서 생성 생략)."; exit 0 }
if (-not $py)  { Write-Host "[!] python 이 없어 보고서 생성을 건너뜁니다(CSV 는 S3 에 있음). python 되는 곳에서 -MergeOnly 로 병합하세요."; exit 0 }

# 4) 전 서버 CSV + 현재 버전기록 취합
aws s3 sync "$S3Base/results/" "$Work\allcsv" --exclude "*" --include "*.csv" --quiet
try { aws s3 cp "$S3Base/reports/.보고서_버전.json" "$Work\out\.보고서_버전.json" --quiet } catch {}

# 5) 병합 보고서 생성(python + lxml)
& $py -c "import lxml.etree" 2>$null
if ($LASTEXITCODE -ne 0) { & $py -m pip install --user lxml --quiet 2>$null }
& $py -c "import lxml.etree" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[!] lxml 이 없어 보고서 생성을 건너뜁니다. python 되는 곳에서 -MergeOnly 로 병합하세요."; exit 0 }
& $py makereport_all.py "$Work\allcsv" -o "$Work\out"
if ($LASTEXITCODE -ne 0) { Write-Host "[!] 보고서 생성 실패"; exit 1 }

# 6) 병합 결과 업로드
aws s3 cp "$Work\out\" "$S3Base/reports/" --recursive --exclude "*" --include "*.xlsx"
aws s3 cp "$Work\out\.보고서_버전.json" "$S3Base/reports/.보고서_버전.json" --quiet
Write-Host "[*] 완료 → $S3Base/reports/ 에 병합 결과보고서 갱신됨"
