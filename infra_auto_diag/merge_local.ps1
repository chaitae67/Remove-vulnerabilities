# merge_local.ps1 - collect scan CSVs from S3 and build the merged Excel reports on THIS PC.
# ASCII-only so it parses under any PowerShell/encoding. Report file names inside are still Korean.
#
# Run on the analyst PC (has python + lxml + this repo). From the infra_auto_diag folder:
#   powershell -ExecutionPolicy Bypass -File merge_local.ps1                    # pull from S3 + build reports
#   powershell -ExecutionPolicy Bypass -File merge_local.ps1 -Upload            # also push reports back to S3
#   powershell -ExecutionPolicy Bypass -File merge_local.ps1 -AwsProfile demo   # use a specific CLI profile/account
#   powershell -ExecutionPolicy Bypass -File merge_local.ps1 -Region ap-southeast-2
#   powershell -ExecutionPolicy Bypass -File merge_local.ps1 -S3Base s3://my-bucket/infra-auto-diag
#
# Bucket: -S3Base > -Bucket > vuln-lab-backup (or vuln-lab-backup-<account id> if only that one is reachable).
# If the S3 download fails the script stops, so reports are never built from old CSVs left in csv_files.
#
param(
  [string]$S3Base,                   # full s3://bucket/prefix (default: s3://<bucket>/infra-auto-diag)
  [string]$Bucket,                   # just the bucket name (prefix stays .../infra-auto-diag)
  [string]$Region,                   # region for the EC2 Name lookup (default: the CLI profile's region)
  [string]$AwsProfile,               # AWS CLI profile / account to use for every aws call
  [string]$Csv    = "csv_files",     # local folder to sync CSVs into
  [string]$Out    = "reports_out",   # local folder for generated xlsx (ASCII name)
  [switch]$Upload                    # also upload the reports to S3 reports/
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

# every aws call goes through these so -AwsProfile applies everywhere
$awsG = @()
if ($AwsProfile) { $awsG += @("--profile", $AwsProfile) }
function Invoke-Aws { & aws @awsG @args }
function Test-Aws {                  # true if the aws call succeeds (output and errors hidden)
  $ErrorActionPreference = "Continue"
  & aws @awsG @args 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Have($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }
if (-not (Have aws)) { Write-Host "[!] aws CLI not found. Install it or run 'aws configure' first."; exit 1 }
$py = if (Have python) { "python" } elseif (Have py) { "py" } else { Write-Host "[!] python not found."; exit 1 }
# full repo has make_reports.py; a lone folder may only have the self-contained makereport_all.py (same options)
$reportTool = if (Test-Path "make_reports.py") { "make_reports.py" } `
  elseif (Test-Path "makereport_all.py") { "makereport_all.py" } `
  else { Write-Host "[!] neither make_reports.py nor makereport_all.py found (run from infra_auto_diag or the folder with makereport_all.py)."; exit 1 }

# resolve the S3 location
if (-not $S3Base) {
  if (-not $Bucket) {
    $Bucket = "vuln-lab-backup"
    if (-not (Test-Aws s3api head-bucket --bucket $Bucket)) {
      $ErrorActionPreference = "Continue"
      $acct = (& aws @awsG sts get-caller-identity --query Account --output text 2>$null | Out-String).Trim()
      $ErrorActionPreference = "Stop"
      if ($acct -and (Test-Aws s3api head-bucket --bucket "vuln-lab-backup-$acct")) { $Bucket = "vuln-lab-backup-$acct" }
    }
  }
  $S3Base = "s3://$Bucket/infra-auto-diag"
}
$S3Base = $S3Base.TrimEnd("/")
if ($S3Base -notmatch '^s3://[^/]+') { Write-Host "[!] -S3Base must look like s3://bucket/prefix (got '$S3Base')."; exit 1 }

New-Item -ItemType Directory -Force -Path $Csv, $Out | Out-Null

Write-Host "[*] pulling CSVs from $S3Base/results/ ..."
Invoke-Aws s3 sync "$S3Base/results/" $Csv --exclude "*" --include "*.csv" --only-show-errors
if ($LASTEXITCODE -ne 0) {
  Write-Host "[!] S3 download failed (aws exit $LASTEXITCODE). Check -S3Base / -Bucket / -AwsProfile."
  Write-Host "    Stopped so the reports are not built from old CSVs in $Csv."
  exit 1
}
$nCsv = @(Get-ChildItem $Csv -Recurse -File -Filter *.csv).Count
Write-Host "[*] $nCsv CSV files in $Csv"

# build IP -> EC2 Name map so reports show the EC2 Name (e.g. web-adm1) instead of the OS hostname/IP
$mapPath = Join-Path $here "hostmap.json"
$regArgs = @()
if ($Region) { $regArgs = @("--region", $Region) }
try {
  $rows = Invoke-Aws ec2 describe-instances @regArgs --query "Reservations[].Instances[].{Ip:PrivateIpAddress,Name:Tags[?Key=='Name']|[0].Value}" --output json | ConvertFrom-Json
  $map = @{}
  foreach ($r in $rows) { if ($r.Ip -and $r.Name) { $map[[string]$r.Ip] = [string]$r.Name } }
  if ($map.Count -gt 0) { ($map | ConvertTo-Json) | Out-File -Encoding utf8 $mapPath; Write-Host "[*] EC2 Name map: $($map.Count) hosts" }
  else { Write-Host "[!] no EC2 Name tags found (keeping existing hostmap.json if any)" }
} catch { Write-Host "[!] could not build EC2 Name map (keeping existing hostmap.json if any): $_" }

Write-Host "[*] building reports with $reportTool ..."
if (Test-Path $mapPath) { & $py $reportTool $Csv -o $Out --hostmap $mapPath }
else { & $py $reportTool $Csv -o $Out }
if ($LASTEXITCODE -ne 0) { Write-Host "[!] report build failed"; exit 1 }

if ($Upload) {
  Write-Host "[*] uploading reports to $S3Base/reports/ ..."
  Invoke-Aws s3 cp "$Out\" "$S3Base/reports/" --recursive --exclude "*" --include "*.xlsx" --only-show-errors
  if ($LASTEXITCODE -ne 0) { Write-Host "[!] upload failed (aws exit $LASTEXITCODE)"; exit 1 }
  if (Test-Path "$Out\.report_version.json") {
    Invoke-Aws s3 cp "$Out\.report_version.json" "$S3Base/reports/.report_version.json" --quiet
    if ($LASTEXITCODE -ne 0) { Write-Host "[!] upload of .report_version.json failed (aws exit $LASTEXITCODE)"; exit 1 }
  }
  Write-Host "[*] uploaded."
}
Write-Host ""
Write-Host "[*] done. reports are in:  $here\$Out"
Get-ChildItem "$here\$Out\*.xlsx" | ForEach-Object { Write-Host ("    " + $_.Name) }
