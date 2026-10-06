#Requires -RunAsAdministrator
<#
.SYNOPSIS
  web1(Windows Server 2019, IIS 10 + URL Rewrite + ARR 역방향 프록시) OS 기준 상태 재현.

.DESCRIPTION
  같은 AMI(Windows_Server-2019-English-Full-Base-2026.09.09, ami-0ae94fb345ba94c74)와
  os/web1/user_data.tpl 로 새로 띄운 인스턴스를, 2026-10-02 조치 후 운영 상태에 맞춘다.
    1) 10/2 이전부터 있던 보안 설정(진단 실측값: results/rfix4_infra_web1.json, wf_result_v2.json)
    2) IIS 역방향 프록시 구성(사이트 C:\WebRoot → in-alb)
    3) 10/2 조치: W-40, W-42, W-47, W-64, WEB-07, WEB-16 (report_1001/조치명령_서버별_20261002.md 5절)
  W-18(CryptSvc)은 10/2 에 시험 후 원복했으므로 Automatic 으로 둔다(남은 취약 항목).
  여러 번 실행해도 같은 결과가 되도록 작성했다. 운영 인스턴스에는 실행하지 않는다(이미 적용됨).

  비밀값은 환경변수 또는 SSM Parameter Store(SecureString)에서만 읽는다. 화면·로그에 출력하지 않는다.
    ZD_RDP_PASSWORD  (없으면 -ZdRdpPasswordParam 이름의 SSM 파라미터)

  확인하지 못한 단계는 '# TODO(확인필요)' 로 표시했다.

.PARAMETER UrlRewriteMsi   URL Rewrite 2.x x64 MSI 로컬 경로(없으면 설치 건너뜀)
.PARAMETER ArrMsi          Application Request Routing 3.x x64 MSI 로컬 경로(없으면 설치 건너뜀)
.PARAMETER Reboot          끝에 재부팅(WEB-16 HTTP.sys 값 반영에 필요)

.EXAMPLE
  # 관리자 PowerShell 또는 SSM Run Command(AWS-RunPowerShellScript)에서
  $env:ZD_RDP_PASSWORD = '<비밀값>'   # 또는 SSM 파라미터 사용
  .\baseline.ps1 -UrlRewriteMsi C:\setup\rewrite_amd64_en-US.msi -ArrMsi C:\setup\requestRouter_amd64.msi -Reboot
#>
[CmdletBinding()]
param(
  [string]$UrlRewriteMsi = $env:URLREWRITE_MSI,
  [string]$ArrMsi = $env:ARR_MSI,
  # TODO(확인필요): SSM 파라미터는 아직 만들지 않았다. 이름은 제안값이다.
  [string]$ZdRdpPasswordParam = '/vuln-lab/web1/zd_rdp_password',
  [string]$Region = 'ap-northeast-2',
  [switch]$ForceWebConfig,
  [switch]$HardenBackupAcl,
  [switch]$Reboot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 공통 함수
# ---------------------------------------------------------------------------
$script:NeedReboot = $false
$script:Warn = New-Object System.Collections.Generic.List[string]
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupRoot = "C:\Backup\baseline-$Stamp"

function Write-Step([string]$Message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Add-Warn([string]$Message) { $script:Warn.Add($Message); Write-Warning $Message }

# 네이티브 명령 실행(표준오류를 오류 레코드로 바꾸지 않게 EAP 를 잠시 Continue 로)
function Invoke-Native {
  param([string]$File, [string[]]$Arguments, [int[]]$OkCodes = @(0))
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & $File @Arguments 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
  if ($OkCodes -notcontains $code) { throw "$File $($Arguments -join ' ') 실패(exit=$code): $($out -join ' ')" }
  return $out
}

# 비밀값: 환경변수 → SSM(aws CLI) → SSM(AWS Tools for PowerShell). 값은 출력하지 않는다.
function Get-SecretValue {
  param([string]$EnvName, [string]$ParamName)
  $v = [Environment]::GetEnvironmentVariable($EnvName)
  if ($v) { return $v }
  if (-not $ParamName) { return $null }
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $aws = Get-Command aws.exe -ErrorAction SilentlyContinue
    if ($aws) {
      $v = & $aws.Source ssm get-parameter --name $ParamName --with-decryption --query Parameter.Value --output text --region $Region 2>$null
      if ($LASTEXITCODE -eq 0 -and $v) { return ([string]($v -join "`n")).Trim() }
    }
    if (Get-Command Get-SSMParameter -ErrorAction SilentlyContinue) {
      try { return (Get-SSMParameter -Name $ParamName -WithDecryption $true -Region $Region).Value } catch { }
    }
  } finally { $ErrorActionPreference = $old }
  return $null
}

function Set-RegValue {
  param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
  New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Set-FwAllowRule {
  param([string]$DisplayName, [string]$Protocol, [string]$LocalPort)
  $r = @(Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue)
  if ($r.Count -eq 0) {
    $p = @{ DisplayName = $DisplayName; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'; Protocol = $Protocol; Enabled = 'True' }
    if ($LocalPort) { $p.LocalPort = $LocalPort }
    New-NetFirewallRule @p | Out-Null
    Write-Step "  방화벽 규칙 생성: $DisplayName"
  } else {
    $r | Enable-NetFirewallRule
  }
}

function New-Dir([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null } }

New-Dir 'C:\Backup'
# 백업 폴더 ACL: 운영 web1 의 C:\Backup 은 상속 ACL(Users RX) 그대로다(apply/web1 WEB-07 로그) -> 기본은 그대로 둔다.
# -HardenBackupAcl 지정 시에만 Administrators·SYSTEM 만 남긴다(was1 10/2 W-40 방식, 운영과 다름).
if ($HardenBackupAcl) {
  Invoke-Native icacls.exe @('C:\Backup', '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F') | Out-Null
}
New-Dir $BackupRoot

# ---------------------------------------------------------------------------
# 1. 계정 (W-01, W-14) - 10/2 이전부터 있던 상태
#    근거: rfix4_infra_web1.json W-01·W-03·W-14, wf_result_v2.json web1 W-03·W-14
# ---------------------------------------------------------------------------
Write-Step '1. 계정'
# 기본 관리자(RID 500) 이름 ZD_ADM. 프로필 경로는 C:\Users\Administrator 그대로.
# user_data(persist)의 'net user Administrator' 는 이름 변경 뒤 실패한다(운영과 같음).
$adm = Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' }
if ($adm.Name -ne 'ZD_ADM') { Rename-LocalUser -InputObject $adm -NewName 'ZD_ADM'; Write-Step '  RID500 → ZD_ADM' }

# RDP 전용 비관리자 계정 ZD_RDP(설명 'Dedicated RDP (W-14)', Remote Desktop Users 단독 구성원)
if (-not (Get-LocalUser -Name 'ZD_RDP' -ErrorAction SilentlyContinue)) {
  $pw = Get-SecretValue -EnvName 'ZD_RDP_PASSWORD' -ParamName $ZdRdpPasswordParam
  if (-not $pw) {
    Add-Warn 'ZD_RDP 비밀번호 없음(ZD_RDP_PASSWORD 또는 SSM) → 계정 생성 건너뜀'
  } else {
    $sec = ConvertTo-SecureString -String $pw -AsPlainText -Force
    $pw = $null
    # TODO(확인필요): 운영 ZD_RDP 는 PasswordRequired=False 플래그가 있다(wf W-09). 생성 방식 미상이라 재현하지 않는다.
    # TODO(확인필요): PasswordNeverExpires 등 계정 옵션 미상 → 기본값.
    New-LocalUser -Name 'ZD_RDP' -Password $sec -Description 'Dedicated RDP (W-14)' | Out-Null
    Write-Step '  ZD_RDP 생성'
  }
}
if (Get-LocalUser -Name 'ZD_RDP' -ErrorAction SilentlyContinue) {
  $isMember = $false
  try { $isMember = [bool](Get-LocalGroupMember -SID 'S-1-5-32-555' | Where-Object { $_.Name -match '\\ZD_RDP$' }) } catch { }
  if (-not $isMember) { Add-LocalGroupMember -SID 'S-1-5-32-555' -Member 'ZD_RDP' }
}
# 참고: ssm-user 는 SSM Agent 가 세션 때 만들고 Administrators 에 넣는다(W-06 인터뷰 항목). 스크립트로 만들지 않는다.

# ---------------------------------------------------------------------------
# 2. 로컬 보안 정책(secedit) - W-04 W-05 W-08 W-09 W-11 W-12 W-14 W-49
#    근거: rfix4_infra_web1.json, wf_result_v2.json web1 W-04~W-12·W-49 (net accounts / secedit 실측)
#    web1 의 암호 기록 개수는 12 (was1 은 24)
# ---------------------------------------------------------------------------
Write-Step '2. 로컬 보안 정책'
$tmp = Join-Path $env:windir 'Temp\zd-baseline'
New-Dir $tmp
$inf = Join-Path $tmp 'policy.inf'
$sdb = Join-Path $tmp 'policy.sdb'
@'
[Unicode]
Unicode=yes
[System Access]
MinimumPasswordAge = 1
MaximumPasswordAge = 90
MinimumPasswordLength = 8
PasswordComplexity = 1
PasswordHistorySize = 12
LockoutBadCount = 5
ResetLockoutCount = 60
LockoutDuration = 60
ClearTextPassword = 0
LSAAnonymousNameLookup = 0
[Privilege Rights]
SeInteractiveLogonRight = *S-1-5-32-544
SeRemoteInteractiveLogonRight = *S-1-5-32-544,*S-1-5-32-555
SeRemoteShutdownPrivilege = *S-1-5-32-544
[Version]
signature="$CHICAGO$"
Revision=1
'@ | Set-Content -LiteralPath $inf -Encoding Unicode
Invoke-Native secedit.exe @('/export', '/cfg', (Join-Path $BackupRoot 'secedit-before.inf'), '/areas', 'SECURITYPOLICY', 'USER_RIGHTS', '/quiet') | Out-Null
# exit 3 = 경고와 함께 완료(일부 항목 매핑 경고). 결과는 12절에서 net accounts 로 확인
Invoke-Native secedit.exe @('/configure', '/db', $sdb, '/cfg', $inf, '/areas', 'SECURITYPOLICY', 'USER_RIGHTS', '/quiet') -OkCodes @(0, 3) | Out-Null
Remove-Item -LiteralPath $sdb, $inf -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 3. 레지스트리 보안 값 - 10/2 이전부터 있던 상태
#    근거: wf_result_v2.json web1 W-07 W-10 W-13 W-15 W-17 W-20 W-28 W-36 W-48 W-50~W-57 W-59 W-60
# ---------------------------------------------------------------------------
Write-Step '3. 레지스트리 보안 값'
$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
Set-RegValue $lsa 'EveryoneIncludesAnonymous' 0      # W-07
Set-RegValue $lsa 'LimitBlankPasswordUse' 1          # W-13
Set-RegValue $lsa 'RestrictAnonymous' 1              # W-51
Set-RegValue $lsa 'RestrictAnonymousSAM' 1           # W-51
Set-RegValue $lsa 'CrashOnAuditFail' 0               # W-50
Set-RegValue $lsa 'LmCompatibilityLevel' 5           # W-59

$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-RegValue $sys 'DontDisplayLastUserName' 1        # W-10
Set-RegValue $sys 'ShutdownWithoutLogon' 0           # W-48
Set-RegValue $sys 'LegalNoticeCaption' 'Warning' 'String'                                   # W-57
Set-RegValue $sys 'LegalNoticeText' 'Authorized users only. Access is monitored. ' 'String' # W-57 (끝 공백 포함 44자)

Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography' 'ForceKeyProtection' 2         # W-15

$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-RegValue $wl 'AutoAdminLogon' '0' 'String'       # W-52
Set-RegValue $wl 'AllocateDASD' '0' 'String'         # W-53

$lms = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
Set-RegValue $lms 'AutoShareServer' 0                # W-17 (기본 관리 공유 C$/ADMIN$ 없음, 재부팅 후 반영)
Set-RegValue $lms 'RestrictNullSessAccess' 1         # W-23
Set-RegValue $lms 'EnableForcedLogOff' 1             # W-56
Set-RegValue $lms 'autodisconnect' 15                # W-56
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force   # W-23 (SMB1 꺼짐)

$tcp = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
Set-RegValue $tcp 'SynAttackProtect' 1               # W-54
Set-RegValue $tcp 'EnableDeadGWDetect' 0
Set-RegValue $tcp 'KeepAliveTime' 300000
Set-RegValue $tcp 'NoNameReleaseOnDemand' 1
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters' 'NoNameReleaseOnDemand' 1

# W-20 모든 인터페이스 NetBIOS over TCP/IP 사용 안 함(NetbiosOptions=2)
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' | ForEach-Object {
  Set-RegValue $_.PSPath 'NetbiosOptions' 2
}

Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Providers\LanMan Print Services\Servers' 'AddPrinterDrivers' 1  # W-55

$nl = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'   # W-60 (OS 기본값과 같음)
foreach ($n in 'RequireSignOrSeal', 'SealSecureChannel', 'SignSecureChannel', 'RequireStrongKey') { Set-RegValue $nl $n 1 }

# RDP (W-28, W-36). fDenyTSConnections=0 은 user_data 가 넣는다.
$rdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
Set-RegValue $rdp 'MinEncryptionLevel' 3
Set-RegValue $rdp 'SecurityLayer' 2
Set-RegValue $rdp 'UserAuthentication' 1
$tsp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
Set-RegValue $tsp 'MaxIdleTime' 1800000
Set-RegValue $tsp 'MaxDisconnectionTime' 1800000
Set-RegValue $tsp 'fResetBroken' 1

# Windows Update 정책(W-27/W-38 인터뷰 항목, 운영값 그대로): web1 은 AUOptions=3, NoAutoUpdate 미설정
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 3

# 시각 동기화(W-41): Amazon Time Sync. AMI 기본값과 같다.
Invoke-Native w32tm.exe @('/config', '/manualpeerlist:169.254.169.123,0x9', '/syncfromflags:manual', '/update') | Out-Null

# ---------------------------------------------------------------------------
# 4. 서비스 (W-18, W-44) - 운영 실측: Spooler/TrkWks/RemoteRegistry/upnphost/SSDPSRV = Stopped/Disabled
#    근거: wf_result_v2.json web1 W-18·W-44
#    CryptSvc 는 10/2 W-18 시험 후 원복(Running/Automatic) - 끄면 Windows 가 다시 켠다(apply/web1 W-18_retry 로그)
# ---------------------------------------------------------------------------
Write-Step '4. 서비스'
foreach ($s in 'Spooler', 'TrkWks', 'RemoteRegistry', 'upnphost', 'SSDPSRV') {
  $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
  if ($svc) {
    if ($svc.Status -ne 'Stopped') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    Set-Service -Name $s -StartupType Disabled
  }
}
Set-Service -Name CryptSvc -StartupType Automatic
# TODO(확인필요): CloudWatch Agent(AmazonCloudWatchAgent, Running) 설치·설정 파일은 확보하지 못했다.
#   운영 로그 그룹: /ec2/web1/windows-event (보존 365일, Terraform logging 도메인). 설정 JSON 확보 후 아래처럼 적용:
#   & "$env:ProgramFiles\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" -a fetch-config -m ec2 -c file:<config.json> -s

# ---------------------------------------------------------------------------
# 5. 감사 정책 (W-40) - 10/2 이전 Success and Failure 9개 + 10/2 DS Access 실패 감사 추가
#    근거: rfix4_infra_web1.json W-40, apply/web1 20261002-105419_W-40.log
# ---------------------------------------------------------------------------
Write-Step '5. 감사 정책'
Invoke-Native auditpol.exe @('/backup', "/file:$BackupRoot\auditpol.csv") | Out-Null
# TODO(확인필요): 아래 9개 외 하위 범주의 운영값은 전체 목록을 확보하지 못했다(기본값 유지).
foreach ($sc in 'User Account Management', 'Security Group Management', 'Credential Validation', 'Sensitive Privilege Use',
                'Logon', 'Logoff', 'Account Lockout', 'Audit Policy Change', 'Directory Service Access') {
  Invoke-Native auditpol.exe @('/set', "/subcategory:$sc", '/success:enable', '/failure:enable') | Out-Null
}
# 10/2 W-40: DS 액세스 범주 실패 감사(나머지 3개 하위 범주는 Failure)
Invoke-Native auditpol.exe @('/set', '/category:DS Access', '/failure:enable') | Out-Null

# ---------------------------------------------------------------------------
# 6. 이벤트 로그 (W-42) - 10/2: 가득 차면 보관(AutoBackup), 최대 20MB
#    근거: apply/web1 20261002-105452_W-42.log
# ---------------------------------------------------------------------------
Write-Step '6. 이벤트 로그'
foreach ($l in 'Security', 'Application', 'System') {
  (Invoke-Native wevtutil.exe @('gl', $l)) | Out-File (Join-Path $BackupRoot "$l-config.txt")
  Invoke-Native wevtutil.exe @('sl', $l, '/ms:20971520', '/rt:true', '/ab:true') | Out-Null   # /rt 와 /ab 는 반드시 함께
  # 운영 레지스트리에 Retention=7776000(90일)이 들어 있다(적용 효과 없음, wf W-42). 그대로 맞춘다.
  Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\$l" 'Retention' 7776000
}
# 주의: Archive-*.evtx 가 계속 쌓인다(Security 하루 약 20MB). C: 여유 공간 점검 필요.

# ---------------------------------------------------------------------------
# 7. 화면 보호기 (W-47)
#    - HKLM 정책 값, HKU\.DEFAULT 값: 10/2 이전부터 있던 상태(rfix4 W-47 참고, wf W-47)
#    - 사용자 하이브(ZD_ADM, ZD_RDP)의 정책 키: 10/2 조치(apply_scripts/web1/W-47.ps1)
# ---------------------------------------------------------------------------
Write-Step '7. 화면 보호기'
$ss = [ordered]@{ ScreenSaveActive = '1'; ScreenSaverIsSecure = '1'; ScreenSaveTimeOut = '600'; 'SCRNSAVE.EXE' = 'C:\Windows\system32\scrnsave.scr' }
foreach ($k in $ss.Keys) {
  Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop' $k $ss[$k] 'String'
  Set-RegValue 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Desktop' $k $ss[$k] 'String'
}
function Set-HiveScreenSaver([string]$DatPath, [string]$Label) {
  if (-not (Test-Path -LiteralPath $DatPath)) { return $false }
  if (Test-Path 'Registry::HKEY_USERS\ZD47') { throw 'HKU\ZD47 가 이미 로드돼 있음 - reg unload HKU\ZD47 후 다시 실행' }
  New-Dir (Join-Path $BackupRoot 'W-47')
  Copy-Item -LiteralPath $DatPath (Join-Path $BackupRoot "W-47\$Label-NTUSER.DAT") -Force
  Invoke-Native reg.exe @('load', 'HKU\ZD47', $DatPath) | Out-Null
  try {
    $key = 'HKU\ZD47\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
    foreach ($k in $ss.Keys) { Invoke-Native reg.exe @('add', $key, '/v', $k, '/t', 'REG_SZ', '/d', $ss[$k], '/f') | Out-Null }
  } finally {
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    $ok = $false
    for ($i = 1; $i -le 6; $i++) {
      $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      & reg.exe unload 'HKU\ZD47' 2>&1 | Out-Null; $code = $LASTEXITCODE
      $ErrorActionPreference = $old
      if ($code -eq 0) { $ok = $true; break }
      Start-Sleep -Seconds 3; [gc]::Collect()
    }
    if (-not $ok) { throw 'reg unload HKU\ZD47 실패 - 수동으로 unload 후 진행' }
  }
  return $true
}
# 로그온 세션이 있으면 하이브를 건드리지 않는다(10/2 와 같은 조건)
$old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& quser.exe 2>&1 | Out-Null; $quserCode = $LASTEXITCODE
$ErrorActionPreference = $old
if ($quserCode -eq 0) {
  Add-Warn 'W-47: 로그온 세션이 있어 사용자 하이브 설정을 건너뜀 - 모두 로그오프 후 다시 실행'
} else {
  $profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special })
  foreach ($name in 'ZD_ADM', 'ZD_RDP') {
    $u = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if (-not $u) { continue }
    $p = $profiles | Where-Object { $_.SID -eq $u.SID.Value } | Select-Object -First 1
    if (-not $p) { Add-Warn "W-47: $name 프로필이 아직 없음(첫 로그온 전). Default 프로필 값으로 대신함 - 첫 로그온 후 다시 실행"; continue }
    if ($p.Loaded) { Add-Warn "W-47: $name 하이브가 로드돼 있어 건너뜀"; continue }
    [void](Set-HiveScreenSaver (Join-Path $p.LocalPath 'NTUSER.DAT') $name)
    Write-Step "  $name 하이브 정책 키 기록"
  }
  # 재현 보완(운영에서 확인한 값 아님): 새 인스턴스에서는 ZD_RDP 프로필이 첫 로그온 때 Default 프로필로 만들어지므로
  # Default 하이브에도 같은 정책 키를 넣어 둔다. TODO(확인필요): 운영 C:\Users\Default\NTUSER.DAT 의 값은 미확인.
  [void](Set-HiveScreenSaver 'C:\Users\Default\NTUSER.DAT' 'Default')
}

# ---------------------------------------------------------------------------
# 8. IIS 역방향 프록시 (W-19 업무상 필요, WEB-04~WEB-26 실측 상태)
#    근거: wf_result_v2.json web1 W-19 WEB-04~WEB-26, rfix4_web_web1.json, apply/web1 00_precheck 로그
# ---------------------------------------------------------------------------
Write-Step '8. IIS'
# TODO(확인필요): 운영에 설치된 IIS 하위 기능 전체 목록은 확보하지 못했다.
#   확인된 것: Web-Server, Web-WebServer, Web-Filtering, Web-Mgmt-Console 설치 /
#   Web-Http-Redirect, Web-ASP, Web-Asp-Net45, Web-CGI, Web-ISAPI-*, Web-Includes, Web-DAV-Publishing, Web-Ftp-*, Web-Mgmt-Service 미설치
$feat = Get-WindowsFeature -Name Web-Server
if (-not $feat.Installed) { Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null }
foreach ($f in 'Web-Filtering', 'Web-Mgmt-Console') { if (-not (Get-WindowsFeature -Name $f).Installed) { Install-WindowsFeature -Name $f | Out-Null } }
Import-Module WebAdministration

# URL Rewrite + ARR (rewrite.dll, requestRouter.dll 설치 확인됨. 버전은 미확인 → TODO(확인필요))
$mods = @(Get-WebGlobalModule | ForEach-Object { $_.Name })
if ($mods -notcontains 'RewriteModule') {
  if ($UrlRewriteMsi -and (Test-Path -LiteralPath $UrlRewriteMsi)) {
    Invoke-Native msiexec.exe @('/i', $UrlRewriteMsi, '/qn', '/norestart') | Out-Null
  } else { Add-Warn 'URL Rewrite MSI 경로 없음(-UrlRewriteMsi) → 설치 건너뜀. 역방향 프록시가 동작하지 않는다' }
}
$mods = @(Get-WebGlobalModule | ForEach-Object { $_.Name })
if ($mods -notcontains 'ApplicationRequestRouting') {
  if ($ArrMsi -and (Test-Path -LiteralPath $ArrMsi)) {
    Invoke-Native msiexec.exe @('/i', $ArrMsi, '/qn', '/norestart') | Out-Null
  } else { Add-Warn 'ARR MSI 경로 없음(-ArrMsi) → 설치 건너뜀' }
}
$mods = @(Get-WebGlobalModule | ForEach-Object { $_.Name })
$apphost = 'MACHINE/WEBROOT/APPHOST'
if ($mods -contains 'ApplicationRequestRouting') {
  # ARR 서버 프록시: enabled=True, preserveHostHeader=True, arrResponseHeader=False (wf WEB-10·WEB-16)
  Set-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/proxy' -Name 'enabled' -Value 'True'
  Set-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/proxy' -Name 'preserveHostHeader' -Value 'True'
  Set-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/proxy' -Name 'arrResponseHeader' -Value 'False'
  # TODO(확인필요): 그 밖의 ARR 값(timeout, reverseRewriteHostInResponseHeaders 등)은 미확인 → 기본값
}
# 서버 수준 Server 헤더 제거(WEB-16, apphost removeServerHeader=True)
Set-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/security/requestFiltering' -Name 'removeServerHeader' -Value 'True'

# 사이트 경로 C:\WebRoot (ACL: SYSTEM·Administrators F, IIS_IUSRS RX, CREATOR OWNER / Users 없음 - wf WEB-14)
New-Dir 'C:\WebRoot'
# TODO(확인필요): CREATOR OWNER 권한 수준 미확인 → 일반값 (OI)(CI)(IO)F
Invoke-Native icacls.exe @('C:\WebRoot', '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-568:(OI)(CI)RX', '*S-1-3-0:(OI)(CI)(IO)F') | Out-Null
$frag = Join-Path $PSScriptRoot 'files\WebRoot\web.config.fragment.xml'
if ($ForceWebConfig -or -not (Test-Path -LiteralPath 'C:\WebRoot\web.config')) {
  # TODO(확인필요): 운영 원본(2,118B)이 아니라 증거로 재구성한 조각이다. 원본 확보 시 교체.
  Copy-Item -LiteralPath $frag -Destination 'C:\WebRoot\web.config' -Force
  Write-Step '  web.config(재구성본) 배치'
}
if (-not (Test-Path -LiteralPath 'C:\WebRoot\error.html')) {
  # TODO(확인필요): 운영 error.html(212B, 일반 문구)의 원문은 확보하지 못했다. 자리표시자를 둔다.
  Set-Content -LiteralPath 'C:\WebRoot\error.html' -Encoding UTF8 -Value '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Error</title></head><body><p>Error</p></body></html>'
  Add-Warn 'C:\WebRoot\error.html 은 자리표시자다(원본 미확보)'
}
Invoke-Native icacls.exe @('C:\WebRoot\*', '/reset') | Out-Null

Set-ItemProperty 'IIS:\Sites\Default Web Site' -Name physicalPath -Value 'C:\WebRoot'
# applicationHost.config <location path="Default Web Site"> httpErrors existingResponse=PassThrough (wf WEB-22)
Set-WebConfigurationProperty -PSPath $apphost -Location 'Default Web Site' -Filter 'system.webServer/httpErrors' -Name 'existingResponse' -Value 'PassThrough'
# IIS 기본 파일 제거(wwwroot 0개, wf WEB-07)
Get-ChildItem -LiteralPath 'C:\inetpub\wwwroot' -Filter 'iisstart.*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force

# HTTPS 바인딩 *:443 (인증서 CN=web1.zerodayclinic.local, 만료 2027-09-28 - wf WEB-20)
# 원본 개인 키는 재현 불가 → 같은 CN 의 자체 서명 인증서를 새로 만든다(지문은 달라진다).
# TODO(확인필요): 원본이 자체 서명인지, 발급 방법은 미확인. ALB→web1 은 HTTP 80 만 쓴다(tg-web).
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq 'CN=web1.zerodayclinic.local' -and $_.NotAfter -gt (Get-Date) } | Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
  $cert = New-SelfSignedCertificate -DnsName 'web1.zerodayclinic.local' -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter ([datetime]'2027-09-28')
  Write-Step "  자체 서명 인증서 생성(지문 $($cert.Thumbprint))"
}
if (-not (Get-WebBinding -Name 'Default Web Site' -Protocol https -Port 443)) {
  New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -IPAddress '*'
}
if (-not (Test-Path 'IIS:\SslBindings\0.0.0.0!443')) {
  (Get-WebBinding -Name 'Default Web Site' -Protocol https -Port 443).AddSslCertificate($cert.Thumbprint, 'My')
}

# IIS 로그 경로 ACL: Users/Everyone/Authenticated Users 없음(WEB-26, wf WEB-26)
foreach ($d in 'C:\inetpub\logs', 'C:\inetpub\logs\LogFiles', 'C:\inetpub\logs\LogFiles\W3SVC1') {
  if (-not (Test-Path -LiteralPath $d)) { continue }
  $acl = Get-Acl -LiteralPath $d
  $bad = @($acl.Access | Where-Object { $_.IdentityReference.Value -match '^(BUILTIN\\Users|Everyone|NT AUTHORITY\\Authenticated Users)$' })
  if ($bad.Count -gt 0) {
    if (-not $acl.AreAccessRulesProtected) { Invoke-Native icacls.exe @($d, '/inheritance:d') | Out-Null }
    foreach ($sid in '*S-1-5-32-545', '*S-1-1-0', '*S-1-5-11') { Invoke-Native icacls.exe @($d, '/remove:g', $sid) | Out-Null }
  }
}

# ---------------------------------------------------------------------------
# 9. WEB-07 (10/2): 웹 루트의 web.config 백업 파일을 C:\Backup\iis-webconfig 로 이동
# ---------------------------------------------------------------------------
Write-Step '9. WEB-07'
$junk = @(Get-ChildItem -LiteralPath 'C:\WebRoot' -Force -Filter 'web.config.before-*' -ErrorAction SilentlyContinue)
if ($junk.Count -gt 0) {
  $bk = 'C:\Backup\iis-webconfig'
  New-Dir $bk
  Invoke-Native icacls.exe @($bk, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F') | Out-Null
  $junk | Move-Item -Destination $bk -Force
  Invoke-Native icacls.exe @("$bk\*", '/reset') | Out-Null
}

# ---------------------------------------------------------------------------
# 10. WEB-16 (10/2): HTTP.sys Server 헤더 제거 DisableServerHeader=2 → 재부팅 후 반영
# ---------------------------------------------------------------------------
Write-Step '10. WEB-16'
$http = 'HKLM:\SYSTEM\CurrentControlSet\Services\HTTP\Parameters'
$cur = (Get-ItemProperty -LiteralPath $http -ErrorAction SilentlyContinue)
$curVal = $null
if ($cur -and ($cur.PSObject.Properties.Name -contains 'DisableServerHeader')) { $curVal = $cur.DisableServerHeader }
if ($curVal -ne 2) {
  Invoke-Native reg.exe @('export', 'HKLM\SYSTEM\CurrentControlSet\Services\HTTP\Parameters', (Join-Path $BackupRoot 'http-parameters-before.reg'), '/y') | Out-Null
  Set-RegValue $http 'DisableServerHeader' 2
  $script:NeedReboot = $true
}

# ---------------------------------------------------------------------------
# 11. W-64 (10/2): 방화벽 3개 프로필 사용 + 부팅마다 방화벽을 끄던 user data 작업 중지
#     허용 규칙(운영 실측, apply/web1 00_precheck): IIS HTTP/HTTPS 기본 규칙, ZD-Allow-SVC-80,
#     OpenSSH SSH Server (sshd), ZD-Allow-RDP-3389, ZD-Allow-ICMP (모두 Inbound/Allow/Any/원격 Any)
# ---------------------------------------------------------------------------
Write-Step '11. W-64'
$tn = 'Amazon Ec2 Launch - Userdata Execution'
$task = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
if ($task -and $task.State -ne 'Disabled') {
  Export-ScheduledTask -TaskName $tn | Out-File (Join-Path $BackupRoot 'userdata-task.xml')
  Disable-ScheduledTask -TaskName $tn | Out-Null
  Write-Step '  user data 부팅 작업 비활성화'
}
# TODO(확인필요): 평문 자격 증명이 든 C:\Windows\Temp\UserScript.ps1 삭제는 10/2 조치에 없었다(권고만, 1001 문서). 운영에 남아 있을 수 있음.

Invoke-Native netsh.exe @('advfirewall', 'export', (Join-Path $BackupRoot 'fw-before.wfw')) | Out-Null
Get-NetFirewallRule -Name 'IIS-WebServerRole-HTTP-In-TCP', 'IIS-WebServerRole-HTTPS-In-TCP' -ErrorAction SilentlyContinue | Enable-NetFirewallRule
Set-FwAllowRule -DisplayName 'ZD-Allow-SVC-80' -Protocol 'TCP' -LocalPort '80'
Set-FwAllowRule -DisplayName 'ZD-Allow-RDP-3389' -Protocol 'TCP' -LocalPort '3389'
# TODO(확인필요): ZD-Allow-ICMP 의 ICMP 유형 제한 여부 미확인 → ICMPv4 전체 허용
Set-FwAllowRule -DisplayName 'ZD-Allow-ICMP' -Protocol 'ICMPv4' -LocalPort $null
# OpenSSH 규칙은 user_data 의 OpenSSH 설치 때 생긴다. 없으면 같은 이름으로 만든다.
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  Set-FwAllowRule -DisplayName 'OpenSSH SSH Server (sshd)' -Protocol 'TCP' -LocalPort '22'
} else { Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' }
foreach ($n in 'ZD-Allow-SVC-80', 'ZD-Allow-RDP-3389', 'ZD-Allow-ICMP') {
  if (-not (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Allow' })) { throw "허용 규칙 확인 실패: $n - 방화벽을 켜지 않음" }
}
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow

# ---------------------------------------------------------------------------
# 12. 확인 출력(읽기 전용)
# ---------------------------------------------------------------------------
Write-Step '12. 확인'
Get-NetFirewallProfile | Format-Table Name, Enabled, DefaultInboundAction, DefaultOutboundAction -AutoSize | Out-String | Write-Host
Get-Service W3SVC, CryptSvc, sshd, AmazonSSMAgent -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize | Out-String | Write-Host
$ts = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
if ($ts) { Write-Host ('user data task: ' + $ts.State) }
$old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& net.exe accounts 2>&1 | Write-Host
& auditpol.exe /get /category:'DS Access' 2>&1 | Write-Host
Write-Host ('health(http://localhost/health, 백엔드 정상이면 302): ' + (& curl.exe -s -o NUL -m 10 -w '%{http_code}' 'http://localhost/health'))
$ErrorActionPreference = $old

if ($script:Warn.Count -gt 0) {
  Write-Host '--- 경고/미완료 ---'
  $script:Warn | ForEach-Object { Write-Host " - $_" }
}
if ($script:NeedReboot) {
  if ($Reboot) { Write-Step '재부팅(WEB-16 반영)'; Restart-Computer -Force }
  else { Write-Host '재부팅 필요: WEB-16(DisableServerHeader) 반영. -Reboot 로 다시 실행하거나 점검 시간에 재부팅.' }
}
