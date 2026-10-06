# was-adm1 — 관리자 WAS (Rocky Linux 8.10)

관리자 웹 앱(clinic-admin, Spring Boot 내장 Tomcat, 8080)이 도는 서버다. 이 문서는 운영 서버의 **2026-10-06 기준 OS 설정**을 자료로 정리한 것이다. 서버는 정지 상태이고 SSM도 오프라인이라, 서버에 직접 접속하지 않고 아래 자료만 근거로 썼다.

| 약어 | 자료 (경로는 `C:\claude_work\infra_diag_0929` 기준) |
|---|---|
| [UD] | `os/was-adm1/user_data.tpl`: 첫 부팅 스크립트. 운영 user_data와 바이트 단위로 같다 |
| [TF] | `compute.tf`, `security.tf`, `loadbalancing.tf`, `_inventory/inventory.json` (이 저장소) |
| [PRE] | `results/apply/was-adm1/20261002-105226_precheck.log`, `…105439_precheck2.log`: 10/2 조치 전 실측 |
| [CMD] | `report_1001/조치명령_서버별_20261002.md` §3 was-adm1 |
| [APPLY] | `apply_scripts/was-adm1/*.sh`와 그 출력 `results/apply/was-adm1/*.log`: 10/2 실제 적용 |
| [RES] | `report_1002/조치결과_보고_20261002.md` |
| [PLAN] | `remediation_plan.md`: 9/29 조치 계획 |
| [D0929] | `results/base_infra_was-adm1.out.txt`, `results/final_infra_was-adm1.out.txt`: 9/29~9/30 진단 |
| [D1002] | `results/rfix4_was-adm1/scan.out` (+ `rfix4_*_was-adm1.json`, CSV): 10/2 조치 후 재진단 |
| [SRC] | `C:\claude_work\clinic-split-full-source\admin-app` |

---

## 1. 인스턴스

| 항목 | 값 | 근거 |
|---|---|---|
| 인스턴스 | `i-07a6c1b4525770b10` (현재 stopped) | [TF] inventory |
| AMI | `ami-015dc263f405fc73c` (Rocky-8-EC2-Base-8.10-20260625.x86_64) | [TF] compute.tf |
| 유형 | t3.medium, CPU credit unlimited, EBS 최적화 | [TF] |
| 네트워크 | WAS 서브넷 `was_01`, 사설 IP **10.0.10.52**, 공인 IP 없음 | [TF] |
| 보안 그룹 | `vuln-lab-was`: 8080은 in-alb SG에서만, 22·3389는 bastion SG에서만 허용 | [TF] security.tf |
| IAM | 인스턴스 프로파일 `vuln-lab-ec2-app-profile` | [TF] inventory |
| 메타데이터 | IMDSv1 허용(`http_tokens = optional`) | [TF] |
| 디스크 | 루트 12GB gp3, 암호화(`vol-08f461dff30f31197`). 파티션은 `/`=nvme0n1p5 xfs 11G, `/boot`=nvme0n1p2 994M | [TF], [PRE] precheck2 |
| 호스트명 | `ip-10-0-10-52.ap-northeast-2.compute.internal` | [D1002] |

## 2. 아키텍처에서의 역할

```
관리자 PC(<ADMIN_IP>) → web-adm1 Nginx :443 → in-alb :443 (Host admin.zerodayclinic.p-e.kr)
  → tg-was-admin (HTTP 8080, 헬스체크 "/" 200-499) → was-adm1:8080 clinic-admin
  → db-active 10.0.20.184:1521/XEPDB1 (Oracle XE 21c, 계정 oraadmin)
```
- 관리용 접속은 두 가지다. bastion(10.0.0.176)을 거치는 SSH(team 키)와 SSM이다. SSM 에이전트는 2026-09-30 01:26 UTC쯤 설치된 것으로 보인다([PRE]: `sudoers.d/ssm-agent-users` 생성 시각). 10/2 조치는 SSM으로 했다([RES]).
- 앱은 자체 IP 제한을 한다: `ADMIN_ALLOWED_NETWORKS=127.0.0.1/32,::1/128,<ADMIN_IP>/32`. 앞단 프록시 헤더는 `--server.forward-headers-strategy=native`로 신뢰한다([PRE] systemctl cat).
- **db-active 의존:** db-active의 `sqlnet.ora`에 있는 `tcp.invited_nodes`에 10.0.10.52가 있어야 DB에 연결된다. 10/2 장애가 이 값이 빠져서 났다([RES] §3). IP가 다른 인스턴스로 다시 만들면 이 목록에 새 IP를 추가해야 한다.

## 3. 설치 소프트웨어와 버전

| 구성 | 버전/상태 | 근거 |
|---|---|---|
| OS | Rocky Linux 8.10 (Green Obsidian) | [PRE] |
| 커널 | **4.18.0-553.170.1.el8_10** (10/2 U-64로 갱신하고 재부팅함. 553.168.1과 553.137.1도 설치돼 있음) | [APPLY] U-64.log, U-64_post.log |
| 10/2 보안 업데이트 | expat-2.5.0-4.el8_10, kernel·kernel-core·kernel-modules·kernel-tools(-libs)·python3-perf 553.170.1 → 미적용 보안 업데이트 0건 | [APPLY] U-64.log, [D1002] U-64 |
| systemd | 239 (239-82.el8_10.19) | [PRE] precheck2 |
| Java | java-21-openjdk **21.0.12.1.1-1.1.el8_10** (`/usr/lib/jvm/java-21-openjdk-21.0.12.1.1-1.1.el8_10.x86_64`) | [PRE] ExecStart, [UD] |
| Python | python3 (user_data의 placeholder용) | [UD] |
| 관리자 앱 | `clinic-admin-app`: Spring Boot 3.5.16, 내장 Tomcat **10.1.55**, ojdbc11 23.6.0.24.10. 메인 클래스는 `com.example.clinic.ClinicSiteApplication`. jar는 73,224,917 bytes(2026-09-28 07:36). multipart 제한 10MB/30MB(jar 안 설정) | [D1002] web, [CMD] WEB-25, [APPLY] WEB-09 rerun·WEB-07 로그 |
| 시각 동기화 | chronyd → 169.254.169.123 (AWS Time Sync) | [APPLY] U-65 |
| 기타 데몬 | sshd, crond, rsyslog + journald, rpcbind(111 수신 중), tuned, polkit, dbus | [D1002] U-42·U-66, [APPLY] U-64 needs-restarting |
| AWS 에이전트 | amazon-ssm-agent, amazon-cloudwatch-agent(동작 중). 버전과 설정은 미확보 | [PRE] `/etc/systemd/system/amazon-*.service`, [APPLY] U-32.log |
| cockpit | cockpit-ws 계정과 `/etc/motd.d/cockpit` 링크만 확인됨(AMI 기본) | [PRE] |
| 없는 것 | firewalld 없음("방화벽=none"), 메일·FTP·SNMP·NFS·DNS 서비스 없음, dnf-automatic 미설치 | [D1002], [D0929] final |

## 4. 서비스와 포트

| 유닛 | 포트 | 상태 | 비고 |
|---|---|---|---|
| `clinic-admin.service` | 8080/tcp | enabled, active, 실행 계정 `clinicapp` | Restart=always, RestartSec=10, WorkingDirectory=/opt/clinic |
| `sshd` | 22/tcp | active | PermitRootLogin no, PasswordAuthentication no(UD), UsePAM yes |
| `chronyd` | — | active | 169.254.169.123 동기화 |
| `rpcbind` | 111 | active | 가이드의 불필요 RPC 서비스는 등록 없음 |
| `crond` / `rsyslog` | — | active | |
| `amazon-ssm-agent` / `amazon-cloudwatch-agent` | — | active | |
| `placeholder.service` (UD) | 8080 | **disabled, inactive** | 앱 배포 뒤 껐다([PRE] precheck2) |
| SELinux | — | **Permissive** | [UD], [APPLY] WEB-09 rerun |

## 5. 주요 설정 파일

| 경로 | 소유·권한 | 내용 | files/ |
|---|---|---|---|
| `/etc/systemd/system/clinic-admin.service` | root 600 | 기본 유닛(User=team, /tmp 로그). 원래 ExecStart에 DB 비밀번호가 평문으로 있었고 drop-in이 덮어쓴다 | 재구성본(비밀번호 인자만 뺌) |
| `…/clinic-admin.service.d/db-creds.conf` | root 600 | `EnvironmentFile=/etc/clinic/db.env` + 비밀번호 없는 ExecStart | **원문**(269 bytes, 크기 일치) |
| `…/clinic-admin.service.d/override.conf` | root 600 | ADMIN_ALLOWED_NETWORKS, `EnvironmentFile=-/etc/clinic/admin-rotate.env` | **원문**(131 bytes) |
| `…/clinic-admin.service.d/security.conf` | root 600 | 업로드·기록 경로, Spring 오류 노출 차단 | **원문**(369 bytes) |
| `…/clinic-admin.service.d/runas.conf` | root 600 | 10/2 WEB-09·26: User/Group=clinicapp, 로그는 `/var/log/clinic-admin/*` | **원문**([APPLY] heredoc) |
| `/etc/clinic/db.env` | root:root 600, 328 bytes | `SPRING_DATASOURCE_URL/USERNAME/PASSWORD` | 없음(비밀값) |
| `/etc/clinic/admin-rotate.env` | root:team 640, 102 bytes | `ROTATE_ADMIN_PASSWORD`, `ROTATE_USER_PASSWORD`, `ROTATE_PASSWORDS_ON_STARTUP` | 없음(비밀값) |
| `/opt/clinic/` | team:team 755 | `admin-app.jar`(clinicapp 600), `uploads/{qna,reviews}`·`records/`(clinicapp 700) | — |
| `/var/log/clinic-admin/` | root 750 / 파일 root 640 | `admin-app.log`, `admin-app-err.log`(systemd `file:`, 재시작 때 앞부분부터 덮어씀) | — |
| `/var/backups/clinic-admin/` | root 700 | 10/2 WEB-07로 옮긴 백업 jar 5개 | — |
| `/etc/pam.d/system-auth`, `password-auth` | root 644, 일반 파일(authselect 미사용) | pwquality → pwhistory(remember=4) → unix, faillock preauth/authfail/account | 일부(`*.fragment`) |
| `/etc/security/pwquality.conf` | | minlen=8, d/u/l/ocredit=-1, enforce_for_root | 일부 |
| `/etc/security/faillock.conf` | | deny=5, unlock_time=600 | 일부 |
| `/etc/chrony.conf` | | 공용 pool 주석 처리, `server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4` | 일부 |
| `/etc/motd` | root 644 | 10/2 U-62 경고문 | **원문** |
| `/etc/tmpfiles.d/var.conf` | | `/usr/lib/tmpfiles.d/var.conf` 복사본. wtmp·lastlog 0644, btmp 0600 | — (스크립트가 생성) |
| `/etc/logrotate.d/wtmp`, `btmp` | | create 0644 / 0600 | — (sed) |
| `/etc/environment` | 644 | DB_HOST, DB_USER, DB_PASS(평문) — [UD] | — |
| `/etc/sudoers.d/` | 440 | `team`(UD), `90-cloud-init-users`(rocky), `ssm-agent-users`(ssm-user). 모두 NOPASSWD:ALL | — |

## 6. 사용자와 그룹

| 계정 | UID/GID | 셸·홈 | sudo | 근거 |
|---|---|---|---|---|
| root | 0 | | | 비밀번호는 UD(`server_password`). 만료 2026-12-16 |
| rocky | (cloud-init 기본) | | NOPASSWD:ALL | [D1002] U-07: 클라우드 기본 계정, 잠김 |
| team | 1001/1001 | /bin/bash, /home/team | NOPASSWD:ALL | [UD], [PRE] precheck2. 키 접속용. 만료 2026-12-16 |
| ssm-user | — | | NOPASSWD:ALL | SSM 에이전트가 만듦, 잠김 |
| clinicapp | **990/987** | /sbin/nologin, /opt/clinic | 없음 | [APPLY] WEB-09 rerun |
| cwagent | 991/988 | /sbin/nologin, /home/cwagent | 없음 | [PRE] |
| cockpit-ws / cockpit-wsinstance | 994/991, 993/990 | /sbin/nologin, /nonexisting | 없음 | [PRE] |
- wheel 그룹은 구성원이 없다. `/usr/bin/su`는 root:root 4750이고 pam_wheel이 켜져 있어 일반 계정은 su를 쓸 수 없다. team은 sudo로 관리한다([D0929]).
- `/home/team`에 빌드 환경이 남아 있다: `apache-maven-3.9.6-bin.tar.gz`, `.m2`, `Remove-vulnerabilities/`, `zeroday-clinic/`, `admin-app.jar` 사본([PRE] precheck2).

## 7. 하드닝 상태

### 7-1. 10/2 이전부터 적용돼 있던 설정
9/29 첫 진단에서 이미 양호였다. 누가 어떤 명령으로 적용했는지는 자료에 없다. 결과 상태만 확인된다.

| 항목 | 상태 | 근거 |
|---|---|---|
| U-01 | PermitRootLogin no (UD) | [D1002] |
| U-02(일부) | login.defs PASS_MAX_DAYS 90 / MIN 1 / WARN 7, pwquality `minlen = 8` | [D0929] base, [PRE] |
| U-03(일부) | faillock.conf `deny = 5`, `unlock_time = 600`. 모듈은 10/2에 적용 | [PRE] |
| U-06 | `/etc/pam.d/su`에 `auth required pam_wheel.so use_uid`, su 4750 | [D0929] |
| U-12 | TMOUT=600 readonly(`/etc/profile.d/tmout.sh:1`, `/etc/profile:86`), sshd ClientAliveInterval 300 / CountMax 2 | [D1002] U-12, [D0929] final(설정 위치 2곳) |
| U-13 | ENCRYPT_METHOD SHA512, pam_unix sha512 | [D1002] |
| U-21 | rsyslog.conf와 rsyslog.d/21-cloudinit.conf가 root 640 | [D1002] |
| U-28 | hosts.deny `ALL:ALL`, hosts.allow 1줄(특정 호스트만). RHEL8 sshd가 libwrap을 쓰지 않아 실제 효과는 없다 | [D1002], `results/r1001_was-adm1/scan.out` |
| U-37(일부) | `/etc/cron.allow` 있음(root만), /etc/crontab·cron.d가 root 640 이하 | [D0929] base, [PLAN], `results/rfix3b_was-adm1/scan.out` |
| U-62(일부) | /etc/issue에 경고문, SSH `Banner /etc/issue.net`. motd는 10/2에 설정 | [D0929], `rfix3b` |

### 7-2. 2026-10-02 조치 (SSM, apply.py)
[CMD] §3의 명령을 [APPLY] 스크립트로 적용했고, 백업 → 적용 → 확인 순서로 진행했다. 전부 `RESULT=APPLIED_VERIFIED`였고, 재부팅 뒤 `U-64_post.log`에서 `ALL_VERIFIED`가 나왔다.

| 항목 | 조치 |
|---|---|
| U-02 | pwquality.conf에 d/u/l/ocredit=-1과 enforce_for_root 추가. system-auth·password-auth에 `pam_pwhistory.so use_authtok remember=4 enforce_for_root`. root·team에 `chage -m 1 -M 90 -W 7` |
| U-03 | pam_faillock 적용(auth preauth / authfail, account) |
| U-20 | `/etc/systemd` 아래 파일을 전부 root 600으로(당시 15개, runas.conf 추가 뒤 16개). web-adm1과 달리 유지 유닛은 없다 |
| U-23 | `/usr/sbin/unix_chkpwd` SUID 제거(4755 → 755) |
| U-30 | `/etc/profile` 60행 `umask 002` → `umask 022` |
| U-32 | `/nonexisting`(root 755)과 `/home/cwagent`(cwagent 750) 생성 |
| U-37 | `/usr/bin/crontab` 4755 → 750, cron.hourly·daily·weekly·monthly 755 → 640 |
| U-62 | `/etc/motd` 경고문(files/etc/motd) |
| U-64 | `dnf -y update --security`(7건) 후 재부팅. 커널 553.170.1 |
| U-65 | 2.rocky.pool.ntp.org 주석 처리, 169.254.169.123 추가 |
| U-67 | zz-kisa-logperm.conf(이름이 달라 무시되던 파일)를 /root/u67_bak으로 옮김. `/etc/tmpfiles.d/var.conf` 재정의, logrotate wtmp 0644·btmp 0600, 현재 파일 권한 수정 |
| WEB-07 | `/opt/clinic`의 백업 jar 5개를 `/var/backups/clinic-admin`(700)으로 옮김 |
| WEB-09 | `clinicapp` 계정(-r, nologin, sudo 없음)을 만들고 drop-in `runas.conf`로 이 계정에서 실행 |
| WEB-13 | admin-app.jar를 clinicapp:clinicapp 600으로. uploads·records는 clinicapp 소유 |
| WEB-26 | 표준출력·오류를 `/tmp`(1777)에서 `/var/log/clinic-admin`(750 root, 파일 640 root)으로 옮김 |

- **조치 후 재진단 [D1002]:** 리눅스는 양호 46, 취약 0, N/A 13, 수동확인 8이다. Tomcat은 양호 12, **취약 1(WEB-25)**, 수동확인 7, N/A 6이다.
- **운영 변경 사항 [RES] §5**
  - 비밀번호 5회 실패 시 600초 잠금(`faillock --user <계정> --reset`으로 해제).
  - `authselect select --force`를 실행하면 수동 PAM 수정이 덮어써진다.
  - systemd·cronie·pam을 갱신하면 U-20·U-37·U-23 권한이 되돌아갈 수 있다.
  - jar를 교체할 때는 `clinicapp:clinicapp 600`을 유지한다.

## 8. 의도적으로 남긴 취약 항목과 설계상 취약점

| 항목 | 이유 | 해결 방법 |
|---|---|---|
| **WEB-25** 내장 Tomcat 10.1.55 < 10.1.60 | 사용자가 jar 재빌드를 조치에서 제외([RES] §4) | 빌드 환경 상위 pom에 `<tomcat.version>10.1.60</tomcat.version>`(spring-boot 3.5.16 상속)을 넣고 재빌드한다. 교체는 [CMD] WEB-25 절차를 따른다. 팀 저장소 pom은 3.3.5라 그대로 빌드하면 Tomcat 10.1.31로 내려간다 |
| user_data 설계(실습용) | team NOPASSWD:ALL, `/etc/environment` DB_PASS 평문(644), root와 team 비밀번호 동일, SELinux permissive, IMDSv1 | user_data와 Terraform에서 의도한 취약 설정. 재현 대상이라 그대로 둔다 |
| 9/29 계획 중 10/2 미적용 | U-07·U-08(rocky 계정·sudoers 정리), U-28(firewalld), U-66(로그 정책) | [PLAN]. [D1002]에서 U-07·U-66은 수동확인, U-28은 양호(TCP Wrapper 기준)로 나왔다 |

## 9. 스크립트로 재현할 수 없는 것

- **앱 바이너리:** `admin-app.jar`(73MB)는 저장소에 없다. 운영 jar는 Spring Boot 3.5.16 기반이다. 반면 `clinic-split-full-source/admin-app`은 3.3.5이고 기본 포트가 8082이며, `ROTATE_*`와 `ADMIN_ALLOWED_NETWORKS` 처리 코드가 없다. 그래서 **운영 jar의 소스가 아니다**. 운영 jar는 서버의 `/home/team`(maven 3.9.6, zeroday-clinic, Remove-vulnerabilities)에서 빌드한 것으로 보인다(TODO(확인필요)).
- **업무 데이터:** `/opt/clinic/records`(예시 개인정보 파일 3개), `uploads/qna`, `uploads/reviews`의 내용.
- **DB:** db-active에 있다. 스키마는 앱이 JPA `ddl-auto=update`로 만든다. 기동할 때 나오는 ORA-00942 36건과 ORA-00955 40건은 정상 경고다([APPLY] WEB-09).
- **비밀값:** DB 비밀번호, admin-rotate 값, root·team 비밀번호(UD 템플릿 변수). 저장소에 두지 않는다.
- **백업과 기록:** `/var/backups/clinic-admin`의 백업 jar, `/root`의 10/2 조치 백업과 로그, `/home/team/.bash_history`.
- **정확한 패키지 버전:** `dnf update --security`는 실행 시점 저장소 기준이라 버전이 운영과 다를 수 있다.
- **인스턴스 고유값:** SSH 호스트 키, machine-id, cloud-init 데이터, SSM 등록 정보, 비밀번호 마지막 변경일(만료일 2026-12-16).
- **원문을 확보하지 못한 파일:** baseline.sh에는 결과 상태만 넣고 `TODO(확인필요)`로 표시했다.
  - `/etc/issue`, `/etc/issue.net`
  - `/etc/hosts.allow`의 허용 줄
  - `/etc/profile.d/tmout.sh`, `/etc/profile` 86행
  - `db.env`·`admin-rotate.env` 원문
  - PAM 주석 줄, chrony.conf·sshd_config 전체
  - CloudWatch Agent 설정, 에이전트 설치 방법
  - `/etc/clinic` 디렉터리 권한, `uploads/qna`·`uploads/reviews` 권한

## 10. baseline.sh 사용법

> **user_data 미실행 주의 (CRLF)** : `user_data.tpl` 은 운영과 바이트 단위로 같게 CRLF 줄바꿈이다.
> 새 인스턴스에서는 `#!/bin/bash` 때문에 cloud-init 이 user_data 를 실행하지 못할 수 있다
> (`/var/log/bootstrap.log` 가 없으면 미실행). 이때는 baseline 전에 user_data 를 CR 을 지우고 직접 실행한다.
> 템플릿 자체는 고치지 않는다.
>
> ```bash
> T=$(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
> curl -s -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/user-data | tr -d '' > /root/ud.sh
> bash /root/ud.sh; shred -u /root/ud.sh      # 렌더링된 user_data 에는 비밀번호가 들어 있다
> ```

같은 AMI와 user_data로 첫 부팅을 마친 **새 인스턴스**에서 root로 실행한다. 정지된 운영 인스턴스를 켜서 실행하지 않는다. 이 디렉터리를 통째로 서버에 복사한 뒤 실행한다.

```bash
# 예시 - 비밀값은 환경변수나 SSM 파라미터 이름으로만 넘긴다(파라미터는 미리 만들어 둬야 한다)
sudo -E env \
  DB_PASSWORD_SSM_PARAM=/<경로>/db_password \
  ADMIN_APP_JAR_SRC=s3://<버킷>/admin-app.jar \
  HOSTS_ALLOW_LINE='<허용 규칙 1줄>' \
  INSTALL_SSM_AGENT=1 INSTALL_CW_AGENT=1 \
  bash ./baseline.sh
```

| 변수 | 필수 | 설명 |
|---|---|---|
| `DB_PASSWORD` 또는 `DB_PASSWORD_SSM_PARAM` | 앱 기동 시 | db.env 비밀번호. SSM은 SecureString(`--with-decryption`). 인스턴스 역할에 `ssm:GetParameter`와 kms 복호화 권한이 필요하다. **현재 계정에는 이 용도의 파라미터가 없다**(`/autodiag/oracle_conn`만 있음) |
| `DB_URL`, `DB_USERNAME` | | 기본값은 운영값 `jdbc:oracle:thin:@10.0.20.184:1521/XEPDB1`, `oraadmin` |
| `ROTATE_ADMIN_PASSWORD(_SSM_PARAM)`, `ROTATE_USER_PASSWORD(_SSM_PARAM)`, `ROTATE_PASSWORDS_ON_STARTUP` | 선택 | 셋 다 있을 때만 admin-rotate.env 생성 |
| `ADMIN_APP_JAR_SRC` | 앱 기동 시 | 로컬 경로 또는 `s3://` |
| `HOSTS_ALLOW_LINE`, `LOGIN_BANNER_FILE` | 선택 | 원문 미확보 항목. 없으면 hosts.* 단계는 건너뛴다. 경고문은 경고 문구가 없을 때만 motd 문구로 채운다 |
| `SKIP_PATCH=1`, `AUTO_REBOOT=1`, `INSTALL_SSM_AGENT=1`, `INSTALL_CW_AGENT=1`, `CW_AGENT_CONFIG_SSM_PARAM` | 선택 | |

**실행 순서**
1. U-64 보안 업데이트. 패키지 갱신이 권한 조치를 되돌리므로 맨 먼저 한다.
2. 에이전트 설치(선택).
3. 10/2 이전부터 있던 하드닝.
4. 앱 배포와 WEB-09/13/26/07.
5. 10/2 조치 U-02 U-03 U-23 U-30 U-32 U-37 U-62 U-65 U-67.
6. U-20. `/etc/systemd`에 파일을 다 배포한 뒤에 한다.
7. 앱 기동과 `/login` 200/302 확인.
8. 읽기 전용 확인.

**동작과 주의**
- 여러 번 실행해도 결과가 같다. 이미 적용된 줄은 다시 넣지 않는다. systemd·pam·cronie를 갱신한 뒤 다시 실행하면 U-20·U-23·U-37이 복구된다.
- 로그는 `/var/log/baseline-was-adm1.log`에 남는다. 비밀값은 출력하지 않는다(`set -x` 미사용).
- 운영 JVM 경로(21.0.12.1.1)가 없으면, 설치된 java-21 경로로 유닛의 ExecStart를 바꿔 배포한다.
- clinicapp은 운영과 같은 uid 990 / gid 987로 만든다. 그 번호를 이미 쓰고 있으면 자동 번호로 만든다.
- 네트워크 허용(SG·NACL)은 Terraform이 관리한다. OS 쪽에서는 db-active `tcp.invited_nodes`에 이 서버 IP가 있어야 DB에 접속된다(2장). IP가 10.0.10.52가 아니면 스크립트가 경고한다.

## 11. 보안 확인 필요 ([RES] §6)
- 운영 `/etc/systemd/system/clinic-admin.service`의 원래 ExecStart에 DB 비밀번호가 평문으로 남아 있다. 10/2 사전 점검 출력으로 SSM 명령 기록에도 남았다. 유효한 비밀번호라면 교체를 권고한다. `files/`의 유닛에서는 이 인자를 뺐다.
- `admin-rotate.env`는 root:team 640이라 team 그룹이 읽을 수 있다(운영 상태 그대로 재현).

## 12. 디렉터리 구성

```
os/was-adm1/
├─ user_data.tpl          첫 부팅 스크립트(운영과 동일, 수정 금지)
├─ baseline.sh            첫 부팅 이후 상태 재현(위 10장)
├─ README.md
└─ files/
   ├─ etc/motd                                           원문(10/2 U-62)
   ├─ etc/systemd/system/clinic-admin.service            재구성본(비밀번호 인자 제거, 머리말 주석)
   ├─ etc/systemd/system/clinic-admin.service.d/
   │    db-creds.conf  override.conf  security.conf      원문(크기 269/131/369 bytes 일치)
   │    runas.conf                                       원문(10/2 WEB-09 heredoc)
   ├─ etc/pam.d/system-auth.fragment, password-auth.fragment   일부(조치 후 auth/account/password/session 줄)
   ├─ etc/security/pwquality.conf.fragment, faillock.conf.fragment   일부(활성 줄)
   └─ etc/chrony.conf.fragment                            일부(바뀐 줄)
```
`*.fragment`는 결과 비교용이다. baseline.sh는 이 파일들을 복사하지 않고, 10/2 명령(sed)을 AMI 기본 파일에 적용한다.
