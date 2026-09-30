#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""kisa_all_check.ps1 단일 파일 생성기 — 인프라+웹 점검 4종을 하나로 합친다.

    kisa_unix_check.sh     (리눅스 인프라 U-01~U-67)
    kisa_win_check.ps1     (윈도우 인프라 W-01~W-64)
    web_linux_check.sh     (리눅스 웹서버 Nginx/Tomcat WEB-01~WEB-26)
    web_windows_check.ps1  (윈도우 웹서버 IIS/Tomcat WEB-01~WEB-26)

생성 결과 kisa_all_check.ps1 은 bash 와 PowerShell 이 모두 읽을 수 있는 겸용(polyglot) 파일이다.
  - bash 로 실행하면  : 앞부분(bash 파트)만 실행 → 리눅스 인프라 + 웹 점검
  - PowerShell 로 실행 : bash 파트는 블록주석(<# … #>)으로 건너뛰고 → 윈도우 인프라 + 웹 점검
원본 4개 스크립트는 수정 없이 그대로 내장되며(평문, 검토 가능), 실행 시 임시폴더에 풀어 각각 실행한다.
원본을 고치면 이 스크립트를 다시 실행해 재생성한다:

    python build_allinone.py     # → kisa_all_check.ps1

※ 생성 파일은 반드시 LF 줄바꿈이어야 bash 로 돌아간다(.gitattributes 에 eol=lf 지정).
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "kisa_all_check.ps1")

SOURCES = {
    "UNIX": "kisa_unix_check.sh",
    "WEB_LINUX": "web_linux_check.sh",
    "WIN": "kisa_win_check.ps1",
    "WEB_WIN": "web_windows_check.ps1",
}

# ---------------------------------------------------------------------------
# 1) 앞부분 — bash/PowerShell 겸용 헤더 + bash 파트
#    · bash      : 1행 echo(BOM 때문에 'command not found' → 2>&1 로 숨김) 후 : '…' 로 2행까지 무시
#    · PowerShell: 1행 echo --% …(| Out-Null 로 버림), 2행 <# 부터 #> 까지 블록주석
#    bash 파트 안에는 '#>' 문자열이 절대 나오면 안 된다(빌드 시 검사).
# ---------------------------------------------------------------------------
BASH_PART = r"""echo --% >/dev/null 2>&1 ; : ' | Out-Null
<#'
#==============================================================================
# kisa_all_check.ps1 — 인프라 + 웹서버 통합 점검 (리눅스·윈도우 겸용 단일 파일)
#   ※ 자동 생성 파일 — 직접 고치지 말고 원본 수정 후 build_allinone.py 로 재생성
#
#   리눅스 :  sudo bash kisa_all_check.ps1 [옵션]
#   윈도우 :  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1 [옵션]   (관리자)
#
#   1) 인프라 점검    : 리눅스 U-01~U-67 / 윈도우 W-01~W-64
#   2) 웹서비스 점검  : 감지된 웹서버마다 WEB-01~WEB-26
#                      (리눅스 Nginx·Tomcat / 윈도우 IIS·Tomcat, 미감지 시 생략)
#   결과 CSV(+웹은 HTML)는 4종으로 분리 저장 (현재 폴더, 한 번 실행한 결과는 같은 일시):
#     리눅스            server_linux_<호스트>_<YYYYMMDD_HHMM>.csv
#     리눅스 웹서비스   web_linux_<nginx|tomcat>_<호스트>_<YYYYMMDD_HHMM>.csv/.html
#     윈도우            server_windows_<호스트>_<YYYYMMDD_HHMM>.csv
#     윈도우 웹서비스   web_windows_<iis|tomcat>_<호스트>_<YYYYMMDD_HHMM>.csv/.html
#   → python make_reports.py <폴더> 로 바로 보고서 변환 가능
#
#   내장 원본: @@SOURCE_LIST@@
#==============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

kisa_all_usage() {
  cat <<'__KISA_ALL_USAGE__'
사용법 (리눅스):  sudo bash kisa_all_check.ps1 [옵션]
  --only all|infra|web   실행 범위 (기본 all = 인프라 + 웹)
  -o, --out-dir DIR      결과(CSV/HTML) 저장 폴더 (기본: 현재 폴더)
  --no-save              결과 파일 저장 안 함(콘솔 출력만)
  --no-color             색상 끄기
  --force-web            웹서버가 감지되지 않아도 웹 점검 실행
  웹 점검 옵션(지정 시 해당 대상 1회만 점검, 그대로 전달):
    --target nginx|tomcat  --app-url URL  --app-jar JAR  --app-yml FILE  --conf nginx.conf  --nginx BIN
예)
  sudo bash kisa_all_check.ps1
  sudo bash kisa_all_check.ps1 --only web --target tomcat --app-url http://localhost:8080
  sudo bash kisa_all_check.ps1 -o /tmp/kisa_result
결과 파일: server_linux_<호스트>_<일시>.csv (리눅스) / web_linux_<nginx|tomcat>_<호스트>_<일시>.csv·.html (리눅스 웹서비스)
종료코드: 0 = 취약 없음, 1 = 취약 항목 존재, 2 = 실행 오류
__KISA_ALL_USAGE__
}

kisa_all_detect_web() {   # 감지된 웹서버 종류를 한 줄에 하나씩 출력 (nginx / tomcat)
  local b
  for b in nginx /usr/sbin/nginx /usr/local/nginx/sbin/nginx; do
    if command -v "$b" >/dev/null 2>&1; then echo nginx; break; fi
  done
  if ps -eo args 2>/dev/null | grep -iE 'java .*(\.jar|catalina|tomcat)' | grep -v grep >/dev/null; then
    echo tomcat
  fi
}

kisa_all_count() {        # $1=결과 JSON  $2=판정값  → 개수 (파일 없으면 -)
  if [ -f "$1" ]; then grep -o "\"status\":\"$2\"" "$1" | wc -l | tr -d ' '; else printf -- '-'; fi
}

kisa_all_main() {
  local only=all outdir="" force_web=0 nocolor=0 nosave=0 web_opt=0
  local -a common=() webargs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --only)        only="${2:-}"; shift 2 ;;
      -o|--out-dir)  outdir="${2:-}"; shift 2 ;;
      --force-web)   force_web=1; shift ;;
      --no-color)    nocolor=1; shift ;;
      --no-save)     nosave=1; shift ;;
      --target|--conf|--nginx|--app-jar|--app-yml|--app-url|--nginx-url)
                     webargs+=("$1" "${2:-}"); web_opt=1; shift 2 ;;
      -h|--help)     kisa_all_usage; return 0 ;;
      *)             echo "[!] 알 수 없는 옵션: $1  (--help 참고)" >&2; shift ;;
    esac
  done
  case "$only" in all|infra|web) ;; *) echo "[!] --only 는 all | infra | web 중 하나입니다" >&2; return 2 ;; esac
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      echo "[!] 윈도우에서는 PowerShell 로 실행하세요:  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1" >&2
      return 2 ;;
  esac
  [ "$nocolor" -eq 1 ] && common+=(--no-color)
  [ "$nosave" -eq 1 ] && common+=(--no-save)

  local H='' Y='' N=''
  if [ -t 1 ] && [ "$nocolor" -eq 0 ]; then H='\033[1;36m'; Y='\033[1;33m'; N='\033[0m'; fi

  # 내장 원본을 임시폴더(700)에 풀기 — 종료 시 자동 삭제
  local tmp
  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t kisa_all) || { echo "[!] 임시 폴더 생성 실패" >&2; return 2; }
  trap "rm -rf '$tmp'" EXIT
  chmod 700 "$tmp"
  kisa_payload_unix      > "$tmp/kisa_unix_check.sh"
  kisa_payload_web_linux > "$tmp/web_linux_check.sh"

  if [ -n "$outdir" ]; then
    mkdir -p "$outdir" && cd "$outdir" || { echo "[!] 출력 폴더로 이동 실패: $outdir" >&2; return 2; }
  fi
  [ "$(id -u)" -ne 0 ] && echo -e "${Y}[!] root 권한이 아닙니다 → shadow·sshd -T·방화벽 등 일부 항목이 '수동확인'으로 나옵니다 (권장: sudo bash kisa_all_check.ps1)${N}"

  local -a labels=() jsons=() files=()
  local rc=0 f
  # 4종 결과 파일명(한 번 실행한 결과는 같은 일시) — 호스트명 정리 방식은 원본(kisa_unix)과 동일
  local hostn stamp
  hostn=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-'); [ -z "$hostn" ] && hostn=linux
  stamp=$(date +%Y%m%d_%H%M)

  # ---- 1) 리눅스 (인프라) ----
  if [ "$only" != web ]; then
    echo; echo -e "${H}######## [1] 리눅스 — 인프라 U-01~U-67 ########${N}"
    local -a isave=()
    [ "$nosave" -eq 0 ] && isave=(--csv "server_linux_${hostn}_${stamp}.csv")
    bash "$tmp/kisa_unix_check.sh" --json "$tmp/infra.json" "${common[@]}" "${isave[@]}"
    labels+=("리눅스 (인프라 U-01~67)"); jsons+=("$tmp/infra.json")
    [ "$nosave" -eq 0 ] && files+=("server_linux_${hostn}_${stamp}.csv")
  fi

  # ---- 2) 리눅스 웹서비스 ----
  local web_note="" k kinds="" opt_target="" j
  if [ "$only" != infra ]; then
    local detected
    detected=$(kisa_all_detect_web)
    if [ "$web_opt" -eq 1 ]; then
      # 웹 옵션을 직접 준 경우 → 1회 실행. --target 이 없으면 원본(web_linux_check.sh)의
      # 자동 판단 규칙을 그대로 따라 대상을 정한다(파일명에 nginx/tomcat 을 넣기 위해).
      local has_ngx=0 has_java=0 has_conf=0 has_jar=0
      case " $detected " in *" nginx "*) has_ngx=1;; esac
      case " $detected " in *" tomcat "*) has_java=1;; esac
      for ((j = 0; j < ${#webargs[@]}; j += 2)); do
        case "${webargs[$j]}" in
          --target)            opt_target=$(printf '%s' "${webargs[$j+1]}" | tr 'A-Z' 'a-z') ;;
          --nginx)             has_ngx=1 ;;
          --conf)              has_conf=1 ;;
          --app-jar|--app-yml) has_jar=1 ;;
        esac
      done
      if [ -n "$opt_target" ]; then kinds=$opt_target
      elif [ "$has_ngx" -eq 1 ] && { [ "$has_java" -eq 0 ] || [ "$has_conf" -eq 1 ]; }; then kinds=nginx
      elif [ "$has_java" -eq 1 ] || [ "$has_jar" -eq 1 ]; then kinds=tomcat
      else kinds=nginx; fi
    else
      kinds=$detected
      if [ -z "$kinds" ] && { [ "$force_web" -eq 1 ] || [ "$only" = web ]; }; then
        echo -e "${Y}[!] 웹서버(nginx/Java WAS)가 감지되지 않았지만 요청에 따라 기본 대상(nginx)으로 점검합니다.${N}"
        kinds=nginx
      fi
      [ -z "$kinds" ] && web_note="웹서버(nginx/Java WAS) 미감지 → 리눅스 웹서비스 점검 생략  (강제: --force-web 또는 --target nginx|tomcat)"
    fi
    for k in $kinds; do
      echo; echo -e "${H}######## [2] 리눅스 웹서비스 — ${k} WEB-01~WEB-26 ########${N}"
      local -a wsave=() targ=()
      [ "$nosave" -eq 0 ] && wsave=(--csv "web_linux_${k}_${hostn}_${stamp}.csv" --html "web_linux_${k}_${hostn}_${stamp}.html")
      [ -z "$opt_target" ] && targ=(--target "$k")
      bash "$tmp/web_linux_check.sh" "${targ[@]}" --json "$tmp/web_$k.json" "${common[@]}" "${wsave[@]}" "${webargs[@]}"
      labels+=("리눅스 웹서비스 - $k (WEB-01~26)"); jsons+=("$tmp/web_$k.json")
      [ "$nosave" -eq 0 ] && files+=("web_linux_${k}_${hostn}_${stamp}.csv" "web_linux_${k}_${hostn}_${stamp}.html")
    done
  fi

  # ---- 통합 요약 ----
  local i v total_vuln=0
  echo
  echo -e "${H}==============================================================${N}"
  echo -e "${H} 통합 요약  —  $(hostname 2>/dev/null)  ($(date '+%Y-%m-%d %H:%M'))${N}"
  echo -e "${H}==============================================================${N}"
  # 한글은 printf 폭 계산이 어긋나므로 숫자 열을 앞에, 구분명을 맨 뒤에 둔다
  echo "   양호  취약   N/A  수동확인  구분"
  for i in "${!labels[@]}"; do
    v=$(kisa_all_count "${jsons[$i]}" 취약)
    printf ' %6s%6s%6s%10s  %s\n' "$(kisa_all_count "${jsons[$i]}" 양호)" "$v" \
      "$(kisa_all_count "${jsons[$i]}" N/A)" "$(kisa_all_count "${jsons[$i]}" 수동확인)" "${labels[$i]}"
    if [ "$v" = "-" ]; then echo -e "   ${Y}↳ 결과가 생성되지 않았습니다(점검 중 오류) — 위 출력 확인${N}"; rc=2
    else total_vuln=$((total_vuln + v)); fi
  done
  [ -n "$web_note" ] && echo " · $web_note"
  if [ "$nosave" -eq 0 ]; then
    echo " · 결과 파일 (저장 위치: $(pwd))"
    for f in "${files[@]}"; do
      if [ -f "$f" ]; then echo "     $f"; else echo -e "     ${Y}$f  ← 생성 안 됨${N}"; fi
    done
    echo "   → 보고서: python make_reports.py <이 폴더>"
  fi
  echo -e "${H}==============================================================${N}"
  [ "$rc" -ne 0 ] && return "$rc"
  [ "$total_vuln" -gt 0 ] && return 1
  return 0
}

# ------------------------------------------------------------------------------
# 내장 원본 (수정 금지 — build_allinone.py 가 원본 파일에서 그대로 복사)
# ------------------------------------------------------------------------------
kisa_payload_unix() {
  cat <<'__KISA_EMBED_UNIX_EOF__'
@@PAYLOAD_UNIX@@
__KISA_EMBED_UNIX_EOF__
}

kisa_payload_web_linux() {
  cat <<'__KISA_EMBED_WEB_LINUX_EOF__'
@@PAYLOAD_WEB_LINUX@@
__KISA_EMBED_WEB_LINUX_EOF__
}

kisa_all_main "$@"
exit $?
"""

# ---------------------------------------------------------------------------
# 2) 뒷부분 — PowerShell 파트 (bash 는 위에서 exit 하므로 여기까지 오지 않음)
#    param() 블록은 첫 문장이어야 해서 쓸 수 없음 → $args 를 직접 해석한다.
#    내장 원본은 here-string(@' … '@) — 원본에 "'@" 로 시작하는 줄이 있으면 안 된다(빌드 시 검사).
# ---------------------------------------------------------------------------
PS_PART = r"""#>
# ============================ Windows (PowerShell) ============================
$script:KisaCliArgs = @($args)
try { chcp 65001 > $null 2>&1 } catch {}

function Show-KisaAllUsage {
    Write-Host @'
사용법 (윈도우, 관리자 PowerShell):
  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1 [옵션]
  -Only all|infra|web    실행 범위 (기본 all = 인프라 + 웹)
  -OutDir DIR            결과(CSV/HTML) 저장 폴더 (기본: 현재 폴더)
  -NoSave                결과 파일 저장 안 함(콘솔 출력만)
  -NoColor               색상 끄기
  -ForceWeb              웹서버가 감지되지 않아도 웹 점검 실행
  웹 점검 옵션(지정 시 해당 대상 1회만 점검, 그대로 전달):
    -Target iis|tomcat  -AppUrl URL  -AppJar JAR
예)
  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1
  powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1 -Only web -Target tomcat -AppUrl http://localhost:8080
결과 파일: server_windows_<호스트>_<일시>.csv (윈도우) / web_windows_<iis|tomcat>_<호스트>_<일시>.csv·.html (윈도우 웹서비스)
종료코드: 0 = 취약 없음, 1 = 취약 항목 존재, 2 = 실행 오류
'@
}

function Get-KisaAllCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    $r = @($o.results)
    return [pscustomobject]@{
        good = @($r | Where-Object { $_.status -eq '양호' }).Count
        vuln = @($r | Where-Object { $_.status -eq '취약' }).Count
        na   = @($r | Where-Object { $_.status -eq 'N/A' }).Count
        man  = @($r | Where-Object { $_.status -eq '수동확인' }).Count
    }
}

function Invoke-KisaAll {
    param([object[]]$CliArgs)
    $only = "all"; $outDir = ""; $forceWeb = $false; $noColor = $false; $noSave = $false
    $webArgs = @{}
    $i = 0
    while ($i -lt $CliArgs.Count) {
        $raw = [string]$CliArgs[$i]
        $key = (($raw -replace '^[-/]+', '') -replace '-', '').ToLower()     # -OutDir / --out-dir 모두 허용
        $val = if ($i + 1 -lt $CliArgs.Count) { [string]$CliArgs[$i + 1] } else { "" }
        if     ($key -eq 'only')                 { $only = $val.ToLower(); $i += 2 }
        elseif ($key -in @('o', 'outdir'))       { $outDir = $val; $i += 2 }
        elseif ($key -eq 'forceweb')             { $forceWeb = $true; $i++ }
        elseif ($key -eq 'nocolor')              { $noColor = $true; $i++ }
        elseif ($key -eq 'nosave')               { $noSave = $true; $i++ }
        elseif ($key -eq 'target')               { $webArgs['Target'] = $val; $i += 2 }
        elseif ($key -eq 'appjar')               { $webArgs['AppJar'] = $val; $i += 2 }
        elseif ($key -in @('appurl', 'nginxurl')) { $webArgs['AppUrl'] = $val; $i += 2 }
        elseif ($key -in @('h', 'help', '?'))    { Show-KisaAllUsage; return 0 }
        else { Write-Host ("[!] 알 수 없는 옵션: {0}  (-Help 참고)" -f $raw) -ForegroundColor Yellow; $i++ }
    }
    if ($only -notin @('all', 'infra', 'web')) { Write-Host "[!] -Only 는 all | infra | web 중 하나입니다" -ForegroundColor Red; return 2 }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Write-Host "[!] 리눅스에서는 bash 로 실행하세요:  sudo bash kisa_all_check.ps1" -ForegroundColor Red
        return 2
    }
    $hc = if ($noColor) { 'Gray' } else { 'Cyan' }
    $yc = if ($noColor) { 'Gray' } else { 'Yellow' }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Host "[!] 관리자 권한이 아닙니다 → 보안정책·SAM·감사정책 등 일부 항목이 '수동확인'으로 나옵니다 (관리자 PowerShell 권장)" -ForegroundColor $yc }

    # 내장 원본을 임시폴더에 풀기(UTF-8 BOM — PowerShell 5.1 한글) — 종료 시 자동 삭제
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kisa_all_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($true)
    $infraPs = Join-Path $tmp "kisa_win_check.ps1"
    $webPs   = Join-Path $tmp "web_windows_check.ps1"
    [IO.File]::WriteAllText($infraPs, $script:KISA_PAYLOAD_WIN, $enc)
    [IO.File]::WriteAllText($webPs, $script:KISA_PAYLOAD_WEB_WIN, $enc)

    # ※ 하위 스크립트 호출을 try 로 감싸면 안 된다 — 호출 스택에 try 가 있으면 PowerShell 이
    #   하위 스크립트의 ErrorActionPreference(SilentlyContinue)를 무시하고 오류를 위로 던져
    #   단독 실행과 결과가 달라진다. 임시폴더 정리는 최상위에서 호출 뒤에 한다.
    $script:KisaTmp = $tmp
    $labels = New-Object System.Collections.ArrayList
    $jsons  = New-Object System.Collections.ArrayList
    $files  = New-Object System.Collections.ArrayList
    $webNote = ""
    if ($outDir -ne "") {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        Push-Location -LiteralPath $outDir; $script:KisaPushed = $true
    }
    $common = @{}
    if ($noColor) { $common['NoColor'] = $true }
    if ($noSave)  { $common['NoSave']  = $true }
    # 4종 결과 파일명(한 번 실행한 결과는 같은 일시) — 호스트명 정리 방식은 원본(kisa_win)과 동일
    $hostn = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', ''); if ($hostn -eq "") { $hostn = "windows" }
    $stamp = Get-Date -Format "yyyyMMdd_HHmm"

    # ---- 1) 윈도우 (인프라) ----
    if ($only -ne 'web') {
        Write-Host ""; Write-Host "######## [1] 윈도우 — 인프라 W-01~W-64 ########" -ForegroundColor $hc
        $j = Join-Path $tmp "infra.json"
        $ia = @{} + $common
        if (-not $noSave) { $ia['Csv'] = "server_windows_{0}_{1}.csv" -f $hostn, $stamp; [void]$files.Add($ia['Csv']) }
        & $infraPs -Json $j @ia | Out-Host
        [void]$labels.Add("윈도우 (인프라 W-01~64)"); [void]$jsons.Add($j)
    }

    # ---- 2) 윈도우 웹서비스 ----
    if ($only -ne 'infra') {
        $hasIis = [bool]((Test-Path "HKLM:\SOFTWARE\Microsoft\InetStp") -or (Get-Service W3SVC -ErrorAction SilentlyContinue))
        $jp = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -match '\.jar' } | Select-Object -First 1
        $kinds = @()
        if ($webArgs.Count -gt 0) {
            # 웹 옵션을 직접 준 경우 → 1회 실행. -Target 이 없으면 원본(web_windows_check.ps1)의
            # 자동 판단 규칙(java 프로세스/AppJar 있으면 tomcat, 아니면 iis)을 그대로 따른다.
            if ($webArgs.ContainsKey('Target') -and $webArgs['Target']) { $kinds = @(([string]$webArgs['Target']).ToLower()) }
            elseif ($jp -or $webArgs.ContainsKey('AppJar')) { $kinds = @('tomcat') }
            else { $kinds = @('iis') }
        } else {
            if ($hasIis) { $kinds += 'iis' }
            if ($jp) { $kinds += 'tomcat' }
            if ($kinds.Count -eq 0 -and ($forceWeb -or $only -eq 'web')) {
                Write-Host "[!] 웹서버(IIS/Java WAS)가 감지되지 않았지만 요청에 따라 기본 대상(iis)으로 점검합니다." -ForegroundColor $yc
                $kinds = @('iis')
            }
            if ($kinds.Count -eq 0) { $webNote = "웹서버(IIS/Java WAS) 미감지 → 윈도우 웹서비스 점검 생략  (강제: -ForceWeb 또는 -Target iis|tomcat)" }
        }
        foreach ($k in $kinds) {
            Write-Host ""; Write-Host ("######## [2] 윈도우 웹서비스 — {0} WEB-01~WEB-26 ########" -f $k) -ForegroundColor $hc
            $j = Join-Path $tmp ("web_{0}.json" -f $k)
            $wa = @{} + $common + $webArgs; $wa['Target'] = $k
            if (-not $noSave) {
                $wa['Csv']  = "web_windows_{0}_{1}_{2}.csv"  -f $k, $hostn, $stamp; [void]$files.Add($wa['Csv'])
                $wa['Html'] = "web_windows_{0}_{1}_{2}.html" -f $k, $hostn, $stamp; [void]$files.Add($wa['Html'])
            }
            & $webPs -Json $j @wa | Out-Host
            [void]$labels.Add(("윈도우 웹서비스 - {0} (WEB-01~26)" -f $k)); [void]$jsons.Add($j)
        }
    }

    # ---- 통합 요약 ----
    $rc = 0; $totalVuln = 0
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor $hc
    Write-Host (" 통합 요약  —  {0}  ({1})" -f $env:COMPUTERNAME, (Get-Date -Format "yyyy-MM-dd HH:mm")) -ForegroundColor $hc
    Write-Host "==============================================================" -ForegroundColor $hc
    Write-Host "   양호  취약   N/A  수동확인  구분"
    for ($n = 0; $n -lt $labels.Count; $n++) {
        $c = Get-KisaAllCount $jsons[$n]
        if ($null -eq $c) {
            Write-Host (" {0,6}{1,6}{2,6}{3,10}  {4}" -f "-", "-", "-", "-", $labels[$n])
            Write-Host "   ↳ 결과가 생성되지 않았습니다(점검 중 오류) — 위 출력 확인" -ForegroundColor $yc
            $rc = 2
        } else {
            Write-Host (" {0,6}{1,6}{2,6}{3,10}  {4}" -f $c.good, $c.vuln, $c.na, $c.man, $labels[$n])
            $totalVuln += $c.vuln
        }
    }
    if ($webNote -ne "") { Write-Host (" · {0}" -f $webNote) }
    if (-not $noSave) {
        Write-Host (" · 결과 파일 (저장 위치: {0})" -f (Get-Location).Path)
        foreach ($f in $files) {
            if (Test-Path -LiteralPath $f) { Write-Host ("     {0}" -f $f) }
            else { Write-Host ("     {0}  ← 생성 안 됨" -f $f) -ForegroundColor $yc }
        }
        Write-Host "   → 보고서: python make_reports.py <이 폴더>"
    }
    Write-Host "==============================================================" -ForegroundColor $hc
    if ($rc -ne 0) { return $rc }
    if ($totalVuln -gt 0) { return 1 }
    return 0
}

# ------------------------------------------------------------------------------
# 내장 원본 (수정 금지 — build_allinone.py 가 원본 파일에서 그대로 복사)
# ------------------------------------------------------------------------------
$script:KISA_PAYLOAD_WIN = @'
@@PAYLOAD_WIN@@
'@

$script:KISA_PAYLOAD_WEB_WIN = @'
@@PAYLOAD_WEB_WIN@@
'@

$script:KisaTmp = $null; $script:KisaPushed = $false
$kisaRc = Invoke-KisaAll -CliArgs $script:KisaCliArgs
if ($script:KisaPushed) { Pop-Location }
if ($script:KisaTmp) { Remove-Item -LiteralPath $script:KisaTmp -Recurse -Force -ErrorAction SilentlyContinue }
exit ([int]($kisaRc | Select-Object -Last 1))
"""


def _read(name):
    """원본을 읽어 BOM 제거 + LF 정규화(작업트리 autocrlf 와 무관하게 같은 결과)."""
    with open(os.path.join(HERE, name), "rb") as f:
        data = f.read()
    text = data.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
    return text.rstrip("\n")


def main():
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    src = {k: _read(v) for k, v in SOURCES.items()}

    # ---- 겸용 파일이 깨지지 않기 위한 제약 검사 ----
    errs = []
    for k in ("UNIX", "WEB_LINUX"):
        if "#>" in src[k]:
            errs.append(f"{SOURCES[k]}: '#>' 가 있으면 PowerShell 블록주석이 조기 종료됨")
        if f"__KISA_EMBED_{k}_EOF__" in src[k]:
            errs.append(f"{SOURCES[k]}: heredoc 종료자와 같은 문자열 포함")
    for k in ("WIN", "WEB_WIN"):
        if any(line.startswith("'@") for line in src[k].split("\n")):
            errs.append(f"{SOURCES[k]}: \"'@\" 로 시작하는 줄이 있으면 here-string 이 조기 종료됨")
    if errs:
        sys.exit("[!] 생성 불가:\n  - " + "\n  - ".join(errs))

    ids = ", ".join(f"{SOURCES[k]}({hashlib.sha1(src[k].encode()).hexdigest()[:8]})"
                    for k in ("UNIX", "WIN", "WEB_LINUX", "WEB_WIN"))
    bash = (BASH_PART.replace("@@SOURCE_LIST@@", ids)
            .replace("@@PAYLOAD_UNIX@@", src["UNIX"])
            .replace("@@PAYLOAD_WEB_LINUX@@", src["WEB_LINUX"]))
    ps = (PS_PART.replace("@@PAYLOAD_WIN@@", src["WIN"])
          .replace("@@PAYLOAD_WEB_WIN@@", src["WEB_WIN"]))

    # bash 파트(2행 '<#' 이후)에 '#>' 가 섞이면 안 됨 — 조립 후 최종 확인
    body = bash.split("\n", 2)[2]
    if "#>" in body:
        sys.exit("[!] 생성 불가: bash 파트에 '#>' 포함")

    out = bash + ps
    with open(OUT, "wb") as f:
        f.write(b"\xef\xbb\xbf" + out.encode("utf-8"))   # BOM: PowerShell 5.1 한글 / LF: bash
    print(f"[+] 생성: {OUT}  ({os.path.getsize(OUT):,} bytes)")
    print(f"    내장: {ids}")


if __name__ == "__main__":
    main()
