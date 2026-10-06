#Requires -RunAsAdministrator
<#
.SYNOPSIS
  was1(Windows Server 2019, 고객 Spring Boot 앱 = 내장 Tomcat, nssm 서비스 clinic-customer) OS 기준 상태 재현.

.DESCRIPTION
  같은 AMI(Windows_Server-2019-English-Full-Base-2026.09.09, ami-0ae94fb345ba94c74)와
  os/was1/user_data.tpl 로 새로 띄운 인스턴스를, 2026-10-02 조치 후 운영 상태에 맞춘다.
    1) 10/2 이전부터 있던 보안 설정(진단 실측값: results/rfix4_infra_was1.json, wf_result_v2.json)
    2) 고객 앱 실행 구성(JDK 21, nssm 2.24, 서비스 clinic-customer, 8080)
    3) 10/2 조치: W-40, W-42, W-47, W-64, WEB-07, WEB-13, WEB-26 (report_1001/조치명령_서버별_20261002.md 6절)
  W-18(CryptSvc)은 was1 에 적용하지 않았다(남은 취약 항목). WEB-25(Tomcat 10.1.60 재빌드)는 사용자가 제외했다.
  여러 번 실행해도 같은 결과가 되도록 작성했다. 운영 인스턴스에는 실행하지 않는다(이미 적용됨).

  비밀값은 환경변수 또는 SSM Parameter Store(SecureString)에서만 읽는다. 화면·로그에 출력하지 않는다.
    DB_PASSWORD      Oracle 앱 계정(oraadmin) 비밀번호 (없으면 -DbPasswordParam 이름의 SSM 파라미터)
    ZD_RDP_PASSWORD  RDP 전용 계정 비밀번호       (없으면 -ZdRdpPasswordParam 이름의 SSM 파라미터)

  확인하지 못한 단계는 '# TODO(확인필요)' 로 표시했다.

.PARAMETER JdkMsi     Microsoft Build of OpenJDK 21.0.12 x64 MSI 로컬 경로(운영 경로 C:\Program Files\Microsoft\jdk-21.0.12.101-hotspot)
.PARAMETER NssmZip    nssm-2.24.zip 로컬 경로(C:\nssm\nssm-2.24\win64\nssm.exe 로 풀림)
.PARAMETER JarSource  고객 앱 jar(clinic-customer-app-0.0.1-SNAPSHOT.jar) 로컬 경로
.PARAMETER Reboot     끝에 재부팅(머신 환경변수 APP_UPLOAD_DIR 을 서비스가 읽으려면 필요)

.EXAMPLE
  $env:DB_PASSWORD = '<비밀값>'; $env:ZD_RDP_PASSWORD = '<비밀값>'   # 또는 SSM 파라미터 사용
  .\baseline.ps1 -JdkMsi C:\setup\microsoft-jdk-21.0.12-windows-x64.msi -NssmZip C:\setup\nssm-2.24.zip -JarSource C:\setup\clinic-customer-app-0.0.1-SNAPSHOT.jar -Reboot
#>
[CmdletBinding()]
param(
  [string]$JdkMsi = $env:JDK_MSI,
  [string]$NssmZip = $env:NSSM_ZIP,
  [string]$JarSource = $env:CUSTOMER_JAR,
  # TODO(확인필요): SSM 파라미터는 아직 만들지 않았다. 이름은 제안값이다(인스턴스 역할에 ssm:GetParameter 권한 필요, 미확인).
  [string]$DbPasswordParam = '/vuln-lab/was1/db_password',
  [string]$ZdRdpPasswordParam = '/vuln-lab/was1/zd_rdp_password',
  [string]$Region = 'ap-northeast-2',
  [switch]$Reboot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 운영 경로(apply/was1 precheck 로그, wf_result_v2.json was1)
$SvcName  = 'clinic-customer'
$JavaExe  = 'C:\Program Files\Microsoft\jdk-21.0.12.101-hotspot\bin\java.exe'
$NssmExe  = 'C:\nssm\nssm-2.24\win64\nssm.exe'
$JarPath  = 'C:\Remove-vulnerabilities\customer-app\target\clinic-customer-app-0.0.1-SNAPSHOT.jar'
$AppDir   = 'C:\clinic\customer-app'
$UploadDir = 'C:\clinic\uploads'
$LogDir   = 'C:\ProgramData\clinic\logs'
$ParamKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcName\Parameters"

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

function Get-HttpCode([string]$Url) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { return [string](& curl.exe -s -o NUL -m 5 -w '%{http_code}' $Url) } finally { $ErrorActionPreference = $old }
}

# 백업 폴더: Administrators·SYSTEM 만(10/2 W-40, apply_scripts/was1/W-40.ps1 와 같음)
New-Dir 'C:\Backup'
Invoke-Native icacls.exe @('C:\Backup', '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F') | Out-Null
New-Dir $BackupRoot

# ---------------------------------------------------------------------------
# 1. 계정 (W-01, W-14) - 10/2 이전부터 있던 상태
#    근거: rfix4_infra_was1.json W-01·W-03·W-14, wf_result_v2.json was1 W-03·W-14
# ---------------------------------------------------------------------------
Write-Step '1. 계정'
$adm = Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' }
if ($adm.Name -ne 'ZD_ADM') { Rename-LocalUser -InputObject $adm -NewName 'ZD_ADM'; Write-Step '  RID500 → ZD_ADM' }

if (-not (Get-LocalUser -Name 'ZD_RDP' -ErrorAction SilentlyContinue)) {
  $pw = Get-SecretValue -EnvName 'ZD_RDP_PASSWORD' -ParamName $ZdRdpPasswordParam
  if (-not $pw) {
    Add-Warn 'ZD_RDP 비밀번호 없음(ZD_RDP_PASSWORD 또는 SSM) → 계정 생성 건너뜀'
  } else {
    $sec = ConvertTo-SecureString -String $pw -AsPlainText -Force
    $pw = $null
    # TODO(확인필요): 운영 ZD_RDP 는 PasswordRequired=False 플래그가 있다(wf W-09). 생성 방식 미상이라 재현하지 않는다.
    New-LocalUser -Name 'ZD_RDP' -Password $sec -Description 'Dedicated RDP (W-14)' | Out-Null
    Write-Step '  ZD_RDP 생성'
  }
}
if (Get-LocalUser -Name 'ZD_RDP' -ErrorAction SilentlyContinue) {
  $isMember = $false
  try { $isMember = [bool](Get-LocalGroupMember -SID 'S-1-5-32-555' | Where-Object { $_.Name -match '\\ZD_RDP$' }) } catch { }
  if (-not $isMember) { Add-LocalGroupMember -SID 'S-1-5-32-555' -Member 'ZD_RDP' }
}

# ---------------------------------------------------------------------------
# 2. 로컬 보안 정책(secedit) - W-04 W-05 W-08 W-09 W-11 W-12 W-14 W-49
#    근거: rfix4_infra_was1.json, wf_result_v2.json was1 (net accounts / secedit 실측)
#    was1 의 암호 기록 개수는 24 (web1 은 12)
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
PasswordHistorySize = 24
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
# exit 3 = 경고와 함께 완료. 결과는 마지막 절에서 net accounts 로 확인
Invoke-Native secedit.exe @('/configure', '/db', $sdb, '/cfg', $inf, '/areas', 'SECURITYPOLICY', 'USER_RIGHTS', '/quiet') -OkCodes @(0, 3) | Out-Null
Remove-Item -LiteralPath $sdb, $inf -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 3. 레지스트리 보안 값 - 10/2 이전부터 있던 상태
#    근거: wf_result_v2.json was1 W-07 W-10 W-13 W-15 W-17 W-20 W-28 W-36 W-48 W-50~W-57 W-59 W-60
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
Set-RegValue $lms 'AutoShareServer' 0                # W-17 (재부팅 후 반영)
Set-RegValue $lms 'RestrictNullSessAccess' 1         # W-23
Set-RegValue $lms 'EnableForcedLogOff' 1             # W-56
Set-RegValue $lms 'autodisconnect' 15                # W-56
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force   # W-23

$tcp = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
Set-RegValue $tcp 'SynAttackProtect' 1               # W-54
Set-RegValue $tcp 'EnableDeadGWDetect' 0
Set-RegValue $tcp 'KeepAliveTime' 300000
Set-RegValue $tcp 'NoNameReleaseOnDemand' 1
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters' 'NoNameReleaseOnDemand' 1

# W-20 모든 인터페이스 NetBIOS over TCP/IP 사용 안 함
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' | ForEach-Object {
  Set-RegValue $_.PSPath 'NetbiosOptions' 2
}

Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Providers\LanMan Print Services\Servers' 'AddPrinterDrivers' 1  # W-55

$nl = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'   # W-60 (OS 기본값과 같음)
foreach ($n in 'RequireSignOrSeal', 'SealSecureChannel', 'SignSecureChannel') { Set-RegValue $nl $n 1 }

# RDP (W-28, W-36). fDenyTSConnections=0 은 user_data 가 넣는다.
$rdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
Set-RegValue $rdp 'MinEncryptionLevel' 3
Set-RegValue $rdp 'SecurityLayer' 2
Set-RegValue $rdp 'UserAuthentication' 1
$tsp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
Set-RegValue $tsp 'MaxIdleTime' 1800000
Set-RegValue $tsp 'MaxDisconnectionTime' 1800000
Set-RegValue $tsp 'fResetBroken' 1

# Windows Update 정책(W-27/W-38 인터뷰 항목, 운영값 그대로): was1 은 NoAutoUpdate=1(자동 업데이트 꺼짐), AUOptions=2
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
Set-RegValue $au 'NoAutoUpdate' 1
Set-RegValue $au 'AUOptions' 2

# 시각 동기화(W-41): Amazon Time Sync. AMI 기본값과 같다.
Invoke-Native w32tm.exe @('/config', '/manualpeerlist:169.254.169.123,0x9', '/syncfromflags:manual', '/update') | Out-Null

# ---------------------------------------------------------------------------
# 4. 서비스 (W-18, W-44) - 운영 실측: Spooler/TrkWks/RemoteRegistry/upnphost/SSDPSRV = Stopped/Disabled
#    근거: wf_result_v2.json was1 W-18·W-44. CryptSvc 는 Automatic 유지(W-18 미적용, 남은 취약)
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
# TODO(확인필요): 운영 was1 은 bowser 드라이버(bowser.sys)가 Disabled/Stopped 이고, 이에 의존하는 LanmanWorkstation 이
#   Automatic 이지만 Stopped 다(wf W-18). 'Browser' 비활성화 조치가 이름 해석 때문에 드라이버에 적용된 부작용으로 보인다.
#   의도된 상태인지 미확인이라 재현하지 않는다. 재현하려면: sc.exe config bowser start= disabled
# TODO(확인필요): CloudWatch Agent(AmazonCloudWatchAgent, Running) 설치·설정 파일 미확보.
#   운영 로그 그룹: /ec2/was1/windows-event (보존 365일, Terraform logging 도메인). 설정 JSON 확보 후:
#   & "$env:ProgramFiles\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" -a fetch-config -m ec2 -c file:<config.json> -s

# ---------------------------------------------------------------------------
# 5. 감사 정책 (W-40) - 10/2 이전 Success and Failure 9개 + 10/2 DS Access 실패 감사 추가
#    근거: rfix4_infra_was1.json W-40, apply/was1 20261002-105714_W-40.log
# ---------------------------------------------------------------------------
Write-Step '5. 감사 정책'
Invoke-Native auditpol.exe @('/backup', "/file:$BackupRoot\auditpol.csv") | Out-Null
# TODO(확인필요): 아래 9개 외 하위 범주의 운영값은 전체 목록을 확보하지 못했다(기본값 유지).
foreach ($sc in 'User Account Management', 'Security Group Management', 'Credential Validation', 'Sensitive Privilege Use',
                'Logon', 'Logoff', 'Account Lockout', 'Audit Policy Change', 'Directory Service Access') {
  Invoke-Native auditpol.exe @('/set', "/subcategory:$sc", '/success:enable', '/failure:enable') | Out-Null
}
Invoke-Native auditpol.exe @('/set', '/category:DS Access', '/failure:enable') | Out-Null

# ---------------------------------------------------------------------------
# 6. 이벤트 로그 (W-42) - 10/2: 가득 차면 보관(AutoBackup), 최대 20MB
#    근거: apply/was1 20261002-105746_W-42.log
# ---------------------------------------------------------------------------
Write-Step '6. 이벤트 로그'
foreach ($l in 'Security', 'Application', 'System') {
  (Invoke-Native wevtutil.exe @('gl', $l)) | Out-File (Join-Path $BackupRoot "$l-config.txt")
  Invoke-Native wevtutil.exe @('sl', $l, '/ms:20971520', '/rt:true', '/ab:true') | Out-Null   # /rt 와 /ab 는 반드시 함께
  Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\$l" 'Retention' 7776000     # 운영 레지스트리 값(wf W-42)
}
# 주의: was1 은 C: 여유가 약 4.6GB(10/2)다. Archive-*.evtx 누적을 지켜본다([R1] 5절).

# ---------------------------------------------------------------------------
# 7. 화면 보호기 (W-47)
#    - HKLM 정책 값, HKU\.DEFAULT 값: 10/2 이전부터 있던 상태(wf W-47)
#    - 사용자 하이브(ZD_ADM, ZD_RDP)의 정책 키: 10/2 조치(apply_scripts/was1/W-47.ps1)
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
  # 재현 보완(운영에서 확인한 값 아님): 새 프로필이 상속하도록 Default 하이브에도 넣는다. TODO(확인필요)
  [void](Set-HiveScreenSaver 'C:\Users\Default\NTUSER.DAT' 'Default')
}

# ---------------------------------------------------------------------------
# 8. 고객 앱 실행 구성
#    근거: apply/was1 precheck·precheck3·precheck4 로그, wf_result_v2.json was1 WEB-01~WEB-26, [D1] WEB-11
# ---------------------------------------------------------------------------
Write-Step '8. 고객 앱'
# 8-1 JDK 21 (Microsoft Build of OpenJDK 21.0.12, 운영 경로 고정)
if (-not (Test-Path -LiteralPath $JavaExe)) {
  if ($JdkMsi -and (Test-Path -LiteralPath $JdkMsi)) {
    # TODO(확인필요): 운영 설치 시 선택한 MSI 기능(JAVA_HOME, PATH 등)은 미확인 → 기본 설치
    Invoke-Native msiexec.exe @('/i', $JdkMsi, '/qn', '/norestart') | Out-Null
  }
  if (-not (Test-Path -LiteralPath $JavaExe)) { Add-Warn "JDK 없음: $JavaExe (-JdkMsi 로 21.0.12 MSI 지정 필요)" }
}

# 8-2 nssm 2.24
if (-not (Test-Path -LiteralPath $NssmExe)) {
  if ($NssmZip -and (Test-Path -LiteralPath $NssmZip)) {
    New-Dir 'C:\nssm'
    Expand-Archive -LiteralPath $NssmZip -DestinationPath 'C:\nssm' -Force
  }
  if (-not (Test-Path -LiteralPath $NssmExe)) { Add-Warn "nssm 없음: $NssmExe (-NssmZip 으로 nssm-2.24.zip 지정 필요)" }
}

# 8-3 jar 배치. 운영은 git 소스 저장소(C:\Remove-vulnerabilities, .git·src·pom.xml 포함)의 빌드 산출물 경로를 그대로 쓴다.
#     TODO(확인필요): 운영 jar(2026-09-28 07:37 빌드, Spring Boot 3.5.16 / tomcat-embed 10.1.55)의 소스 커밋 미확인.
#     여기서는 jar 파일만 같은 경로에 둔다(소스 트리는 재현하지 않음).
New-Dir (Split-Path $JarPath -Parent)
if ($JarSource -and (Test-Path -LiteralPath $JarSource)) {
  $same = $false
  if (Test-Path -LiteralPath $JarPath) { $same = ((Get-FileHash -LiteralPath $JarSource).Hash -eq (Get-FileHash -LiteralPath $JarPath).Hash) }
  if (-not $same) {
    $running = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($running -and $running.Status -ne 'Stopped') { Add-Warn 'jar 교체는 서비스 중지 후 해야 함 - 건너뜀(nssm stop → Stopped 확인 → 교체 → nssm start)' }
    else { Copy-Item -LiteralPath $JarSource -Destination $JarPath -Force; Write-Step '  jar 배치' }
  }
}
if (Test-Path -LiteralPath $JarPath) {
  # 실행 jar ACL: SYSTEM·Administrators·NETWORK SERVICE(RX)만, Users 없음(wf WEB-13·WEB-14)
  # TODO(확인필요): SYSTEM·Administrators 권한 수준 미확인 → F
  Invoke-Native icacls.exe @($JarPath, '/inheritance:r', '/grant:r', '*S-1-5-18:F', '*S-1-5-32-544:F', '*S-1-5-20:RX') | Out-Null
} else { Add-Warn "jar 없음: $JarPath (-JarSource 지정 필요) - 서비스를 시작하지 않음" }

# 8-4 앱 디렉터리·업로드 경로
#   - AppDirectory C:\clinic\customer-app (비어 있음, NETWORK SERVICE Modify 명시)           [D1 WEB-11]
#   - 업로드 C:\clinic\uploads(\qna, \reviews): NETWORK SERVICE Modify, SYSTEM·Administrators F, Users 없음 [wf WEB-24]
#   - 상위 C:\clinic 에도 Users 없음                                                          [wf WEB-24]
# TODO(확인필요): C:\clinic 의 정확한 ACE 목록 미확인 → SYSTEM·Administrators F 만 두고 하위에 NETWORK SERVICE Modify 명시
New-Dir 'C:\clinic'
Invoke-Native icacls.exe @('C:\clinic', '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F') | Out-Null
foreach ($d in $AppDir, $UploadDir, "$UploadDir\qna", "$UploadDir\reviews") { New-Dir $d }
foreach ($d in $AppDir, $UploadDir) { Invoke-Native icacls.exe @($d, '/grant', '*S-1-5-20:(OI)(CI)M') | Out-Null }
# 업로드 경로 머신 환경변수(앱 application.yml 의 ${APP_UPLOAD_DIR:...}) [wf WEB-24]
if ([Environment]::GetEnvironmentVariable('APP_UPLOAD_DIR', 'Machine') -ne $UploadDir) {
  [Environment]::SetEnvironmentVariable('APP_UPLOAD_DIR', $UploadDir, 'Machine')
  # 서비스는 부팅 때 환경을 받는다. 재부팅 전에 시작하면 ${user.home}\zeroday-clinic\uploads 를 쓴다.
  $script:NeedReboot = $true
}

# 8-5 로그 디렉터리 (WEB-26 조치 후 상태: 상속 끊음, SYSTEM F, Administrators F, NETWORK SERVICE M, 파일은 상속)
#     근거: apply/was1 20261002-113241_WEB-26-resume.log
New-Dir $LogDir
Invoke-Native icacls.exe @($LogDir, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-20:(OI)(CI)M') | Out-Null
if (@(Get-ChildItem -LiteralPath $LogDir -Force).Count -gt 0) { Invoke-Native icacls.exe @("$LogDir\*", '/reset', '/t') | Out-Null }

# 8-6 nssm 서비스 clinic-customer
#     Application=java.exe, AppDirectory, AppStdout/AppStderr, 시작 Auto, 실행 계정 NT Authority\NetworkService
#     TODO(확인필요): DisplayName·Description·AppExit 외 nssm 값(회전 등)은 미확인 → nssm 기본값
$svcObj = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $NssmExe) -and (Test-Path -LiteralPath $JavaExe)) {
  if (-not $svcObj) {
    # 인자 없이 설치(비밀번호가 명령행에 남지 않게). AppParameters 는 아래에서 레지스트리로 직접 넣는다.
    Invoke-Native $NssmExe @('install', $SvcName, $JavaExe) | Out-Null
    Write-Step '  서비스 생성'
  }
  Invoke-Native $NssmExe @('set', $SvcName, 'Application', $JavaExe) | Out-Null
  Invoke-Native $NssmExe @('set', $SvcName, 'AppDirectory', $AppDir) | Out-Null
  Invoke-Native $NssmExe @('set', $SvcName, 'AppStdout', "$LogDir\service-out.log") | Out-Null
  Invoke-Native $NssmExe @('set', $SvcName, 'AppStderr', "$LogDir\service-err.log") | Out-Null
  Invoke-Native $NssmExe @('set', $SvcName, 'Start', 'SERVICE_AUTO_START') | Out-Null

  # AppParameters (REG_EXPAND_SZ): 템플릿 + 비밀번호(환경변수/SSM). 값은 출력하지 않는다.
  $tplLines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'files\clinic-customer.AppParameters.tpl') -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') })
  $dbpw = Get-SecretValue -EnvName 'DB_PASSWORD' -ParamName $DbPasswordParam
  if (-not $dbpw) {
    Add-Warn 'DB 비밀번호 없음(DB_PASSWORD 또는 SSM) → AppParameters 미설정, 서비스 시작 안 함'
  } else {
    $val = $tplLines[-1].Replace('${db_password}', $dbpw)
    $dbpw = $null
    New-ItemProperty -LiteralPath $ParamKey -Name 'AppParameters' -Value $val -PropertyType ExpandString -Force | Out-Null
    $val = $null
  }

  # 실행 계정 NetworkService (nssm 대신 WMI 로 설정 - 빈 비밀번호 인자 문제 회피)
  $w = Get-CimInstance Win32_Service -Filter "Name='$SvcName'"
  if ($w.StartName -notmatch 'NetworkService') {
    $r = Invoke-CimMethod -InputObject $w -MethodName Change -Arguments @{ StartName = 'NT AUTHORITY\NetworkService'; StartPassword = '' }
    if ($r.ReturnValue -ne 0) { throw "서비스 계정 변경 실패(ReturnValue=$($r.ReturnValue))" }
  }
} else { Add-Warn 'nssm 또는 JDK 가 없어 서비스 구성을 건너뜀' }

# ---------------------------------------------------------------------------
# 9. WEB-13 (10/2): 서비스 Parameters 키(DB 연결 정보 포함) ACL = SYSTEM F, Administrators F, NETWORK SERVICE 읽기
#    근거: apply_scripts/was1/WEB-13.ps1, apply/was1 20261002-113431_WEB-13-resume.log
# ---------------------------------------------------------------------------
Write-Step '9. WEB-13'
if (Test-Path -LiteralPath $ParamKey) {
  (Get-Acl -LiteralPath $ParamKey).Sddl | Out-File (Join-Path $BackupRoot 'web13-regacl-before.txt') -Encoding ascii
  $acl = New-Object System.Security.AccessControl.RegistrySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($s in 'S-1-5-18', 'S-1-5-32-544') {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule((New-Object System.Security.Principal.SecurityIdentifier $s), 'FullControl', 'ContainerInherit', 'None', 'Allow')))
  }
  $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-20'), 'ReadKey', 'ContainerInherit', 'None', 'Allow')))
  Set-Acl -LiteralPath $ParamKey -AclObject $acl
}

# ---------------------------------------------------------------------------
# 10. WEB-07 (10/2): 실행 jar 경로의 백업·구버전 jar 를 C:\Backup\clinic 으로 이동(새 인스턴스에는 보통 없음)
#     근거: apply_scripts/was1/WEB-07.ps1
# ---------------------------------------------------------------------------
Write-Step '10. WEB-07'
$t = Split-Path $JarPath -Parent
$junk = @(Get-ChildItem -LiteralPath $t -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.jar\.|\.bak\.jar$' -or $_.Name -eq 'clinic-customer-app.jar' })
if ($junk.Count -gt 0) {
  $bk = 'C:\Backup\clinic'
  New-Dir $bk
  Invoke-Native icacls.exe @($bk, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F') | Out-Null
  $junk | Move-Item -Destination $bk -Force
  Invoke-Native icacls.exe @("$bk\*", '/reset') | Out-Null
}

# ---------------------------------------------------------------------------
# 11. W-64 (10/2): 방화벽 3개 프로필 사용 + 부팅마다 방화벽을 끄던 user data 작업 중지
#     허용 규칙(운영 실측, apply/was1 precheck·W-64): ZD-Allow-SVC-8080, Allow-App-8080, Allow-SSH-22,
#     OpenSSH SSH Server (sshd), ZD-Allow-RDP-3389, ZD-Allow-ICMP (모두 Inbound/Allow/Any/원격 Any)
# ---------------------------------------------------------------------------
Write-Step '11. W-64'
$tn = 'Amazon Ec2 Launch - Userdata Execution'
$task = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
if ($task -and $task.State -ne 'Disabled') {
  Export-ScheduledTask -TaskName $tn | Out-File (Join-Path $BackupRoot 'userdata-task.xml') -Encoding unicode
  Disable-ScheduledTask -TaskName $tn | Out-Null
  Write-Step '  user data 부팅 작업 비활성화'
}
# TODO(확인필요): 평문 자격 증명이 든 C:\Windows\Temp\UserScript.ps1 삭제는 10/2 조치에 없었다(권고만, 1001 문서).

Invoke-Native netsh.exe @('advfirewall', 'export', (Join-Path $BackupRoot 'fw-before.wfw')) | Out-Null
Set-FwAllowRule -DisplayName 'ZD-Allow-SVC-8080' -Protocol 'TCP' -LocalPort '8080'
Set-FwAllowRule -DisplayName 'Allow-App-8080' -Protocol 'TCP' -LocalPort '8080'
Set-FwAllowRule -DisplayName 'Allow-SSH-22' -Protocol 'TCP' -LocalPort '22'
Set-FwAllowRule -DisplayName 'ZD-Allow-RDP-3389' -Protocol 'TCP' -LocalPort '3389'
# TODO(확인필요): ZD-Allow-ICMP 의 ICMP 유형 제한 여부 미확인 → ICMPv4 전체 허용
Set-FwAllowRule -DisplayName 'ZD-Allow-ICMP' -Protocol 'ICMPv4' -LocalPort $null
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  Set-FwAllowRule -DisplayName 'OpenSSH SSH Server (sshd)' -Protocol 'TCP' -LocalPort '22'
} else { Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' }
foreach ($n in 'ZD-Allow-SVC-8080', 'Allow-App-8080', 'Allow-SSH-22', 'ZD-Allow-RDP-3389', 'ZD-Allow-ICMP') {
  if (-not (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Allow' })) { throw "허용 규칙 확인 실패: $n - 방화벽을 켜지 않음" }
}
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow

# ---------------------------------------------------------------------------
# 12. 서비스 시작과 확인
#     재시작은 'nssm restart' 대신 stop → Stopped 확인 → start ([R1] 5절: nssm restart 는 중지 단계에서 시간 초과)
#     DB 접속: db-active(10.0.20.184) sqlnet.ora tcp.invited_nodes 에 이 서버 IP 가 있어야 한다(운영 10.0.10.174).
# ---------------------------------------------------------------------------
Write-Step '12. 시작·확인'
$svcObj = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
$hasParams = $false
if (Test-Path -LiteralPath $ParamKey) { $hasParams = ((Get-Item -LiteralPath $ParamKey).GetValueNames() -contains 'AppParameters') }
if ($svcObj -and $hasParams -and (Test-Path -LiteralPath $JarPath)) {
  if ($script:NeedReboot) {
    Write-Host '서비스는 재부팅 뒤 자동 시작된다(APP_UPLOAD_DIR 반영).'
  } elseif ($svcObj.Status -ne 'Running') {
    Start-Service -Name $SvcName
    $t0 = Get-Date; $code = ''
    while (((Get-Date) - $t0).TotalSeconds -lt 150) { Start-Sleep -Seconds 5; $code = Get-HttpCode 'http://localhost:8080/login'; if ($code -in '200', '302') { break } }
    Write-Host "http://localhost:8080/login = $code (200 또는 302 정상)"
  }
}
Get-NetFirewallProfile | Format-Table Name, Enabled, DefaultInboundAction, DefaultOutboundAction -AutoSize | Out-String | Write-Host
Get-Service $SvcName, CryptSvc, sshd, AmazonSSMAgent -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize | Out-String | Write-Host
$ts = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
if ($ts) { Write-Host ('user data task: ' + $ts.State) }
$old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& net.exe accounts 2>&1 | Write-Host
& auditpol.exe /get /category:'DS Access' 2>&1 | Write-Host
& icacls.exe $LogDir 2>&1 | Write-Host
$ErrorActionPreference = $old
if (Test-Path -LiteralPath $ParamKey) {
  (Get-Acl -LiteralPath $ParamKey).Access | Format-Table IdentityReference, RegistryRights, AccessControlType -AutoSize | Out-String | Write-Host
}

if ($script:Warn.Count -gt 0) {
  Write-Host '--- 경고/미완료 ---'
  $script:Warn | ForEach-Object { Write-Host " - $_" }
}
if ($script:NeedReboot) {
  if ($Reboot) { Write-Step '재부팅'; Restart-Computer -Force }
  else { Write-Host '재부팅 필요: APP_UPLOAD_DIR 환경변수 반영. -Reboot 로 다시 실행하거나 점검 시간에 재부팅.' }
}
