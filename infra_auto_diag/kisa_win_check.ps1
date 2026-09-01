<#
==============================================================================
 KISA 주요정보통신기반시설 기술적 취약점 점검 (Windows Server)  W-01 ~ W-64
  - 보고서 양식(보고서_양식_Windows.xlsx / 3-1 시트) 의 항목·진단기준을 그대로 사용
  - 각 항목 앞 # [기준] 주석 = 양식 '진단기준' 열 내용
  - 읽기 전용(READ-ONLY): 레지스트리/정책/ACL 조회만, 변경 없음
  - 대상: Windows Server 2012 R2 / 2016 / 2019 / 2022 (Windows 10/11 도 대부분 동작)
  - 권장 실행:  powershell -ExecutionPolicy Bypass -File kisa_win_check.ps1 -Json out.json
               (관리자 권한 필요 — secedit / SAM ACL / 감사정책)

 판정 표기
   양호 / 취약 / N/A(점검 대상 없음) / 수동확인(정책·인터뷰 필요)

 GUI(kisa_gui.py) 연동: kisa_unix_check.sh 와 동일 스키마
   {"host","os","family":"windows","results":[{"code","importance","title","status","evidence":[...]}]}
==============================================================================
#>
[CmdletBinding()]
param(
    [string]$Json = "",
    [switch]$NoColor
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
try { chcp 65001 > $null 2>&1 } catch {}

$script:good = 0; $script:vuln = 0; $script:na = 0; $script:man = 0
$script:results = New-Object System.Collections.ArrayList

$IMP = @{
    "W-01"="상";"W-02"="상";"W-03"="상";"W-04"="상";"W-05"="상";"W-06"="상"
    "W-07"="중";"W-08"="중";"W-09"="상";"W-10"="중";"W-11"="중";"W-12"="중";"W-13"="중";"W-14"="중"
    "W-15"="상";"W-16"="상";"W-17"="상";"W-18"="상";"W-19"="상";"W-20"="상";"W-21"="상";"W-22"="상"
    "W-23"="상";"W-24"="상";"W-25"="상";"W-26"="상";"W-27"="상";"W-28"="중";"W-29"="중";"W-30"="중"
    "W-31"="중";"W-32"="중";"W-33"="하";"W-34"="중";"W-35"="중";"W-36"="중";"W-37"="중"
    "W-38"="상";"W-39"="상";"W-40"="중";"W-41"="중";"W-42"="하";"W-43"="중"
    "W-44"="상";"W-45"="상";"W-46"="상";"W-47"="상";"W-48"="상";"W-49"="상";"W-50"="상";"W-51"="상"
    "W-52"="상";"W-53"="상";"W-54"="중";"W-55"="중";"W-56"="중";"W-57"="하";"W-58"="중";"W-59"="중"
    "W-60"="중";"W-61"="중";"W-62"="중";"W-63"="중";"W-64"="중"
}

function Rep {
    param([string]$Code, [string]$Title, [string]$Status, [string[]]$Evidence)
    switch ($Status) {
        "GOOD" { $script:good++; $k = "양호";   $col = "Green" }
        "VULN" { $script:vuln++; $k = "취약";   $col = "Red" }
        "NA"   { $script:na++;   $k = "N/A";    $col = "Yellow" }
        "MAN"  { $script:man++;  $k = "수동확인"; $col = "Cyan" }
    }
    if ($NoColor) { Write-Host ("{0,-6} {1,-44} [{2}]" -f $Code, $Title, $k) }
    else {
        Write-Host ("{0,-6} " -f $Code) -NoNewline -ForegroundColor Cyan
        Write-Host ("{0,-44} " -f $Title) -NoNewline
        Write-Host ("[{0}]" -f $k) -ForegroundColor $col
    }
    foreach ($e in $Evidence) { Write-Host ("         - {0}" -f $e) }
    [void]$script:results.Add([pscustomobject]@{
        code = $Code; importance = $IMP[$Code]; title = $Title; status = $k; evidence = @($Evidence)
    })
}

# ---------------- 공통 헬퍼 ----------------
function RegVal { param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null } }
function SvcObj { param([string]$Name) Get-Service -Name $Name -ErrorAction SilentlyContinue }
function SvcRunning { param([string]$Name) (SvcObj $Name).Status -eq "Running" }
function FeatureInstalled { param([string]$Name)
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $f = Get-WindowsFeature -Name $Name -ErrorAction SilentlyContinue; return ($f -and $f.Installed)
    }
    return $false }
function PortListening { param([int]$Port) [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) }
function AclHasEveryone { param([string]$P)
    if (-not (Test-Path $P)) { return $null }
    try {
        $acl = Get-Acl $P -ErrorAction Stop
        foreach ($a in $acl.Access) {
            if ($a.IdentityReference.Value -in @("Everyone","모든 사람","NT AUTHORITY\Anonymous Logon") -and
                $a.AccessControlType -eq "Allow") { return $true }
        }
        return $false
    } catch { return $null }
}

$IS_ADMIN = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------- 로컬 보안 정책 (secedit) ----------------
$SEC = @{}; $PRIV = @{}
if ($IS_ADMIN) {
    $inf = Join-Path $env:TEMP ("kisa_secpol_{0}.inf" -f $PID)
    secedit /export /cfg $inf /quiet 2>$null | Out-Null
    if (Test-Path $inf) {
        $section = ""
        foreach ($line in (Get-Content $inf -Encoding Unicode -ErrorAction SilentlyContinue)) {
            $t = $line.Trim()
            if ($t -match '^\[(.+)\]$') { $section = $matches[1]; continue }
            if ($t -match '^\s*([^=]+?)\s*=\s*(.*)$') {
                if ($section -eq "Privilege Rights") { $PRIV[$matches[1].Trim()] = $matches[2].Trim() }
                else { $SEC[$matches[1].Trim()] = $matches[2].Trim() }
            }
        }
        Remove-Item $inf -Force -ErrorAction SilentlyContinue
    }
}
function SecInt { param([string]$Key) if ($SEC.ContainsKey($Key)) { try { [int]$SEC[$Key] } catch { $null } } else { $null } }
function PrivOnlyAdmin { param([string]$Key)
    $v = $PRIV[$Key]
    if ($null -eq $v) { return $null }
    $ids = ($v -replace '\*','').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $allowed = @("S-1-5-32-544","Administrators","BUILTIN\Administrators")
    foreach ($i in $ids) { if ($allowed -notcontains $i) { return $false } }
    return $true
}

# ---------------- net accounts (백업) ----------------
$NA = @{}
foreach ($line in (net accounts 2>$null)) { if ($line -match '^(.+?):\s+(.+?)\s*$') { $NA[$matches[1].Trim()] = $matches[2].Trim() } }
function NAInt { param([string]$Key)
    if ($NA.ContainsKey($Key)) {
        if ($NA[$Key] -match 'Never|없음') { return 0 }
        $m = [regex]::Match($NA[$Key], '\d+'); if ($m.Success) { return [int]$m.Value }
    }
    return $null }

# ---------------- 로컬 계정/그룹 ----------------
function LocalUsers {
    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) { return Get-LocalUser -ErrorAction SilentlyContinue }
    return Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction SilentlyContinue
}
function GroupMembers { param([string]$Sid)
    try {
        if (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue) {
            return @(Get-LocalGroupMember -SID $Sid -ErrorAction Stop | ForEach-Object { $_.Name })
        }
    } catch {}
    return @()
}
function UserEnabled { param($u)
    if ($u.PSObject.Properties.Name -contains "Enabled") { return $u.Enabled }
    return (-not $u.Disabled)
}

$IIS_ON = [bool]((SvcObj "W3SVC") -and (FeatureInstalled "Web-Server"))
function IISProp { param([string]$Filter, [string]$Name)
    try { Import-Module WebAdministration -ErrorAction Stop
          return (Get-WebConfigurationProperty -Filter $Filter -Name $Name -ErrorAction Stop).Value } catch { return $null } }

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$OS_NAME = if ($os) { $os.Caption.Trim() } else { "Windows" }
$OS_BUILD = if ($os) { [int]$os.BuildNumber } else { 0 }
$HOSTN = $env:COMPUTERNAME

Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host " KISA Windows 취약점 점검 (W-01~W-64)  READ-ONLY" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host (" 호스트 : {0}" -f $HOSTN)
Write-Host (" OS     : {0}  (Build {1})" -f $OS_NAME, $OS_BUILD)
Write-Host (" 시각   : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
if (-not $IS_ADMIN) { Write-Host " 주의: 관리자 권한이 아니어서 보안정책/SAM/감사정책 등 일부 항목이 '수동확인'으로 표기됩니다." -ForegroundColor Yellow }
Write-Host ""

#==============================================================================
Write-Host "[ 1. 계정 관리 ]" -ForegroundColor White
#==============================================================================

# W-01 Administrator 계정 이름 변경 등 보안성 강화
# [기준] 양호 - 기본 계정 이름을 변경하거나 강화된 비밀번호를 적용 / 취약 - 미변경 + 단순 비밀번호
$adminAcct = LocalUsers | Where-Object { ($_.SID.Value) -like "*-500" } | Select-Object -First 1
$adminName = if ($adminAcct) { $adminAcct.Name } else { ($SEC["NewAdministratorName"] -replace '"','') }
if ($adminName -and $adminName -ne "Administrator") {
    Rep "W-01" "Administrator 계정 이름 변경 등 보안성 강화" "GOOD" @("기본 관리자 계정 이름 = '$adminName' (변경됨)")
} elseif ($adminName -eq "Administrator") {
    Rep "W-01" "Administrator 계정 이름 변경 등 보안성 강화" "MAN" @("기본 관리자 계정 이름이 'Administrator' 그대로 → 이름 변경 또는 복잡도 높은 비밀번호 적용 여부(인터뷰) 확인")
} else {
    Rep "W-01" "Administrator 계정 이름 변경 등 보안성 강화" "MAN" @("관리자 계정 이름 확인 불가 → 관리자 권한으로 재점검")
}

# W-02 Guest 계정 비활성화
# [기준] 양호 - Guest 계정 비활성화 / 취약 - 활성화
$guest = LocalUsers | Where-Object { ($_.SID.Value) -like "*-501" } | Select-Object -First 1
if (-not $guest) { Rep "W-02" "Guest 계정 비활성화" "GOOD" @("Guest 계정 없음") }
elseif (UserEnabled $guest) { Rep "W-02" "Guest 계정 비활성화" "VULN" @("Guest 계정($($guest.Name)) 활성화됨 → 비활성화 필요") }
else { Rep "W-02" "Guest 계정 비활성화" "GOOD" @("Guest 계정($($guest.Name)) 비활성화됨") }

# W-03 불필요한 계정 제거
# [기준] 양호 - 불필요한 계정 없음 / 취약 - 존재
$users = @(LocalUsers)
$susp = @()
foreach ($u in $users) {
    if (($u.SID.Value) -like "*-500" -or ($u.SID.Value) -like "*-501") { continue }
    if ($u.Name -in @("DefaultAccount","WDAGUtilityAccount")) { continue }
    if ((UserEnabled $u) -and -not $u.LastLogon) { $susp += "$($u.Name)(로그온이력없음)" }
}
if ($susp.Count -gt 0) { Rep "W-03" "불필요한 계정 제거" "VULN" @("사용 흔적 없는 활성 계정: $($susp -join ', ') → 미사용이면 삭제/비활성화") }
else { Rep "W-03" "불필요한 계정 제거" "MAN" @("로컬 계정: $(($users | ForEach-Object { $_.Name }) -join ', ')", "각 계정의 필요성은 관리자 확인") }

# W-04 계정 잠금 임계값 설정
# [기준] 양호 - 계정 잠금 임계값 5 이하 / 취약 - 5 초과 (0=제한없음도 취약)
$lc = SecInt "LockoutBadCount"; if ($null -eq $lc) { $lc = NAInt "잠금 임계값"; if ($null -eq $lc) { $lc = NAInt "Lockout threshold" } }
if ($null -ne $lc -and $lc -ge 1 -and $lc -le 5) { Rep "W-04" "계정 잠금 임계값 설정" "GOOD" @("계정 잠금 임계값 = $lc 회 (5 이하)") }
else { Rep "W-04" "계정 잠금 임계값 설정" "VULN" @("계정 잠금 임계값 = $(if($null -eq $lc){'확인불가'}elseif($lc -eq 0){'0(제한없음)'}else{"$lc"}) (기준: 1~5회)") }

# W-05 해독 가능한 암호화를 사용하여 암호 저장 해제
# [기준] 양호 - "사용 안 함"(0) / 취약 - "사용"(1)
$ct = SecInt "ClearTextPassword"
if ($null -eq $ct) { Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장 해제" "MAN" @("ClearTextPassword 확인 불가 (관리자 권한 필요)") }
elseif ($ct -eq 0) { Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장 해제" "GOOD" @("역호환 암호화 저장 = 사용 안 함") }
else { Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장 해제" "VULN" @("역호환 암호화 저장 = 사용 → 사용 안 함으로 변경") }

# W-06 관리자 그룹에 최소한의 사용자 포함
# [기준] 양호 - Administrators 구성원 1명 이하 또는 불필요한 관리자 계정 없음 / 취약 - 불필요한 관리자 계정 존재
$admins = @(GroupMembers "S-1-5-32-544") | Where-Object { $_ }
if ($admins.Count -le 1) { Rep "W-06" "관리자 그룹에 최소한의 사용자 포함" "GOOD" @("Administrators 그룹 구성원($($admins.Count)명): $($admins -join ', ')") }
else { Rep "W-06" "관리자 그룹에 최소한의 사용자 포함" "MAN" @("Administrators 그룹 구성원($($admins.Count)명): $($admins -join ', ')", "각 구성원의 관리자 권한 필요성 확인") }

# W-07 Everyone 사용 권한을 익명 사용자에게 적용
# [기준] 양호 - "사용 안 함"(EveryoneIncludesAnonymous=0) / 취약 - "사용"(1)
$eia = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "EveryoneIncludesAnonymous"
if ($eia -eq 0) { Rep "W-07" "Everyone 사용 권한을 익명 사용자에게 적용" "GOOD" @("EveryoneIncludesAnonymous = 0 (익명에 Everyone 권한 미적용)") }
elseif ($null -eq $eia) { Rep "W-07" "Everyone 사용 권한을 익명 사용자에게 적용" "MAN" @("EveryoneIncludesAnonymous 값 없음 → 정책 확인") }
else { Rep "W-07" "Everyone 사용 권한을 익명 사용자에게 적용" "VULN" @("EveryoneIncludesAnonymous = $eia → '사용 안 함'으로 설정") }

# W-08 계정 잠금 기간 설정
# [기준] 양호 - 계정 잠금 기간 및 원래대로 설정 기간이 60분 이상 / 취약 - 미설정 또는 60분 미만
$ld = SecInt "LockoutDuration"; if ($null -eq $ld) { $ld = NAInt "잠금 기간(분)" }
$rl = SecInt "ResetLockoutCount"; if ($null -eq $rl) { $rl = NAInt "잠금 수를 다음 시간 후 원래대로 설정(분)" }
if ($null -ne $ld -and $ld -ge 60 -and $null -ne $rl -and $rl -ge 60) {
    Rep "W-08" "계정 잠금 기간 설정" "GOOD" @("계정 잠금 기간 = $ld 분, 원래대로 설정 기간 = $rl 분 (모두 60분 이상)")
} else {
    Rep "W-08" "계정 잠금 기간 설정" "VULN" @("계정 잠금 기간 = $ld 분, 원래대로 설정 기간 = $rl 분 (기준: 모두 60분 이상)")
}

# W-09 비밀번호 관리정책 설정
# [기준] 양호 - 복잡성/최소길이/최대·최소 사용기간/암호 기록 모두 적용 / 취약 - 일부 미적용
$pc = SecInt "PasswordComplexity"
$ml = SecInt "MinimumPasswordLength"; if ($null -eq $ml) { $ml = NAInt "최소 암호 길이" }
$mxa = SecInt "MaximumPasswordAge"; if ($null -eq $mxa) { $mxa = NAInt "최대 암호 사용 기간(일)" }
$mna = SecInt "MinimumPasswordAge"; if ($null -eq $mna) { $mna = NAInt "최소 암호 사용 기간(일)" }
$ph  = SecInt "PasswordHistorySize"; if ($null -eq $ph) { $ph = NAInt "암호 기록 유지" }
$miss = @()
if ($pc -ne 1) { $miss += "복잡성(미사용)" }
if ($null -eq $ml -or $ml -lt 8) { $miss += "최소길이($ml/기준 8)" }
if ($null -eq $mxa -or $mxa -lt 1 -or $mxa -gt 90) { $miss += "최대사용기간($(if($mxa -eq 0){'무제한'}else{$mxa})/기준 1~90)" }
if ($null -eq $mna -or $mna -lt 1) { $miss += "최소사용기간($mna/기준 1이상)" }
if ($null -eq $ph -or $ph -lt 12) { $miss += "암호기록($ph/기준 12)" }
if ($miss.Count -eq 0) { Rep "W-09" "비밀번호 관리정책 설정" "GOOD" @("복잡성 사용, 최소길이 $ml, 최대 $mxa 일, 최소 $mna 일, 기록 $ph 개") }
elseif ($null -eq $pc -and $null -eq $ml) { Rep "W-09" "비밀번호 관리정책 설정" "MAN" @("보안정책 확인 불가 (관리자 권한 필요)") }
else { Rep "W-09" "비밀번호 관리정책 설정" "VULN" @("미흡: $($miss -join ', ')") }

# W-10 마지막 사용자 이름 표시 안 함
# [기준] 양호 - "사용"(DontDisplayLastUserName=1) / 취약 - "사용 안 함"(0)
$dl = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DontDisplayLastUserName"
if ($dl -eq 1) { Rep "W-10" "마지막 사용자 이름 표시 안 함" "GOOD" @("DontDisplayLastUserName = 1") }
elseif ($null -eq $dl) { Rep "W-10" "마지막 사용자 이름 표시 안 함" "MAN" @("값 없음 → 정책 확인") }
else { Rep "W-10" "마지막 사용자 이름 표시 안 함" "VULN" @("DontDisplayLastUserName = $dl → '사용'으로 설정") }

# W-11 로컬 로그온 허용
# [기준] 양호 - Administrators, IUSR_ 만 존재 / 취약 - 그 외 계정/그룹 존재
$il = $PRIV["SeInteractiveLogonRight"]
if ($il -and $il -notmatch 'S-1-1-0|S-1-5-11|S-1-5-32-545|Everyone|Users|Authenticated Users') {
    Rep "W-11" "로컬 로그온 허용" "GOOD" @("로컬 로그온 허용 대상: $il (Users/Everyone 미포함)")
} elseif ($null -eq $il) {
    Rep "W-11" "로컬 로그온 허용" "MAN" @("SeInteractiveLogonRight 확인 불가 (관리자 권한 필요)")
} else {
    Rep "W-11" "로컬 로그온 허용" "VULN" @("로컬 로그온 허용에 Users/Everyone 등 포함: $il")
}

# W-12 익명 SID/이름 변환 허용 해제
# [기준] 양호 - "사용 안 함" / 취약 - "사용"
$lsl = SecInt "LSAAnonymousNameLookup"
if ($lsl -eq 0) { Rep "W-12" "익명 SID/이름 변환 허용 해제" "GOOD" @("익명 SID/이름 변환 허용 = 사용 안 함") }
elseif ($null -eq $lsl) { Rep "W-12" "익명 SID/이름 변환 허용 해제" "MAN" @("LSAAnonymousNameLookup 확인 불가") }
else { Rep "W-12" "익명 SID/이름 변환 허용 해제" "VULN" @("익명 SID/이름 변환 허용 = 사용 → 사용 안 함으로 변경") }

# W-13 콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한
# [기준] 양호 - "사용"(LimitBlankPasswordUse=1) / 취약 - "사용 안 함"(0)
$lb = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LimitBlankPasswordUse"
if ($lb -eq 1) { Rep "W-13" "콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한" "GOOD" @("LimitBlankPasswordUse = 1") }
elseif ($null -eq $lb) { Rep "W-13" "콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한" "MAN" @("값 없음 → 정책 확인") }
else { Rep "W-13" "콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한" "VULN" @("LimitBlankPasswordUse = $lb → '사용'으로 설정") }

# W-14 원격터미널 접속 가능한 사용자 그룹 제한
# [기준] 양호 - 관리자 외 원격 접속 전용 계정 존재 + 불필요 계정 미등록 / 취약 - 별도 계정 없음
$rdu = @(GroupMembers "S-1-5-32-555")
Rep "W-14" "원격터미널 접속 가능한 사용자 그룹 제한" "MAN" @("Remote Desktop Users 구성원: $(if($rdu.Count){$rdu -join ', '}else{'없음(Administrators만 RDP 가능)'})", "관리자 외 RDP 전용 계정 운영 정책 확인")

#==============================================================================
Write-Host "[ 2. 서비스 관리 ]" -ForegroundColor White
#==============================================================================

# W-15 사용자 개인키 사용 시 암호 입력
# [기준] 양호 - 개인 키 사용 시마다 암호 입력 / 취약 - 안 받음
$fkp = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Cryptography" "ForceKeyProtection"
if ($fkp -eq 2) { Rep "W-15" "사용자 개인키 사용 시 암호 입력" "GOOD" @("ForceKeyProtection = 2 (개인 키 사용 시 항상 암호 요구)") }
else { Rep "W-15" "사용자 개인키 사용 시 암호 입력" "MAN" @("ForceKeyProtection = $fkp → 인증서 개인 키 보호 수준(사용 시 암호 요구) 수동 확인") }

# W-16 공유 권한 및 사용자 그룹 설정
# [기준] 양호 - 일반 공유 없음 또는 Everyone 권한 없음 / 취약 - Everyone 권한 있는 공유 존재
$shares = @(Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 0 -and $_.Name -notmatch '\$$' })
$everyoneShare = @()
foreach ($s in $shares) {
    try {
        $ss = Get-CimInstance -ClassName Win32_LogicalShareSecuritySetting -Filter "Name='$($s.Name)'" -ErrorAction Stop
        $sd = $ss | Invoke-CimMethod -MethodName GetSecurityDescriptor
        foreach ($ace in $sd.Descriptor.DACL) {
            if ($ace.Trustee.Name -in @("Everyone","모든 사람")) { $everyoneShare += $s.Name }
        }
    } catch {}
}
if ($shares.Count -eq 0) { Rep "W-16" "공유 권한 및 사용자 그룹 설정" "GOOD" @("사용자 정의 공유 없음") }
elseif ($everyoneShare.Count -gt 0) { Rep "W-16" "공유 권한 및 사용자 그룹 설정" "VULN" @("Everyone 권한이 부여된 공유: $($everyoneShare -join ', ')") }
else { Rep "W-16" "공유 권한 및 사용자 그룹 설정" "GOOD" @("공유($($shares.Name -join ', '))에 Everyone 권한 없음") }

# W-17 하드디스크 기본 공유 제거
# [기준] 양호 - AutoShareServer(AutoShareWks)=0 AND 기본 공유 없음 / 취약 - =1 또는 기본 공유 존재
$as = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "AutoShareServer"
if ($null -eq $as) { $as = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "AutoShareWks" }
$admShares = @(Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\$$' -and $_.Name -ne 'IPC$' } | ForEach-Object { $_.Name })
if ($as -eq 0 -and $admShares.Count -eq 0) { Rep "W-17" "하드디스크 기본 공유 제거" "GOOD" @("AutoShareServer=0, 기본 관리 공유 없음") }
else { Rep "W-17" "하드디스크 기본 공유 제거" "VULN" @("AutoShareServer=$as, 기본 공유: $(if($admShares.Count){$admShares -join ', '}else{'없음'}) → AutoShareServer=0 설정 및 공유 제거") }

# W-18 불필요한 서비스 제거
# [기준] 양호 - 불필요한 서비스 중지 / 취약 - 구동 중
$risky = @("Alerter","Messenger","Browser","RemoteRegistry","SharedAccess","TlntSvr","Telnet","SNMPTRAP","simptcp","Fax","upnphost","SSDPSRV","RemoteAccess")
$running = @($risky | Where-Object { SvcRunning $_ })
if ($running.Count -eq 0) { Rep "W-18" "불필요한 서비스 제거" "GOOD" @("Alerter/Messenger/Browser/Telnet/SSDP 등 불필요 서비스 미실행") }
else { Rep "W-18" "불필요한 서비스 제거" "VULN" @("실행 중인 불필요 서비스: $($running -join ', ') → 미사용 시 중지/사용 안 함") }

# W-19 불필요한 IIS 서비스 구동 점검
# [기준] 양호 - IIS 미사용 또는 필요에 의해 사용 / 취약 - 불필요하게 사용
if (-not $IIS_ON) { Rep "W-19" "불필요한 IIS 서비스 구동 점검" "GOOD" @("IIS(W3SVC) 미설치/미실행") }
else { Rep "W-19" "불필요한 IIS 서비스 구동 점검" "MAN" @("IIS 실행 중 → 웹 서버 용도가 맞는지 확인 (불필요 시 제거)") }

# W-20 NetBIOS 바인딩 서비스 구동 점검
# [기준] 양호 - TCP/IP-NetBIOS 바인딩 제거 / 취약 - 미제거
$nbt = $false
try { foreach ($a in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True")) { if ($a.TcpipNetbiosOptions -ne 2) { $nbt = $true } } } catch { $nbt = $true }
if ($nbt) { Rep "W-20" "NetBIOS 바인딩 서비스 구동 점검" "VULN" @("일부 인터페이스에서 NetBIOS over TCP/IP 활성 → '사용 안 함'으로 설정") }
else { Rep "W-20" "NetBIOS 바인딩 서비스 구동 점검" "GOOD" @("모든 인터페이스에서 NetBIOS over TCP/IP 비활성") }

# --- FTP (W-21, W-22, W-24) / 공유 익명(W-23) ---
$FTP_ON = [bool]((SvcRunning "FTPSVC") -or (SvcRunning "MSFTPSVC") -or (PortListening 21))
$ftpTls = IISProp "/system.applicationHost/sites/site/ftpServer/security/ssl" "controlChannelPolicy"

# W-21 암호화되지 않는 FTP 서비스 비활성화
# [기준] 양호 - FTP 미사용 또는 Secure FTP 사용 / 취약 - 평문 FTP 사용
if (-not $FTP_ON) { Rep "W-21" "암호화되지 않는 FTP 서비스 비활성화" "GOOD" @("FTP 서비스 미실행") }
elseif ("$ftpTls" -match "Require|SslRequire") { Rep "W-21" "암호화되지 않는 FTP 서비스 비활성화" "GOOD" @("FTP 실행 중이나 SSL/TLS 필수 설정") }
else { Rep "W-21" "암호화되지 않는 FTP 서비스 비활성화" "VULN" @("평문 FTP(21) 실행 중 (SSL 필수 아님) → SFTP/FTPS 로 전환") }

# W-22 FTP 디렉토리 접근권한 설정
# [기준] 양호 - FTP 홈 디렉터리에 Everyone 권한 없음 / 취약 - Everyone 권한 있음
if (-not $FTP_ON) { Rep "W-22" "FTP 디렉토리 접근권한 설정" "NA" @("FTP 미실행") }
else { Rep "W-22" "FTP 디렉토리 접근권한 설정" "MAN" @("FTP 홈 디렉터리 권한(Everyone 쓰기 금지) 수동 확인") }

# W-23 공유 서비스에 대한 익명 접근 제한 설정
# [기준] 양호 - 공유 서비스 미사용 또는 익명 인증 사용 안 함 / 취약 - 익명 인증 사용
$ftpAnon = IISProp "/system.ftpServer/security/authentication/anonymousAuthentication" "enabled"
$iisAnon = IISProp "/system.webServer/security/authentication/anonymousAuthentication" "enabled"
if (-not $FTP_ON -and -not $IIS_ON) { Rep "W-23" "공유 서비스에 대한 익명 접근 제한 설정" "GOOD" @("FTP/IIS 미사용") }
elseif ($ftpAnon -eq $true) { Rep "W-23" "공유 서비스에 대한 익명 접근 제한 설정" "VULN" @("FTP 익명 인증 활성화됨") }
elseif ($iisAnon -eq $true -and $FTP_ON) { Rep "W-23" "공유 서비스에 대한 익명 접근 제한 설정" "MAN" @("IIS 익명 인증 활성 → 웹 공개 콘텐츠용인지 확인") }
else { Rep "W-23" "공유 서비스에 대한 익명 접근 제한 설정" "GOOD" @("FTP 익명 인증 비활성") }

# W-24 FTP 접근 제어 설정
# [기준] 양호 - 특정 IP 주소에서만 접속하도록 접근 제어 적용 / 취약 - 미적용
if (-not $FTP_ON) { Rep "W-24" "FTP 접근 제어 설정" "NA" @("FTP 미실행") }
else {
    $ipsec = IISProp "/system.ftpServer/security/ipSecurity" "allowUnlisted"
    if ($ipsec -eq $false) { Rep "W-24" "FTP 접근 제어 설정" "GOOD" @("ipSecurity allowUnlisted=false (허용 목록 방식)") }
    else { Rep "W-24" "FTP 접근 제어 설정" "VULN" @("FTP IP 주소 제한(ipSecurity) 미적용") }
}

# W-25 DNS Zone Transfer 설정
# [기준] 양호 - DNS 비활성 / 영역 전송 안 함 / 특정 서버로만 / 취약 - 그 외
$DNS_ON = [bool]((SvcRunning "DNS") -and (FeatureInstalled "DNS"))
if (-not $DNS_ON) { Rep "W-25" "DNS Zone Transfer 설정" "GOOD" @("DNS 서버 역할 미사용") }
else {
    $anyXfer = @()
    try { Import-Module DnsServer -ErrorAction Stop
          foreach ($z in (Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq "Primary" })) {
              if ($z.SecureSecondaries -eq "TransferAnyServer") { $anyXfer += $z.ZoneName }
          } } catch {}
    if ($anyXfer.Count -gt 0) { Rep "W-25" "DNS Zone Transfer 설정" "VULN" @("모든 서버로 영역 전송 허용: $($anyXfer -join ', ')") }
    else { Rep "W-25" "DNS Zone Transfer 설정" "GOOD" @("영역 전송이 제한(특정 서버만/안 함)됨") }
}

# W-26 RDS(Remote Data Services) 제거
# [기준] 양호 - IIS 미사용 / Win2008 이상 / MSADC 가상디렉토리 없음 / 관련 레지스트리 없음 중 하나 이상
$rdsKeys = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\RDSServer.DataFactory",
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\AdvancedDataFactory",
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\VbBusObj.VbBusObjCls")
if (-not $IIS_ON) { Rep "W-26" "RDS(Remote Data Services) 제거" "GOOD" @("IIS 미사용 → RDS 위협 없음") }
elseif ($OS_BUILD -ge 6001) { Rep "W-26" "RDS(Remote Data Services) 제거" "GOOD" @("Windows Server 2008 이상 (Build $OS_BUILD) → 기본적으로 RDS 미포함") }
elseif (@($rdsKeys | Where-Object { Test-Path $_ }).Count -eq 0) { Rep "W-26" "RDS(Remote Data Services) 제거" "GOOD" @("RDS ADCLaunch 레지스트리 없음") }
else { Rep "W-26" "RDS(Remote Data Services) 제거" "VULN" @("RDS 관련 레지스트리 존재 → 제거 필요") }

# W-27 최신 Windows OS Build 버전 적용
$hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
$hfDate = if ($hf) { $hf.InstalledOn.ToString("yyyy-MM-dd") } else { "확인불가" }
Rep "W-27" "최신 Windows OS Build 버전 적용" "MAN" @("OS: $OS_NAME (Build $OS_BUILD), 최근 업데이트: $($hf.HotFixID) ($hfDate)", "최신 누적 업데이트 적용 및 패치 절차 수립 여부(인터뷰) 확인")

# W-28 터미널 서비스 암호화 수준 설정
# [기준] 양호 - RDP 미사용 또는 암호화 "클라이언트와 호환 가능(중간)" 이상 / 취약 - "낮음"
$rdpDeny = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections"
$rdpEnc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "MinEncryptionLevel"
if ($rdpDeny -eq 1) { Rep "W-28" "터미널 서비스 암호화 수준 설정" "GOOD" @("원격 데스크톱 연결 비활성(fDenyTSConnections=1)") }
elseif ($rdpEnc -ge 2) { Rep "W-28" "터미널 서비스 암호화 수준 설정" "GOOD" @("RDP MinEncryptionLevel = $rdpEnc (중간 이상)") }
elseif ($null -eq $rdpEnc) { Rep "W-28" "터미널 서비스 암호화 수준 설정" "MAN" @("RDP MinEncryptionLevel 값 없음 → 정책 확인") }
else { Rep "W-28" "터미널 서비스 암호화 수준 설정" "VULN" @("RDP MinEncryptionLevel = $rdpEnc (낮음) → 중간 이상으로 설정") }

# --- SNMP (W-29 ~ W-31) ---
$SNMP_ON = [bool](SvcObj "SNMP")
$comm = @(); try { $comm = (Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\ValidCommunities" -ErrorAction Stop).Property } catch {}

# W-29 불필요한 SNMP 서비스 구동 점검
# [기준] 양호 - SNMP 미사용 또는 Community String 설정하여 사용 / 취약 - 불필요하게 사용
if (-not $SNMP_ON) { Rep "W-29" "불필요한 SNMP 서비스 구동 점검" "GOOD" @("SNMP 서비스 미설치/미실행") }
elseif ($comm.Count -gt 0) { Rep "W-29" "불필요한 SNMP 서비스 구동 점검" "MAN" @("SNMP 사용 중 (Community 설정됨) → 업무상 필요 여부 확인") }
else { Rep "W-29" "불필요한 SNMP 서비스 구동 점검" "VULN" @("SNMP 서비스 실행/설치됨 → 미사용 시 제거") }

# W-30 SNMP Community String 복잡성 설정
# [기준] 양호 - SNMP 미사용 또는 Community String 이 public/private 아님 / 취약 - public/private
if (-not $SNMP_ON) { Rep "W-30" "SNMP Community String 복잡성 설정" "GOOD" @("SNMP 미사용") }
elseif ($comm -contains "public" -or $comm -contains "private") { Rep "W-30" "SNMP Community String 복잡성 설정" "VULN" @("Community String 에 public/private 사용: $($comm -join ', ')") }
elseif ($comm.Count -gt 0) { Rep "W-30" "SNMP Community String 복잡성 설정" "GOOD" @("Community String 이 기본값(public/private) 아님") }
else { Rep "W-30" "SNMP Community String 복잡성 설정" "MAN" @("Community String 확인 불가") }

# W-31 SNMP Access control 설정
# [기준] 양호 - SNMP 미사용 또는 특정 호스트로부터만 수신 / 취약 - 모든 호스트 허용
if (-not $SNMP_ON) { Rep "W-31" "SNMP Access control 설정" "GOOD" @("SNMP 미사용") }
else {
    $mgr = @(); try { $mgr = (Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\PermittedManagers" -ErrorAction Stop).Property } catch {}
    if ($mgr.Count -gt 0) { Rep "W-31" "SNMP Access control 설정" "GOOD" @("허용 관리자(PermittedManagers) $($mgr.Count)개 지정") }
    else { Rep "W-31" "SNMP Access control 설정" "VULN" @("모든 호스트로부터 SNMP 패킷 수신 허용") }
}

# W-32 DNS 서비스 구동 점검
# [기준] 양호 - DNS 미사용 또는 동적 업데이트 "없음" / 취약 - 사용 + 동적 업데이트 설정
if (-not $DNS_ON) { Rep "W-32" "DNS 서비스 구동 점검" "GOOD" @("DNS 서버 역할 미사용") }
else {
    $dyn = @()
    try { Import-Module DnsServer -ErrorAction Stop
          foreach ($z in (Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq "Primary" })) {
              if ($z.DynamicUpdate -ne "None") { $dyn += "$($z.ZoneName)($($z.DynamicUpdate))" }
          } } catch {}
    if ($dyn.Count -eq 0) { Rep "W-32" "DNS 서비스 구동 점검" "GOOD" @("모든 주 영역의 동적 업데이트 = 없음") }
    else { Rep "W-32" "DNS 서비스 구동 점검" "VULN" @("동적 업데이트 활성 영역: $($dyn -join ', ')") }
}

# W-33 HTTP/FTP/SMTP 배너 차단
# [기준] 양호 - 배너 정보 미노출 / 취약 - 노출
$rmSrvHdr = IISProp "/system.webServer/security/requestFiltering" "removeServerHeader"
if (-not $IIS_ON -and -not $FTP_ON -and -not (SvcRunning "SMTPSVC")) {
    Rep "W-33" "HTTP/FTP/SMTP 배너 차단" "NA" @("HTTP/FTP/SMTP 서비스 미실행")
} elseif ($IIS_ON -and $rmSrvHdr -ne $true) {
    Rep "W-33" "HTTP/FTP/SMTP 배너 차단" "VULN" @("IIS removeServerHeader != true → HTTP 응답에 Server 헤더로 IIS 버전 노출")
} else {
    Rep "W-33" "HTTP/FTP/SMTP 배너 차단" "MAN" @("운영 중 서비스의 응답 배너에서 제품/버전 노출 여부 수동 확인 (FTP messages, SMTP banner 등)")
}

# W-34 Telnet 서비스 비활성화
# [기준] 양호 - Telnet 미구동 또는 인증 방법 NTLM / 취약 - 구동 + 인증 NTLM 아님
if (-not (SvcRunning "TlntSvr") -and -not (PortListening 23)) {
    Rep "W-34" "Telnet 서비스 비활성화" "GOOD" @("Telnet 서버 미실행")
} else {
    $tnlm = RegVal "HKLM:\SOFTWARE\Microsoft\TelnetServer\1.0" "NTLM"
    if ($tnlm -ge 2) { Rep "W-34" "Telnet 서비스 비활성화" "MAN" @("Telnet 실행 중이나 인증=NTLM($tnlm) → SSH/RDP 대체 권장") }
    else { Rep "W-34" "Telnet 서비스 비활성화" "VULN" @("Telnet 서버 실행 중 + 인증 NTLM 아님 → 비활성화 필요") }
}

# W-35 불필요한 ODBC/OLE-DB 데이터 소스와 드라이브 제거
# [기준] 양호 - 시스템 DSN 데이터 소스를 현재 사용 중 / 취약 - 사용하지 않는 DSN 존재
$dsn = @()
try { $dsn = (Get-ChildItem "HKLM:\SOFTWARE\ODBC\ODBC.INI" -ErrorAction Stop | Where-Object { $_.PSChildName -ne "ODBC Data Sources" } | ForEach-Object { $_.PSChildName }) } catch {}
if ($dsn.Count -eq 0) { Rep "W-35" "불필요한 ODBC/OLE-DB 데이터 소스와 드라이브 제거" "GOOD" @("시스템 ODBC DSN 없음") }
else { Rep "W-35" "불필요한 ODBC/OLE-DB 데이터 소스와 드라이브 제거" "MAN" @("시스템 ODBC DSN: $($dsn -join ', ') → 미사용 항목/평문 자격증명 제거 여부 확인") }

# W-36 원격터미널 접속 타임아웃 설정
# [기준] 양호 - Timeout 30분 이하 / 취약 - 미적용 또는 30분 초과
$idleP = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" "MaxIdleTime"
if ($null -eq $idleP) { $idleP = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "MaxIdleTime" }
if ($idleP -and $idleP -gt 0 -and $idleP -le 1800000) { Rep "W-36" "원격터미널 접속 타임아웃 설정" "GOOD" @("RDP 유휴 세션 제한 = $([math]::Round($idleP/60000)) 분 (30분 이하)") }
else { Rep "W-36" "원격터미널 접속 타임아웃 설정" "VULN" @("RDP 유휴 세션 제한 = $(if($idleP){[math]::Round($idleP/60000)}else{'미설정'}) → 30분 이하로 설정") }

# W-37 예약된 작업에 의심스러운 명령이 등록되어 있는지 점검
$tasks = @()
try { $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' -and $_.State -ne "Disabled" } | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" } } catch {}
if ($tasks.Count -eq 0) { Rep "W-37" "예약된 작업에 의심스러운 명령이 등록되어 있는지 점검" "GOOD" @("사용자 정의 활성 예약 작업 없음") }
else { Rep "W-37" "예약된 작업에 의심스러운 명령이 등록되어 있는지 점검" "MAN" @("사용자 정의 예약 작업($($tasks.Count)개): $(($tasks | Select-Object -First 10) -join ', ')", "각 작업의 실행 명령/등록 경위 확인") }

#==============================================================================
Write-Host "[ 3. 패치 관리 ]" -ForegroundColor White
#==============================================================================

# W-38 주기적 보안 패치 및 벤더 권고사항 적용
$daysAgo = if ($hf) { (New-TimeSpan -Start $hf.InstalledOn -End (Get-Date)).Days } else { 9999 }
if ($daysAgo -le 90) { Rep "W-38" "주기적 보안 패치 및 벤더 권고사항 적용" "MAN" @("최근 업데이트: $($hf.HotFixID) ($hfDate, ${daysAgo}일 전)", "패치 절차 수립 및 정기 적용 여부(인터뷰) 확인") }
else { Rep "W-38" "주기적 보안 패치 및 벤더 권고사항 적용" "VULN" @("최근 업데이트 $hfDate (약 ${daysAgo}일 전) → 90일 이상 미적용, 누적/보안 패치 적용 필요") }

# W-39 백신 프로그램 업데이트
$av = $null; try { $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop } catch {}
$def = $null; try { $def = Get-MpComputerStatus -ErrorAction Stop } catch {}
if ($def -and $def.AntivirusEnabled) {
    $sigOld = ($def.AntivirusSignatureLastUpdated -and (New-TimeSpan -Start $def.AntivirusSignatureLastUpdated -End (Get-Date)).Days -gt 7)
    if ($sigOld) { Rep "W-39" "백신 프로그램 업데이트" "VULN" @("Defender 서명 최종 업데이트: $($def.AntivirusSignatureLastUpdated) (7일 초과)") }
    else { Rep "W-39" "백신 프로그램 업데이트" "GOOD" @("Defender 실시간 보호 활성, 서명 $($def.AntivirusSignatureLastUpdated)") }
} elseif ($av) {
    Rep "W-39" "백신 프로그램 업데이트" "MAN" @("백신 제품: $(($av | ForEach-Object { $_.displayName }) -join ', ')", "엔진/시그니처 최신 여부 확인")
} else {
    Rep "W-39" "백신 프로그램 업데이트" "VULN" @("동작 중인 백신 미확인 → 백신 설치 및 최신 엔진 업데이트 필요")
}

#==============================================================================
Write-Host "[ 4. 로그 관리 ]" -ForegroundColor White
#==============================================================================

# W-40 정책에 따른 시스템 로깅 설정
# [기준] 양호 - 감사 정책 권고 기준대로 설정 / 취약 - 아님
if ($IS_ADMIN) {
    $ap = auditpol /get /category:* 2>$null
    $need = @("Logon","Logoff","Account Lockout","User Account Management","Security Group Management",
              "Audit Policy Change","Sensitive Privilege Use","Security State Change","Other System Events")
    $missAudit = @()
    foreach ($n in $need) {
        $l = $ap | Select-String -SimpleMatch $n | Select-Object -First 1
        if (-not $l -or $l -match "No Auditing|감사 안 함") { $missAudit += $n }
    }
    if ($missAudit.Count -eq 0) { Rep "W-40" "정책에 따른 시스템 로깅 설정" "GOOD" @("주요 감사 범주(로그온/계정 관리/정책 변경/권한 사용/시스템) 성공·실패 감사 설정") }
    else { Rep "W-40" "정책에 따른 시스템 로깅 설정" "VULN" @("감사 미설정: $($missAudit -join ', ') → 권고 기준대로 성공/실패 감사 설정") }
} else {
    Rep "W-40" "정책에 따른 시스템 로깅 설정" "MAN" @("감사 정책(auditpol)은 관리자 권한 필요 → 관리자로 재점검")
}

# W-41 NTP 및 시각 동기화 설정
# [기준] 양호 - NTP/시각 동기화를 "설정"한 경우 (외부 NTP 지정 또는 도메인 계층 동기화)
#        취약 - 미설정(NoSync 이거나 NTP 서버 미지정 + 로컬 CMOS 전용)
#   ※ W32Time 은 도메인 미조인 서버에서 평소 '중지(수동/트리거)' 상태가 정상이므로
#     서비스 실행 여부가 아니라 레지스트리 구성으로 판단한다. status 출력은 참고용.
$w32   = SvcObj "W32Time"
$w32p  = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
$w32Type   = RegVal $w32p "Type"                 # NTP / NT5DS / AllSync / NoSync
$w32Server = [string](RegVal $w32p "NtpServer")  # 예: time.windows.com,0x9 / 169.254.169.123
$ntpClient = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient" "Enabled"

$w32exe = Join-Path $env:SystemRoot "System32\w32tm.exe"
$w32status = if (Test-Path $w32exe) { & $w32exe /query /status 2>$null | Out-String } else { "" }
$src = ""
if ($w32status -match '(?m)^\s*(?:Source|원본)\s*:\s*(.+?)\s*$') { $src = $Matches[1].Trim() }
$srcOk = ($src -and $src -notmatch 'Local CMOS Clock|Free-running|로컬 CMOS')

$cfgOk = ($null -ne $w32) -and $w32Type -and ($w32Type -ne "NoSync") -and `
         ( ($w32Server.Trim()) -or ($w32Type -eq "NT5DS") -or ($ntpClient -eq 1) )

$w32ev = ("W32Time=$([string]$w32.Status)/$([string]$w32.StartType), Type=$w32Type, " +
          "NtpServer=$w32Server, 현재 동기화 원본=$src")
if ($cfgOk -or $srcOk) {
    Rep "W-41" "NTP 및 시각 동기화 설정" "GOOD" @($w32ev, "NTP/시각 동기화가 설정되어 있어 양호함")
} else {
    Rep "W-41" "NTP 및 시각 동기화 설정" "VULN" @($w32ev, "NTP 서버 미지정 또는 NoSync → 외부 NTP/시각 동기화 설정 필요")
}

# W-42 이벤트 로그 관리 설정
# [기준] 양호 - 최대 로그 크기 10,240KB 이상 AND 이벤트 덮어씀 기간 "90일 이후"(또는 덮어쓰지 않음/가득 차면 보관)
#        취약 - 크기 미달 이거나, "필요에 따라 덮어씀"(=90일 이하)
$logbad = @()
$logunk = @()
foreach ($lg in @("Security","Application","System")) {
    $base = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\" + $lg
    $sz = RegVal $base "MaxSize"
    if ($null -eq $sz) { $sz = (Get-WinEvent -ListLog $lg -ErrorAction SilentlyContinue).MaximumSizeInBytes }
    $ret    = RegVal $base "Retention"
    $autobk = RegVal $base "AutoBackupLogFiles"        # 1 = 가득 차면 보관
    if ($null -eq $sz -and $null -eq $ret) { $logunk += $lg; continue }  # 관리자 권한 부족 등

    $szKB = if ($sz) { [math]::Round($sz/1KB) } else { 0 }
    if ($szKB -lt 10240) { $logbad += "$lg 크기 ${szKB}KB(<10,240)" }

    # Retention: 0/미설정 = 필요시 덮어씀(취약), 0xFFFFFFFF(-1) = 덮어쓰지 않음, 그 외 = 보존 초
    $retNum = $null
    if ($null -ne $ret) { try { $retNum = [int64]$ret } catch { $retNum = $null } }
    if ($null -ne $retNum -and $retNum -lt 0) { $retNum = 4294967295 }
    $retOk = ($autobk -eq 1) -or ($retNum -eq 4294967295) -or ($null -ne $retNum -and $retNum -ge 7776000)
    if (-not $retOk) {
        $how = if ($null -eq $retNum) { "미설정(필요시 덮어씀)" } elseif ($retNum -eq 0) { "필요시 덮어씀" } else { "$([math]::Floor($retNum/86400))일 후 덮어씀" }
        $logbad += "$lg 덮어씀=$how(<90일)"
    }
}
if ($logbad.Count -gt 0) {
    Rep "W-42" "이벤트 로그 관리 설정" "VULN" @(($logbad -join " / "), "최대 로그 크기 10,240KB 이상 및 '90일 이후 이벤트 덮어씀' 설정 필요")
} elseif ($logunk.Count -gt 0) {
    Rep "W-42" "이벤트 로그 관리 설정" "MAN" @("로그 설정 확인 불가(관리자 권한 필요): $($logunk -join ', ')")
} else {
    Rep "W-42" "이벤트 로그 관리 설정" "GOOD" @("보안/응용/시스템 로그 최대 크기 10,240KB 이상 + 90일 이후 덮어씀(또는 덮어쓰지 않음/보관) 설정")
}

# W-43 이벤트 로그 파일 접근 통제 설정
# [기준] 양호 - 로그 디렉터리에 Everyone 권한 없음 / 취약 - Everyone 권한 있음
$logDir = "$env:SystemRoot\System32\winevt\Logs"
$heLog = AclHasEveryone $logDir
if ($heLog -eq $false) { Rep "W-43" "이벤트 로그 파일 접근 통제 설정" "GOOD" @("$logDir 에 Everyone 권한 없음") }
elseif ($null -eq $heLog) { Rep "W-43" "이벤트 로그 파일 접근 통제 설정" "MAN" @("로그 디렉터리 ACL 확인 불가 (관리자 권한 필요)") }
else { Rep "W-43" "이벤트 로그 파일 접근 통제 설정" "VULN" @("$logDir 에 Everyone 권한 존재 → 제거") }

#==============================================================================
Write-Host "[ 5. 보안 관리 ]" -ForegroundColor White
#==============================================================================

function RegExpect { param([string]$C,[string]$T,[string]$P,[string]$N,$Want,[string]$G,[string]$B)
    $v = RegVal $P $N
    if ($null -eq $v) { Rep $C $T "MAN" @("$N 값 없음 → 정책 확인") }
    elseif ($v -eq $Want) { Rep $C $T "GOOD" @("$G (현재값 $v)") }
    else { Rep $C $T "VULN" @("$B (현재값 $v, 기준 $Want)") }
}

# W-44 원격으로 액세스할 수 있는 레지스트리 경로
# [기준] 양호 - Remote Registry Service 중지 / 취약 - 사용 중
$rr = SvcObj "RemoteRegistry"
if (-not $rr -or $rr.Status -ne "Running") { Rep "W-44" "원격으로 액세스할 수 있는 레지스트리 경로" "GOOD" @("Remote Registry 서비스 중지/미설치 (StartType=$($rr.StartType))") }
else { Rep "W-44" "원격으로 액세스할 수 있는 레지스트리 경로" "VULN" @("Remote Registry 서비스 실행 중 → 중지 및 '사용 안 함'") }

# W-45 백신 프로그램 설치
# [기준] 양호 - 백신 설치 / 취약 - 미설치
if ($av -or ($def -and $def.AMServiceEnabled)) { Rep "W-45" "백신 프로그램 설치" "GOOD" @("백신 설치됨: $(if($av){($av|ForEach-Object{$_.displayName}) -join ', '}else{'Microsoft Defender'})") }
else { Rep "W-45" "백신 프로그램 설치" "VULN" @("백신 프로그램 미설치 → 설치 필요") }

# W-46 SAM 파일 접근 통제 설정
# [기준] 양호 - SAM 파일 권한에 Administrators, System 만 모든 권한 / 취약 - 그 외 그룹 권한
$samPath = "$env:SystemRoot\System32\config\SAM"
if (-not $IS_ADMIN) { Rep "W-46" "SAM 파일 접근 통제 설정" "MAN" @("SAM ACL 조회는 관리자 권한 필요") }
else {
    try {
        $acl = Get-Acl $samPath -ErrorAction Stop
        $bad = @($acl.Access | Where-Object { $_.IdentityReference.Value -notin @("NT AUTHORITY\SYSTEM","BUILTIN\Administrators","Administrators","SYSTEM") })
        if ($bad.Count -eq 0) { Rep "W-46" "SAM 파일 접근 통제 설정" "GOOD" @("SAM 파일 권한 = SYSTEM/Administrators 만") }
        else { Rep "W-46" "SAM 파일 접근 통제 설정" "VULN" @("SAM 파일에 추가 권한: $(($bad | ForEach-Object { $_.IdentityReference.Value }) -join ', ')") }
    } catch { Rep "W-46" "SAM 파일 접근 통제 설정" "MAN" @("SAM ACL 조회 실패") }
}

# W-47 화면보호기 설정
# [기준] 양호 - 화면 보호기 설정 + 대기 10분(600초) 이하 + 해제 암호 사용 / 취약 - 아님
$ssA = RegVal "HKCU:\Control Panel\Desktop" "ScreenSaveActive"
$ssS = RegVal "HKCU:\Control Panel\Desktop" "ScreenSaverIsSecure"
$ssT = [int](RegVal "HKCU:\Control Panel\Desktop" "ScreenSaveTimeOut")
$ssPol = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop" "ScreenSaverIsSecure"
if ((($ssA -eq "1") -and ($ssS -eq "1") -and ($ssT -gt 0) -and ($ssT -le 600)) -or ($ssPol -eq "1")) {
    Rep "W-47" "화면보호기 설정" "GOOD" @("화면 보호기 활성 + 암호 보호 + 대기 $ssT 초")
} else {
    Rep "W-47" "화면보호기 설정" "VULN" @("화면 보호기 암호 보호/대기시간(<=600초) 미흡 (Active=$ssA Secure=$ssS Timeout=$ssT)")
}

# W-48 로그온하지 않고 시스템 종료 허용
RegExpect "W-48" "로그온하지 않고 시스템 종료 허용" "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "ShutdownWithoutLogon" 0 `
    "로그온 화면에서 시스템 종료 불가" "로그온 없이 시스템 종료 가능 → '사용 안 함'으로 설정"

# W-49 원격 시스템에서 강제로 시스템 종료
$p49 = PrivOnlyAdmin "SeRemoteShutdownPrivilege"
if ($p49 -eq $true) { Rep "W-49" "원격 시스템에서 강제로 시스템 종료" "GOOD" @("SeRemoteShutdownPrivilege = Administrators 만") }
elseif ($null -eq $p49) { Rep "W-49" "원격 시스템에서 강제로 시스템 종료" "MAN" @("권한 할당 확인 불가 (관리자 권한 필요)") }
else { Rep "W-49" "원격 시스템에서 강제로 시스템 종료" "VULN" @("SeRemoteShutdownPrivilege 에 Administrators 외 대상 포함: $($PRIV['SeRemoteShutdownPrivilege'])") }

# W-50 보안 감사를 로그할 수 없는 경우 즉시 시스템 종료
RegExpect "W-50" "보안 감사를 로그할 수 없는 경우 즉시 시스템 종료" "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "CrashOnAuditFail" 0 `
    "감사 실패 시 시스템 종료 안 함(가용성)" "감사 실패 시 시스템 강제 종료 → '사용 안 함'으로 설정"

# W-51 SAM 계정과 공유의 익명 열거 허용 안 함
# [기준] 양호 - "SAM 계정과 공유의 익명 열거 허용 안 함" 사용(RestrictAnonymous=1) / 취약 - 사용 안 함(0 또는 미설정)
#  ※ 본 항목은 RestrictAnonymous (기본값 0). RestrictAnonymousSAM(기본값 1)은 "SAM 계정" 항목이라 별개 — 참고만.
$lsaP  = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
$ra    = RegVal $lsaP "RestrictAnonymous"
$raSAM = RegVal $lsaP "RestrictAnonymousSAM"
$raVal    = if ($null -eq $ra)    { 0 } else { try { [int]$ra }    catch { 0 } }
$raSAMVal = if ($null -eq $raSAM) { 1 } else { try { [int]$raSAM } catch { 1 } }
if ($raVal -ge 1) {
    Rep "W-51" "SAM 계정과 공유의 익명 열거 허용 안 함" "GOOD" @("RestrictAnonymous=$raVal (익명 열거 제한), RestrictAnonymousSAM=$raSAMVal")
} else {
    Rep "W-51" "SAM 계정과 공유의 익명 열거 허용 안 함" "VULN" @("RestrictAnonymous=$(if($null -eq $ra){'미설정(=0)'}else{$ra}) → 익명 사용자가 SAM 계정·공유 열거 가능, '사용'(1)으로 설정 필요 (RestrictAnonymousSAM=$raSAMVal)")
}

# W-52 Autologon 기능 제어
$aal = RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoAdminLogon"
$dpw = RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "DefaultPassword"
if (($aal -eq 1 -or $aal -eq "1") -or $dpw) { Rep "W-52" "Autologon 기능 제어" "VULN" @("자동 로그온 활성(AutoAdminLogon=$aal)$(if($dpw){', DefaultPassword 평문 저장'})") }
else { Rep "W-52" "Autologon 기능 제어" "GOOD" @("자동 로그온 비활성 (AutoAdminLogon 미설정/0)") }

# W-53 이동식 미디어 포맷 및 꺼내기 허용
RegExpect "W-53" "이동식 미디어 포맷 및 꺼내기 허용" "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AllocateDASD" 0 `
    "로그온한 관리자만 이동식 미디어 접근(0)" "이동식 미디어 접근 제한 미흡 → 0(Administrators) 권장"

# W-54 DoS 공격 방어 레지스트리 설정
# [기준] 양호 - SynAttackProtect>=1, EnableDeadGWDetect=0, KeepAliveTime=300000, NoNameReleaseOnDemand=1 모두 / 취약 - 미설정
$tp = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
$sap = RegVal $tp "SynAttackProtect"; $edg = RegVal $tp "EnableDeadGWDetect"; $kat = RegVal $tp "KeepAliveTime"
$nnr = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\Netbt\Parameters" "NoNameReleaseOnDemand"
$d54 = @()
if (-not ($sap -ge 1)) { $d54 += "SynAttackProtect($sap/기준>=1)" }
if ($edg -ne 0) { $d54 += "EnableDeadGWDetect($edg/기준 0)" }
if ($kat -ne 300000) { $d54 += "KeepAliveTime($kat/기준 300000)" }
if ($nnr -ne 1) { $d54 += "NoNameReleaseOnDemand($nnr/기준 1)" }
if ($d54.Count -eq 0) { Rep "W-54" "DoS 공격 방어 레지스트리 설정" "GOOD" @("SynAttackProtect/EnableDeadGWDetect/KeepAliveTime/NoNameReleaseOnDemand 모두 권고값") }
else { Rep "W-54" "DoS 공격 방어 레지스트리 설정" "VULN" @("미흡: $($d54 -join ', ')") }

# W-55 사용자가 프린터 드라이버를 설치할 수 없게 함
RegExpect "W-55" "사용자가 프린터 드라이버를 설치할 수 없게 함" "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Providers\LanMan Print Services\Servers" "AddPrinterDrivers" 1 `
    "관리자만 프린터 드라이버 설치 가능" "일반 사용자의 프린터 드라이버 설치 허용 → 제한(PrintNightmare 대응)"

# W-56 SMB 세션 중단 관리 설정
# [기준] 양호 - "로그온 시간 만료 시 클라이언트 연결 끊기" 사용 + "세션 중단 전 유휴 시간" 15분 이하 / 취약 - 아님
$efl = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "EnableForcedLogOff"
$adc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "autodisconnect"
if (($efl -eq 1 -or $null -eq $efl) -and $null -ne $adc -and [int]$adc -ge 0 -and [int]$adc -le 15) {
    Rep "W-56" "SMB 세션 중단 관리 설정" "GOOD" @("EnableForcedLogOff=$efl, autodisconnect=$adc 분 (<=15)")
} else {
    Rep "W-56" "SMB 세션 중단 관리 설정" "VULN" @("EnableForcedLogOff=$efl, autodisconnect=$(if($null -eq $adc){'미설정'}else{$adc}) (기준: 사용 + 15분 이하)")
}

# W-57 로그온 시 경고 메시지 설정
$cap = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "LegalNoticeCaption"
$txt = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "LegalNoticeText"
if ($cap -and $txt) { Rep "W-57" "로그온 시 경고 메시지 설정" "GOOD" @("로그온 경고 메시지 설정됨 (제목: '$cap')") }
else { Rep "W-57" "로그온 시 경고 메시지 설정" "VULN" @("LegalNoticeCaption/Text 미설정 → 비인가 접근 경고 문구 설정") }

# W-58 사용자별 홈 디렉터리 권한 설정
# [기준] 양호 - 홈 디렉터리에 Everyone 권한 없음 (All Users, Default User 제외) / 취약 - Everyone 권한 있음
$userDirs = @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") })
$badHome = @()
foreach ($d in $userDirs) { if ((AclHasEveryone $d.FullName) -eq $true) { $badHome += $d.Name } }
if ($userDirs.Count -eq 0) { Rep "W-58" "사용자별 홈 디렉터리 권한 설정" "NA" @("사용자 홈 디렉터리 없음") }
elseif ($badHome.Count -eq 0) { Rep "W-58" "사용자별 홈 디렉터리 권한 설정" "GOOD" @("사용자 홈 디렉터리($($userDirs.Count)개)에 Everyone 권한 없음") }
else { Rep "W-58" "사용자별 홈 디렉터리 권한 설정" "VULN" @("Everyone 권한이 있는 홈 디렉터리: $($badHome -join ', ')") }

# W-59 LAN Manager 인증 수준
# [기준] 양호 - "NTLMv2 응답만 보냄"(LmCompatibilityLevel >= 3) / 취약 - LM/NTLM 허용
$lmc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LmCompatibilityLevel"
if ($lmc -ge 3) { Rep "W-59" "LAN Manager 인증 수준" "GOOD" @("LmCompatibilityLevel = $lmc (NTLMv2 응답만)") }
elseif ($null -eq $lmc) { Rep "W-59" "LAN Manager 인증 수준" "MAN" @("LmCompatibilityLevel 값 없음 → 기본값 확인 (기준: 3 이상)") }
else { Rep "W-59" "LAN Manager 인증 수준" "VULN" @("LmCompatibilityLevel = $lmc → 3(NTLMv2 응답만) 이상으로 설정") }

# W-60 보안 채널 데이터 디지털 암호화 또는 서명
# [기준] 양호 - RequireSignOrSeal/SealSecureChannel/SignSecureChannel 모두 1 / 취약 - 일부 0
$np = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters"
$rss = RegVal $np "RequireSignOrSeal"; $ssc = RegVal $np "SealSecureChannel"; $sgn = RegVal $np "SignSecureChannel"
if (($rss -eq 1 -or $null -eq $rss) -and ($ssc -eq 1 -or $null -eq $ssc) -and ($sgn -eq 1 -or $null -eq $sgn)) {
    Rep "W-60" "보안 채널 데이터 디지털 암호화 또는 서명" "GOOD" @("RequireSignOrSeal=$rss, SealSecureChannel=$ssc, SignSecureChannel=$sgn (기본값 포함 모두 사용)")
} else {
    Rep "W-60" "보안 채널 데이터 디지털 암호화 또는 서명" "VULN" @("일부 '사용 안 함': RequireSignOrSeal=$rss, SealSecureChannel=$ssc, SignSecureChannel=$sgn")
}

# W-61 파일 및 디렉토리 보호
# [기준] 양호 - NTFS 파일 시스템 / 취약 - FAT
$fat = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | Where-Object { $_.FileSystem -and $_.FileSystem -notmatch 'NTFS|ReFS' })
if ($fat.Count -eq 0) { Rep "W-61" "파일 및 디렉토리 보호" "GOOD" @("모든 고정 디스크가 NTFS/ReFS") }
else { Rep "W-61" "파일 및 디렉토리 보호" "VULN" @("FAT 계열 볼륨: $(($fat | ForEach-Object { "$($_.DeviceID)($($_.FileSystem))" }) -join ', ') → NTFS 로 전환") }

# W-62 시작프로그램 목록 분석
$runKeys = @()
foreach ($rk in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run","HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run")) {
    try { $p = Get-Item $rk -ErrorAction Stop; foreach ($n in $p.Property) { $runKeys += "$n" } } catch {}
}
Rep "W-62" "시작프로그램 목록 분석" "MAN" @("자동 실행 등록: $(if($runKeys.Count){$runKeys -join ', '}else{'없음'})", "시작 프로그램·서비스 정기 점검 및 불필요 항목 제거 여부 확인")

# W-63 도메인 컨트롤러-사용자의 시간 동기화
# [기준] 양호 - 컴퓨터 시계 동기화 최대 허용 오차 5분 이하 / 취약 - 5분 초과
$isDC = ($os.ProductType -eq 2)
$maxSkew = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" "MaxClockSkewMinutes"
$kerbSkew = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kerberos\Parameters" "MaxClockSkew"
$eff = if ($null -ne $maxSkew) { $maxSkew } elseif ($null -ne $kerbSkew) { $kerbSkew } else { 5 }
if (-not $isDC) { Rep "W-63" "도메인 컨트롤러-사용자의 시간 동기화" "NA" @("도메인 컨트롤러 아님 (Kerberos 시간 오차 정책은 DC/도메인 정책 대상)") }
elseif ($eff -le 5) { Rep "W-63" "도메인 컨트롤러-사용자의 시간 동기화" "GOOD" @("Kerberos 최대 시계 오차 = $eff 분 (5분 이하)") }
else { Rep "W-63" "도메인 컨트롤러-사용자의 시간 동기화" "VULN" @("Kerberos 최대 시계 오차 = $eff 분 (기준: 5분 이하)") }

# W-64 윈도우 방화벽 설정
# [기준] 양호 - Windows 방화벽 "사용" / 취약 - "사용 안 함"
$fw = @(); try { $fw = Get-NetFirewallProfile -ErrorAction Stop } catch {}
$fwOff = @($fw | Where-Object { -not $_.Enabled })
if ($fw.Count -gt 0 -and $fwOff.Count -eq 0) { Rep "W-64" "윈도우 방화벽 설정" "GOOD" @("도메인/개인/공용 방화벽 프로필 모두 사용") }
elseif ($fw.Count -eq 0) { Rep "W-64" "윈도우 방화벽 설정" "MAN" @("방화벽 프로필 상태 확인 불가 → 별도 호스트 방화벽/보안그룹 확인") }
else { Rep "W-64" "윈도우 방화벽 설정" "VULN" @("방화벽 비활성 프로필: $($fwOff.Name -join ', ')") }

#==============================================================================
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host (" 요약   양호={0}   취약={1}   N/A={2}   수동확인={3}   (총 {4})" -f $good, $vuln, $na, $man, ($good+$vuln+$na+$man)) -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host " 수동확인 항목은 정책 수립 여부 등 인터뷰가 필요한 잔여 항목입니다."
Write-Host ""

# ---------------- JSON 파일 출력 (GUI 연동) ----------------
if ($Json -ne "") {
    $out = [pscustomobject]@{
        host = $HOSTN; os = $OS_NAME; family = "windows"; results = @($script:results)
    }
    $out | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $Json -Encoding UTF8
    Write-Host (" JSON 저장: {0}" -f $Json)
}
