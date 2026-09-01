<#
==============================================================================
 KISA 주요정보통신기반시설 기술적 취약점 점검 (Windows Server)  W-01 ~ W-82
  - "주요정보통신기반시설 기술적 취약점 분석·평가 상세가이드(Windows)" 판단기준 적용
  - 각 항목 앞에 # [기준] 주석으로 양호/취약 조건 명시. 판단은 이 기준으로만 한다.
  - 읽기 전용(READ-ONLY): 레지스트리/정책 조회만, 변경 없음
  - 대상: Windows Server 2012 R2 / 2016 / 2019 / 2022 (Windows 10/11 도 대부분 동작)
  - 권장 실행:  powershell -ExecutionPolicy Bypass -File kisa_win_check.ps1 -Json out.json
               (관리자 권한 필요 — secedit / SAM ACL / 감사정책 조회)

 판정 표기
   양호     : 판단기준 충족
   취약     : 판단기준 미충족
   N/A      : 점검 대상 서비스/역할 미사용 → 위협 없음
   수동확인 : 정책 수립 여부 등 시스템 상태만으로 확정 불가(인터뷰 필요) 잔여 항목

 GUI(kisa_gui.py) 연동: -Json <경로> 지정 시 kisa_unix_check.sh 와 동일한 스키마로 저장
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
chcp 65001 > $null 2>&1

# ---------------- 결과 집계 ----------------
$script:good = 0; $script:vuln = 0; $script:na = 0; $script:man = 0
$script:results = New-Object System.Collections.ArrayList

$IMP = @{
    "W-01"="상";"W-02"="상";"W-03"="상";"W-04"="상";"W-05"="상";"W-06"="상"
    "W-07"="상";"W-08"="상";"W-09"="상";"W-10"="상";"W-11"="상";"W-12"="상";"W-13"="상";"W-14"="상"
    "W-15"="상";"W-16"="상";"W-17"="상";"W-18"="상";"W-19"="상";"W-20"="상";"W-21"="상";"W-22"="상"
    "W-23"="상";"W-24"="상";"W-25"="상";"W-26"="상";"W-27"="상";"W-28"="상";"W-29"="상";"W-30"="상"
    "W-31"="상";"W-32"="중";"W-33"="중";"W-34"="상";"W-35"="상";"W-36"="상";"W-37"="상";"W-38"="중"
    "W-39"="상";"W-40"="하";"W-41"="중";"W-42"="중";"W-43"="상";"W-44"="상";"W-45"="중"
    "W-46"="상";"W-47"="상";"W-48"="상";"W-49"="중";"W-50"="중";"W-51"="중";"W-52"="중";"W-53"="중"
    "W-54"="중";"W-55"="중";"W-56"="중";"W-57"="중";"W-58"="중";"W-59"="중";"W-60"="중";"W-61"="상"
    "W-62"="상";"W-63"="중";"W-64"="중";"W-65"="상";"W-66"="상";"W-67"="상";"W-68"="상";"W-69"="상"
    "W-70"="중";"W-71"="중";"W-72"="중";"W-73"="중";"W-74"="중";"W-75"="중";"W-76"="중";"W-77"="하"
    "W-78"="중";"W-79"="중";"W-80"="중";"W-81"="중";"W-82"="중"
}

function Rep {
    param([string]$Code, [string]$Title, [string]$Status, [string[]]$Evidence)
    switch ($Status) {
        "GOOD" { $script:good++; $k = "양호";   $col = "Green" }
        "VULN" { $script:vuln++; $k = "취약";   $col = "Red" }
        "NA"   { $script:na++;   $k = "N/A";    $col = "Yellow" }
        "MAN"  { $script:man++;  $k = "수동확인"; $col = "Cyan" }
    }
    if ($NoColor) {
        Write-Host ("{0,-6} {1,-46} [{2}]" -f $Code, $Title, $k)
    } else {
        Write-Host ("{0,-6} " -f $Code) -NoNewline -ForegroundColor Cyan
        Write-Host ("{0,-46} " -f $Title) -NoNewline
        Write-Host ("[{0}]" -f $k) -ForegroundColor $col
    }
    foreach ($e in $Evidence) { Write-Host ("         - {0}" -f $e) }
    [void]$script:results.Add([pscustomobject]@{
        code = $Code; importance = $IMP[$Code]; title = $Title; status = $k
        evidence = @($Evidence)
    })
}

# ---------------- 공통 헬퍼 ----------------
function RegVal {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}
function SvcState { param([string]$Name) $s = Get-Service -Name $Name -ErrorAction SilentlyContinue; if ($s) { $s.Status } else { $null } }
function SvcRunning { param([string]$Name) (SvcState $Name) -eq "Running" }
function FeatureInstalled {
    param([string]$Name)
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $f = Get-WindowsFeature -Name $Name -ErrorAction SilentlyContinue
        return ($f -and $f.Installed)
    }
    return $false
}
function PortListening { param([int]$Port) [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) }

$IS_ADMIN = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------- 로컬 보안 정책 (secedit) ----------------
$SEC = @{}          # [System Access] / [Registry Values] 등 key=value
$PRIV = @{}         # [Privilege Rights]  SeXxx = SID/이름 목록
if ($IS_ADMIN) {
    $inf = Join-Path $env:TEMP ("kisa_secpol_{0}.inf" -f $PID)
    secedit /export /cfg $inf /quiet 2>$null | Out-Null
    if (Test-Path $inf) {
        $section = ""
        foreach ($line in (Get-Content $inf -Encoding Unicode -ErrorAction SilentlyContinue)) {
            $t = $line.Trim()
            if ($t -match '^\[(.+)\]$') { $section = $matches[1]; continue }
            if ($t -match '^\s*([^=]+?)\s*=\s*(.*)$') {
                $key = $matches[1].Trim(); $valv = $matches[2].Trim()
                if ($section -eq "Privilege Rights") { $PRIV[$key] = $valv }
                else { $SEC[$key] = $valv }
            }
        }
        Remove-Item $inf -Force -ErrorAction SilentlyContinue
    }
}
function SecInt { param([string]$Key) if ($SEC.ContainsKey($Key)) { try { [int]$SEC[$Key] } catch { $null } } else { $null } }

# ---------------- net accounts (백업 소스) ----------------
$NA = @{}
foreach ($line in (net accounts 2>$null)) {
    if ($line -match '^(.+?):\s+(.+?)\s*$') { $NA[$matches[1].Trim()] = $matches[2].Trim() }
}
function NAInt {
    param([string]$Key)
    if ($NA.ContainsKey($Key)) {
        $v = $NA[$Key]
        if ($v -match 'Never|없음|해당 없음') { return 0 }
        $m = [regex]::Match($v, '\d+'); if ($m.Success) { return [int]$m.Value }
    }
    return $null
}

# ---------------- 로컬 계정/그룹 ----------------
function LocalUsers {
    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) { return Get-LocalUser -ErrorAction SilentlyContinue }
    return Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction SilentlyContinue
}
function AdminGroupMembers {
    try {
        if (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue) {
            return (Get-LocalGroupMember -SID "S-1-5-32-544" -ErrorAction Stop | ForEach-Object { $_.Name })
        }
    } catch {}
    $g = [ADSI]"WinNT://./Administrators,group"
    return @($g.Invoke("Members") | ForEach-Object { ([ADSI]$_).InvokeGet("Name") })
}

# ---------------- IIS ----------------
$IIS_ON = (SvcState "W3SVC") -ne $null -and (FeatureInstalled "Web-Server")
function IISConfig {
    param([string]$Filter, [string]$Name)
    try {
        Import-Module WebAdministration -ErrorAction Stop
        return (Get-WebConfigurationProperty -Filter $Filter -Name $Name -ErrorAction Stop).Value
    } catch { return $null }
}

$os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue)
$OS_NAME = if ($os) { $os.Caption.Trim() } else { "Windows" }
$HOSTN = $env:COMPUTERNAME

Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host " KISA Windows 취약점 점검 (W-01~W-82)  READ-ONLY" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host (" 호스트 : {0}" -f $HOSTN)
Write-Host (" OS     : {0}" -f $OS_NAME)
Write-Host (" 시각   : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
if (-not $IS_ADMIN) { Write-Host " 주의: 관리자 권한이 아니어서 보안정책/SAM/감사정책 등 일부 항목이 '수동확인'으로 표기됩니다." -ForegroundColor Yellow }
Write-Host ""

#==============================================================================
Write-Host "[ 1. 계정 관리 ]" -ForegroundColor White
#==============================================================================

# W-01 Administrator 계정 이름 변경
# [기준] 양호 - 기본 관리자(RID 500) 계정 이름이 'Administrator' 가 아님 / 취약 - 'Administrator'
$adminAcct = LocalUsers | Where-Object { $_.SID -like "*-500" -or ($_.SID.Value -like "*-500") }
$adminName = if ($adminAcct) { ($adminAcct | Select-Object -First 1).Name } else { $SEC["NewAdministratorName"] -replace '"','' }
if ($adminName -and $adminName -ne "Administrator") {
    Rep "W-01" "Administrator 계정 이름 변경" "GOOD" @("기본 관리자 계정 이름 = '$adminName' (Administrator 아님)")
} elseif ($adminName -eq "Administrator") {
    Rep "W-01" "Administrator 계정 이름 변경" "VULN" @("기본 관리자 계정 이름이 'Administrator' 그대로 → 이름 변경 필요")
} else {
    Rep "W-01" "Administrator 계정 이름 변경" "MAN" @("기본 관리자 계정 이름 확인 불가 → 관리자 권한으로 재점검")
}

# W-02 Guest 계정 상태
# [기준] 양호 - Guest 계정 비활성화 / 취약 - 활성화
$guest = LocalUsers | Where-Object { $_.SID -like "*-501" -or ($_.SID.Value -like "*-501") } | Select-Object -First 1
if ($guest) {
    $enabled = if ($guest.PSObject.Properties.Name -contains "Enabled") { $guest.Enabled } else { -not $guest.Disabled }
    if ($enabled) { Rep "W-02" "Guest 계정 상태" "VULN" @("Guest 계정($($guest.Name))이 활성화됨 → 비활성화 필요") }
    else          { Rep "W-02" "Guest 계정 상태" "GOOD" @("Guest 계정($($guest.Name)) 비활성화됨") }
} else {
    Rep "W-02" "Guest 계정 상태" "GOOD" @("Guest 계정 없음")
}

# W-03 불필요한 계정 제거
# [기준] 양호 - 불필요/의심 계정 없음 / 취약 - 사용하지 않는 활성 계정, 만료·미접속 계정 방치
$users = LocalUsers
$suspect = @()
foreach ($u in $users) {
    if ($u.SID -like "*-500" -or $u.SID -like "*-501" -or $u.SID.Value -like "*-500" -or $u.SID.Value -like "*-501") { continue }
    $name = $u.Name
    if ($name -in @("DefaultAccount","WDAGUtilityAccount","krbtgt")) { continue }
    $en = if ($u.PSObject.Properties.Name -contains "Enabled") { $u.Enabled } else { -not $u.Disabled }
    $last = if ($u.PSObject.Properties.Name -contains "LastLogon") { $u.LastLogon } else { $null }
    if ($en -and -not $last) { $suspect += "$name(로그온이력없음)" }
}
if ($suspect.Count -gt 0) {
    Rep "W-03" "불필요한 계정 제거" "VULN" @("사용 흔적 없는 활성 계정: $($suspect -join ', ') → 미사용이면 삭제/비활성화")
} else {
    $names = ($users | ForEach-Object { $_.Name }) -join ", "
    Rep "W-03" "불필요한 계정 제거" "MAN" @("로컬 계정 목록: $names", "각 계정의 사용 목적/필요성은 관리자 확인 필요")
}

# W-04 계정 잠금 임계값 설정
# [기준] 양호 - 계정 잠금 임계값이 1~5회 / 취약 - 0(제한없음) 또는 6회 이상
$lockCnt = SecInt "LockoutBadCount"; if ($null -eq $lockCnt) { $lockCnt = NAInt "잠금 임계값" }
if ($null -eq $lockCnt) { $lockCnt = NAInt "Lockout threshold" }
if ($null -ne $lockCnt -and $lockCnt -ge 1 -and $lockCnt -le 5) {
    Rep "W-04" "계정 잠금 임계값 설정" "GOOD" @("계정 잠금 임계값 = $lockCnt 회 (1~5회)")
} else {
    Rep "W-04" "계정 잠금 임계값 설정" "VULN" @("계정 잠금 임계값 = $(if($null -eq $lockCnt){'확인불가'}else{"$lockCnt 회"}) (기준: 1~5회)")
}

# W-05 해독 가능한 암호화를 사용하여 암호 저장
# [기준] 양호 - '해독 가능한 암호화를 사용하여 암호 저장' 사용 안 함(0) / 취약 - 사용(1)
$clear = SecInt "ClearTextPassword"
if ($null -eq $clear) {
    Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장" "MAN" @("보안정책(ClearTextPassword) 확인 불가 → 관리자 권한으로 재점검")
} elseif ($clear -eq 0) {
    Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장" "GOOD" @("역호환 암호화 저장 = 사용 안 함")
} else {
    Rep "W-05" "해독 가능한 암호화를 사용하여 암호 저장" "VULN" @("역호환 암호화 저장 = 사용 → 사용 안 함으로 변경")
}

# W-06 관리자 그룹에 최소한의 사용자 포함
# [기준] 양호 - Administrators 그룹에 불필요한 계정 없음 / 취약 - 불필요/미접속 계정 포함
$admins = @(AdminGroupMembers)
$admins = $admins | Where-Object { $_ }
if ($admins.Count -le 2) {
    Rep "W-06" "관리자 그룹에 최소한의 사용자 포함" "GOOD" @("Administrators 그룹 구성원: $($admins -join ', ')")
} else {
    Rep "W-06" "관리자 그룹에 최소한의 사용자 포함" "MAN" @("Administrators 그룹 구성원($($admins.Count)명): $($admins -join ', ')", "각 구성원의 관리자 권한 필요성 확인")
}

#==============================================================================
Write-Host "[ 2. 서비스 관리 ]" -ForegroundColor White
#==============================================================================

# W-07 공유 권한 및 사용자 그룹 설정
# [기준] 양호 - Everyone 에 전체 제어/변경 권한이 부여된 공유 없음 / 취약 - 존재
$shares = Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 0 -and $_.Name -notmatch '\$$' }
$everyoneShare = @()
foreach ($s in $shares) {
    try {
        $acl = Get-CimInstance -ClassName Win32_LogicalShareSecuritySetting -Filter "Name='$($s.Name)'" -ErrorAction Stop
        $sd = $acl | Invoke-CimMethod -MethodName GetSecurityDescriptor
        foreach ($ace in $sd.Descriptor.DACL) {
            if ($ace.Trustee.Name -in @("Everyone","모든 사람") -and ($ace.AccessMask -band 0x1F01FF)) {
                $everyoneShare += "$($s.Name)"
            }
        }
    } catch {}
}
if ($shares.Count -eq 0) {
    Rep "W-07" "공유 권한 및 사용자 그룹 설정" "NA" @("사용자 정의 공유 없음")
} elseif ($everyoneShare.Count -gt 0) {
    Rep "W-07" "공유 권한 및 사용자 그룹 설정" "VULN" @("Everyone 에 광범위 권한이 부여된 공유: $($everyoneShare -join ', ')")
} else {
    Rep "W-07" "공유 권한 및 사용자 그룹 설정" "GOOD" @("공유($($shares.Name -join ', '))에 Everyone 광범위 권한 없음")
}

# W-08 하드디스크 기본 공유 제거
# [기준] 양호 - AutoShareServer/AutoShareWks = 0 (기본 관리 공유 자동 생성 안 함) / 취약 - 1 또는 미설정
$autoShare = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "AutoShareServer"
if ($null -eq $autoShare) { $autoShare = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "AutoShareWks" }
if ($autoShare -eq 0) {
    Rep "W-08" "하드디스크 기본 공유 제거" "GOOD" @("AutoShareServer=0 → 기본 관리 공유(C\$, ADMIN\$) 자동 생성 안 함")
} else {
    $adminShares = (Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\$$' } | ForEach-Object { $_.Name }) -join ", "
    Rep "W-08" "하드디스크 기본 공유 제거" "VULN" @("AutoShareServer 미설정/1 → 기본 공유 활성: $adminShares", "레지스트리에 AutoShareServer=0 설정 권장")
}

# W-09 불필요한 서비스 제거
# [기준] 양호 - Alerter, Messenger, Remote Registry 등 불필요·위험 서비스 중지 / 취약 - 실행 중
$riskySvc = @("Alerter","Messenger","Browser","RemoteRegistry","SharedAccess","Telnet","TlntSvr","SNMPTRAP","simptcp","W3SVC-Legacy")
$running = @()
foreach ($rs in $riskySvc) { if (SvcRunning $rs) { $running += $rs } }
if ($running.Count -eq 0) {
    Rep "W-09" "불필요한 서비스 제거" "GOOD" @("Alerter/Messenger/RemoteRegistry/Telnet 등 위험 서비스 미실행")
} else {
    Rep "W-09" "불필요한 서비스 제거" "VULN" @("실행 중인 불필요·위험 서비스: $($running -join ', ') → 미사용 시 중지/사용 안 함")
}

# W-10 IIS 서비스 구동 점검
# [기준] 양호 - IIS 미사용 / 취약 - 불필요하게 실행 중
if (-not $IIS_ON) {
    Rep "W-10" "IIS 서비스 구동 점검" "GOOD" @("IIS(W3SVC) 미설치/미실행")
} else {
    Rep "W-10" "IIS 서비스 구동 점검" "MAN" @("IIS 실행 중 → 웹 서버 용도가 맞는지, 불필요 시 제거 확인")
}

# --- IIS 세부 (W-11 ~ W-23, W-33) : IIS 미설치면 N/A ---
function IISna { param([string]$c, [string]$t) Rep $c $t "NA" @("IIS 미설치/미실행 → 점검 대상 없음") }
if (-not $IIS_ON) {
    IISna "W-11" "IIS 디렉토리 리스팅 제거";      IISna "W-12" "IIS CGI 실행 제한"
    IISna "W-13" "IIS 상위 디렉토리 접근 금지";   IISna "W-14" "IIS 불필요한 파일 제거"
    IISna "W-15" "IIS 웹 프로세스 권한 제한";     IISna "W-16" "IIS 링크 사용금지"
    IISna "W-17" "IIS 파일 업로드 및 다운로드 제한"; IISna "W-18" "IIS DB 연결 취약점 점검"
    IISna "W-19" "IIS 가상 디렉토리 삭제";        IISna "W-20" "IIS 데이터 파일 ACL 적용"
    IISna "W-21" "IIS 미사용 스크립트 매핑 제거"; IISna "W-22" "IIS Exec 명령어 쉘 호출 진단"
    IISna "W-23" "IIS WebDAV 비활성화";           IISna "W-33" "IIS 웹서비스 정보 숨김"
} else {
    # W-11 디렉토리 리스팅
    $dirBrowse = IISConfig "/system.webServer/directoryBrowse" "enabled"
    if ($dirBrowse -eq $false) { Rep "W-11" "IIS 디렉토리 리스팅 제거" "GOOD" @("directoryBrowse.enabled = false") }
    else { Rep "W-11" "IIS 디렉토리 리스팅 제거" "VULN" @("디렉터리 검색(directory browsing) 활성 → 비활성화 필요") }

    # W-12 CGI/ISAPI 제한
    $cgiRestrict = $null
    try { Import-Module WebAdministration -ErrorAction Stop
          $cgiRestrict = (Get-WebConfiguration "/system.webServer/security/isapiCgiRestriction").notListedCgisAllowed } catch {}
    if ($cgiRestrict -eq $false -or $null -eq $cgiRestrict) { Rep "W-12" "IIS CGI 실행 제한" "MAN" @("ISAPI/CGI 제한 목록 검토 필요 (notListedCgisAllowed=$cgiRestrict)") }
    else { Rep "W-12" "IIS CGI 실행 제한" "VULN" @("목록에 없는 CGI 실행 허용됨") }

    # W-13 상위 디렉토리(parent path)
    $parentPath = IISConfig "/system.webServer/asp" "enableParentPaths"
    if ($parentPath -eq $true) { Rep "W-13" "IIS 상위 디렉토리 접근 금지" "VULN" @("ASP enableParentPaths = true → '..' 경로 접근 가능") }
    else { Rep "W-13" "IIS 상위 디렉토리 접근 금지" "GOOD" @("ASP enableParentPaths = false/미사용") }

    # W-14 불필요한 파일(샘플)
    $samplePaths = @("$env:SystemDrive\inetpub\scripts","$env:SystemDrive\inetpub\iissamples","$env:windir\help\iishelp","$env:SystemDrive\inetpub\AdminScripts")
    $found = $samplePaths | Where-Object { Test-Path $_ }
    if ($found) { Rep "W-14" "IIS 불필요한 파일 제거" "VULN" @("기본 샘플/스크립트 디렉터리 존재: $($found -join ', ')") }
    else { Rep "W-14" "IIS 불필요한 파일 제거" "GOOD" @("IIS 기본 샘플/AdminScripts 디렉터리 없음") }

    # W-15 웹 프로세스 권한
    Rep "W-15" "IIS 웹 프로세스 권한 제한" "MAN" @("응용 프로그램 풀 ID가 ApplicationPoolIdentity/전용 계정인지, LocalSystem 아닌지 확인")

    # W-16 심볼릭 링크
    Rep "W-16" "IIS 링크 사용금지" "MAN" @("웹 루트 내 심볼릭 링크/정션 존재 여부 수동 확인 (dir /AL /S)")

    # W-17 업로드/다운로드 크기 제한
    $maxLen = IISConfig "/system.webServer/security/requestFiltering/requestLimits" "maxAllowedContentLength"
    if ($maxLen -and [int64]$maxLen -le 30000000) { Rep "W-17" "IIS 파일 업로드 및 다운로드 제한" "GOOD" @("maxAllowedContentLength = $maxLen bytes") }
    else { Rep "W-17" "IIS 파일 업로드 및 다운로드 제한" "VULN" @("요청 크기 제한(maxAllowedContentLength) 미설정/과대 (=$maxLen)") }

    # W-18 DB 연결(.mdb 등)
    Rep "W-18" "IIS DB 연결 취약점 점검" "MAN" @("웹 루트에 .mdb/.mdf 등 DB 파일 노출 여부, 연결문자열 평문 저장 여부 확인")

    # W-19 가상 디렉토리(IISADMPWD 등)
    $badVdir = @()
    try { Import-Module WebAdministration -ErrorAction Stop
          $badVdir = Get-WebVirtualDirectory | Where-Object { $_.Path -match 'IISADMPWD|MSADC|Scripts|IISSamples|IISAdmin' } | ForEach-Object { $_.Path } } catch {}
    if ($badVdir) { Rep "W-19" "IIS 가상 디렉토리 삭제" "VULN" @("불필요한 기본 가상 디렉터리: $($badVdir -join ', ')") }
    else { Rep "W-19" "IIS 가상 디렉토리 삭제" "GOOD" @("IISADMPWD/MSADC 등 기본 가상 디렉터리 없음") }

    # W-20 데이터 파일 ACL
    Rep "W-20" "IIS 데이터 파일 ACL 적용" "MAN" @("웹 콘텐츠 디렉터리에 Everyone 쓰기 권한 없는지, IUSR 최소 권한인지 확인")

    # W-21 스크립트 매핑
    $badMap = @()
    try { Import-Module WebAdministration -ErrorAction Stop
          $handlers = Get-WebConfiguration "/system.webServer/handlers" | Select-Object -ExpandProperty Collection
          $badMap = $handlers | Where-Object { $_.path -match '\.(htr|idc|stm|shtm|shtml|printer|htw|ida|idq)$' } | ForEach-Object { $_.path } } catch {}
    if ($badMap) { Rep "W-21" "IIS 미사용 스크립트 매핑 제거" "VULN" @("불필요 스크립트 매핑: $($badMap -join ', ')") }
    else { Rep "W-21" "IIS 미사용 스크립트 매핑 제거" "GOOD" @(".htr/.idc/.printer 등 위험 스크립트 매핑 없음") }

    # W-22 Exec 쉘 호출
    Rep "W-22" "IIS Exec 명령어 쉘 호출 진단" "MAN" @("cmd.exe/command.com 매핑 또는 SSI #exec 허용 여부 확인")

    # W-23 WebDAV
    $webdav = FeatureInstalled "Web-DAV-Publishing"
    if ($webdav) { Rep "W-23" "IIS WebDAV 비활성화" "VULN" @("WebDAV Publishing 기능 설치됨 → 미사용 시 제거") }
    else { Rep "W-23" "IIS WebDAV 비활성화" "GOOD" @("WebDAV 미설치") }

    # W-33 웹서비스 정보 숨김
    $srvHdr = IISConfig "/system.webServer/security/requestFiltering" "removeServerHeader"
    if ($srvHdr -eq $true) { Rep "W-33" "IIS 웹서비스 정보 숨김" "GOOD" @("removeServerHeader = true (Server 헤더 제거)") }
    else { Rep "W-33" "IIS 웹서비스 정보 숨김" "VULN" @("HTTP 응답에 Server/X-Powered-By 헤더로 IIS 버전 노출 → 제거 필요") }
}

# W-24 NetBIOS 바인딩 서비스 구동 점검
# [기준] 양호 - 모든 인터페이스에서 NetBIOS over TCP/IP 비활성 / 취약 - 활성
$nbtEnabled = $false
try {
    $adapters = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop
    foreach ($a in $adapters) { if ($a.TcpipNetbiosOptions -ne 2) { $nbtEnabled = $true } }
} catch { $nbtEnabled = $true }
if ($nbtEnabled) { Rep "W-24" "NetBIOS 바인딩 서비스 구동 점검" "VULN" @("일부 인터페이스에서 NetBIOS over TCP/IP 활성 → '사용 안 함'으로 설정") }
else            { Rep "W-24" "NetBIOS 바인딩 서비스 구동 점검" "GOOD" @("모든 인터페이스에서 NetBIOS over TCP/IP 비활성") }

# --- FTP (W-25 ~ W-28) ---
$FTP_ON = (SvcRunning "FTPSVC") -or (SvcRunning "MSFTPSVC") -or (PortListening 21)
if (-not $FTP_ON) {
    Rep "W-25" "FTP 서비스 구동 점검" "GOOD" @("FTP 서비스 미실행")
    Rep "W-26" "FTP 디렉토리 접근권한 설정" "NA" @("FTP 미실행")
    Rep "W-27" "Anonymous FTP 금지" "NA" @("FTP 미실행")
    Rep "W-28" "FTP 접근 제어 설정" "NA" @("FTP 미실행")
} else {
    Rep "W-25" "FTP 서비스 구동 점검" "MAN" @("FTP 서비스 실행 중 → 업무상 필요 여부 확인, 미사용 시 중지")
    $anon = IISConfig "/system.applicationHost/sites/site/ftpServer/security/authentication/anonymousAuthentication" "enabled"
    if ($anon -eq $true) { Rep "W-27" "Anonymous FTP 금지" "VULN" @("FTP 익명 인증 활성화됨") }
    else { Rep "W-27" "Anonymous FTP 금지" "GOOD" @("FTP 익명 인증 비활성") }
    Rep "W-26" "FTP 디렉토리 접근권한 설정" "MAN" @("FTP 홈 디렉터리 권한(Everyone 쓰기 금지) 확인")
    Rep "W-28" "FTP 접근 제어 설정" "MAN" @("IP 주소/도메인 제한(ipSecurity) 설정 여부 확인")
}

# --- DNS (W-29, W-37) ---
$DNS_ON = (SvcRunning "DNS") -and (FeatureInstalled "DNS")
if (-not $DNS_ON) {
    Rep "W-29" "DNS Zone Transfer 설정" "NA" @("DNS 서버 역할 미사용")
    Rep "W-37" "DNS 서비스 구동 점검" "GOOD" @("DNS 서버 역할 미사용")
} else {
    $zt = @()
    try {
        Import-Module DnsServer -ErrorAction Stop
        foreach ($z in (Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq "Primary" })) {
            $x = Get-DnsServerZoneTransferPolicy -ErrorAction SilentlyContinue
            $zi = Get-DnsServerZone -Name $z.ZoneName
            if ($zi.SecureSecondaries -eq "TransferAnyServer") { $zt += $z.ZoneName }
        }
    } catch {}
    if ($zt.Count -gt 0) { Rep "W-29" "DNS Zone Transfer 설정" "VULN" @("모든 서버로 영역 전송 허용된 영역: $($zt -join ', ')") }
    else { Rep "W-29" "DNS Zone Transfer 설정" "GOOD" @("영역 전송이 특정 서버로 제한됨") }
    Rep "W-37" "DNS 서비스 구동 점검" "MAN" @("DNS 서버 운영 중 → 최신 패치 적용/재귀 질의 제한 확인")
}

# W-30 RDS(Remote Data Services) 제거
# [기준] 양호 - RDS 관련 레지스트리 핸들러 없음 / 취약 - 존재
$rdsKeys = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\RDSServer.DataFactory",
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\AdvancedDataFactory",
    "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC\Parameters\ADCLaunch\VbBusObj.VbBusObjCls"
)
$rdsFound = $rdsKeys | Where-Object { Test-Path $_ }
if (-not $IIS_ON) { Rep "W-30" "RDS(Remote Data Services) 제거" "NA" @("IIS 미사용 → RDS 위협 없음") }
elseif ($rdsFound) { Rep "W-30" "RDS(Remote Data Services) 제거" "VULN" @("RDS 관련 레지스트리 존재: $($rdsFound -join ', ')") }
else { Rep "W-30" "RDS(Remote Data Services) 제거" "GOOD" @("RDS ADCLaunch 레지스트리 없음") }

# W-31 최신 서비스팩 적용
$build = "$($os.Version) (Build $($os.BuildNumber))"
Rep "W-31" "최신 서비스팩 적용" "MAN" @("OS 버전: $OS_NAME $build", "벤더 지원 종료 여부 및 최신 누적 업데이트 적용 상태 확인")

# W-32 터미널 서비스 암호화 수준 설정
# [기준] 양호 - RDP 최소 암호화 수준 = '높음'(3) 이상 / 취약 - 그 이하
$rdpEnc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "MinEncryptionLevel"
if ($rdpEnc -ge 3) { Rep "W-32" "터미널 서비스 암호화 수준 설정" "GOOD" @("RDP MinEncryptionLevel = $rdpEnc (높음 이상)") }
elseif ($null -eq $rdpEnc) { Rep "W-32" "터미널 서비스 암호화 수준 설정" "MAN" @("RDP-Tcp MinEncryptionLevel 값 없음 → 정책 확인") }
else { Rep "W-32" "터미널 서비스 암호화 수준 설정" "VULN" @("RDP MinEncryptionLevel = $rdpEnc (기준: 3=높음 이상)") }

# --- SNMP (W-34 ~ W-36) ---
$SNMP_ON = (SvcRunning "SNMP") -or (SvcState "SNMP")
if (-not $SNMP_ON) {
    Rep "W-34" "SNMP 서비스 구동 점검" "GOOD" @("SNMP 서비스 미설치/미실행")
    Rep "W-35" "SNMP 서비스 커뮤니티스트링의 복잡성 설정" "NA" @("SNMP 미사용")
    Rep "W-36" "SNMP Access control 설정" "NA" @("SNMP 미사용")
} else {
    Rep "W-34" "SNMP 서비스 구동 점검" "VULN" @("SNMP 서비스 실행/설치됨 → 미사용 시 제거")
    $comm = @()
    try { $comm = (Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\ValidCommunities").Property } catch {}
    if ($comm -contains "public" -or $comm -contains "private") { Rep "W-35" "SNMP 서비스 커뮤니티스트링의 복잡성 설정" "VULN" @("커뮤니티 스트링에 public/private 사용: $($comm -join ', ')") }
    elseif ($comm.Count -gt 0) { Rep "W-35" "SNMP 서비스 커뮤니티스트링의 복잡성 설정" "MAN" @("커뮤니티 스트링: $($comm -join ', ') → 복잡도(영문+숫자 조합, 길이) 확인") }
    else { Rep "W-35" "SNMP 서비스 커뮤니티스트링의 복잡성 설정" "MAN" @("커뮤니티 스트링 확인 불가") }
    $mgrs = @()
    try { $mgrs = (Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\PermittedManagers").Property } catch {}
    if ($mgrs.Count -gt 0) { Rep "W-36" "SNMP Access control 설정" "GOOD" @("허용 관리자(PermittedManagers) 지정됨: $($mgrs.Count)개") }
    else { Rep "W-36" "SNMP Access control 설정" "VULN" @("SNMP 허용 관리자 제한 없음 (모든 호스트 허용)") }
}

# W-38 HTTP/FTP/SMTP 배너 차단
Rep "W-38" "HTTP/FTP/SMTP 배너 차단" "MAN" @("운영 중인 서비스의 응답 배너에서 제품/버전 정보 노출 여부 확인 (W-33/FTP 배너 포함)")

# W-39 Telnet 보안 설정
# [기준] 양호 - Telnet 서버 미사용 / 취약 - 실행 중
if ((SvcRunning "TlntSvr") -or (PortListening 23)) {
    Rep "W-39" "Telnet 보안 설정" "VULN" @("Telnet 서버 실행 중 → SSH/RDP 로 대체, 미사용 시 제거")
} else {
    Rep "W-39" "Telnet 보안 설정" "GOOD" @("Telnet 서버 미실행")
}

# W-40 불필요한 ODBC/OLE-DB 데이터소스와 드라이브 제거
$dsn = @()
try { $dsn += (Get-ChildItem "HKLM:\SOFTWARE\ODBC\ODBC.INI" -ErrorAction Stop | Where-Object { $_.PSChildName -ne "ODBC Data Sources" } | ForEach-Object { $_.PSChildName }) } catch {}
if ($dsn.Count -eq 0) { Rep "W-40" "불필요한 ODBC/OLE-DB 데이터소스와 드라이브 제거" "GOOD" @("시스템 ODBC DSN 없음") }
else { Rep "W-40" "불필요한 ODBC/OLE-DB 데이터소스와 드라이브 제거" "MAN" @("시스템 ODBC DSN: $($dsn -join ', ') → 미사용 항목/평문 자격증명 확인") }

# W-41 원격터미널 접속 타임아웃 설정
# [기준] 양호 - RDP 유휴 세션 시간 제한(MaxIdleTime) 설정 / 취약 - 미설정
$maxIdle = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" "MaxIdleTime"
if ($null -eq $maxIdle) { $maxIdle = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "MaxIdleTime" }
if ($maxIdle -and $maxIdle -gt 0 -and $maxIdle -le 3600000) {
    Rep "W-41" "원격터미널 접속 타임아웃 설정" "GOOD" @("RDP 유휴 세션 제한 = $([math]::Round($maxIdle/60000)) 분")
} else {
    Rep "W-41" "원격터미널 접속 타임아웃 설정" "VULN" @("RDP 유휴 세션 시간 제한 미설정 → 화면 잠금/세션 종료 정책 적용")
}

# W-42 예약된 작업에 의심스러운 명령 등록 여부 점검
$tasks = @()
try {
    $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' -and $_.State -ne "Disabled" } |
             ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }
} catch { $tasks = (schtasks /query /fo LIST 2>$null | Select-String "TaskName:" | ForEach-Object { ($_ -split ":",2)[1].Trim() }) }
if ($tasks.Count -eq 0) {
    Rep "W-42" "예약된 작업에 의심스러운 명령 등록 여부 점검" "GOOD" @("사용자 정의 활성 예약 작업 없음")
} else {
    Rep "W-42" "예약된 작업에 의심스러운 명령 등록 여부 점검" "MAN" @("사용자 정의 예약 작업($($tasks.Count)개): $(( $tasks | Select-Object -First 10) -join ', ')", "각 작업의 실행 명령/등록 경위 확인")
}

#==============================================================================
Write-Host "[ 3. 패치 관리 ]" -ForegroundColor White
#==============================================================================

# W-43 최신 HOT FIX 적용
$hf = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
$hfDate = if ($hf -and $hf.InstalledOn) { $hf.InstalledOn.ToString("yyyy-MM-dd") } else { "확인불가" }
$daysAgo = if ($hf -and $hf.InstalledOn) { (New-TimeSpan -Start $hf.InstalledOn -End (Get-Date)).Days } else { 9999 }
if ($daysAgo -le 90) {
    Rep "W-43" "최신 HOT FIX 적용" "MAN" @("최근 업데이트: $($hf.HotFixID) ($hfDate, ${daysAgo}일 전)", "정기 패치 관리 정책/절차 수립 여부는 인터뷰 확인")
} else {
    Rep "W-43" "최신 HOT FIX 적용" "VULN" @("최근 업데이트 적용일 $hfDate (약 ${daysAgo}일 전) → 90일 이상 미적용", "누적 업데이트/보안 패치 적용 필요")
}

# W-44 백신 프로그램 설치
# [기준] 양호 - 백신(실시간 감시 포함) 설치·동작 / 취약 - 미설치
$av = $null
try { $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop } catch {}
$defender = $null
try { $defender = Get-MpComputerStatus -ErrorAction Stop } catch {}
if ($av) {
    $names = ($av | ForEach-Object { $_.displayName }) -join ", "
    Rep "W-44" "백신 프로그램 설치" "GOOD" @("백신 제품 등록됨: $names")
} elseif ($defender -and $defender.AntivirusEnabled) {
    Rep "W-44" "백신 프로그램 설치" "GOOD" @("Microsoft Defender 실시간 보호 활성 (서명 $($defender.AntivirusSignatureLastUpdated))")
} else {
    Rep "W-44" "백신 프로그램 설치" "VULN" @("동작 중인 백신(실시간 감시) 미확인 → 백신 설치/활성화 필요")
}

# W-45 로그의 정기적 검토 및 보고
Rep "W-45" "로그의 정기적 검토 및 보고" "MAN" @("이벤트 로그·보안 로그의 정기 검토 및 보고 체계 수립 여부는 인터뷰 확인")

#==============================================================================
Write-Host "[ 4. 로그 관리 ]" -ForegroundColor White
#==============================================================================

# W-46 정책에 따른 시스템 로깅 설정 (감사 정책)
# [기준] 양호 - 계정 로그온/계정 관리/로그온/개체 액세스/정책 변경/권한 사용/시스템 이벤트 감사(성공+실패) / 취약 - 주요 범주 미설정
if ($IS_ADMIN) {
    $ap = auditpol /get /category:* 2>$null
    $need = @("Logon","Logoff","Account Lockout","User Account Management","Security Group Management",
              "Audit Policy Change","Sensitive Privilege Use","Security State Change","IPsec Driver","Other System Events")
    $missing = @()
    foreach ($n in $need) {
        $l = $ap | Select-String -SimpleMatch $n | Select-Object -First 1
        if (-not $l -or $l -match "No Auditing|감사 안 함") { $missing += $n }
    }
    if ($missing.Count -eq 0) { Rep "W-46" "정책에 따른 시스템 로깅 설정" "GOOD" @("주요 감사 범주(로그온/계정 관리/정책 변경/권한 사용/시스템) 활성") }
    else { Rep "W-46" "정책에 따른 시스템 로깅 설정" "VULN" @("감사 미설정 항목: $($missing -join ', ') → 성공/실패 감사 설정") }
} else {
    Rep "W-46" "정책에 따른 시스템 로깅 설정" "MAN" @("감사 정책(auditpol)은 관리자 권한 필요 → root/관리자로 재점검")
}

# W-47 이벤트 로그 관리 설정
# [기준] 양호 - 보안 로그 최대 크기 >= 80MB(권고), 응용/시스템 >= 10MB, 보존 정책 설정 / 취약 - 작음
$logbad = @()
foreach ($lg in @(@{n="Security";min=83886080}, @{n="Application";min=10485760}, @{n="System";min=10485760})) {
    $sz = RegVal ("HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\" + $lg.n) "MaxSize"
    if ($null -eq $sz) { $sz = (Get-WinEvent -ListLog $lg.n -ErrorAction SilentlyContinue).MaximumSizeInBytes }
    if ($null -eq $sz -or $sz -lt $lg.min) { $logbad += ("{0}({1}MB)" -f $lg.n, [math]::Round(($sz/1MB),0)) }
}
if ($logbad.Count -eq 0) { Rep "W-47" "이벤트 로그 관리 설정" "GOOD" @("보안 로그 >= 80MB, 응용/시스템 로그 >= 10MB") }
else { Rep "W-47" "이벤트 로그 관리 설정" "VULN" @("로그 크기 기준 미달: $($logbad -join ', ') (보안 80MB / 응용·시스템 10MB 권고)") }

# W-48 원격으로 액세스 할 수 있는 레지스트리 경로
# [기준] 양호 - AllowedExactPaths/AllowedPaths 가 최소한으로 제한 / 취약 - 과도하게 개방
$allowedPaths = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\SecurePipeServers\winreg\AllowedPaths" "Machine"
$restrictNull = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "RestrictAnonymous"
if ($allowedPaths -and $allowedPaths.Count -le 8) {
    Rep "W-48" "원격으로 액세스 할 수 있는 레지스트리 경로" "GOOD" @("AllowedPaths 항목 $($allowedPaths.Count)개로 제한됨")
} elseif ($null -eq $allowedPaths) {
    Rep "W-48" "원격으로 액세스 할 수 있는 레지스트리 경로" "MAN" @("winreg\AllowedPaths\Machine 값 확인 필요")
} else {
    Rep "W-48" "원격으로 액세스 할 수 있는 레지스트리 경로" "VULN" @("원격 접근 허용 레지스트리 경로가 과다($($allowedPaths.Count)개)")
}

# W-49 원격에서 익명으로 접근할 수 있는 공유
# [기준] 양호 - NullSessionShares / NullSessionPipes 비어있음 / 취약 - 값 존재
$nullShares = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "NullSessionShares"
$nullShares = @($nullShares | Where-Object { $_ -and $_.Trim() -ne "" })
if ($nullShares.Count -eq 0) { Rep "W-49" "원격에서 익명으로 접근할 수 있는 공유" "GOOD" @("NullSessionShares 비어있음") }
else { Rep "W-49" "원격에서 익명으로 접근할 수 있는 공유" "VULN" @("익명 접근 허용 공유: $($nullShares -join ', ')") }

# W-50 Anonymous 로그온 금지 / SAM 익명 열거 제한
# [기준] 양호 - RestrictAnonymous=1, RestrictAnonymousSAM=1, EveryoneIncludesAnonymous=0 / 취약 - 아님
$ra = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "RestrictAnonymous"
$rasam = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "RestrictAnonymousSAM"
$eia = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "EveryoneIncludesAnonymous"
if ($rasam -eq 1 -and $eia -eq 0) { Rep "W-50" "Anonymous 로그온 금지" "GOOD" @("RestrictAnonymousSAM=1, EveryoneIncludesAnonymous=0 (RestrictAnonymous=$ra)") }
else { Rep "W-50" "Anonymous 로그온 금지" "VULN" @("RestrictAnonymousSAM=$rasam, EveryoneIncludesAnonymous=$eia (기준: 1 / 0)") }

# W-69 사용자별 홈 디렉토리 권한 (로그관리 그룹 편성상 여기에)
Rep "W-69" "공유 폴더/홈 디렉토리 권한 설정" "MAN" @("사용자 프로파일/공유 폴더에 Everyone·Users 쓰기 권한 없는지 수동 확인")

#==============================================================================
Write-Host "[ 5. 보안 관리 ]" -ForegroundColor White
#==============================================================================

function RegYesNo {
    param([string]$Code, [string]$Title, [string]$Path, [string]$Name, $Want, [string]$GoodMsg, [string]$BadMsg)
    $v = RegVal $Path $Name
    if ($null -eq $v) { Rep $Code $Title "MAN" @("$Name 값 없음 → 정책 확인 필요") }
    elseif ($v -eq $Want) { Rep $Code $Title "GOOD" @("$GoodMsg (현재값 $v)") }
    else { Rep $Code $Title "VULN" @("$BadMsg (현재값 $v, 기준 $Want)") }
}

# W-46 패스워드 복잡성  → 번호 재사용 방지 위해 W-51~ 로 이어서 매핑
# W-51 패스워드 복잡성 설정
$pc = SecInt "PasswordComplexity"
if ($pc -eq 1) { Rep "W-51" "패스워드 복잡성 설정" "GOOD" @("암호 복잡성 사용") }
elseif ($null -eq $pc) { Rep "W-51" "패스워드 복잡성 설정" "MAN" @("PasswordComplexity 확인 불가 (관리자 권한 필요)") }
else { Rep "W-51" "패스워드 복잡성 설정" "VULN" @("암호 복잡성 사용 안 함 → 사용으로 변경") }

# W-52 패스워드 최소 암호 길이
$ml = SecInt "MinimumPasswordLength"; if ($null -eq $ml) { $ml = NAInt "최소 암호 길이"; if ($null -eq $ml) { $ml = NAInt "Minimum password length" } }
if ($ml -ge 8) { Rep "W-52" "패스워드 최소 암호 길이" "GOOD" @("최소 암호 길이 = $ml (>=8)") }
else { Rep "W-52" "패스워드 최소 암호 길이" "VULN" @("최소 암호 길이 = $(if($null -eq $ml){'확인불가'}else{$ml}) (기준: 8자 이상)") }

# W-53 패스워드 최대 사용 기간
$mxa = SecInt "MaximumPasswordAge"; if ($null -eq $mxa) { $mxa = NAInt "최대 암호 사용 기간(일)"; if ($null -eq $mxa) { $mxa = NAInt "Maximum password age (days)" } }
if ($mxa -ge 1 -and $mxa -le 90) { Rep "W-53" "패스워드 최대 사용 기간" "GOOD" @("최대 사용 기간 = $mxa 일 (1~90)") }
else { Rep "W-53" "패스워드 최대 사용 기간" "VULN" @("최대 사용 기간 = $(if($mxa -eq 0){'무제한'}else{$mxa}) 일 (기준: 1~90)") }

# W-54 패스워드 최소 사용 기간
$mna = SecInt "MinimumPasswordAge"; if ($null -eq $mna) { $mna = NAInt "최소 암호 사용 기간(일)" }
if ($mna -ge 1) { Rep "W-54" "패스워드 최소 사용 기간" "GOOD" @("최소 사용 기간 = $mna 일 (>=1)") }
else { Rep "W-54" "패스워드 최소 사용 기간" "VULN" @("최소 사용 기간 = 0 일 (기준: 1일 이상)") }

# W-55 최근 암호 기억(패스워드 히스토리)
$ph = SecInt "PasswordHistorySize"; if ($null -eq $ph) { $ph = NAInt "암호 기록 유지" }
if ($ph -ge 12) { Rep "W-55" "최근 암호 기억" "GOOD" @("암호 기록 = $ph 개 (>=12)") }
else { Rep "W-55" "최근 암호 기억" "VULN" @("암호 기록 = $(if($null -eq $ph){'확인불가'}else{$ph}) 개 (기준: 12개 이상)") }

# W-56 계정 잠금 기간
$ld = SecInt "LockoutDuration"; if ($null -eq $ld) { $ld = NAInt "잠금 기간(분)" }
if ($ld -ge 60) { Rep "W-56" "계정 잠금 기간 설정" "GOOD" @("계정 잠금 기간 = $ld 분 (>=60)") }
else { Rep "W-56" "계정 잠금 기간 설정" "VULN" @("계정 잠금 기간 = $(if($null -eq $ld){'확인불가'}else{$ld}) 분 (기준: 60분 이상)") }

# W-57 마지막 사용자 이름 표시 안 함
RegYesNo "W-57" "마지막 사용자 이름 표시 안 함" "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DontDisplayLastUserName" 1 `
    "로그온 화면에 마지막 사용자 이름 표시 안 함" "마지막 사용자 이름이 표시됨 → '표시 안 함'으로 설정"

# W-58 로그온하지 않고 시스템 종료 허용 안 함
RegYesNo "W-58" "로그온하지 않고 시스템 종료 허용 안 함" "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "ShutdownWithoutLogon" 0 `
    "로그온 화면에서 시스템 종료 불가" "로그온 없이 시스템 종료 가능 → '사용 안 함'으로 설정"

# W-59 원격 시스템에서 강제로 시스템 종료
$rsd = $PRIV["SeRemoteShutdownPrivilege"]
if ($rsd -and ($rsd -replace '\*','') -match '^S-1-5-32-544$|^Administrators$|^\s*$') {
    Rep "W-59" "원격 시스템에서 강제로 시스템 종료" "GOOD" @("SeRemoteShutdownPrivilege = Administrators 만 ($rsd)")
} elseif ($null -eq $rsd) {
    Rep "W-59" "원격 시스템에서 강제로 시스템 종료" "MAN" @("권한 할당(SeRemoteShutdownPrivilege) 확인 불가 (관리자 권한 필요)")
} else {
    Rep "W-59" "원격 시스템에서 강제로 시스템 종료" "VULN" @("SeRemoteShutdownPrivilege 에 Administrators 외 대상 포함: $rsd")
}

# W-60 보안 감사를 로그할 수 없는 경우 즉시 시스템 종료
RegYesNo "W-60" "보안 감사 로그 불가 시 즉시 시스템 종료" "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "CrashOnAuditFail" 0 `
    "감사 실패 시 시스템 종료 안 함(가용성)" "감사 실패 시 시스템 강제 종료 설정 → '사용 안 함' 권장"

# W-61 SAM 계정과 공유의 익명 열거 허용 안 함
RegYesNo "W-61" "SAM 계정과 공유의 익명 열거 허용 안 함" "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "RestrictAnonymousSAM" 1 `
    "SAM 계정 익명 열거 제한" "SAM 계정 익명 열거 허용 → '사용'으로 설정"

# W-62 Autologon 기능 제어
$autoLogon = RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoAdminLogon"
$defPw = RegVal "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "DefaultPassword"
if (($autoLogon -eq 1 -or $autoLogon -eq "1") -or $defPw) {
    Rep "W-62" "Autologon 기능 제어" "VULN" @("자동 로그온 활성(AutoAdminLogon=$autoLogon)" + $(if($defPw){", DefaultPassword 레지스트리에 평문 저장"}else{""}))
} else {
    Rep "W-62" "Autologon 기능 제어" "GOOD" @("자동 로그온 비활성 (AutoAdminLogon 미설정/0)")
}

# W-63 이동식 미디어 포맷 및 꺼내기 허용
RegYesNo "W-63" "이동식 미디어 포맷 및 꺼내기 허용" "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AllocateDASD" 0 `
    "로그온한 관리자만 이동식 미디어 접근 (0)" "이동식 미디어 접근 제한 미흡 → 0(Administrators) 권장"

# W-64 디스크볼륨 암호화 설정 (BitLocker)
$bl = $null
try { $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop } catch {}
if ($bl -and $bl.ProtectionStatus -eq "On") {
    Rep "W-64" "디스크볼륨 암호화 설정" "GOOD" @("시스템 볼륨($env:SystemDrive) BitLocker 보호 활성")
} else {
    Rep "W-64" "디스크볼륨 암호화 설정" "MAN" @("시스템 볼륨 BitLocker 미적용 → 물리 보안/데이터 민감도에 따라 암호화 적용 여부 결정")
}

# W-65 로그온 메시지 설정 (경고 문구)
$capt = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "LegalNoticeCaption"
$text = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "LegalNoticeText"
if ($capt -and $text) { Rep "W-65" "로그온 시 경고 메시지 설정" "GOOD" @("로그온 경고 메시지 설정됨 (제목: '$capt')") }
else { Rep "W-65" "로그온 시 경고 메시지 설정" "VULN" @("LegalNoticeCaption/Text 미설정 → 비인가 접근 경고 문구 설정") }

# W-66 화면 보호기 설정
$ssActive = RegVal "HKCU:\Control Panel\Desktop" "ScreenSaveActive"
$ssSecure = RegVal "HKCU:\Control Panel\Desktop" "ScreenSaverIsSecure"
$ssTime = RegVal "HKCU:\Control Panel\Desktop" "ScreenSaveTimeOut"
$ssPolicy = RegVal "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop" "ScreenSaverIsSecure"
if (($ssActive -eq "1" -and $ssSecure -eq "1" -and [int]$ssTime -le 600 -and [int]$ssTime -gt 0) -or $ssPolicy -eq "1") {
    Rep "W-66" "화면 보호기 설정" "GOOD" @("화면 보호기 활성 + 암호 보호 + 대기시간 $([int]$ssTime)초")
} else {
    Rep "W-66" "화면 보호기 설정" "VULN" @("화면 보호기 암호 보호/대기시간(<=600초) 미흡 (Active=$ssActive Secure=$ssSecure Timeout=$ssTime)")
}

# W-67 원격 데스크톱 접속 가능 사용자 제한
$rdpUsers = @()
try { $rdpUsers = Get-LocalGroupMember -SID "S-1-5-32-555" -ErrorAction Stop | ForEach-Object { $_.Name } } catch {}
$rdpAllowed = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections"
if ($rdpAllowed -eq 1) {
    Rep "W-67" "원격 터미널 접속 사용자 그룹 제한" "GOOD" @("원격 데스크톱 연결이 비활성화됨(fDenyTSConnections=1)")
} elseif ($rdpUsers.Count -eq 0) {
    Rep "W-67" "원격 터미널 접속 사용자 그룹 제한" "GOOD" @("Remote Desktop Users 그룹 구성원 없음 (관리자만 RDP 가능)")
} else {
    Rep "W-67" "원격 터미널 접속 사용자 그룹 제한" "MAN" @("Remote Desktop Users 구성원: $($rdpUsers -join ', ') → 필요 사용자만 유지")
}

# W-68 콘솔 로그온 시 로컬 계정에서 빈 암호 사용 제한
RegYesNo "W-68" "로컬 계정 빈 암호 사용 제한" "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LimitBlankPasswordUse" 1 `
    "빈 암호 로컬 계정의 네트워크 로그온 차단" "빈 암호 사용 제한 미설정 → '사용'으로 설정"

# W-70 NetBIOS/SMB 유휴 세션 자동 연결 끊기
$autoDisc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "autodisconnect"
if ($null -ne $autoDisc -and [int]$autoDisc -ge 0 -and [int]$autoDisc -le 15) {
    Rep "W-70" "SMB 유휴 세션 자동 연결 끊기" "GOOD" @("autodisconnect = $autoDisc 분 (<=15)")
} else {
    Rep "W-70" "SMB 유휴 세션 자동 연결 끊기" "VULN" @("autodisconnect = $(if($null -eq $autoDisc){'미설정'}else{$autoDisc}) (기준: 15분 이하)")
}

# W-71 SMB 서명 요구
$smbSign = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" "RequireSecuritySignature"
if ($smbSign -eq 1) { Rep "W-71" "SMB 통신 서명 설정" "GOOD" @("서버 SMB 서명 항상 요구(RequireSecuritySignature=1)") }
else { Rep "W-71" "SMB 통신 서명 설정" "VULN" @("SMB 서명 요구 안 함(=$smbSign) → 항상 서명 요구 권장(SMB Relay 방어)") }

# W-72 LAN Manager 인증 수준
$lmc = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "LmCompatibilityLevel"
if ($lmc -ge 3) { Rep "W-72" "LAN Manager 인증 수준" "GOOD" @("LmCompatibilityLevel = $lmc (NTLMv2 사용, LM/NTLM 거부)") }
elseif ($null -eq $lmc) { Rep "W-72" "LAN Manager 인증 수준" "MAN" @("LmCompatibilityLevel 값 없음 → 정책 확인 (기준: 3 이상)") }
else { Rep "W-72" "LAN Manager 인증 수준" "VULN" @("LmCompatibilityLevel = $lmc (기준: 3 이상 - NTLMv2)") }

# W-73 LDAP 서명 요구 (도메인 컨트롤러/클라이언트)
$ldapClient = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\LDAP" "LDAPClientIntegrity"
if ($null -eq $ldapClient -or $ldapClient -ge 1) { Rep "W-73" "LDAP 클라이언트 서명 요구" "GOOD" @("LDAPClientIntegrity = $($ldapClient) (협상 이상)") }
else { Rep "W-73" "LDAP 클라이언트 서명 요구" "VULN" @("LDAPClientIntegrity = 0 (서명 없음) → 1 이상 권장") }

# W-74 익명 사용자의 Everyone 권한 적용 제한 (W-50과 연계 재확인)
RegYesNo "W-74" "Everyone 권한을 익명 사용자에게 적용 안 함" "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" "EveryoneIncludesAnonymous" 0 `
    "익명 사용자에게 Everyone 권한 미적용" "익명 사용자가 Everyone 권한 획득 → '사용 안 함'으로 설정"

# W-75 로컬 로그온 허용 그룹 제한
$intLogon = $PRIV["SeInteractiveLogonRight"]
if ($intLogon -and $intLogon -notmatch 'S-1-1-0|S-1-5-11|Everyone|Users|Authenticated Users|모든 사용자') {
    Rep "W-75" "로컬 로그온 허용" "GOOD" @("로컬 로그온 허용 대상: $intLogon (Users/Everyone 미포함)")
} elseif ($null -eq $intLogon) {
    Rep "W-75" "로컬 로그온 허용" "MAN" @("SeInteractiveLogonRight 확인 불가 (관리자 권한 필요)")
} else {
    Rep "W-75" "로컬 로그온 허용" "VULN" @("로컬 로그온 허용에 Users/Everyone 등 광범위 그룹 포함: $intLogon")
}

# W-76 네트워크에서 이 컴퓨터 액세스 (Everyone 제한)
$netAccess = $PRIV["SeNetworkLogonRight"]
if ($netAccess -and $netAccess -match 'S-1-1-0|Everyone') {
    Rep "W-76" "네트워크에서 이 컴퓨터 액세스 권한" "VULN" @("네트워크 액세스 권한에 Everyone(S-1-1-0) 포함: $netAccess")
} elseif ($null -eq $netAccess) {
    Rep "W-76" "네트워크에서 이 컴퓨터 액세스 권한" "MAN" @("SeNetworkLogonRight 확인 불가")
} else {
    Rep "W-76" "네트워크에서 이 컴퓨터 액세스 권한" "GOOD" @("네트워크 액세스 권한에 Everyone 미포함")
}

# W-77 사용자가 프린터 드라이버를 설치할 수 없게 함
RegYesNo "W-77" "프린터 드라이버 설치 제한" "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Providers\LanMan Print Services\Servers" "AddPrinterDrivers" 1 `
    "관리자만 프린터 드라이버 설치 가능" "일반 사용자의 프린터 드라이버 설치 허용 → 제한 권장(PrintNightmare 대응)"

# W-78 원격 데스크톱 NLA(네트워크 수준 인증) 요구
$nla = RegVal "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "UserAuthentication"
if ($nla -eq 1) { Rep "W-78" "RDP 네트워크 수준 인증(NLA) 요구" "GOOD" @("UserAuthentication=1 (NLA 요구)") }
elseif ($null -eq $nla) { Rep "W-78" "RDP 네트워크 수준 인증(NLA) 요구" "MAN" @("RDP-Tcp UserAuthentication 값 없음") }
else { Rep "W-78" "RDP 네트워크 수준 인증(NLA) 요구" "VULN" @("UserAuthentication=$nla → NLA 요구(1)로 설정") }

# W-79 SMBv1 프로토콜 비활성화
$smb1 = $null
try { $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch {}
if ($smb1 -eq $false) { Rep "W-79" "SMBv1 프로토콜 비활성화" "GOOD" @("SMBv1 서버 프로토콜 비활성") }
elseif ($null -eq $smb1) { Rep "W-79" "SMBv1 프로토콜 비활성화" "MAN" @("SMBv1 상태 확인 불가") }
else { Rep "W-79" "SMBv1 프로토콜 비활성화" "VULN" @("SMBv1 활성 → 비활성화 필요(EternalBlue 등)") }

# W-80 DoS 공격 방어 TCP/IP 레지스트리 설정
$synAttack = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" "SynAttackProtect"
$keepAlive = RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" "KeepAliveTime"
if ($synAttack -ge 1 -or ($keepAlive -and $keepAlive -le 300000)) {
    Rep "W-80" "DoS 공격 방어 레지스트리 설정" "GOOD" @("SynAttackProtect=$synAttack, KeepAliveTime=$keepAlive")
} else {
    Rep "W-80" "DoS 공격 방어 레지스트리 설정" "MAN" @("SynAttackProtect/KeepAliveTime/EnableDeadGWDetect 등 TCP/IP 강화 설정 미확인", "최신 OS는 기본 보호 → 방화벽/부하분산 계층 방어 여부 확인")
}

# W-81 Windows 방화벽 사용
$fw = @()
try { $fw = Get-NetFirewallProfile -ErrorAction Stop } catch {}
$fwOff = $fw | Where-Object { -not $_.Enabled }
if ($fw.Count -gt 0 -and $fwOff.Count -eq 0) { Rep "W-81" "Windows 방화벽 사용" "GOOD" @("도메인/개인/공용 프로필 방화벽 모두 사용") }
elseif ($fw.Count -eq 0) { Rep "W-81" "Windows 방화벽 사용" "MAN" @("방화벽 프로필 상태 확인 불가 → 별도 호스트 방화벽/보안그룹 확인") }
else { Rep "W-81" "Windows 방화벽 사용" "VULN" @("방화벽 비활성 프로필: $($fwOff.Name -join ', ')") }

# W-82 UAC(사용자 계정 컨트롤) 사용
$uac = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "EnableLUA"
$uacAdmin = RegVal "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "ConsentPromptBehaviorAdmin"
if ($uac -eq 1 -and $uacAdmin -ge 1) { Rep "W-82" "UAC(사용자 계정 컨트롤) 사용" "GOOD" @("EnableLUA=1, ConsentPromptBehaviorAdmin=$uacAdmin") }
elseif ($null -eq $uac) { Rep "W-82" "UAC(사용자 계정 컨트롤) 사용" "MAN" @("EnableLUA 값 없음") }
else { Rep "W-82" "UAC(사용자 계정 컨트롤) 사용" "VULN" @("UAC 비활성(EnableLUA=$uac) 또는 관리자 승인 프롬프트 미설정") }

#==============================================================================
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host (" 요약   양호={0}   취약={1}   N/A={2}   수동확인={3}   (총 {4})" -f $good, $vuln, $na, $man, ($good+$vuln+$na+$man)) -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host " 수동확인 항목은 정책 수립 여부 등 인터뷰가 필요한 잔여 항목입니다."
Write-Host " 이 스크립트는 읽기 전용입니다. 조치는 각 항목 [기준] 에 맞춰 별도 수행하세요."
Write-Host ""

# ---------------- JSON 파일 출력 (GUI 연동) ----------------
if ($Json -ne "") {
    $out = [pscustomobject]@{
        host   = $HOSTN
        os     = $OS_NAME
        family = "windows"
        results = @($script:results)
    }
    $out | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $Json -Encoding UTF8
    Write-Host (" JSON 저장: {0}" -f $Json)
}
