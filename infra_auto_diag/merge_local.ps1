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
# make_reports.py(전체 리포) 가 있으면 그걸, 없으면 자체완결형 makereport_all.py 로 폴백
$reportTool = if (Test-Path "make_reports.py") { "make_reports.py" } `
  elseif (Test-Path "makereport_all.py") { "makereport_all.py" } `
  else { Write-Host "[!] make_reports.py / makereport_all.py 둘 다 없음 (infra_auto_diag 폴더나 makereport_all.py 가 있는 폴더에서 실행)."; exit 1 }

New-Item -ItemType Directory -Force -Path $Csv, $Out | Out-Null

Write-Host "[*] pulling CSVs from $S3Base/results/ ..."
aws s3 sync "$S3Base/results/" $Csv --exclude "*" --include "*.csv"

# build IP -> EC2 Name map so reports show the EC2 Name (e.g. web-adm1) instead of the OS hostname/IP
$mapPath = Join-Path $here "hostmap.json"
try {
  $rows = aws ec2 describe-instances --query "Reservations[].Instances[].{Ip:PrivateIpAddress,Name:Tags[?Key=='Name']|[0].Value}" --output json | ConvertFrom-Json
  $map = @{}
  foreach ($r in $rows) { if ($r.Ip -and $r.Name) { $map[[string]$r.Ip] = [string]$r.Name } }
  if ($map.Count -gt 0) { ($map | ConvertTo-Json) | Out-File -Encoding utf8 $mapPath; Write-Host "[*] EC2 Name map: $($map.Count) hosts" }
  else { $mapPath = $null; Write-Host "[!] no EC2 Name tags found (using hostnames)" }
} catch { Write-Host "[!] could not build EC2 Name map (using hostnames): $_"; $mapPath = $null }

Write-Host "[*] building reports with $reportTool ..."
if ($reportTool -eq "make_reports.py") {
  if ($mapPath -and (Test-Path $mapPath)) { & $py make_reports.py $Csv -o $Out --hostmap $mapPath }
  else { & $py make_reports.py $Csv -o $Out }
} else {
  # makereport_all.py 는 템플릿 내장 자체완결형. 출력은 reports_out/ 기본(-o/--hostmap 미지원)
  & $py makereport_all.py $Csv
}
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
