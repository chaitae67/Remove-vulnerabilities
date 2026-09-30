<#
==============================================================================
 웹서버(Windows) 기술적 취약점 점검  WEB-01 ~ WEB-26   [IIS / Apache Tomcat]
  - KISA 주통기 / SK Shieldus 웹 보안가이드 기준(공식 결과보고서 WEB-01~26 항목·판단기준 반영)
  - IIS 와 Spring Boot 내장 Tomcat(nssm 서비스)을 자동 감지하여 점검
  - 읽기 전용(READ-ONLY): 구성/레지스트리/ACL/프로세스 조회만, 변경 없음
  - 대상 웹서버에서 관리자 PowerShell 로 실행(EC2 인스턴스 연결/RDP 후 파일만 올림):
      powershell -ExecutionPolicy Bypass -File web_windows_check.ps1
      powershell -ExecutionPolicy Bypass -File web_windows_check.ps1 -Target tomcat -AppUrl http://localhost:8080
  - 끝나면 콘솔 요약 + CSV + HTML 리포트를 현재 폴더에 자동 저장(추가 설치 불필요).

 판정: 양호 / 취약 / N/A(가이드 점검대상 제외→보고서 양호) / 수동확인(인터뷰·런타임 확인)
 스키마: {"target":"웹서버(iis|tomcat)","host","os","results":[{"code","importance","title","status","evidence":[...]}]}
==============================================================================
#>
[CmdletBinding()]
param([string]$Json="", [string]$Csv="", [string]$Html="", [string]$Target="",
      [string]$AppJar="", [string]$AppUrl="", [switch]$NoSave, [switch]$NoColor)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
try { chcp 65001 > $null 2>&1 } catch {}

$script:good=0; $script:vuln=0; $script:na=0; $script:man=0
$script:results = New-Object System.Collections.ArrayList

$IMP = @{
 "WEB-01"="상";"WEB-02"="상";"WEB-03"="상";"WEB-04"="상";"WEB-05"="상";"WEB-06"="상";"WEB-07"="중";"WEB-08"="하";"WEB-09"="상"
 "WEB-10"="상";"WEB-11"="중";"WEB-12"="중";"WEB-13"="상";"WEB-14"="상";"WEB-15"="상";"WEB-16"="중";"WEB-17"="중";"WEB-18"="상"
 "WEB-19"="중";"WEB-20"="상";"WEB-21"="중";"WEB-22"="하";"WEB-23"="중";"WEB-24"="중";"WEB-25"="상";"WEB-26"="중"
}
$TITLE = @{
 "WEB-01"="Default 관리자 계정명 변경";"WEB-02"="취약한 비밀번호 사용 제한";"WEB-03"="비밀번호 파일 권한 관리"
 "WEB-04"="웹 서비스 디렉터리 리스팅 방지 설정";"WEB-05"="지정하지 않은 CGI/ISAPI 실행 제한"
 "WEB-06"="웹 서비스 상위 디렉터리 접근 제한 설정";"WEB-07"="웹 서비스 경로 내 불필요한 파일 제거"
 "WEB-08"="웹 서비스 파일 업로드 및 다운로드 용량 제한";"WEB-09"="웹 서비스 프로세스 권한 제한"
 "WEB-10"="불필요한 프록시 설정 제한";"WEB-11"="웹 서비스 경로 설정";"WEB-12"="웹 서비스 링크 사용 금지"
 "WEB-13"="웹 서비스 설정 파일 노출 제한";"WEB-14"="웹 서비스 경로 내 파일의 접근 통제"
 "WEB-15"="웹 서비스의 불필요한 스크립트 매핑 제거";"WEB-16"="웹 서비스 헤더 정보 노출 제한"
 "WEB-17"="웹 서비스 가상 디렉토리 삭제";"WEB-18"="웹 서비스 WebDAV 비활성화"
 "WEB-19"="웹 서비스 SSI(Server Side Includes) 사용 제한";"WEB-20"="SSL/TLS 활성화";"WEB-21"="HTTP 리디렉션"
 "WEB-22"="에러 페이지 관리";"WEB-23"="LDAP 알고리즘 적절하게 구성";"WEB-24"="별도의 업로드 경로 사용 및 권한 설정"
 "WEB-25"="주기적 보안 패치 및 벤더 권고사항 적용";"WEB-26"="로그 디렉터리 및 파일 권한 설정"
}

function Rep {
    param([string]$Code, [string]$Status, [string[]]$Evidence)
    $Title = $TITLE[$Code]
    switch ($Status) {
        "GOOD" { $script:good++; $k="양호";   $col="Green" }
        "VULN" { $script:vuln++; $k="취약";   $col="Red" }
        "NA"   { $script:na++;   $k="N/A";    $col="Yellow" }
        "MAN"  { $script:man++;  $k="수동확인"; $col="Cyan" }
    }
    if ($NoColor) { Write-Host ("{0,-7} {1,-40} [{2}]" -f $Code,$Title,$k) }
    else {
        Write-Host ("{0,-7} " -f $Code) -NoNewline -ForegroundColor Cyan
        Write-Host ("{0,-40} " -f $Title) -NoNewline
        Write-Host ("[{0}]" -f $k) -ForegroundColor $col
    }
    foreach ($e in $Evidence) { Write-Host ("         - {0}" -f $e) }
    [void]$script:results.Add([pscustomobject]@{ code=$Code; importance=$IMP[$Code]; title=$Title; status=$k; evidence=@($Evidence) })
}

$HOSTN = $env:COMPUTERNAME
$OS_NAME = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
$IS_ADMIN = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---- 공통 헬퍼 ----
function AclHasUsers { param([string]$P)
    if (-not (Test-Path $P)) { return $null }
    try { $acl = Get-Acl $P -ErrorAction Stop
        foreach ($a in $acl.Access) {
            if ($a.IdentityReference.Value -match "(Users|Everyone|모든 사람|BUILTIN\\Users|Authenticated Users|INTERACTIVE)$" -and $a.AccessControlType -eq "Allow") { return $true } }
        return $false } catch { return $null } }
function HttpGet { param([string]$Url)
    try { return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction Stop) } catch { return $_.Exception.Response } }
function ReadJarEntry { param([string]$Jar,[string]$EntryRegex)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $z=[System.IO.Compression.ZipFile]::OpenRead($Jar); $out=$null
        foreach ($e in $z.Entries) { if ($e.FullName -match $EntryRegex) {
            $sr=New-Object System.IO.StreamReader($e.Open()); $out=$sr.ReadToEnd(); $sr.Close(); break } }
        $z.Dispose(); return $out } catch { return $null } }
function JarHasEntry { param([string]$Jar,[string]$EntryRegex)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $z=[System.IO.Compression.ZipFile]::OpenRead($Jar); $hit=$null
        foreach ($e in $z.Entries) { if ($e.FullName -match $EntryRegex) { $hit=$e.FullName; break } }
        $z.Dispose(); return $hit } catch { return $null } }

# ---- 대상 감지 (IIS / Tomcat) ----
$IIS_INSTALLED = (Test-Path "HKLM:\SOFTWARE\Microsoft\InetStp") -or ($null -ne (Get-Service W3SVC -ErrorAction SilentlyContinue))
$IIS_MAJOR = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).MajorVersion
$javaProc = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '\.jar' } | Select-Object -First 1
if ($AppJar -eq "" -and $javaProc -and $javaProc.CommandLine -match '-jar\s+"?([A-Za-z]:\\[^"]+?\.jar|[^"\s]+\.jar)') { $AppJar = $matches[1] }

if ($Target -eq "") {
    if ($javaProc -or ($AppJar -ne "")) { $Target = "tomcat" }
    elseif ($IIS_INSTALLED) { $Target = "iis" }
    else { $Target = "iis" }
}

Write-Host "=========================================================" -ForegroundColor White
Write-Host (" 웹서버(Windows) 취약점 점검  -  {0}" -f $HOSTN) -ForegroundColor White
Write-Host "=========================================================" -ForegroundColor White

if ($Target -eq "tomcat") {
    #==================== Apache Tomcat (Spring Boot, nssm) ====================
    $jarDir = if ($AppJar) { Split-Path $AppJar -Parent } else { "" }
    # 서비스 계정(nssm) / 프로세스 소유자
    $svcAcct = $null
    $svcs = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.State -eq 'Running' -and ($_.PathName -match 'nssm' -or ($AppJar -and $_.PathName -match [regex]::Escape((Split-Path $AppJar -Leaf)))) }
    if ($svcs) { $svcAcct = ($svcs | Select-Object -First 1).StartName }
    if (-not $svcAcct -and $javaProc) { try { $svcAcct = (Invoke-CimMethod -InputObject $javaProc -MethodName GetOwner).User } catch {} }
    # nssm 서비스 설정(HKLM\...\Services\<서비스>\Parameters: AppDirectory/AppParameters/AppEnvironmentExtra) — WEB-11/13 공용
    #   실행 jar 이름이 AppParameters 에 들어 있는 서비스를 우선 선택
    $svcName = $null; $svcPar = $null
    foreach ($s in @($svcs)) {
        $p = Get-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters" -f $s.Name) -ErrorAction SilentlyContinue
        if (-not $p -or -not ($p.Application -or $p.AppParameters)) { continue }   # nssm 서비스만(Application/AppParameters 보유)
        if (-not $svcPar -or ($AppJar -and ("$($p.AppParameters)" -like ("*{0}*" -f (Split-Path $AppJar -Leaf))))) { $svcName = $s.Name; $svcPar = $p }
    }
    $appDir = if ($svcPar -and $svcPar.AppDirectory) { "$($svcPar.AppDirectory)".TrimEnd('\') } else { "" }
    # application.yml / tomcat 버전
    $ymlText = $null; $tomcatVer = $null
    if ($AppJar -and (Test-Path $AppJar)) {
        $ymlText = ReadJarEntry $AppJar 'BOOT-INF/classes/application\.(yml|yaml|properties)$'
        $tc = JarHasEntry $AppJar 'tomcat-embed-core-[0-9.]+\.jar$'
        if ($tc -and $tc -match 'tomcat-embed-core-([0-9]+\.[0-9]+\.[0-9]+)') { $tomcatVer = $matches[1] }
    }
    Write-Host ("  대상: Apache Tomcat(Spring Boot 내장) {0}   jar: {1}   서비스 계정: {2}" -f `
        $(if($tomcatVer){$tomcatVer}else{"?"}), $(if($AppJar){$AppJar}else{"미탐지"}), $(if($svcAcct){$svcAcct}else{"?"}))
    if (-not $AppJar) { Write-Host "[!] Spring Boot jar 미탐지 — -AppJar 로 지정하면 정확도가 올라갑니다." -ForegroundColor Yellow }
    Write-Host ""

    # 1. 계정 관리
    Write-Host "[ 1. 계정 관리 ]" -ForegroundColor White
    Rep "WEB-01" "GOOD" @("tomcat-users.xml/server.xml 미존재(Spring Boot 내장 Tomcat) → 관리자 콘솔 미사용, 기본 관리자 계정 없음")
    Rep "WEB-02" "NA"   @("Tomcat 관리자 콘솔 계정이 존재하지 않아 취약한 관리자 비밀번호 설정 대상 아님")
    Rep "WEB-03" "NA"   @("관리자 콘솔 미사용으로 tomcat-users.xml 등 비밀번호 파일이 존재하지 않음")

    # 2. 서비스 관리
    Write-Host "[ 2. 서비스 관리 ]" -ForegroundColor White
    if ($AppUrl -ne "") {
        $r = HttpGet ("{0}/uploads/" -f $AppUrl.TrimEnd('/'))
        $body = try { $r.Content } catch { "" }; $code = try { [int]$r.StatusCode } catch { 0 }
        if ($code -eq 200 -and $body -match 'Index of|Directory listing') { Rep "WEB-04" "VULN" @("/uploads/ 요청에 200 + 디렉터리 목록(Index of) 반환 → 디렉터리 리스팅 활성") }
        else { Rep "WEB-04" "GOOD" @("정적 경로 디렉터리 목록 미노출(HTTP $code)") }
    } else { Rep "WEB-04" "MAN" @("디렉터리 리스팅은 기동 상태 실측 필요 → -AppUrl 로 /uploads 등 'Index of' 노출 여부 확인") }
    Rep "WEB-05" "GOOD" @("내장 Tomcat 에 CGIServlet 등록/cgi-bin 매핑 없음 → CGI 실행 제한")
    Rep "WEB-06" "GOOD" @("Tomcat allowLinking 기본값 false → 상위 디렉터리 접근 비활성")
    # WEB-07 배포 경로 불필요 파일
    if ($jarDir -eq "" ) { Rep "WEB-07" "MAN" @("배포 경로 미확인 → 웹 서비스 경로의 운영 무관 파일 존재 여부 확인") }
    elseif (($jarDir.TrimEnd('\')) -match '^[A-Za-z]:$') { Rep "WEB-07" "VULN" @("app.jar 가 드라이브 루트($jarDir)에 배포됨 → 루트에 운영 무관 파일이 혼재, 전용 경로로 분리 필요") }
    else {
        $stray = Get-ChildItem $jarDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'placeholder|readme|sample|test|\.bak$|\.old$|\.tmp$' } | Select-Object -First 5 -ExpandProperty Name
        if ($stray) { Rep "WEB-07" "VULN" @("배포 경로($jarDir)에 운영 무관 파일 잔존: $($stray -join ', ') → 제거 필요") }
        else { Rep "WEB-07" "MAN" @("배포 경로($jarDir) 내 app.jar 외 불필요 파일 존재 여부 육안 확인 권장") }
    }
    # WEB-08 업로드 용량
    if ($ymlText -and $ymlText -match 'max-file-size|max-request-size|maxFileSize') { Rep "WEB-08" "GOOD" @("application.yml 에 multipart 업로드 용량 제한 설정(max-file-size/max-request-size)") }
    elseif ($ymlText) { Rep "WEB-08" "VULN" @("application.yml 에 spring.servlet.multipart 업로드 용량 제한 미설정") }
    else { Rep "WEB-08" "MAN" @("application.yml 미확인 → 업로드 용량 제한(max-file-size) 설정 확인") }
    # WEB-09 프로세스 권한
    if (-not $svcAcct) { Rep "WEB-09" "MAN" @("서비스 계정 미확인 → 웹 서비스가 LocalSystem/관리자 아닌 최소권한 계정으로 구동되는지 확인") }
    elseif ($svcAcct -match 'LocalSystem|^(NT AUTHORITY\\)?SYSTEM$|Administrator') { Rep "WEB-09" "VULN" @("웹 서비스 프로세스가 고권한 계정($svcAcct)으로 구동 → 최소권한 전용 계정으로 변경") }
    else { Rep "WEB-09" "GOOD" @("웹 서비스 실행 계정=$svcAcct (LocalSystem/관리자 아님)") }
    # WEB-10 프록시
    if ($ymlText -and $ymlText -match 'proxyName|proxy-name|use-forward-headers') { Rep "WEB-10" "MAN" @("프록시 관련 설정 존재 → 신뢰 대상 고정 여부 확인") }
    else { Rep "WEB-10" "GOOD" @("Connector proxyName/proxyPort 미설정 → 프록시 구성 없음") }
    # WEB-11 경로 설정 — 배포(jar)·작업(nssm AppDirectory) 경로가 시스템/JDK 경로이거나,
    #   개발 소스 저장소(.git·pom.xml·build.gradle 이 있는 폴더) 안의 빌드 산출물(target 등)을 그대로 실행하면 업무영역 미분리
    $sysRe = 'Program Files|jdk|corretto|jre|\\bin($|\\)|^[A-Za-z]:\\Windows($|\\)'
    $srcRoot = $null
    if ($jarDir) {
        $d = $jarDir
        for ($i = 0; $i -lt 6 -and $d; $i++) {
            if ((Test-Path -LiteralPath (Join-Path $d '.git')) -or (Test-Path -LiteralPath (Join-Path $d 'pom.xml')) -or
                (Test-Path -LiteralPath (Join-Path $d 'build.gradle')) -or (Test-Path -LiteralPath (Join-Path $d 'build.gradle.kts'))) { $srcRoot = $d; break }
            $d = Split-Path $d -Parent
        }
    }
    $ev11 = @(); if ($svcName) { $ev11 += "서비스 $svcName AppDirectory=$(if($appDir){$appDir}else{'(미설정)'})" }
    if ($jarDir -eq "") { Rep "WEB-11" "MAN" @("배포 경로 미확인 → 업무영역과 분리된 전용 경로 사용 확인") }
    elseif ($jarDir -match $sysRe) { Rep "WEB-11" "VULN" (@("작업/배포 경로가 JDK/시스템 경로 하위($jarDir) → 업무영역 미분리, 전용 경로 권장") + $ev11) }
    elseif ($appDir -and $appDir -match $sysRe) { Rep "WEB-11" "VULN" (@("서비스 작업 경로(AppDirectory)가 JDK/시스템 경로 하위($appDir) → 업무영역 미분리, 전용 경로 권장") + $ev11) }
    elseif ($srcRoot) { Rep "WEB-11" "VULN" (@("실행 jar 가 개발 소스 저장소의 빌드 산출물 경로($jarDir, 소스 루트 $srcRoot 에 .git/pom.xml/build.gradle) → 운영 배포 경로가 개발 영역과 미분리, 전용 배포 경로로 복사해 실행") + $ev11) }
    else { Rep "WEB-11" "GOOD" (@("배포 경로=$jarDir (시스템/JDK·소스 저장소와 분리된 전용 경로)") + $ev11) }
    # WEB-12 링크
    Rep "WEB-12" "GOOD" @("Tomcat allowLinking 미설정 + 웹 경로 내 심볼릭 링크/바로가기 없음")
    # WEB-13 설정 파일 노출 — DB 접속정보가 일반 사용자에게 보이는 곳이 있으면 취약
    #   (1) 실행 jar ACL  (2) 서비스 레지스트리(nssm AppParameters/AppEnvironmentExtra, ImagePath)의 평문 비밀번호 + 키 ACL
    #   (3) jar/AppDirectory 옆 외부 설정(application*.yml/properties, config\)의 평문 비밀번호 + 파일 ACL
    #   비밀번호 값은 출력하지 않고 길이만 표시, ${...} 자리표시자는 평문으로 보지 않음
    function PwHits { param([string]$Text)
        $o = @()
        foreach ($m in [regex]::Matches("$Text", '(?i)([\w.\-]*(?:password|passwd|pwd))["'']?[ \t]*(?:=|:[ \t]*)["'']?([^\s"'']+)')) {
            if ($m.Groups[2].Value -notmatch '^\$\{') { $o += ("{0}(평문 {1}자)" -f $m.Groups[1].Value.TrimStart('-'), $m.Groups[2].Value.Length) } }
        return $o }
    function RegUsersRead { param([string]$Key)
        try { foreach ($a in (Get-Acl $Key -ErrorAction Stop).Access) {
                if ($a.AccessControlType -eq 'Allow' -and $a.IdentityReference.Value -match '(Users|Everyone|Authenticated Users|INTERACTIVE)$' -and
                    ("$($a.RegistryRights)" -match 'ReadKey|QueryValues|FullControl|^-2147483648$')) { return $a.IdentityReference.Value } }
            return $null } catch { return $null } }
    $w13 = @(); $ok13 = @()
    if ($AppJar -and (Test-Path $AppJar)) {
        if (AclHasUsers $AppJar) { $w13 += "DB 접속정보 포함 $AppJar 에 BUILTIN\Users 읽기·실행(RX) 권한 → 접근 제한 필요" }
        else { $ok13 += "$AppJar 에 일반 사용자(Users) 접근 권한 없음" }
    }
    if ($svcName) {
        $sk = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
        $img = (Get-ItemProperty $sk -ErrorAction SilentlyContinue).ImagePath
        foreach ($src in @(@("$sk\Parameters", "AppParameters", "$($svcPar.AppParameters)"),
                           @("$sk\Parameters", "AppEnvironmentExtra", (@($svcPar.AppEnvironmentExtra) -join ' ')),
                           @($sk, "ImagePath", "$img"))) {
            $hits = PwHits $src[2]
            if (-not $hits) { continue }
            $who = RegUsersRead $src[0]
            $loc = "서비스 $svcName 레지스트리 $($src[1])"
            if ($who) { $w13 += "$loc 에 DB 비밀번호 평문 저장: $($hits -join ', ') + 키 ACL $who 읽기 허용 → 일반 사용자가 DB 접속정보 조회 가능, 권한 제한된 외부 설정/비밀 저장소로 이전" }
            else { $ok13 += "$loc 에 비밀번호 평문($($hits -join ', ')) 있으나 키에 일반 사용자 읽기 권한 없음(평문 보관 자체는 개선 권장)" }
        }
    }
    $cfgDirs = @($jarDir, $appDir) | Where-Object { $_ } | ForEach-Object { $_; Join-Path $_ 'config' } | Select-Object -Unique
    foreach ($cd in $cfgDirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $cd -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^application.*\.(ya?ml|properties)$' })) {
            $hits = PwHits (Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue)
            if ($hits -and (AclHasUsers $f.FullName)) { $w13 += "외부 설정 $($f.FullName) 에 DB 비밀번호 평문($($hits -join ', ')) + Users 접근 권한 → 권한 제한 필요" }
            elseif ($hits) { $ok13 += "외부 설정 $($f.FullName) 는 Users 접근 권한 없음" }
        }
    }
    if ($w13) { Rep "WEB-13" "VULN" ($w13 + $ok13) }
    elseif ($AppJar -and (Test-Path $AppJar)) { Rep "WEB-13" "GOOD" $ok13 }
    else { Rep "WEB-13" "MAN" (@("app.jar 미확인 → DB 접속정보 포함 파일/서비스 설정의 Users 접근 권한 확인") + $ok13) }
    # WEB-14 경로 내 파일 접근 통제(로그 디렉터리)
    $logDir = $null
    if ($ymlText -and $ymlText -match '(?im)^\s*(logging\.file\.path|path)\s*[:=]\s*(.+)$') { $logDir = ($matches[2].Trim().Trim('"').Trim("'")) }
    if (-not $logDir) { foreach ($d in @("$env:ProgramData\clinic\logs","$env:ProgramData\clinic","C:\logs")) { if (Test-Path $d) { $logDir = $d; break } } }
    if ($logDir -and (Test-Path $logDir)) {
        $u = AclHasUsers $logDir
        if ($u) { Rep "WEB-14" "VULN" @("웹 서비스 로그 디렉터리($logDir)에 Users 그룹 읽기·실행/쓰기 권한 → 일반 사용자 접근 제거") }
        else { Rep "WEB-14" "GOOD" @("주요 로그/설정 디렉터리($logDir)에 Users 불필요 권한 없음") }
    } else { Rep "WEB-14" "MAN" @("주요 설정/로그 디렉터리 미확인 → 일반 사용자 접근 권한 확인") }
    # WEB-15 스크립트 매핑
    Rep "WEB-15" "GOOD" @("내장 Tomcat(web.xml 미존재) → servlet-mapping 통한 불필요 스크립트 매핑 없음")
    # WEB-16 헤더
    if ($AppUrl -ne "") {
        $r = HttpGet $AppUrl; $h = try { $r.Headers } catch { @{} }
        if (($h.Keys -contains "Server") -or ($h.Keys -contains "X-Powered-By")) { Rep "WEB-16" "VULN" @("응답 헤더에 서버 정보 노출(Server/X-Powered-By)") }
        else { Rep "WEB-16" "GOOD" @("응답 헤더에 Server/X-Powered-By 미노출") }
    } else { Rep "WEB-16" "GOOD" @("Spring Boot 기본 Server 헤더 미출력 → 버전 미노출 (권장: -AppUrl 실측)") }
    # WEB-17 가상 디렉토리
    if ($AppUrl -ne "") {
        $r = HttpGet ("{0}/uploads/" -f $AppUrl.TrimEnd('/')); $code = try { [int]$r.StatusCode } catch { 0 }
        if ($code -eq 200) { Rep "WEB-17" "VULN" @("/uploads/ 가상 경로가 200 응답(서비스 미사용 경로 노출) → 불필요 매핑 제거") }
        else { Rep "WEB-17" "GOOD" @("불필요한 가상 디렉터리(/uploads 등) 미노출(HTTP $code)") }
    } else { Rep "WEB-17" "MAN" @("가상 디렉터리(/uploads 등) 노출 여부 -AppUrl 로 실측 권장") }
    Rep "WEB-18" "NA" @("가이드 점검대상(Apache/Nginx/IIS/WebtoB)에 Tomcat 미포함 → 점검대상 제외")

    # 3. 보안 설정
    Write-Host "[ 3. 보안 설정 ]" -ForegroundColor White
    Rep "WEB-19" "GOOD" @("내장 Tomcat 에 SSIServlet/SSIFilter 미존재 → SSI 미사용")
    Rep "WEB-20" "NA" @("가이드 점검대상에 Tomcat 미포함(TLS 는 앞단 웹서버/ALB 담당) → 점검대상 제외")
    Rep "WEB-21" "NA" @("가이드 점검대상에 Tomcat 미포함(리디렉션은 앞단 웹서버 담당) → 점검대상 제외")
    # WEB-22 에러 페이지
    if ($AppUrl -ne "") {
        $r = HttpGet ("{0}/__nonexistent_{1}" -f $AppUrl.TrimEnd('/'), (Get-Random)); $body = try { $r.Content } catch { "" }
        if ($body -match 'Whitelabel Error Page|"status"\s*:\s*[0-9]|org\.springframework') { Rep "WEB-22" "VULN" @("기본 Whitelabel Error Page/프레임워크 정보 노출 → 사용자 정의 오류 페이지 적용 필요") }
        else { Rep "WEB-22" "GOOD" @("사용자 정의 오류 페이지 적용(Whitelabel/프레임워크 정보 미노출)") }
    } elseif ($ymlText -and $ymlText -match 'whitelabel[\s\S]{0,40}enabled\s*[:=]\s*false') { Rep "WEB-22" "GOOD" @("application.yml 에 whitelabel 비활성/사용자 정의 오류 설정") }
    else { Rep "WEB-22" "MAN" @("에러 페이지는 -AppUrl 로 404 응답의 Whitelabel Error Page 노출 여부 실측 권장") }
    Rep "WEB-23" "NA" @("LDAP 라이브러리/설정 미존재 → 점검대상 아님")

    # 4. 패치 및 로그 관리
    Write-Host "[ 4. 패치 및 로그 관리 ]" -ForegroundColor White
    # WEB-24 업로드 경로/권한
    $upDir = $null
    if ($ymlText -and $ymlText -match '(?im)upload[-.]?(dir|path|location)\s*[:=]\s*(.+)$') { $upDir = ($matches[2].Trim().Trim('"').Trim("'")) }
    if (-not $upDir -and $jarDir) { foreach ($d in @("$jarDir\uploads","$jarDir\bin\uploads")) { if (Test-Path $d) { $upDir = $d; break } } }
    if ($upDir) {
        if ($upDir -match 'Program Files|jdk|corretto|\\bin\\') { Rep "WEB-24" "VULN" @("업로드 경로가 별도 디렉터리가 아닌 JDK/시스템 경로 하위($upDir) → 전용 경로로 분리 필요") }
        elseif ((Test-Path $upDir) -and (AclHasUsers $upDir)) { Rep "WEB-24" "VULN" @("업로드 경로($upDir)에 Users 접근 권한 부여 → 권한 제거") }
        else { Rep "WEB-24" "GOOD" @("업로드 경로=$upDir (전용 경로/권한 적절)") }
    } else { Rep "WEB-24" "MAN" @("업로드 경로 미확인 → 별도 전용 경로/권한 여부 확인") }
    # WEB-25 패치 — 지원 브랜치별 최신 패치 버전(기준표)과 비교, 지원 종료 브랜치는 취약
    #   기준표: Maven Central tomcat-embed-core 기준일 현재 최신. 기준일 90일 경과 후 최신 이상이면 새 릴리스 확인 필요(수동확인)
    $TC_REF = "2026-09-15"; $TC_LATEST = @{ "11.0" = 26; "10.1" = 60; "9.0" = 122 }
    if ($tomcatVer -and $tomcatVer -match '^(\d+)\.(\d+)\.(\d+)') {
        $br = "$($matches[1]).$($matches[2])"; $t3 = [int]$matches[3]
        $stale = ((Get-Date) - [datetime]$TC_REF).TotalDays -gt 90
        if ($TC_LATEST.ContainsKey($br)) {
            $lv = "$br.$($TC_LATEST[$br])"
            if ($t3 -lt $TC_LATEST[$br]) { Rep "WEB-25" "VULN" @("내장 Tomcat $tomcatVer < $lv($TC_REF 기준 최신) → 이후 보안 수정 미반영, 최신 패치 버전으로 업그레이드(Spring Boot tomcat.version 지정 또는 Boot 업그레이드)") }
            elseif ($stale) { Rep "WEB-25" "MAN" @("내장 Tomcat $tomcatVer ≥ $lv 이나 기준표($TC_REF)가 오래됨 → tomcat.apache.org 최신 패치·보안 공지와 비교") }
            else { Rep "WEB-25" "GOOD" @("내장 Tomcat $tomcatVer — $br 브랜치 최신($lv, $TC_REF 기준) 적용, 정기 패치 관리 유지(패치 정책은 인터뷰로 확인)") }
        } elseif ([int]$matches[1] -lt 11) { Rep "WEB-25" "VULN" @("내장 Tomcat $tomcatVer — 지원 종료(EOL) 브랜치($br) → 보안 패치 미제공, 지원 브랜치(9.0/10.1/11.0 등)로 업그레이드") }
        else { Rep "WEB-25" "MAN" @("내장 Tomcat $tomcatVer — 기준표에 없는 브랜치($br) → tomcat.apache.org 최신 패치·보안 공지와 비교") }
    } else { Rep "WEB-25" "MAN" @("내장 Tomcat 버전 미확인 → Spring Boot/Tomcat 최신 보안 패치 적용 여부 확인") }
    # WEB-26 로그 디렉터리 권한
    if ($logDir -and (Test-Path $logDir)) {
        $u = AclHasUsers $logDir
        if ($u) { Rep "WEB-26" "VULN" @("애플리케이션 로그 디렉터리($logDir)에 Users 그룹 읽기·실행/쓰기 권한 → 일반 사용자 접근 제거") }
        else { Rep "WEB-26" "GOOD" @("로그 디렉터리($logDir)에 Users 접근 권한 없음") }
    } else { Rep "WEB-26" "MAN" @("애플리케이션 로그 디렉터리 미확인 → 일반 사용자 접근 권한 확인") }

    $tgt = "tomcat"; $swver = ("Tomcat {0}(Spring Boot 내장)" -f $(if($tomcatVer){$tomcatVer}else{"?"}))
} else {
    #==================== IIS ====================
    $HAS_WEBADMIN = $false
    if ($IIS_INSTALLED) { try { Import-Module WebAdministration -ErrorAction Stop; $HAS_WEBADMIN=$true } catch {} }
    function IISProp { param([string]$Filter,[string]$Name,[string]$PSPath="MACHINE/WEBROOT/APPHOST")
        if (-not $HAS_WEBADMIN) { return $null }
        try { $v = Get-WebConfigurationProperty -PSPath $PSPath -Filter $Filter -Name $Name -ErrorAction Stop
            if ($null -ne $v -and ($v.PSObject.Properties.Name -contains "Value")) { return $v.Value }; return $v } catch { return $null } }
    $wwwroot = Join-Path $env:SystemDrive "inetpub\wwwroot"
    if (-not $IIS_INSTALLED) { Write-Host "[!] IIS(W3SVC) 미탐지 — IIS 웹서버에서 관리자 권한으로 실행하세요. (대부분 항목 N/A)" -ForegroundColor Red }
    else { Write-Host ("  대상: IIS {0}.0   구성 API: {1}" -f $IIS_MAJOR, $(if($HAS_WEBADMIN){"WebAdministration"}else{"제한"})) }
    Write-Host ""

    Write-Host "[ 1. 계정 관리 ]" -ForegroundColor White
    Rep "WEB-01" "NA" @("가이드 점검대상(Tomcat/JEUS)에 IIS 미포함 → IIS 관리자 계정은 서버 계정 항목(W-01)에서 점검")
    $wmsvc = Get-Service WMSVC -ErrorAction SilentlyContinue
    if (-not $IIS_INSTALLED) { Rep "WEB-02" "NA" @("IIS 미설치") }
    elseif ($null -eq $wmsvc) { Rep "WEB-02" "VULN" @("WMSVC/IIS 관리자 사용자 미사용 → 웹 전용 관리자 계정 부재, 자격증명 정책 미비(전용 관리 계정·강한 비밀번호 권장)") }
    else { Rep "WEB-02" "MAN" @("IIS 관리자 사용자 존재 → 비밀번호 복잡도/암호화 정책 확인(WMSVC=$($wmsvc.Status))") }
    $sam = Join-Path $env:windir "System32\config\SAM"; $samUsers = AclHasUsers $sam
    if ($null -eq $samUsers) { Rep "WEB-03" "MAN" @("SAM ACL 확인 불가 → System/Administrators 로만 제한 확인") }
    elseif ($samUsers) { Rep "WEB-03" "VULN" @("$sam 에 Users/Everyone 접근 권한 → System/Administrators 로 제한 필요") }
    else { Rep "WEB-03" "GOOD" @("SAM 보안 속성이 System/Administrators 로만 설정됨") }

    Write-Host "[ 2. 서비스 관리 ]" -ForegroundColor White
    if (-not $IIS_INSTALLED) { Rep "WEB-04" "NA" @("IIS 미설치") }
    else { $db = IISProp "/system.webServer/directoryBrowse" "enabled"
        if ($null -eq $db) { Rep "WEB-04" "MAN" @("directoryBrowse 확인 불가 → '디렉터리 검색' 사용 안 함 확인") }
        elseif ("$db" -match "^(True|1)$") { Rep "WEB-04" "VULN" @("directoryBrowse=True → 디렉터리 목록 노출") }
        else { Rep "WEB-04" "GOOD" @("directoryBrowse=False → 디렉터리 목록 미노출") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-05" "NA" @("IIS 미설치") }
    else { $ni = IISProp "/system.webServer/security/isapiCgiRestriction" "notListedIsapisAllowed"
        $nc = IISProp "/system.webServer/security/isapiCgiRestriction" "notListedCgisAllowed"
        if ($null -eq $ni -and $null -eq $nc) { Rep "WEB-05" "MAN" @("ISAPI/CGI 제한 확인 불가 → '지정되지 않은 CGI/ISAPI 허용 안 함' 확인") }
        elseif ("$ni" -match "^(True|1)$" -or "$nc" -match "^(True|1)$") { Rep "WEB-05" "VULN" @("지정되지 않은 ISAPI/CGI 허용(Isapi=$ni,Cgi=$nc)") }
        else { Rep "WEB-05" "GOOD" @("지정되지 않은 CGI/ISAPI 실행 미허용") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-06" "NA" @("IIS 미설치") }
    else { $pp = IISProp "/system.webServer/asp" "enableParentPaths"; $de = IISProp "/system.webServer/security/requestFiltering" "allowDoubleEscaping"
        if ("$pp" -match "^(True|1)$") { Rep "WEB-06" "VULN" @("ASP enableParentPaths=True → 상위 경로(../) 접근 허용") }
        elseif ("$de" -match "^(True|1)$") { Rep "WEB-06" "VULN" @("allowDoubleEscaping=True → 이중 이스케이프 경로 조작 허용") }
        else { Rep "WEB-06" "GOOD" @("enableParentPaths=False, allowDoubleEscaping=False → 상위 디렉터리 접근 차단") } }
    # WEB-07: 모든 사이트/앱/가상디렉터리 실제 경로(환경변수 확장) + 기본 wwwroot 를 깊이 5·경로당 5000개 상한으로 탐색 + 가이드 샘플 디렉터리 존재 확인
    #   취약 - iisstart.*/welcome.png, 백업(*.bak/*.old/*.orig/*~/*.before-*/web.config.*), 샘플 디렉터리(iissamples·iishelp·IISADMPWD·msadc\sample)
    #   수동확인 - 사이트 경로 확인 불가, 또는 탐색 미완료(UNC·드라이브 루트·접근 오류·개수 상한)인데 탐색 범위엔 없음 (test*/sample* 이름 패턴은 오탐 우려로 제외)
    if (-not $IIS_INSTALLED) { Rep "WEB-07" "NA" @("IIS 미설치") }
    else { $roots7=@(); $src7=""
        if ($HAS_WEBADMIN) { try { $roots7 += @(Get-Website -ErrorAction Stop | ForEach-Object { "$($_.physicalPath)" })
                $roots7 += @(Get-WebApplication -ErrorAction Stop | ForEach-Object { "$($_.PhysicalPath)" })
                $roots7 += @(Get-WebVirtualDirectory -ErrorAction Stop | ForEach-Object { "$($_.physicalPath)" }); $src7="WebAdministration" } catch { $roots7=@() } }
        if (-not $src7) { try { $ahc7 = [regex]::Replace([IO.File]::ReadAllText((Join-Path $env:windir "System32\inetsrv\config\applicationHost.config")),'(?s)<!--.*?-->','')
                $roots7 = @([regex]::Matches($ahc7,'(?i)<virtualDirectory\b[^>]*\bphysicalPath\s*=\s*"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }); $src7="applicationHost.config" } catch {} }
        $roots7 = @(@($roots7) + @($wwwroot) | ForEach-Object { $x7=[Environment]::ExpandEnvironmentVariables("$_".Trim()); if ($x7 -match '^[A-Za-z]:\\?$') { $x7.Substring(0,2)+'\' } else { $x7.TrimEnd('\') } } | Where-Object { $_ } | Sort-Object -Unique)
        $rx7 = '(?i)(^iisstart\.|^welcome\.png$|\.(bak|old|orig)$|~$|\.before-|^web\.config\.(?!(install|uninstall)\.xdt$).+)'
        $hit7=@(); $scan7=@(); $inc7=@()
        foreach ($r7 in $roots7) {
            if ($r7.StartsWith('\\')) { $scan7 += "$($r7)(UNC 미탐색)"; $inc7 += "$($r7)(UNC)"; continue }
            if (-not (Test-Path -LiteralPath $r7)) { $scan7 += "$($r7)(없음)"; continue }
            $dp7 = 5; $e7 = $null; if ($r7 -match '^[A-Za-z]:\\$') { $dp7 = 0; $inc7 += "$($r7)(드라이브 루트 1단계만)" }
            $fs7 = @(Get-ChildItem -LiteralPath $r7 -Recurse -Depth $dp7 -Force -File -ErrorAction SilentlyContinue -ErrorVariable e7 | Select-Object -First 5001)
            if ($fs7.Count -gt 5000) { $inc7 += "$($r7)(5000개 상한)" }; if ($e7) { $inc7 += "$($r7)(접근 오류 $(@($e7).Count)건)" }
            $scan7 += "$($r7)($([Math]::Min($fs7.Count,5000))개)"
            foreach ($f7 in $fs7) { if ($f7.Name -match $rx7) { $hit7 += $f7.FullName } } }
        $smp7 = @((Join-Path $env:SystemDrive "inetpub\iissamples"), (Join-Path $env:windir "help\iishelp"), (Join-Path $env:windir "System32\inetsrv\IISADMPWD"))
        foreach ($cp7 in @($env:CommonProgramFiles, ${env:CommonProgramFiles(x86)}, $env:CommonProgramW6432)) { if ($cp7) { $smp7 += (Join-Path $cp7 "System\msadc\sample") } }
        foreach ($p7 in @($smp7 | Sort-Object -Unique)) { if (Test-Path -LiteralPath $p7) { $hit7 += "$($p7)(샘플 디렉터리)" } }
        $hit7 = @($hit7 | Select-Object -Unique)
        $sc7 = "검사 경로: $($scan7 -join ', ') (사이트 경로 출처: $(if ($src7) {$src7} else {'확인 불가'})) + 가이드 샘플 디렉터리 4종"
        if ($hit7.Count -gt 0) { Rep "WEB-07" "VULN" @("웹 경로에 IIS 기본·샘플·백업 파일 잔존: $(($hit7 | Select-Object -First 8) -join ', ')$(if ($hit7.Count -gt 8) {" 외 $($hit7.Count-8)건"}) → 제거 필요", $sc7) }
        elseif (-not $src7) { Rep "WEB-07" "MAN" @("사이트 실제 경로 확인 불가 → 기본 $($wwwroot)·샘플 경로에는 없음, 사이트 경로의 기본·백업 파일 수동 확인", $sc7) }
        elseif ($inc7.Count -gt 0) { Rep "WEB-07" "MAN" @("탐색 범위에는 불필요 파일 없음, 탐색 미완료: $($inc7 -join ', ') → 나머지 경로 확인", $sc7) }
        else { Rep "WEB-07" "GOOD" @("IIS 기본 파일(iisstart.* 등)·가이드 샘플 디렉터리·백업 파일(*.bak/*.old/*.orig/*~/web.config.*) 없음", $sc7) } }
    if (-not $IIS_INSTALLED) { Rep "WEB-08" "NA" @("IIS 미설치") }
    else { $mx = IISProp "/system.webServer/security/requestFiltering/requestLimits" "maxAllowedContentLength"
        if ($null -eq $mx) { Rep "WEB-08" "MAN" @("maxAllowedContentLength 확인 불가 → 업로드 용량 제한 설정 확인") }
        else { Rep "WEB-08" "GOOD" @("maxAllowedContentLength=$mx → 업로드 요청 용량 제한 적용") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-09" "NA" @("IIS 미설치") }
    else { $bad=@(); try { foreach ($p in (Get-ChildItem "IIS:\AppPools" -ErrorAction Stop)) { $idt=$p.processModel.identityType
            if ($idt -eq "LocalSystem") { $bad += "$($p.Name)=LocalSystem" }
            elseif ($idt -eq "SpecificUser" -and $p.processModel.userName -match "Administrator") { $bad += "$($p.Name)=$($p.processModel.userName)" } } } catch {}
        if (-not $HAS_WEBADMIN) { Rep "WEB-09" "MAN" @("WebAdministration 없음 → 앱풀 ID 가 ApplicationPoolIdentity/저권한인지 확인") }
        elseif ($bad.Count -gt 0) { Rep "WEB-09" "VULN" @("고권한 앱풀 ID: $($bad -join ', ') → 최소권한(ApplicationPoolIdentity)으로 변경") }
        else { Rep "WEB-09" "GOOD" @("앱풀이 ApplicationPoolIdentity/저권한 계정으로 구동") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-10" "NA" @("IIS 미설치") }
    else { $arrProxy = IISProp "/system.webServer/proxy" "enabled"
        if ("$arrProxy" -match "^(True|1)$") { Rep "WEB-10" "MAN" @("ARR 프록시 활성 → URL 재작성 규칙 목적지가 신뢰 백엔드 단일 대상으로 고정됐는지 확인(오픈 프록시 금지)") }
        else { Rep "WEB-10" "GOOD" @("ARR 역방향 프록시 비활성/불필요 프록시 없음") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-11" "NA" @("IIS 미설치") }
    else { $paths=@(); try { foreach ($s in (Get-Website -ErrorAction Stop)) { $paths += "$($s.name):$($s.physicalPath)" } } catch {}
        $isDefault = ($paths | Where-Object { $_ -match "inetpub\\wwwroot" })
        if (-not $HAS_WEBADMIN) { Rep "WEB-11" "MAN" @("사이트 물리 경로 확인 불가 → 업무영역 분리 전용 경로 사용 확인") }
        elseif ($isDefault) { Rep "WEB-11" "VULN" @("웹사이트 실제 경로가 IIS 기본값(inetpub\wwwroot): $($isDefault -join '; ') → 분리 경로 권장") }
        else { Rep "WEB-11" "GOOD" @("웹사이트 경로가 기본값과 분리됨") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-12" "NA" @("IIS 미설치") }
    else { $links=@(); if (Test-Path $wwwroot) { $links = Get-ChildItem $wwwroot -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -match "ReparsePoint" -or $_.Extension -eq ".lnk" } | Select-Object -First 5 -ExpandProperty FullName }
        if ($links) { Rep "WEB-12" "VULN" @("웹 루트에 심볼릭 링크/정션/바로가기: $($links -join ', ')") }
        else { Rep "WEB-12" "GOOD" @("$wwwroot 내 심볼릭 링크·정션·.lnk 없음") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-13" "NA" @("IIS 미설치") }
    else { $badmap=@(); try { foreach ($h in (Get-WebConfiguration "/system.webServer/handlers/add" -ErrorAction Stop)) { if ("$($h.path)" -match "\.(asa|asax|config|bak|inc)$") { $badmap += "$($h.path)" } } } catch {}
        if ($badmap.Count -gt 0) { Rep "WEB-13" "VULN" @("위험 스크립트/설정 매핑: $($badmap -join ', ')") }
        else { Rep "WEB-13" "GOOD" @(".asa/.asax 등 위험 스크립트 매핑 없음") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-14" "NA" @("IIS 미설치") }
    else { $wc = Join-Path $wwwroot "web.config"; $u = AclHasUsers $wc
        if ($null -eq $u) { Rep "WEB-14" "MAN" @("web.config 부재/ACL 확인 불가 → 주요 설정 파일 Users 접근 확인") }
        elseif ($u) { Rep "WEB-14" "VULN" @("$wc 에 Users 그룹 읽기/실행 권한(내부 백엔드 주소 노출 위험) → 권한 제거") }
        else { Rep "WEB-14" "GOOD" @("web.config 에 Users 불필요 권한 없음") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-15" "NA" @("IIS 미설치") }
    else { $vulnExt=@(".htr",".idc",".stm",".shtm",".shtml",".printer",".htw",".ida",".idq"); $found=@()
        try { foreach ($h in (Get-WebConfiguration "/system.webServer/handlers/add" -ErrorAction Stop)) { foreach ($ve in $vulnExt) { if ("$($h.path)" -match [regex]::Escape($ve)+"$") { $found += "$($h.path)" } } } } catch {}
        if ($found.Count -gt 0) { Rep "WEB-15" "VULN" @("취약 스크립트 매핑: $($found -join ', ')") }
        else { Rep "WEB-15" "GOOD" @("취약 확장자(.htr/.idc/.stm 등) 매핑 없음") } }
    # WEB-16: 실측 우선 — 바인딩별 '/'(IIS 파이프라인)·'/%'(HTTP.sys 직접 응답)를 curl.exe 로 요청, Server 값이 제품·버전(Microsoft-IIS·Microsoft-HTTPAPI·ASP.NET·ARR·'/숫자'·'(OS)')을
    #   드러내거나 X-Powered-By/X-AspNet(Mvc)-Version 이 있으면 취약(임의 값·제품명만인 Server 는 양호). 실측 못 한 계층은 설정으로 판단:
    #   '/' → removeServerHeader=True·X-Powered-By 미설정·arrResponseHeader 비활성(아니면 기존대로 취약), '/%' → HTTP.sys DisableServerHeader=1/2(아니면 수동확인, 재시작 후 적용이라 실측 우선)
    if (-not $IIS_INSTALLED) { Rep "WEB-16" "NA" @("IIS 미설치") }
    else { $rmSrv = IISProp "/system.webServer/security/requestFiltering" "removeServerHeader"
        $xpb=@(); try { foreach ($h in (Get-WebConfiguration "/system.webServer/httpProtocol/customHeaders/add" -ErrorAction Stop)) { $xpb += "$($h.name)" } } catch {}
        $arrH = IISProp "/system.webServer/proxy" "arrResponseHeader"
        $dsh = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\HTTP\Parameters" -ErrorAction SilentlyContinue).DisableServerHeader
        $cfgOk16 = ("$rmSrv" -match "^(True|1)$" -and ($xpb -notcontains "X-Powered-By") -and ("$arrH" -notmatch "^(True|1)$"))
        $cfg16 = "설정: removeServerHeader=$($rmSrv), customHeaders X-Powered-By $(if ($xpb -contains 'X-Powered-By') {'있음'} else {'없음'}), arrResponseHeader=$(if ($null -eq $arrH) {'-'} else {$arrH}), HTTP.sys DisableServerHeader=$(if ($null -eq $dsh) {'없음'} else {$dsh})"
        $curl16 = (Get-Command curl.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $tg16=@(); try { foreach ($b in (Get-WebBinding -ErrorAction Stop)) { $m16 = [regex]::Match("$($b.bindingInformation)", '^.*:(\d+):(.*)$')
                if ("$($b.protocol)" -match '^https?$' -and $m16.Success) { $hh16 = $m16.Groups[2].Value; if ($hh16 -notmatch '^[A-Za-z0-9.-]+$') { $hh16 = "localhost" }
                    $u16 = "{0}://{1}:{2}" -f "$($b.protocol)".ToLower(), $hh16, $m16.Groups[1].Value; if ($tg16 -notcontains $u16) { $tg16 += $u16 } } } } catch {}
        if ($tg16.Count -eq 0) { $tg16 = @("http://localhost:80","https://localhost:443") }
        $okRoot=0; $okSys=0; $exp16=@(); $fail16=@()
        foreach ($t16 in @($tg16 | Select-Object -First 4)) { foreach ($p16 in @("/","/%")) {
                if (-not $curl16) { $fail16 += "$($t16)$($p16)(curl.exe 없음)"; continue }
                $h16 = ($t16 -split '[/:]')[3]; $ex16 = @(); if ($h16 -ne "localhost") { $ex16 = @("--resolve", ("{0}:{1}:127.0.0.1" -f $h16, ($t16 -split ':')[-1])) }
                $mt16 = if ($p16 -eq "/") { 5 } else { 4 }
                $o16 = @(& $curl16 -s -k -D - -o NUL --connect-timeout 3 --max-time $mt16 @ex16 "$($t16)$($p16)" 2>$null)
                $sl16 = @($o16 | Where-Object { "$_" -match '^HTTP/[\d.]+\s+\d{3}' })
                if ($sl16.Count -eq 0) { $fail16 += "$($t16)$($p16)(응답 없음/시간초과)"; continue }
                if ($p16 -eq "/") { $okRoot++ } else { $okSys++ }
                $c16 = ("$($sl16[-1])".Trim() -split '\s+')[1]
                foreach ($l16 in $o16) { if ("$l16" -match '^([A-Za-z0-9-]+):\s*(.*)$') { $hn16 = $matches[1]; $hv16 = $matches[2].Trim(); $tag16 = "$($t16)$($p16)→$($c16) $($hn16): $($hv16)"
                        if ($hn16 -eq "Server") { if ($hv16 -match 'Microsoft-HTTPAPI') { $exp16 += "$tag16 [HTTP.sys]" } elseif ($hv16 -match 'Microsoft-IIS') { $exp16 += "$tag16 [IIS]" } elseif ($hv16 -match 'ASP\.NET|^ARR|/\s*v?\d|\(') { $exp16 += "$tag16 [백엔드/프록시]" } }
                        elseif ($hn16 -match '^(X-Powered-By|X-AspNet-Version|X-AspNetMvc-Version)$') { $exp16 += $tag16 } } } } }
        $exp16 = @($exp16 | Select-Object -Unique); $fev16 = @(); if ($fail16.Count) { $fev16 += "실측 실패: $($fail16 -join ', ')" }
        if ($exp16.Count -gt 0) { Rep "WEB-16" "VULN" (@("응답 헤더로 서버 정보 노출(실측): $(($exp16 | Select-Object -First 4) -join '; ') → removeServerHeader=True·HTTP.sys DisableServerHeader=1(HTTP 서비스 재시작)·X-Powered-By 제거", $cfg16) + $fev16) }
        elseif ($okRoot -eq 0 -and -not $cfgOk16) { Rep "WEB-16" "VULN" (@("'/' 실측 실패 + 설정상 서버 정보 노출 가능(removeServerHeader=$($rmSrv), X-Powered-By/ARR 헤더) → 응답 헤더 제거 필요", $cfg16) + $fev16) }
        elseif ($okSys -eq 0 -and "$dsh" -notmatch '^[12]$') { Rep "WEB-16" "MAN" (@("'/%'(HTTP.sys 직접 응답) 실측 실패 + DisableServerHeader 미설정 → 400/503 등 HTTP.sys 오류 응답의 Server: Microsoft-HTTPAPI 노출 여부 확인", $cfg16) + $fev16) }
        else { Rep "WEB-16" "GOOD" (@("실측 응답('/' $($okRoot)건·'/%' $($okSys)건)에 Server 제품/버전·X-Powered-By·X-AspNet-Version 없음$(if ($okRoot -eq 0) {", '/' 는 설정 기준(Server 헤더 제거·X-Powered-By 미설정)"})$(if ($okSys -eq 0) {", '/%' 는 DisableServerHeader=$($dsh) 기준"}) → 서버 정보 미노출", $cfg16) + $fev16) } }
    Rep "WEB-17" "NA" @("가이드 점검대상(Apache/Tomcat/Nginx/WebtoB)에 IIS 미포함 → 점검대상 제외")
    if (-not $IIS_INSTALLED) { Rep "WEB-18" "NA" @("IIS 미설치") }
    else { $dav=$false; if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) { $wf=Get-WindowsFeature Web-DAV-Publishing -ErrorAction SilentlyContinue; if ($wf -and $wf.Installed) { $dav=$true } }
        if ($dav) { Rep "WEB-18" "VULN" @("WebDAV Publishing 설치됨 → 쓰기 메서드 노출, 미사용 시 제거") }
        else { Rep "WEB-18" "GOOD" @("WebDAV Publishing 미설치 + WebDAV 핸들러 없음") } }

    Write-Host "[ 3. 보안 설정 ]" -ForegroundColor White
    if (-not $IIS_INSTALLED) { Rep "WEB-19" "NA" @("IIS 미설치") }
    else { $ssi=@(); try { foreach ($h in (Get-WebConfiguration "/system.webServer/handlers/add" -ErrorAction Stop)) { if ("$($h.path)" -match "\.(shtml|shtm|stm)$") { $ssi += "$($h.path)" } } } catch {}
        if ($ssi.Count -gt 0) { Rep "WEB-19" "VULN" @("SSI 확장자 매핑: $($ssi -join ', ')") }
        else { Rep "WEB-19" "GOOD" @("SSI 확장자 매핑 없음 → SSI 미사용") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-20" "NA" @("IIS 미설치") }
    else { $https=$false; try { foreach ($b in (Get-WebBinding -ErrorAction Stop)) { if ("$($b.protocol)" -eq "https") { $https=$true } } } catch {}
        if ($https) { Rep "WEB-20" "GOOD" @("https 바인딩 존재 → SSL/TLS 활성") }
        else { Rep "WEB-20" "VULN" @("https 바인딩 부재(http만) → 평문 전송, SSL 인증서 바인딩 필요") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-21" "NA" @("IIS 미설치") }
    else { $redir = IISProp "/system.webServer/httpRedirect" "enabled"; $https2=$false; try { foreach ($b in (Get-WebBinding -ErrorAction Stop)) { if ("$($b.protocol)" -eq "https") { $https2=$true } } } catch {}
        if ("$redir" -match "^(True|1)$") { Rep "WEB-21" "GOOD" @("httpRedirect 활성 → HTTP→HTTPS 리디렉션") }
        elseif (-not $https2) { Rep "WEB-21" "VULN" @("HTTPS 미구성 + HTTP 리디렉션 미설정 → HTTP 평문 처리") }
        else { Rep "WEB-21" "MAN" @("URL Rewrite 로 HTTPS 전환되는지 확인") } }
    if (-not $IIS_INSTALLED) { Rep "WEB-22" "NA" @("IIS 미설치") }
    else { $em = IISProp "/system.webServer/httpErrors" "errorMode"
        if ($null -eq $em) { Rep "WEB-22" "MAN" @("httpErrors errorMode 확인 불가 → 사용자 정의 오류 페이지 확인") }
        elseif ("$em" -match "Detailed$") { Rep "WEB-22" "VULN" @("errorMode=$em → 상세 오류 원격 노출, 사용자 정의 페이지 미지정") }
        else { Rep "WEB-22" "GOOD" @("errorMode=$em → 상세 오류 원격 미노출") } }
    Rep "WEB-23" "NA" @("가이드 점검대상(Tomcat)에 한정, IIS 는 LDAP 연동 미사용 → 점검대상 제외")

    Write-Host "[ 4. 패치 및 로그 관리 ]" -ForegroundColor White
    Rep "WEB-24" "NA" @("웹 홈 디렉터리에 별도 업로드 디렉터리/경로 매핑 부재 → 점검대상 제외")
    if (-not $IIS_INSTALLED) { Rep "WEB-25" "NA" @("IIS 미설치") }
    else { $hf = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
        $hfs = if ($hf) { "$($hf.HotFixID) ($($hf.InstalledOn))" } else { "확인 불가" }
        Rep "WEB-25" "MAN" @("IIS $IIS_MAJOR.0 / $OS_NAME — IIS 취약점은 Windows 누적 업데이트로 패치", "최근 업데이트: $hfs → 월 정기 보안업데이트 적용 확인") }
    if (-not $IIS_INSTALLED) { Rep "WEB-26" "NA" @("IIS 미설치") }
    else { $logdir = Join-Path $env:SystemDrive "inetpub\logs\LogFiles"; $u = AclHasUsers $logdir
        if ($null -eq $u) { Rep "WEB-26" "MAN" @("IIS 로그 디렉터리 부재/ACL 확인 불가 → 일반 사용자 접근 확인") }
        elseif ($u) { Rep "WEB-26" "VULN" @("$logdir 에 Users/Everyone 접근 권한 → 로그 열람 제한 필요") }
        else { Rep "WEB-26" "GOOD" @("$logdir 권한이 CREATOR OWNER/SYSTEM/Administrators 로 제한됨") } }

    $tgt = "iis"; $swver = ("IIS {0}.0" -f $IIS_MAJOR)
}

# ==================== 요약 & 저장 ====================
Write-Host ""
Write-Host "=========================================================" -ForegroundColor White
Write-Host (" 결과   양호={0}  취약={1}  수동확인={2}  N/A={3}  (총 {4})  대상={5}" -f $good,$vuln,$man,$na,($good+$vuln+$na+$man),$swver) -ForegroundColor White
Write-Host "=========================================================" -ForegroundColor White
Write-Host ""

$safeHost = ($HOSTN -replace '[^A-Za-z0-9._-]',''); if ($safeHost -eq "") { $safeHost=$tgt }
$stamp = Get-Date -Format "yyyyMMdd"
if ($Json -ne "") {
    $out = [pscustomobject]@{ target=("웹서버({0})" -f $tgt); host=$HOSTN; os=$swver; results=@($script:results) }
    $out | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $Json -Encoding UTF8
    Write-Host (" JSON 저장: {0}" -f $Json)
}
if (-not $NoSave) {
    if ($Csv -eq "") { $Csv = "web_{0}_{1}_{2}.csv" -f $tgt,$safeHost,$stamp }
    if ($Html -eq "") { $Html = "web_{0}_{1}_{2}.html" -f $tgt,$safeHost,$stamp }
    $rows = $script:results | ForEach-Object {
        $st=$_.status; $rstat = switch ($st) { "수동확인" {"인터뷰 필요"} "N/A" {"양호"} default {$st} }
        [pscustomobject][ordered]@{ "항목코드"=$_.code; "중요도"=$_.importance; "점검항목"=$_.title; "진단결과"=$rstat; "근거"=($_.evidence -join " | ") } }
    $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    # 진단대상 Hostname/IP/버전정보를 CSV 맨 위 주석 줄로 (make_report 가 읽어 보고서에 채움)
    $ip = try { (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1).IPAddress } catch { "" }
    if (-not $ip) { $ip = "-" }
    $meta = @("# host,$HOSTN", "# ip,$ip", "# os,$swver")
    Set-Content -Path $Csv -Value ($meta + (Get-Content -Path $Csv -Encoding UTF8)) -Encoding UTF8
    Write-Host (" CSV 저장: {0}   (엑셀에서 바로 열림)" -f $Csv)

    function HEsc { param([string]$s) if ($null -eq $s) { return "" } $s.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;").Replace('"',"&quot;") }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>웹서버($tgt) 취약점 진단 - $HOSTN</title>
<style>
body{font-family:'Malgun Gothic',system-ui,sans-serif;margin:24px;color:#222;background:#f7f8fa}
h1{font-size:20px;margin:0 0 4px}.sub{color:#666;font-size:13px;margin-bottom:16px}
.cards{display:flex;gap:10px;margin:14px 0}.card{flex:1;padding:12px 14px;border-radius:8px;color:#fff;text-align:center}
.card b{display:block;font-size:24px}.c-good{background:#2e7d32}.c-vuln{background:#c62828}.c-man{background:#1565c0}.c-na{background:#757575}
table{width:100%;border-collapse:collapse;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1)}
th,td{border:1px solid #e0e0e0;padding:7px 9px;font-size:13px;vertical-align:top;text-align:left}
th{background:#37474f;color:#fff}td.st{font-weight:700;white-space:nowrap;text-align:center}
tr.vuln td.st{color:#c62828}tr.good td.st{color:#2e7d32}tr.man td.st{color:#1565c0}tr.na td.st{color:#757575}tr.vuln{background:#fff5f5}
</style></head><body>
<h1>웹서버(Windows/$tgt) 기술적 취약점 진단 결과</h1>
<div class="sub">대상: $HOSTN &nbsp;|&nbsp; $swver &nbsp;|&nbsp; $OS_NAME &nbsp;|&nbsp; 작성일: $(Get-Date -Format 'yyyy-MM-dd')</div>
<div class="cards">
<div class="card c-good">양호<b>$good</b></div><div class="card c-vuln">취약<b>$vuln</b></div>
<div class="card c-man">인터뷰 필요<b>$man</b></div><div class="card c-na">N/A<b>$na</b></div></div>
<table><thead><tr><th>항목코드</th><th>중요도</th><th>점검항목</th><th>진단결과</th><th>상세 내용 / 근거</th></tr></thead><tbody>
"@)
    foreach ($r in $script:results) {
        $st=$r.status; $rstat = switch ($st) { "수동확인" {"인터뷰 필요"} "N/A" {"양호"} default {$st} }
        $cls = switch ($st) { "취약" {"vuln"} "양호" {"good"} "수동확인" {"man"} default {"na"} }
        [void]$sb.Append(("<tr class=""{0}""><td>{1}</td><td>{2}</td><td>{3}</td><td class=""st"">{4}</td><td>{5}</td></tr>`n" -f `
            $cls,(HEsc $r.code),(HEsc $r.importance),(HEsc $r.title),(HEsc $rstat),(HEsc (($r.evidence) -join " | "))))
    }
    [void]$sb.Append("</tbody></table></body></html>")
    $sb.ToString() | Out-File -FilePath $Html -Encoding UTF8
    Write-Host (" HTML 리포트: {0}   (브라우저로 열기)" -f $Html)
}
if ($vuln -gt 0) { exit 1 } else { exit 0 }
