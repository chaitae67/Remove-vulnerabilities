# was1 — 고객 WAS (Windows Server 2019, Spring Boot 내장 Tomcat, nssm 서비스)

2026-10-02 조치 뒤의 운영 OS 상태를 정리하고, 같은 상태를 새 인스턴스에 다시 만드는 방법을 적었다.
라이브 접속 없이 아래 출처만 썼다. 각 주장 끝의 `[..]`가 출처다.

| 표기 | 출처 (경로 기준: `C:\claude_work\infra_diag_0929\`) |
|---|---|
| [R1] | `report_1002\조치결과_보고_20261002.md` (10/2 조치 결과 보고) |
| [R2] | `report_1001\조치명령_서버별_20261002.md` 6절 (was1 조치 명령) |
| [A] | `results\apply\was1\20261002-*.log` (10/2 SSM 실행 로그), `apply_scripts\was1\*.ps1` |
| [E4] | `results\rfix4_infra_was1.json`, `results\rfix4_web_was1.json` (10/2 11:43 KST 조치 후 재진단) |
| [E6] | `results\ad1002b_infra_was1.json` (10/2 13:04 KST, 진단 스크립트 수정판) |
| [WF] | `wf_result_v2.json` was1 항목 (9/29~9/30 실서버 읽기 전용 실측, 조치 이전) |
| [D1] | `report_1001\취약항목_판단기준_조치방법_20261001.md` (10/1 실측 기록) |
| [FIN] | `results\final_infra_was1.json` (9/30 진단, 자동 시작 서비스 목록) |
| [RP] | `remediation_plan.md` was1 절 |
| [INV] | `C:\claude_work\vuln-lab-iac\_inventory\inventory.json` (AWS 읽기 전용 조회, 10/6) |
| [SRC] | `C:\claude_work\clinic-split-full-source\` (README-SERVER-SPLIT.md, customer-app), `C:\claude_work\Remove-vulnerabilities\deploy\V5_DEPLOYMENT.md` |

[WF]는 조치 이전 측정값이다. 10/2 조치와 관계없는 항목은 [E4]에서 같은 값으로 다시 확인됐다.

## 1. 인스턴스

| 항목 | 값 |
|---|---|
| 인스턴스 | `i-096b9c4090b81f0f0` (Name=was1), 현재 **stopped** [INV] |
| AMI | `ami-0ae94fb345ba94c74` = `Windows_Server-2019-English-Full-Base-2026.09.09` [INV, aws ec2 describe-images] |
| OS | Windows Server 2019 Datacenter 1809, Build 17763.9245 (KB5122876, AMI 내장) [E4 W-27, WF W-38] |
| 타입 / 서브넷 / IP | t3.medium / `subnet-09424e6b7917eb327` / **10.0.10.174** (DB 접속 허용 목록에 들어가는 주소) [INV, R1 3절] |
| 보안 그룹 / IAM | `vuln-lab-was` (sg-0b00a070406f462b6) / `vuln-lab-ec2-app-profile` [INV] |
| 호스트 이름 | `EC2AMAZ-7VPV0O3` (EC2Launch 자동 생성) [A] |
| 디스크 | C: 1개, NTFS, 32GB. 여유 약 4.6GB(10/2) [WF W-61, A W-42] |
| 도메인 | WORKGROUP [WF W-04] |
| user_data | `os/was1/user_data.tpl` (운영값과 바이트 동일, web1과 같은 내용, `<persist>true</persist>`) |

## 2. 아키텍처 안의 역할

```
web1(IIS/ARR) → in-alb :443 / :8443 (HTTPS) → tg-was (HTTP 8080, 헬스체크 '/', 정상코드 200-499)
             → was1 :8080  java.exe (서비스 clinic-customer, NetworkService)
             → db-active 10.0.20.184:1521 / XEPDB1 (Oracle 21c XE, 계정 oraadmin)
```
- 출처: tg/리스너 [INV], DB 접속 [WF WEB-13, A precheck3]
- 원래 설계는 고객 앱 8081, Nginx WEB01이었다 [SRC README-SERVER-SPLIT.md]. 운영은 `--server.port=8080`과 IIS(web1)를 쓴다.
- 구 Terraform(`C:\claude_work\vuln-lab\ec2.tf`)의 was1은 AL2023+Ollama였다. 운영과 다르다.
  - 운영 was1에는 Ollama(11434) 리스너가 없다 [A precheck].
- DB 접속 허용 목록 장애가 있었다 [R1 3절].
  - db-active `sqlnet.ora` `tcp.invited_nodes`에서 10.0.10.174가 빠졌다.
  - 10/2 11:08 KST WEB-13 재시작 때 고객 앱이 같은 원인(DB 연결 거부)으로 기동하지 못했다. 고객 사이트는 502였고 11:18에 복구됐다.
  - 새 인스턴스의 IP가 바뀌면 db-active 허용 목록도 고쳐야 한다.

## 3. 설치 소프트웨어

| 소프트웨어 | 상태·버전 | 출처 |
|---|---|---|
| Microsoft Build of OpenJDK 21 | `C:\Program Files\Microsoft\jdk-21.0.12.101-hotspot\bin\java.exe` | [A precheck] |
| NSSM 2.24 | `C:\nssm\nssm-2.24\win64\nssm.exe` | [A WEB-13·R2 WEB-13] |
| 고객 앱 jar | `C:\Remove-vulnerabilities\customer-app\target\clinic-customer-app-0.0.1-SNAPSHOT.jar`, 73,214,002B, 2026-09-28 07:37 빌드 | [A precheck] |
| jar 구성 | Spring Boot 3.5.16, tomcat-embed-core/websocket/el **10.1.55**, spring-security 6.5.11, spring-webmvc 6.2.19. 클래스 72개 | [WF WEB-04·WEB-25·WEB-23] |
| jar 안 application.yml | forward-headers-strategy=native, multipart 10MB/30MB, server.error.include-*=never, upload-dir `${APP_UPLOAD_DIR:${user.home}/zeroday-clinic/uploads}` | [WF WEB-08·WEB-10·WEB-22·WEB-24] |
| OpenSSH Server | sshd Running/Automatic (user_data 설치) | [A precheck, WF W-21] |
| Amazon SSM Agent / CloudWatch Agent | 둘 다 Running. CloudWatch는 `/ec2/was1/windows-event`로 전송, 설정 파일 미확보 | [FIN W-62, INV log_groups] |
| IIS | 설치 안 됨 | [WF W-19] |
| Microsoft Defender | 실시간 보호 사용 | [WF W-39·W-45] |

## 4. 서비스와 포트

| 포트 | 프로세스 | 용도 |
|---|---|---|
| TCP 8080 | java.exe (부모 nssm.exe, 서비스 clinic-customer) | 고객 앱(HTTP). TLS는 앞단 ALB/web1이 맡는다 |
| TCP 22 | sshd | SSH |
| TCP 3389 | TermService | RDP (NLA, TLS) |
| TCP 135 / 445 / 5985 / 47001, 동적 RPC | Windows 기본 | 방화벽 허용 규칙 없음 |

출처: [A precheck]

서비스 `clinic-customer` (nssm, 레지스트리 `HKLM\SYSTEM\CurrentControlSet\Services\clinic-customer`) [A precheck·precheck4, WF WEB-09]

| 값 | 내용 |
|---|---|
| StartMode / 실행 계정 | Auto / `NT Authority\NetworkService` |
| Application | `C:\Program Files\Microsoft\jdk-21.0.12.101-hotspot\bin\java.exe` |
| AppDirectory | `C:\clinic\customer-app` (비어 있음) |
| AppParameters (REG_EXPAND_SZ) | `-jar <위 jar> --spring.datasource.url=jdbc:oracle:thin:@10.0.20.184:1521/XEPDB1 --spring.datasource.username=oraadmin --spring.datasource.password=<평문 비밀번호> --server.port=8080` → 템플릿 `files/clinic-customer.AppParameters.tpl` |
| AppStdout / AppStderr | `C:\ProgramData\clinic\logs\service-out.log` / `service-err.log` |
| 하위 키 | `Parameters\AppExit` (nssm 기본) |
| 머신 환경변수 | `APP_UPLOAD_DIR=C:\clinic\uploads` (AppEnvironmentExtra는 비어 있음) [WF WEB-24·WEB-08] |

- 재시작할 때는 `nssm restart`를 쓰지 않는다. 중지 단계에서 시간이 초과된다.
  - `nssm stop` → Stopped 확인 → `nssm start` 순서로 한다 [R1 5절].

## 5. 주요 경로

| 경로 | 용도 / ACL | 출처 |
|---|---|---|
| `C:\Remove-vulnerabilities\` | git 소스 저장소(.git, src, pom.xml, .env.example). 실행 jar가 이 안의 target에 있다. 상위 ACL은 Users (CI)(AD)(WD) 상속 | [WF WEB-07·WEB-11, D1] |
| 실행 jar | SYSTEM, Administrators, NETWORK SERVICE(RX)만. Users 없음 | [WF WEB-13·WEB-14] |
| `C:\clinic\uploads` (`qna`, `reviews`) | 업로드 저장소. NETWORK SERVICE Modify, SYSTEM·Administrators Full, Users 없음 (상위 `C:\clinic`도 Users 없음) | [WF WEB-24] |
| `C:\clinic\customer-app` | AppDirectory, 비어 있음, NETWORK SERVICE Modify 명시 | [D1 WEB-11] |
| `C:\ProgramData\clinic\logs` | 앱 표준출력/오류 로그. 10/2 WEB-26 뒤 SYSTEM F, Administrators F, NETWORK SERVICE M만 | [A WEB-26-resume] |
| `C:\Backup\` | 10/2 조치 백업(Administrators·SYSTEM만): W-40, W-42, W-47, W-64, `clinic\`(옮긴 jar 8개, ACL 백업 SDDL) | [A W-40·WEB-07·WEB-13] |

## 6. 사용자·그룹

| 계정 | 상태 | 비고 |
|---|---|---|
| ZD_ADM (SID …-500) | 사용 | 기본 Administrator 개명, 프로필 `C:\Users\Administrator` [E4 W-01] |
| ZD_RDP (SID …-1009) | 사용 | 'Dedicated RDP (W-14)', Remote Desktop Users 단독 구성원, 비관리자, PasswordRequired=False 플래그 [WF W-03·W-09·W-14] |
| ssm-user (SID …-1008) | 사용 안 함 | SSM Agent가 만들고 Administrators에 넣음 [WF W-06] |
| NT AUTHORITY\NetworkService | 서비스 계정 | clinic-customer 실행 [A precheck] |
| Guest, DefaultAccount, WDAGUtilityAccount | 사용 안 함 | [E4] |

## 7. 보안 설정 상태 (10/2 조치 후)

### 7.1 10/2 이전부터 있던 설정 ([E4]에서 양호 재확인)

web1과 같다(web1 README 7.1 참고). 다른 점은 아래와 같다.

| 항목 | was1 값 | 출처 |
|---|---|---|
| W-09 암호 기록 | **24개** (web1은 12) | [WF W-05·W-09, E4 W-09] |
| Windows Update 정책 | AU **NoAutoUpdate=1**, AUOptions=2. wuauserv Manual. WU 검색·설치 이력 없음 | [WF W-27·W-38] |
| W-18 관련 | bowser 드라이버 Disabled/Stopped, 이 드라이버에 의존하는 LanmanWorkstation이 Automatic인데 Stopped | [WF W-18] |

- bowser 상태는 'Browser' 비활성화가 드라이버에 잘못 적용된 부작용으로 보인다. 스크립트에서는 재현하지 않는다(TODO).

공통 값(요약)

| 분류 | 값 |
|---|---|
| 계정 잠금 | 5회 / 60분 / 60분 |
| 암호 | 복잡성, 8자, 최대 90일, 최소 1일 |
| 사용자 권한 | 로컬 로그온 Administrators, 원격 Administrators+RDU |
| LSA·SMB·NetBIOS·RDP·TCP·Winlogon | 레지스트리 값 |
| 서비스 Disabled | Spooler, TrkWks, RemoteRegistry, upnphost, SSDPSRV |
| 시각 | NTP 169.254.169.123 |
| 감사 | 9개 하위 범주 Success and Failure |
| 화면 보호기 | HKLM·.DEFAULT 값 |

### 7.2 2026-10-02 조치 (SSM으로 적용, [R1] 2절·[R2] 6절·[A])

| 항목 | 내용 | 확인 |
|---|---|---|
| W-40 | DS 액세스 실패 감사 추가. `C:\Backup` ACL을 Administrators·SYSTEM으로 제한 | [A W-40 로그] |
| W-42 | 3개 로그 AutoBackup(/rt:true /ab:true), 최대 20MB | [A W-42 로그] |
| W-47 | ZD_ADM·ZD_RDP 하이브 정책 키 4개 값 기록 | [A W-47 로그(값 기록됨, 검증 정규식 오류), W-47-verify, E4 W-47] |
| WEB-07 | target의 백업·구버전 jar 8개를 `C:\Backup\clinic`으로 이동. 실행 jar만 남김 | [A WEB-07 로그] |
| WEB-26 | 로그 디렉터리 상속 끊고 SYSTEM F / Administrators F / NETWORK SERVICE M, 파일 ACL 재설정(Users 제거). 시도 3회째 적용(1·2회는 검증 스크립트 오류로 롤백) | [A WEB-26·WEB-26-resume] |
| WEB-13 | `Services\clinic-customer\Parameters` 키 ACL 보호. SYSTEM Full, Administrators Full, NETWORK SERVICE ReadKey. 11:34 KST 재적용, stop/start 뒤 19초에 /login 302, ORA 오류 없음 | [A WEB-13-resume] |
| W-64 | user data 부팅 작업 비활성화. 방화벽 3개 프로필 사용(기본 인바운드 차단), 02:37:23 UTC. tg-was/tg-web healthy 유지 | [A W-64, tg_health_poll] |
| W-37 | W-64 결과로 양호 | [R1 2절, E4 W-37] |

방화벽 허용 규칙 (모두 Inbound / Allow / Profile Any / 원격 Any) [A precheck·W-64]

| 규칙 | 프로토콜/포트 |
|---|---|
| ZD-Allow-SVC-8080 | TCP 8080 |
| Allow-App-8080 | TCP 8080 |
| Allow-SSH-22 | TCP 22 |
| OpenSSH SSH Server (sshd) | TCP 22 |
| ZD-Allow-RDP-3389 | TCP 3389 |
| ZD-Allow-ICMP | ICMPv4 |

- W-18은 web1에서 시험해 유지할 수 없음을 확인했다. 그래서 was1에는 적용하지 않았다 [R1 2·4절, A 디렉터리에 W-18 없음].

## 8. 의도적으로 남긴 취약 항목

| 항목 | 상태 | 이유 / 해결 방법 |
|---|---|---|
| W-18 | 취약(CryptSvc 실행 중) [E4, R1 4절] | 유지 불가. 예외 처리 권고. 13:04 수정판 진단 [E6]은 '양호'(판정 제외)로 냄 |
| WEB-25 | 취약(내장 Tomcat 10.1.55 < 10.1.60) [E4, R1 4절] | 사용자 제외. 빌드 환경에서 `tomcat.version` 10.1.60으로 재빌드 후 jar 교체 [R2 WEB-25] |

- 인터뷰 필요 항목: W-03, W-06, W-14, W-27·W-38(자동 업데이트 꺼짐, 패치 수단 없음), W-62, WEB-04, WEB-07, WEB-14, WEB-17, WEB-22 [E4].

## 9. 보안 확인 필요 (조치 범위 밖)

- **DB 비밀번호 평문 노출**
  - `AppParameters`와 java 프로세스 명령행에 `--spring.datasource.password`가 평문으로 있다 [WF WEB-13, R1 6절].
  - 10/2 WEB-13은 키의 일반 사용자 읽기만 막았다. 명령행은 로컬 관리자나 같은 세션 프로세스가 볼 수 있다.
  - 외부 설정으로 옮기는 안이 있다(`C:\clinic\customer-app\config\application.properties`) [RP WEB-13].
- **배포 경로**
  - 실행 jar가 git 소스 트리 안에 있다. `C:\Remove-vulnerabilities`는 Users가 파일을 만들 수 있다 [WF WEB-11, RP WEB-11].
- **웹셸 형태 파일**
  - 쓰지 않는 옛 경로 `C:\clinic\run\uploads`에 `poc.jsp`, `qna\poc.jsp`, `qna\jsp_shell*.jsp`가 있다(10/1 확인) [D1 WEB-11, R1 6절].
  - 침해 흔적일 수 있다. 증적을 남긴 뒤 보안 담당자가 확인한다.
- **남은 파일**
  - `C:\clinic\customer-app-broken.jar`, `C:\clinic\customer-app.jar`, `C:\` 루트의 `app.log`·`app-err.log`·`jt.log`·`jte.log` [WF WEB-07].
  - 빈 경로 `C:\Windows\ServiceProfiles\NetworkService\zeroday-clinic\uploads` [WF WEB-11].
- **평문 관리자 비밀번호**
  - `C:\Windows\Temp\UserScript.ps1`에 남아 있을 수 있다. 10/2에는 삭제하지 않았다 [D1].
- **소스 기본값**
  - 앱 소스(`clinic-split-full-source/customer-app/src/main/resources/application.yml`)에 메일 계정 기본값이 평문으로 있다(값은 여기 적지 않음) [SRC].

## 10. 스크립트로 재현할 수 없는 것

- **앱 jar**
  - 운영 jar(9/28 07:37 빌드)의 소스 커밋을 모른다.
  - 로컬 `Remove-vulnerabilities`의 HEAD(10/2 커밋)와 `clinic-split-full-source`(Boot 3.3.5, 포트 8081)는 운영 jar와 다르다.
  - jar는 `-JarSource`로 직접 넘긴다. git 소스 트리 전체는 재현하지 않는다.
- **DB**: 내용(XEPDB1, db-active), DB 비밀번호 값
- **업로드 파일**: `C:\clinic\uploads`의 qna·reviews 첨부
- **로그**: `service-out.log`(10/2 기준 약 30MB) 등
- **설치 파일**: JDK 21.0.12 MSI, nssm-2.24.zip. 직접 받아 넘긴다.
- **CloudWatch Agent**: 설정 JSON 미확보
- **ZD_RDP 비밀번호와 PasswordRequired=False 플래그**
- **SID·호스트 이름**: 로컬 SID, 호스트 이름, ssm-user
- **AppParameters의 인자 순서**: 가운데 세 `--spring.datasource.*` 인자의 정확한 순서는 미확인이다. 전체 길이만 운영 값과 일치를 확인했다.
- **ACL 세부**: 감사 정책 전체 목록, `C:\clinic` 정확한 ACE, nssm 기타 값(DisplayName, Description, 로그 회전)
- **10/2 이전 잔재**: `C:\Backup` 안의 백업본, 옮긴 jar 8개 등은 새 인스턴스에 생기지 않는다.

## 11. 재현 방법

1. Terraform(`compute.tf`의 `aws_instance.was1`)으로 같은 AMI와 `user_data.tpl`로 인스턴스를 만든다.
2. db-active `sqlnet.ora` `tcp.invited_nodes`에 새 was1 IP가 있는지 확인한다(운영 10.0.10.174).
   - 이 작업은 db-active 쪽이다. 진단 스크립트는 돌리지 않는다.
3. `os/was1` 폴더를 인스턴스에 복사한다. 예: `C:\zd-baseline`
4. 설치 파일 3개를 준비한다: JDK 21.0.12 x64 MSI, nssm-2.24.zip, 고객 앱 jar.
5. 비밀값을 준비한다.
   - 환경변수 `DB_PASSWORD`, `ZD_RDP_PASSWORD`를 넣는다.
   - 또는 SSM SecureString `/vuln-lab/was1/db_password`, `/vuln-lab/was1/zd_rdp_password`를 쓴다. 이름은 제안값이며 아직 없다.
   - SSM을 쓸 때는 인스턴스 역할 권한을 확인한다.
6. 실행한다.
   ```powershell
   cd C:\zd-baseline
   .\baseline.ps1 -JdkMsi C:\setup\microsoft-jdk-21.0.12-windows-x64.msi -NssmZip C:\setup\nssm-2.24.zip `
                  -JarSource C:\setup\clinic-customer-app-0.0.1-SNAPSHOT.jar -Reboot
   ```
   - 처음 실행하면 `APP_UPLOAD_DIR`을 넣는다. 그래서 재부팅해야 서비스가 올바른 업로드 경로로 시작한다.
   - 다시 실행해도 결과가 같다.
   - ZD_RDP 첫 로그온 뒤 한 번 더 실행해 W-47 사용자 하이브 값을 넣는다.
7. 확인(읽기 전용)
   - `curl.exe -s -o NUL -w "%{http_code}" http://localhost:8080/login`이 200 또는 302여야 한다.
   - `icacls C:\ProgramData\clinic\logs`에 Users가 없어야 한다.
   - `(Get-Acl HKLM:\SYSTEM\CurrentControlSet\Services\clinic-customer\Parameters).Access`가 SYSTEM, Administrators, NETWORK SERVICE만이어야 한다.
   - 방화벽 3개 프로필이 ON이어야 한다.
   - tg-was가 healthy여야 한다.

파일

| 파일 | 내용 |
|---|---|
| `user_data.tpl` | 운영 user_data 템플릿(수정 금지) |
| `baseline.ps1` | 위 7절 상태와 앱 실행 구성을 재현하는 스크립트 |
| `files/clinic-customer.AppParameters.tpl` | nssm AppParameters 템플릿. 비밀번호는 `${db_password}` 자리표시자, 근거 머리말 포함 |
