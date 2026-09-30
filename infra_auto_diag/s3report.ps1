# s3report.ps1 - one shot on a Windows server:
#   scan (infra+web) -> upload CSV to S3 -> pull ALL CSVs from S3
#   -> build report(xlsx) -> merge into the report on S3 (accumulate + version).
#
# ASCII-only on purpose so Windows PowerShell 5.1 parses it under any encoding.
#
# Usage (admin PowerShell):
#   powershell -ExecutionPolicy Bypass -File s3report.ps1
#   powershell -ExecutionPolicy Bypass -File s3report.ps1 -Only web -Target iis
#   powershell -ExecutionPolicy Bypass -File s3report.ps1 -MergeOnly   # merge S3 CSVs only, no scan
#   powershell -ExecutionPolicy Bypass -File s3report.ps1 -NoReport    # scan + upload only
#
# Needs: aws CLI + (for report step) python + lxml. S3 access (IAM role / keys).
param(
  [string]$S3Base = "s3://vuln-lab-backup/infra-auto-diag",
  [string]$Work   = "$env:USERPROFILE\kisa_work",
  [switch]$MergeOnly,
  [switch]$NoReport,
  [Parameter(ValueFromRemainingArguments = $true)] $ScanArgs
)
$ErrorActionPreference = "Stop"
function Have($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }
if (-not (Have aws)) { Write-Host "[!] aws CLI not found. Install it first."; exit 1 }

$py = if (Have python) { "python" } elseif (Have py) { "py" } else { $null }
New-Item -ItemType Directory -Force -Path "$Work\scan","$Work\allcsv","$Work\out" | Out-Null
Set-Location $Work

# 1) fetch tools
if (-not $NoReport)  { aws s3 cp "$S3Base/tools/makereport_all.py" makereport_all.py --quiet }
if (-not $MergeOnly) { aws s3 cp "$S3Base/tools/kisa_all_check.ps1" kisa_all_check.ps1 --quiet }

# 2) scan -> scan\ CSV
if (-not $MergeOnly) {
  Get-ChildItem "$Work\scan" -Include *.csv,*.html -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Write-Host "[*] scanning..."
  $a = @("-ExecutionPolicy","Bypass","-File","kisa_all_check.ps1","-OutDir","$Work\scan")
  if ($ScanArgs) { $a += $ScanArgs }
  & powershell @a
  if (-not (Get-ChildItem "$Work\scan\*.csv" -ErrorAction SilentlyContinue)) {
    Write-Host "[!] no CSV produced. Check the scan log."; exit 1
  }
  # 3) upload my CSV to S3
  aws s3 cp "$Work\scan\" "$S3Base/results/" --recursive --exclude "*" --include "*.csv"
  Write-Host "[*] CSV uploaded -> $S3Base/results/"
}

if ($NoReport) { Write-Host "[*] done (report step skipped)."; exit 0 }
if (-not $py)  { Write-Host "[!] python not found; skipping report (CSV is already on S3). Run -MergeOnly on a host with python."; exit 0 }

# 4) pull all CSVs + current version manifest
aws s3 sync "$S3Base/results/" "$Work\allcsv" --exclude "*" --include "*.csv" --quiet
try { aws s3 cp "$S3Base/reports/.report_version.json" "$Work\out\.report_version.json" --quiet } catch {}

# 5) build merged report (python + lxml)
& $py -c "import lxml.etree" 2>$null
if ($LASTEXITCODE -ne 0) { & $py -m pip install --user lxml --quiet 2>$null }
& $py -c "import lxml.etree" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[!] lxml missing; skipping report. Run -MergeOnly on a host with python."; exit 0 }
& $py makereport_all.py "$Work\allcsv" -o "$Work\out"
if ($LASTEXITCODE -ne 0) { Write-Host "[!] report build failed"; exit 1 }

# 6) upload merged reports (xlsx + manifest)
aws s3 cp "$Work\out\" "$S3Base/reports/" --recursive --exclude "*" --include "*.xlsx"
if (Test-Path "$Work\out\.report_version.json") { aws s3 cp "$Work\out\.report_version.json" "$S3Base/reports/.report_version.json" --quiet }
Write-Host "[*] done -> merged report refreshed at $S3Base/reports/"
