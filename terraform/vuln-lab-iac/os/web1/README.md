# web1 — 고객 웹 프런트 (Windows Server 2019, IIS 10 + ARR 역방향 프록시)

2026-10-02 조치 뒤의 운영 OS 상태를 정리하고, 같은 상태를 새 인스턴스에 다시 만드는 방법을 적었다.
라이브 접속 없이 아래 출처만 썼다. 각 주장 끝의 `[..]`가 출처다.

| 표기 | 출처 (경로 기준: `C:\claude_work\infra_diag_0929\`) |
|---|---|
| [R1] | `report_1002\조치결과_보고_20261002.md` (10/2 조치 결과 보고) |
| [R2] | `report_1001\조치명령_서버별_20261002.md` 5절 (web1 조치 명령) |
| [A] | `results\apply\web1\20261002-*.log` (10/2 SSM 실행 로그), `apply_scripts\web1\*.ps1` |
| [E4] | `results\rfix4_infra_web1.json`, `results\rfix4_web_web1.json` (10/2 11:43 KST 조치 후 재진단) |
| [E6] | `results\ad1002b_infra_web1.json` (10/2 13:04 KST, 진단 스크립트 수정판으로 재진단) |
| [WF] | `wf_result_v2.json` web1 항목 (9/29~9/30 실서버 읽기 전용 실측, 조치 이전) |
| [D1] | `report_1001\취약항목_판단기준_조치방법_20261001.md` (10/1 실측 기록) |
| [RP] | `remediation_plan.md` web1 절 |
| [FIN] | `results\final_infra_web1.json` (9/30 진단, 자동 시작 서비스 목록) |
| [INV] | `C:\claude_work\vuln-lab-iac\_inventory\inventory.json` (AWS 읽기 전용 조회, 10/6) |
| [DEP] | `C:\claude_work\Remove-vulnerabilities\deploy\V5_DEPLOYMENT.md`, `customer-web.config.v5.example` |

[WF]는 조치 이전 측정값이다. 10/2 조치와 관계없는 항목은 [E4]에서 같은 값으로 다시 확인됐다.

## 1. 인스턴스

| 항목 | 값 |
|---|---|
| 인스턴스 | `i-0640686af1bcd3002` (Name=web1), 현재 **stopped** [INV] |
| AMI | `ami-0ae94fb345ba94c74` = `Windows_Server-2019-English-Full-Base-2026.09.09` (Amazon 제공) [INV, aws ec2 describe-images] |
| OS | Windows Server 2019 Datacenter 1809, Build 17763.9245 (KB5122876, 2026-09 LCU, AMI 내장) [E4 W-27, WF W-38] |
| 타입 / 서브넷 / IP | t3.small / `subnet-00cf9ec7ae8b5ded6` / 10.0.2.8, 공인 IP 없음 [INV] |
| 보안 그룹 / IAM | `vuln-lab-web` (sg-090541087ae489f84) / `vuln-lab-ec2-app-profile` [INV] |
| 호스트 이름 | `EC2AMAZ-A863V5R` (EC2Launch 자동 생성, 새 인스턴스에서는 달라짐) [A] |
| 디스크 | C: 1개, NTFS, 32GB [WF W-61] |
| 도메인 | WORKGROUP (도메인 미가입) [WF W-04] |
| user_data | `os/web1/user_data.tpl` (운영값과 바이트 동일, `<persist>true</persist>`) |

## 2. 아키텍처 안의 역할

```
인터넷 → ex-alb :443 (HTTPS) → tg-web (HTTP 80, 헬스체크 /health, 정상코드 200,302)
       → web1 IIS(Default Web Site, URL Rewrite + ARR)
       → https://internal-in-alb-1262980660.ap-northeast-2.elb.amazonaws.com:443
       → in-alb :443 → tg-was (HTTP 8080) → was1 (고객 Spring Boot 앱)
ex-alb :80 은 443 으로 리다이렉트
```
- 출처: tg/리스너 [INV], 프록시 규칙 [A W-18_health 로그, WF WEB-10]
- web1에는 업무 데이터나 앱이 없다. 모든 요청을 in-alb로 넘긴다.
- `/health`도 백엔드로 넘어가므로 was1이 응답해야 302가 나온다.
  - 10/2 02:08 UTC부터 was1 장애 동안 502가 났다 [A W-18_rollback].

## 3. 설치 소프트웨어

| 소프트웨어 | 상태·버전 | 출처 |
|---|---|---|
| IIS 10.0 (Web-Server, Web-WebServer, Web-Filtering, Web-Mgmt-Console) | 설치. W3SVC Running/Automatic, WAS Running | [WF W-19·WEB-01·WEB-08, A 00_precheck] |
| IIS URL Rewrite (rewrite.dll, RewriteModule) | 설치, 버전 미확인 | [WF W-19·WEB-05] |
| Application Request Routing (requestRouter.dll) | 설치, 버전 미확인. proxy enabled=True | [WF W-19·WEB-10] |
| 미설치 IIS 기능 | Web-Http-Redirect, Web-ASP, Web-Asp-Net45, Web-CGI, Web-ISAPI-*, Web-Includes, Web-DAV-Publishing, Web-Ftp-*, Web-Mgmt-Service | [WF WEB-05·WEB-13·WEB-18·WEB-19·W-21·WEB-02] |
| OpenSSH Server | sshd Running/Automatic (user_data 설치) | [A 00_precheck, WF W-37] |
| Amazon SSM Agent | Running/Automatic | [A 00_precheck] |
| Amazon CloudWatch Agent | Running. 로그 그룹 `/ec2/web1/windows-event`로 전송. 설정 파일 미확보 | [FIN W-62, RP W-62, INV log_groups] |
| Microsoft Defender | 실시간 보호 사용, 엔진 1.1.26080.3 | [WF W-39·W-45] |

## 4. 서비스와 포트

| 포트 | 프로세스 | 용도 |
|---|---|---|
| TCP 80 / 443 | System (HTTP.sys) → IIS | 사이트 바인딩 `http *:80`, `https *:443`. ALB는 80만 쓴다 |
| TCP 22 | sshd | SSH |
| TCP 3389 | TermService | RDP (NLA, TLS) |
| TCP 135 / 445 / 5985 / 47001, 동적 RPC | Windows 기본 | 방화벽에 허용 규칙이 없어 외부 차단 |

출처: [A 00_precheck], [WF W-21]

## 5. 주요 설정 위치

| 대상 | 경로 / 값 | 출처 |
|---|---|---|
| 사이트 | `Default Web Site` (id 1), physicalPath `C:\WebRoot`, 앱 풀 DefaultAppPool (ApplicationPoolIdentity) | [WF WEB-09·WEB-11] |
| 사이트 설정 | `C:\WebRoot\web.config` (2,118B, 9/29 00:57 수정). 원문 미확보 → 조각 `files/WebRoot/web.config.fragment.xml` | [A 00_precheck, WF WEB-10·WEB-21·WEB-22] |
| 오류 페이지 | `C:\WebRoot\error.html` (212B, 일반 문구). 원문 미확보 | [WF WEB-22] |
| 규칙 HttpsRedirect | `{HTTP_X_FORWARDED_PROTO}`가 `^http$`이면 `https://{HTTP_HOST}/{R:1}`로 301 | [WF WEB-21] |
| 규칙 ReverseProxy | `(.*)` → `https://internal-in-alb-...:443/{R:1}` Rewrite, stopProcessing | [A W-18_health, WF WEB-07·WEB-10] |
| 서버 수준 | ARR proxy enabled=True, preserveHostHeader=True, arrResponseHeader=False / requestFiltering removeServerHeader=True / `<location path="Default Web Site">` httpErrors existingResponse=PassThrough / maxAllowedContentLength 기본 30,000,000 | [WF WEB-08·WEB-10·WEB-16·WEB-22] |
| 인증서 | `Cert:\LocalMachine\My`, CN=web1.zerodayclinic.local, 만료 2027-09-28, 지문 659DC41B…F410 | [WF WEB-20] |
| HTTP.sys | `HKLM\SYSTEM\CurrentControlSet\Services\HTTP\Parameters\DisableServerHeader=2` (10/2) | [A WEB-16] |
| IIS 로그 | `%SystemDrive%\inetpub\logs\LogFiles\W3SVC1`, W3C | [A 00_precheck, WF WEB-26] |
| 백업 | `C:\Backup\` (W-40, W-42, W-47, W-64, iis-webconfig, http-parameters-before.reg) | [R1 7절, A] |

## 6. 사용자·그룹

| 계정 | 상태 | 비고 |
|---|---|---|
| ZD_ADM (SID …-500) | 사용 | 기본 Administrator를 개명. 프로필 `C:\Users\Administrator` [E4 W-01, WF W-01] |
| ZD_RDP (SID …-1008) | 사용 | 설명 'Dedicated RDP (W-14)'. Remote Desktop Users 단독 구성원, 비관리자. PasswordRequired=False 플래그가 있음 [WF W-03·W-09·W-14] |
| ssm-user (SID …-1009) | 사용 안 함 | SSM Agent가 세션 때 만들고 Administrators에 넣는다 [WF W-06] |
| Guest, DefaultAccount, WDAGUtilityAccount | 사용 안 함 | [E4 W-02·W-03] |

- Administrators 구성원: ZD_ADM, ssm-user [E4 W-06].

## 7. 보안 설정 상태 (10/2 조치 후)

### 7.1 10/2 이전부터 있던 설정 (팀 사전 조치, [E4]에서 양호 재확인)

| 항목 | 값 | 출처 |
|---|---|---|
| W-04·W-08 계정 잠금 | 임계값 5회, 잠금 60분, 재설정 60분 | [WF W-04·W-08] |
| W-05·W-09 암호 정책 | 복잡성 사용, 최소 8자, 최대 90일, 최소 1일, **기록 12개**, 해독 가능 저장 안 함 | [WF W-05·W-09] |
| W-10·W-48·W-57 | DontDisplayLastUserName=1, ShutdownWithoutLogon=0, 로그온 경고 'Warning' / 'Authorized users only. Access is monitored. ' | [WF W-10·W-48·W-57] |
| W-11·W-14·W-49 사용자 권한 | 로컬 로그온=Administrators, 원격 데스크톱 로그온=Administrators+Remote Desktop Users, 원격 종료=Administrators | [WF W-11·W-14·W-49] |
| W-07·W-12·W-13·W-50·W-51·W-59 (LSA) | EveryoneIncludesAnonymous=0, LSAAnonymousNameLookup=0, LimitBlankPasswordUse=1, CrashOnAuditFail=0, RestrictAnonymous=1, RestrictAnonymousSAM=1, LmCompatibilityLevel=5 | [WF] |
| W-15 | ForceKeyProtection=2 | [WF W-15] |
| W-16·W-17·W-23·W-56 (SMB) | 공유는 IPC$뿐, AutoShareServer=0, RestrictNullSessAccess=1, SMB1 꺼짐, EnableForcedLogOff=1, autodisconnect=15 | [WF] |
| W-20 | 모든 인터페이스 NetBIOS over TCP/IP 사용 안 함(NetbiosOptions=2) | [WF W-20] |
| W-18·W-44 서비스 | Spooler, TrkWks, RemoteRegistry, upnphost, SSDPSRV = Stopped/Disabled | [WF W-18·W-44] |
| W-28·W-36 RDP | MinEncryptionLevel=3, SecurityLayer=2, NLA=1 / 정책 MaxIdleTime·MaxDisconnectionTime=30분, fResetBroken=1 | [WF W-28·W-36] |
| W-41 시각 동기화 | W32Time NTP 169.254.169.123,0x9 | [WF W-41] |
| W-52·W-53·W-54·W-55·W-60 | AutoAdminLogon=0, AllocateDASD=0, SynAttackProtect=1 등 TCP 4개, AddPrinterDrivers=1, Netlogon 서명 3개=1 | [WF] |
| W-40 (일부) | 계정 관리·계정 로그온·권한 사용·로그온/로그오프·정책 변경 하위 9개 Success and Failure | [E4 W-40] |
| W-47 (일부) | HKLM 정책 값, HKU\.DEFAULT 값은 있었으나 사용자 하이브에는 없었음 | [WF W-47] |
| IIS | 디렉터리 검색 꺼짐, CGI/ISAPI 미허용, 상위 경로 차단, wwwroot 기본 파일 삭제, `C:\WebRoot` ACL에 Users 없음, 로그 경로 SYSTEM·Administrators만 | [E4 WEB-04~WEB-26] |
| Windows Update 정책 | AU AUOptions=3 (자동 다운로드, 설치는 수동) | [WF W-27·W-38] |

### 7.2 2026-10-02 조치 (SSM으로 적용, [R1] 2절·[R2] 5절·[A])

| 항목 | 내용 | 확인 |
|---|---|---|
| W-40 | `auditpol /set /category:"DS Access" /failure:enable` → Directory Service Access = Success and Failure | [A W-40 로그] |
| W-42 | Security·Application·System `wevtutil sl /rt:true /ab:true` → AutoBackup, 최대 20MB | [A W-42 로그] |
| W-47 | ZD_ADM·ZD_RDP 하이브 `Software\Policies\Microsoft\Windows\Control Panel\Desktop`에 ScreenSaveActive=1, ScreenSaverIsSecure=1, ScreenSaveTimeOut=600, SCRNSAVE.EXE=scrnsave.scr | [A W-47 로그, E4 W-47] |
| W-64 | user data 부팅 작업 `Amazon Ec2 Launch - Userdata Execution` 비활성화, 방화벽 3개 프로필 사용(기본 인바운드 차단), 02:00:06 UTC | [A W-64 로그] |
| WEB-07 | `C:\WebRoot\web.config.before-*` 백업 6개를 `C:\Backup\iis-webconfig`로 이동 | [A WEB-07 로그] |
| WEB-16 | HTTP.sys DisableServerHeader=2 + 재부팅(02:04 UTC). `/%` 400 응답에서 Server 헤더 사라짐 | [A WEB-16·WEB-16_post 로그] |
| W-37 | 조치 항목이 아니다. W-64로 user data 작업이 꺼져 인터뷰 필요에서 양호로 바뀜 | [R1 2절, E4 W-37] |

방화벽 허용 규칙 (모두 Inbound / Allow / Profile Any / 원격 Any) [A 00_precheck·W-64]

| 규칙 | 프로토콜/포트 |
|---|---|
| World Wide Web Services (HTTP Traffic-In) | TCP 80 |
| World Wide Web Services (HTTPS Traffic-In) | TCP 443 |
| ZD-Allow-SVC-80 | TCP 80 |
| OpenSSH SSH Server (sshd) | TCP 22 |
| ZD-Allow-RDP-3389 | TCP 3389 |
| ZD-Allow-ICMP | ICMPv4 |

### 7.3 시험 후 원복: W-18 (Cryptographic Services)

- 01:57 UTC에 중지·사용 안 함으로 바꿨으나 Windows가 바로 '수동'으로 되돌리고 다시 켰다 [A W-18 retry, WEB-16_post 7040 이벤트].
  - 새 PowerShell 프로세스가 뜰 때 다시 켜진다.
- 문서 롤백으로 **Automatic/Running**으로 복구했다(11:13 KST) [A W-18_rollback].

## 8. 의도적으로 남긴 취약 항목

| 항목 | 상태 | 이유 |
|---|---|---|
| W-18 | 취약(CryptSvc 실행 중) [E4, R1 4절] | 유지 불가(시험 결과). Windows Update·서명 확인에 필요하다. 예외 처리 권고 [R1 4절] |

- 13:04 KST 수정판 진단 [E6]은 W-18을 '양호'(Microsoft 필수 서비스로 판정 제외)로 냈다. 보고서 [R1]은 남은 취약으로 집계했다.
- 그 밖의 인터뷰 필요 항목: W-03, W-06(ssm-user 관리자), W-14, W-19, W-27·W-38(패치 절차, 최신 OOB KB5129238 미설치), W-33, W-62, WEB-10, WEB-14, WEB-25 [E4, WF].

## 9. 운영 주의

- user data 부팅 작업이 꺼져 있다. 그래서 user_data를 고쳐도 다음 부팅에 반영되지 않는다 [R1 5절].
  - 다시 켜면 부팅마다 방화벽 3개 프로필이 꺼진다.
  - 'net user Administrator'(이름 변경으로 실패), OpenSSH 설치, authorized_keys 덮어쓰기도 다시 돈다 [WF W-37].
- 이벤트 로그 보관본(`Archive-*.evtx`)이 계속 쌓인다. Security는 하루 약 20MB다. C: 여유 공간을 본다 [R2 W-42].
- 백엔드 주소(in-alb DNS 이름)가 web.config에 하드코딩돼 있다. in-alb를 다시 만들면 web.config를 고친다.
- 인스턴스는 10/6 08:22 UTC에 기동 기록이 있다(LaunchTime) [INV]. 10/2 이후 OS 변경을 보여 주는 자료는 없다.

## 10. 보안 확인 필요 (조치 범위 밖)

- `C:\Windows\Temp\UserScript.ps1`에 평문 관리자 비밀번호가 남아 있을 수 있다.
  - 10/1 두 서버에 있었다 [D1 W-64 절]. 10/2에는 삭제하지 않았다(권고만).
- `C:\Backup`은 상속 ACL(Users 읽기)이다 [A WEB-07 로그] `baseline.ps1` 기본 동작도 이 상태를 유지한다. `-HardenBackupAcl` 을 주면 Administrators·SYSTEM 만 남긴다(운영과 다름).
  - 그 아래 `W-47`에 NTUSER.DAT 백업이 있다. `iis-webconfig`만 Administrators·SYSTEM으로 제한했다.
- HTTPS 바인딩은 OS 기본 SCHANNEL 설정을 쓴다. 그래서 TLS 1.0도 협상된다 [WF WEB-20, 판정 밖 권고].

## 11. 스크립트로 재현할 수 없는 것

- 운영 `web.config` 원문(2,118B)과 `error.html` 원문(212B)
  - 증거로 재구성한 조각과 자리표시자만 넣는다(`TODO(확인필요)`).
- TLS 인증서 개인 키
  - 같은 CN으로 새 자체 서명 인증서를 만든다. 지문이 달라지고, 발급 방식은 미확인이다.
- URL Rewrite·ARR 설치 파일과 버전
  - MSI는 직접 받아 `-UrlRewriteMsi`·`-ArrMsi`로 넘긴다.
- CloudWatch Agent 설정 JSON(미확보)
- 계정 비밀번호(ZD_ADM은 user_data의 `server_password`, ZD_RDP는 비밀값), 로컬 SID, 호스트 이름
- ssm-user(SSM Agent가 만듦), 이벤트 로그·IIS 로그 내용, `C:\Backup` 안의 조치 전 백업본
- 조치 전 백업 파일들(web.config.before-* 6개)
  - 새 인스턴스에는 생기지 않는다.
- 감사 정책 중 9개 하위 범주 밖의 운영값(전체 목록 미확보)

## 12. 재현 방법

1. Terraform(`compute.tf`의 `aws_instance.web1`)으로 같은 AMI와 `user_data.tpl`로 인스턴스를 만든다.
   - user_data가 첫 부팅에 다음을 실행한다.
     - Administrator 비밀번호 설정
     - RDP 허용, 방화벽 끄기
     - OpenSSH 설치, 키 등록
2. `os/web1` 폴더를 인스턴스에 복사한다. 예: `C:\zd-baseline`
3. 비밀값을 준비한다.
   - `ZD_RDP_PASSWORD` 환경변수를 넣는다.
   - 또는 SSM SecureString `/vuln-lab/web1/zd_rdp_password`를 쓴다. 이름은 제안값이며 아직 없다.
   - SSM을 쓸 때는 인스턴스 역할에 `ssm:GetParameter` 권한이 있는지 확인한다(미확인).
4. 관리자 PowerShell 또는 SSM Run Command로 실행한다.
   ```powershell
   cd C:\zd-baseline
   .\baseline.ps1 -UrlRewriteMsi C:\setup\rewrite_amd64_en-US.msi -ArrMsi C:\setup\requestRouter_amd64.msi -Reboot
   ```
   - 다시 실행해도 결과가 같다.
   - W-47 사용자 하이브는 로그온 세션이 없을 때만 바뀐다.
   - ZD_RDP 프로필은 첫 로그온 뒤에 생긴다. 그래서 첫 로그온 뒤 한 번 더 실행한다.
5. 확인(읽기 전용)
   - `curl.exe -s -i "http://localhost/%"`에 Server 헤더가 없어야 한다.
   - `netsh advfirewall show allprofiles state`가 3개 모두 ON이어야 한다.
   - `auditpol /get /category:"DS Access"`, `Get-WinEvent -ListLog Security,Application,System`을 본다.
   - tg-web 헬스체크가 healthy인지 본다(was1과 in-alb가 정상이어야 한다).

파일

| 파일 | 내용 |
|---|---|
| `user_data.tpl` | 운영 user_data 템플릿(수정 금지) |
| `baseline.ps1` | 위 7절 상태를 재현하는 스크립트 |
| `files/WebRoot/web.config.fragment.xml` | 증거로 재구성한 web.config 조각(원본 아님, 머리말에 근거 표기) |
