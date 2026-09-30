# merge_local.ps1 - collect scan CSVs from S3 and build the merged Excel reports on THIS PC.
# ASCII-only so it parses under any PowerShell/encoding. Report file names inside are still Korean.
#
# Run on the analyst PC (has python + lxml + this repo). From the infra_auto_diag folder:
#   powershell -ExecutionPolicy Bypass -File merge_local.ps1           # pull from S3 + build reports
#   powershell -ExecutionPolicy Bypass -File merge_local.ps1 -Upload   # also push reports back to S3
#   powershell -ExecutionPolicy Bypass -File merge_local.ps1 -Out myfolder
#
param(
  [string]$S3Base = "s3://vuln-lab-backup/infra-auto-diag",
  [string]$Csv    = "csv_files",     # local folder to sync CSVs into
  [string]$Out    = "reports_out",   # local folder for generated xlsx (ASCII name)
  [switch]$Upload                    # also upload the reports to S3 reports/
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

function Have($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }
if (-not (Have aws)) { Write-Host "[!] aws CLI not found. Install it or run 'aws configure' first."; exit 1 }
$py = if (Have python) { "python" } elseif (Have py) { "py" } else { Write-Host "[!] python not found."; exit 1 }
if (-not (Test-Path "make_reports.py")) { Write-Host "[!] run this from the infra_auto_diag folder (make_reports.py not found)."; exit 1 }

New-Item -ItemType Directory -Force -Path $Csv, $Out | Out-Null

Write-Host "[*] pulling CSVs from $S3Base/results/ ..."
aws s3 sync "$S3Base/results/" $Csv --exclude "*" --include "*.csv"

Write-Host "[*] building reports with make_reports.py ..."
& $py make_reports.py $Csv -o $Out
if ($LASTEXITCODE -ne 0) { Write-Host "[!] report build failed"; exit 1 }

if ($Upload) {
  Write-Host "[*] uploading reports to $S3Base/reports/ ..."
  aws s3 cp "$Out\" "$S3Base/reports/" --recursive --exclude "*" --include "*.xlsx"
  if (Test-Path "$Out\.report_version.json") {
    aws s3 cp "$Out\.report_version.json" "$S3Base/reports/.report_version.json" --quiet
  }
}
Write-Host ""
Write-Host "[*] done. reports are in:  $here\$Out"
Get-ChildItem "$here\$Out\*.xlsx" | ForEach-Object { Write-Host ("    " + $_.Name) }
