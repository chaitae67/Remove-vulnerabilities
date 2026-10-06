# db-active — 운영체제 구성 (2026-10-06 기준)

Oracle Database 21c XE 를 Docker 컨테이너로 운영하는 DB 서버다. 이 문서는 라이브 접속 없이 아래 근거 자료만으로 현재 OS 상태를 정리했다.
인스턴스는 정지 상태이고 SSM 도 오프라인이라, 실측은 2026-10-01·10-02 의 기록이 마지막이다.

| 파일 | 내용 |
|---|---|
| `user_data.tpl` | 최초 부팅 user_data 템플릿. 라이브 값과 같고 비밀값만 변수로 바꿨다. **수정 금지** |
| `baseline.sh` | 같은 AMI 와 user_data 로 만든 새 인스턴스를 현재 상태로 맞추는 스크립트. root 로 실행하고, 여러 번 실행해도 결과가 같다 |
| `files/listener.ora` | Oracle 리스너 설정 원문. 원본 214바이트에 10/2 D-15 조치로 2행이 붙었다 |
| `files/99-kisa-warning` | 10/2 U-62 조치로 만든 update-motd 경고 스크립트 원문(231바이트) |
| `files/sqlnet.ora.fragment` | sqlnet.ora 일부. 확인된 설정 3줄만 있다 |
| `files/rc.local.fragment` | /etc/rc.d/rc.local 일부. 확인된 2행만 있다 |

> **운영 중인 db-active 에서는 `baseline.sh` 를 실행하지 않는다.** 9/29·9/30 진단 스크립트 때문에 메모리가 고갈돼 재부팅한 사고가 있어 진단·변경이 금지된 서버다. 스크립트도 10/2 조치 흔적 파일이 있으면 스스로 멈춘다.

## 근거 자료 약어

경로 기준은 `C:\claude_work\infra_diag_0929`(읽기 전용 원본)다.

| 약어 | 자료 |
|---|---|
| [UD] | `os/db-active/user_data.tpl` |
| [OLD] | `C:\claude_work\vuln-lab\db_ec2.tf`, `README.md` (원래 Terraform, 부트스트랩 의도) |
| [CMD1002] | `report_1001/조치명령_서버별_20261002.md` 4장(db-active) |
| [APPLY] | `apply_scripts/db-active/*.sh` + `results/apply/db-active/*.log` (10/2 실제 적용 스크립트와 출력) |
| [RES1002] | `report_1002/조치결과_보고_20261002.md` |
| [RFIX4] | `results/rfix4_db-active/` (`aio.out`, `dbms.out`, `db.json`, `server_linux_*.csv`). 10/2 조치 후 재진단 |
| [WF1001] | `wf_1001.json`. 10/1 db-active 읽기 전용 실측 검증 결과로, 항목 코드로 인용한다 |
| [MANUAL] | `ref/manual_reports.json` 의 `linux:db-active`. 9/28 이행조치 전 팀 수동 진단 |
| [G1001] | `report_1001/취약항목_판단기준_조치방법_20261001.md` |
| [CTX] | `AGENT_CONTEXT_1001.md` |
| [INV] | `vuln-lab-iac/_inventory/inventory.json`. 10/6 읽기 전용 `describe-images`, `describe-snapshots` 결과도 포함 |
| [APP] | `C:\claude_work\clinic-split-full-source` |

## 1. 인스턴스와 OS

| 항목 | 값 | 근거 |
|---|---|---|
| 인스턴스 | `i-088821e81bec61385`, t3.medium(RAM 3,867MB, 스왑 없음, 평소 가용 메모리 약 1.4GB), 정지 상태 | [INV], [APPLY] 00_before.log |
| AMI | `ami-0d84f865d3f4728e2` = `amzn2-ami-hvm-2.0.20260914.1-x86_64-gp2`(Amazon Linux 2) | [INV] |
| OS·커널 | Amazon Linux release 2 (Karoo), `4.14.355-284.742.amzn2.x86_64`. 커널은 AMI 에 들어 있던 1개뿐이다 | [APPLY] 00_before.log, [RFIX4] U-64, [WF1001] U-64 |
| 지원 | `SUPPORT_END="2026-06-30"`. 지원이 끝났고 확장 지원 수단이 없다 | [WF1001] U-64 |
| 네트워크 | db-01 서브넷 `10.0.20.184`(호스트명 ip-10-0-20-184). 라우팅은 local 과 S3 게이트웨이 엔드포인트뿐이라 인터넷이 없다 | [INV] |
| SG `vuln-lab-db` | 인바운드 1521 ← `vuln-lab-was` SG, 22 ← `vuln-lab-bastion` SG. 아웃바운드 443 → `vuln-lab-vpce-ssm` SG, S3 접두사 목록 | [INV] |
| 관리 경로 | SSM 인터페이스 엔드포인트(ssm, ssmmessages, ec2messages)를 쓴다. 9/30 에 온보딩했다 | [INV], [WF1001] U-07 |
| IAM 프로파일 | `vuln-lab-ec2-app-profile` | [INV] |
| IMDS | `http_tokens=optional`(IMDSv1 허용) | [INV] |
| 루트 볼륨 | `enc-db-root` 30GB gp3, KMS 암호화. 9/19 스냅샷 `snap-09a9d91b71face9a8`(04:45 UTC)로 다시 만들었다 | [INV] |
| 데이터 볼륨 | `enc-db-data` 20GB gp3, KMS 암호화, `/dev/sdf`(nvme) → `/oradata`(xfs). 9/19 스냅샷 `snap-0acbe6991b5c6159c`(04:45 UTC)로 다시 만들었다 | [INV], [WF1001] U-15 |

## 2. 아키텍처에서 맡은 역할

- 고객 앱(was1 `10.0.10.174`)과 관리자 앱(was-adm1 `10.0.10.52`)이 함께 쓰는 단일 Oracle DB 다. 이중화는 없다. 근거: [OLD] README, [WF1001] D-02·D-06
- 접속 대상은 PDB `XEPDB1`(`jdbc:oracle:thin:@10.0.20.184:1521/XEPDB1`)이다. 근거: [WF1001] D-02, `remediation_plan.md` WEB-13
- 리스너 로그상 원격 클라이언트는 위 두 WAS 의 JarLauncher 뿐이다. 근거: [WF1001] D-02
- 앱 소스 기본값은 `FREEPDB1`/`clinic` 이지만 운영은 환경변수로 덮어쓴다. 테이블은 JPA `ddl-auto: update` 로 만든다. 근거: [APP] README-SERVER-SPLIT.md, application.yml

## 3. 설치 소프트웨어

| 소프트웨어 | 버전·상태 | 근거 |
|---|---|---|
| Docker | yum 으로 설치(9/17, yum.log). 버전은 확인하지 못했다(TODO). 저장소는 amzn2-core, amzn2-extras | [WF1001] U-64 |
| Oracle XE | 이미지 `gvenzl/oracle-xe:21-slim`, DB `21.3.0.0.0`(21c Express Edition), 적용 패치 없음 | [RFIX4] dbms.out, [WF1001] D-16 |
| amazon-ssm-agent | AMI 기본 설치본, 9/30 업데이트. 버전은 확인하지 못했다(TODO) | [WF1001] U-64 |
| amazon-cloudwatch-agent | 9/21 설치, active. `/var/log/messages`, `/var/log/secure` 를 로그 그룹 `aws_instance_logs` 로 보내도록 설정했다 | [WF1001] U-64·U-66 |
| rsyslog | 8.24.0-57.amzn2, active. 설정은 패키지 기본값이다 | [WF1001] U-21·U-66 |
| postfix | 2.10.1-6.amzn2.0.4. 설치만 되어 있고 중지·disabled 상태다 | [WF1001] U-45 |
| chrony | chronyd active, 169.254.169.123 과 동기화된다(AMI 기본 설정) | [WF1001] U-65, [RFIX4] U-65 |
| 기타 | bash 4.2.46, libpwquality 1.2.3(pwquality.conf 의 `enforce_for_root` 미지원), rpcbind active(AMI 기본) | [CTX], [G1001] U-02, [WF1001] U-42 |

user_data 는 AL2023(`dnf`)을 전제로 쓰였지만 실제 AMI 는 AL2 라 `dnf` 가 없다. 그래서 `dnf -y update` 와 `dnf -y install docker tar`, 그리고 그 뒤의 docker 단계가 모두 실패했다. 전체·보안 업데이트 이력이 한 번도 없고 docker 그룹 구성원도 없다. 운영자가 9/17 에 yum 으로 docker 를 설치하고 컨테이너를 직접 띄웠다. 근거: [UD], [OLD] db_ec2.tf, [WF1001] U-64·D-14

## 4. 서비스와 포트

| 포트 | 프로세스 | 비고 | 근거 |
|---|---|---|---|
| 22/tcp | sshd | hosts.allow 로 bastion `10.0.0.176` 만 허용 | [WF1001] U-34·U-53 |
| 111/tcp·udp, 930/udp | rpcbind | portmapper 만 등록되어 있다 | [WF1001] U-42 |
| 1521/tcp | tnslsnr(컨테이너, host 네트워크) | `0.0.0.0:1521` | [APPLY] D-15.log |
| 5500/tcp | tnslsnr | EM Express(tcps), 지갑 경로 `/opt/oracle/admin/XE/xdb_wallet` | [APPLY] 00_before.log |
| 37673/tcp | ora_d000 | 디스패처. 동적 포트다 | [WF1001] U-38 |
| 68·546/udp, 323/udp(local) | dhclient, chronyd | — | [WF1001] U-38 |

| 유닛 | 상태 | 근거 |
|---|---|---|
| `docker.service` | **LoadState=error**, inactive, UnitFileState=enabled. user_data 가 만든 drop-in `/etc/systemd/system/docker.service.d/override.conf` 에 `ExecStart=` 한 줄만 있어 systemd 가 "lacks both ExecStart= and ExecStop=" 로 거부한다. 9/17 04:36 부터 같은 상태다 | [APPLY] chk_docker.log, chk_docker2.log |
| dockerd | `/etc/rc.d/rc.local` 의 `dockerd &` 로 뜬다. cgroup 은 `rc-local.service` 이고 cgroup 드라이버는 cgroupfs 다. Docker 원격 API(2375)는 열려 있지 않다 | [APPLY] chk_docker*.log, U-20.log, [WF1001] U-38 |
| 컨테이너 `oracle-xe` | `--restart always`, `--network host`, `/oradata:/opt/oracle/oradata`, Config.User=oracle(uid 54321) | [G1001] U-64(db-active), [WF1001] D-07 |
| amazon-ssm-agent, amazon-cloudwatch-agent, chronyd, sshd, crond, rsyslog | active | [APPLY] U-20.log, [WF1001] U-66 |
| atd | 활성. 10/2 조치에서 끄지 않았다 | [G1001] U-37, [APPLY] U-37.sh |
| postfix | disabled, inactive | [WF1001] U-45 |

## 5. 주요 설정 파일

| 경로 | 상태 | 근거 |
|---|---|---|
| `/etc/ssh/sshd_config` | `PermitRootLogin no`, `Banner /etc/issue.net`(9/28 04:12 수정), ClientAliveInterval 0 | [RFIX4] U-01, [WF1001] U-12·U-62 |
| `/etc/issue`, `/etc/issue.net` | 195바이트 경고문(9/28). 원문은 확인하지 못했다(TODO) | [WF1001] U-62 |
| `/etc/motd` → `/var/lib/update-motd/motd` | update-motd 가 매일 다시 만든다. `/etc/update-motd.d/99-kisa-warning`(10/2)이 경고문을 덧붙인다 | [APPLY] U-62.log |
| `/etc/pam.d/system-auth-ac`, `password-auth-ac` | authconfig 생성본에 pam_faillock(deny=5)를 더했다. 10/2 에 pam_pwhistory(remember=4, enforce_for_root)와 pwquality `enforce_for_root` 를 추가했다. `system-auth`, `password-auth` 는 링크다 | [APPLY] U-02.log, [RFIX4] U-03 |
| `/etc/security/pwquality.conf` | `minlen = 8`, `minclass = 3`(9/28), `dcredit/ucredit/lcredit/ocredit = -1`(10/2) | [APPLY] U-02.log |
| `/etc/login.defs` | PASS_MAX_DAYS 90, PASS_MIN_DAYS 1, PASS_WARN_AGE 7, PASS_MIN_LEN 8, UMASK 077, ENCRYPT_METHOD SHA512 | [RFIX4] U-02·U-13·U-30 |
| `/etc/profile` | 77~78행 `TMOUT=600` / `export TMOUT`. umask 분기는 둘 다 022(bashrc, csh.cshrc 도 같다) | [WF1001] U-12·U-30 |
| `/etc/hosts.allow`, `/etc/hosts.deny` | `sshd : 10.0.0.176` / `ALL : ALL` | [WF1001] U-53·U-28 |
| `/etc/pam.d/su`, `/usr/bin/su` | pam_wheel 적용, su 권한 4750 | [RFIX4] U-06 |
| `/etc/sudoers.d/` | `team`(28B, 440, NOPASSWD:ALL), `ssm-agent-users`(58B, 9/30), `90-cloud-init-users`(81B, 9/28 수정. ec2-user NOPASSWD 는 비활성) | [APPLY] 00_before.log, [RFIX4] U-63 |
| `/etc/rsyslog.conf`, `/etc/rsyslog.d/*.conf` | 640 root | [RFIX4] U-21 |
| `/etc/logrotate.conf` | weekly, rotate 104, wtmp `create 0644`(9/28) | [WF1001] U-66·U-67 |
| `/etc/tmpfiles.d/var.conf` | `f /var/log/wtmp 0644 root utmp -`(10/2) | [APPLY] U-67.log |
| `/etc/chrony.conf` | 50행 `#log measurements statistics tracking`(10/2 에 기록 끔). 소스는 `sourcedir /run/chrony-dhcp`, `/etc/chrony.d` | [APPLY] U-67.log, [WF1001] U-65 |
| `/etc/systemd/journald.conf` | `SplitMode=none`(10/2, 재부팅해야 반영) | [APPLY] U-67.log |
| `/etc/systemd/**` | 파일 10개 모두 root 600(10/2) | [APPLY] U-20.log |
| `/etc/cron.allow` 등 | crontab·at 750, cron.{hourly,daily,weekly,monthly} 640(10/2). /etc/crontab 640, anacrontab 600, cron.allow 640(root), cron.deny 600, at.deny 640, cron.d/* 640 | [APPLY] U-37.log, [G1001] U-37 |
| `/etc/rc.d/rc.local` | root 755, 60바이트(9/17 10:05). 2행 `dockerd &`, 4행 `docker start oracle-xe`. baseline.sh 가 쓰는 1행 `#!/bin/bash` 와 3행(dockerd 대기 루프)은 **원문이 아닌 대체 내용**이다 | [APPLY] chk_docker2.log, [WF1001] U-17 |
| `/etc/environment` | `ORACLE_SID`, `ORACLE_USER`, **`ORACLE_PWD` 평문**, 644 | [UD], [WF1001] U-14 참고 |
| `/etc/fstab` | user_data 가 `<장치명> /oradata xfs defaults,nofail 0 2` 를 추가했다 | [UD] |
| `/oradata/dbconfig/XE/listener.ora` | 644 oracle:oinstall. 내용은 `files/listener.ora` | [APPLY] 00_before.log, D-15.log |
| `/oradata/dbconfig/XE/sqlnet.ora` | 600 oracle:oinstall. 확인된 설정은 `files/sqlnet.ora.fragment` 에 있다 | [WF1001] D-08·D-10, [RFIX4] D-10 |
| `/oradata/dbconfig/XE/{orapwXE,spfileXE.ora,tnsnames.ora}` | 640, 640, 644 oracle:oinstall | [APPLY] 00_before.log |
| 컨테이너 `/opt/oracle/homes/OraDBHome21cXE/network/admin` | TNS_ADMIN. listener.ora·sqlnet.ora 는 dbconfig 를 가리키는 링크다 | [RFIX4] dbms.out, [WF1001] D-08 |

## 6. 사용자와 그룹

| 계정 | 내용 | 근거 |
|---|---|---|
| root | 비밀번호 있음(SHA512). 사용기간 min 1 / max 90 / warn 7, **2026-12-16 만료**. SSH 직접 로그인 차단 | [APPLY] U-02.log, [RES1002] 5장 |
| team (uid 1001) | user_data 로 만들었다. ed25519 키와 비밀번호가 있고 sudo NOPASSWD:ALL 이다. 사용기간은 10/2 전부터 정책 안이었으나 정확한 값은 확인하지 못했다(TODO) | [UD], [WF1001] U-02 |
| ssm-user | SSM Agent 가 만든다. 잠금 상태, sudo NOPASSWD:ALL | [WF1001] U-07·U-63 |
| ec2-user (uid 1000) | wheel 그룹에서 뺐다. 로그인 셸 보유 일반 계정 목록에는 없다. 셸·잠금을 어떻게 바꿨는지는 확인하지 못했다(TODO) | [MANUAL] U-08, [WF1001] U-07, [APPLY] 00_before.log |
| oracle (54321) | gid `oinstall`(54321), 보조 그룹 `dba`(54322), `/sbin/nologin`, 홈 `/home/oracle`(750, 10/2 생성). 9/28 U-15(소유자 없는 /oradata 파일) 조치로 만든 것으로 보인다 | [WF1001] U-15, [MANUAL] U-15, [APPLY] U-32.log |
| cwagent 995, ec2-instance-connect 998, rngd 997, ftp 14 | 패키지 계정. 홈 디렉터리는 10/2 에 만들었다(750) | [APPLY] U-32.log |
| 그룹 | wheel(구성원 없음), docker(992, 구성원 없음) | [APPLY] 00_before.log, [RFIX4] U-09 |
| DB: XEPDB1 `ORAADMIN` | 9/17 생성(gvenzl APP_USER). 고객 앱 스키마 소유자이고 테이블 10개, 인덱스 14개, 시퀀스 10개가 있다. CONNECT, RESOURCE, CREATE VIEW/SYNONYM/MATERIALIZED VIEW, 프로파일 ORA_CIS_PROFILE | [WF1001] D-02·D-04·D-20 |
| DB: XEPDB1 `ORAADMIN_ADM` | 9/29 생성. CONNECT, RESOURCE, ORAADMIN 테이블 10개에 대한 S/I/U/D 와 private synonym 10개, 프로파일 ORA_CIS_PROFILE | [WF1001] D-02·D-20 |
| DB: CDB$ROOT `OPS$ORACLE` | EXTERNAL 인증, gvenzl 헬스체크용 | [WF1001] D-02 |
| DB: SYS·SYSTEM | 루트에서 LOCKED. 운영 접속은 컨테이너 안 OS 인증(`/ as sysdba`)으로 한다 | [WF1001] D-01·D-03 |

## 7. 보안 조치 상태

### 7-1. 9/28 전후 팀 이행조치

1차 수동 진단 이후, 10/1 실측 이전에 적용됐다. 설정 파일 수정 시각은 대부분 9/28 이다. 원래 명령은 확보하지 못했다. 조치 전 상태는 [MANUAL], 조치 후 상태는 [WF1001]·[RFIX4] 로 확인했다.

| 항목 | 조치 전 → 조치 후 |
|---|---|
| U-01 | PermitRootLogin yes → no |
| U-02 | PASS_MAX_DAYS 99999 / MIN 0 → 90 / 1, pwquality minlen 8·minclass 3 |
| U-03 | 잠금 없음 → pam_faillock deny=5 |
| U-06 | pam_wheel 주석 → 적용, su 4750 |
| U-07~09 | 미사용 계정 `rlagustj`(1002)·그룹 `unused1`(1003) 제거, wheel 에서 ec2-user 제거. 두 계정은 user_data 밖에서 만든 것이라 새 인스턴스에는 없다 |
| U-12 | TMOUT 없음 → 600 |
| U-15 | 소유자 없는 /oradata 파일 → 호스트 oracle(54321) 계정 생성 |
| U-21 | rsyslog.conf 644 → 640 |
| U-23 | unix_chkpwd·at·newgrp 의 SUID, wall·write 의 SGID 제거 |
| U-28 | 정책 없음 → TCP Wrapper |
| U-30 | 일반 사용자 umask 002 → 022 |
| U-45~48 | postfix 구동 → 중지·disabled |
| U-62 | issue·issue.net·SSH Banner |
| U-66 | logrotate 104주 보관, CloudWatch Agent(9/21) |

9/29~9/30 에는 DB 쪽 조치를 했다. 이것도 명령은 확보하지 못했다.
- sqlnet.ora 에 `tcp.validnode_checking`, `tcp.invited_nodes`, `ALLOWED_LOGON_VERSION_SERVER=12a` 를 넣었다(9/30 01:27).
- ORAADMIN 에 ORA_CIS_PROFILE(LIFE_TIME 90, GRACE 5, FAILED_LOGIN 5, LOCK_TIME 1, ORA12C_VERIFY_FUNCTION)을 지정했다.
- ORAADMIN_ADM 계정을 만들었다.
- 루트 SYS·SYSTEM 을 잠갔다.
- `audit_trail=DB,EXTENDED` 를 설정했다.

근거: [WF1001] D-01~D-10, [RFIX4] D-26

### 7-2. 2026-10-02 조치

명령은 [CMD1002] 와 [APPLY] 그대로다. 모두 백업 → 적용 → 확인 순서로 진행했고 결과는 APPLIED_VERIFIED 였다. DB 와 컨테이너는 재시작하지 않았다. 근거: [RES1002] 2장

| 항목 | 내용 |
|---|---|
| U-02 | 두 *-ac 파일에 `pam_pwhistory.so use_authtok remember=4 enforce_for_root` 추가, pwquality 에 `enforce_for_root` 와 `[dulo]credit=-1` 추가, `chage -m 1 -M 90 -W 7 root` |
| U-20 | `/etc/systemd` 파일 10개를 root 600 으로. docker cgroupfs 를 확인한 뒤 daemon-reload |
| U-32 | ftp, ec2-instance-connect, rngd, cwagent, oracle 의 홈 디렉터리 생성(750) |
| U-37 | crontab·at 750, cron.* 디렉터리 640 |
| U-62 | `/etc/update-motd.d/99-kisa-warning` 생성. motd 에도 덧붙였고 update-motd 즉시 실행은 하지 않았다 |
| U-67 | wtmp 644(tmpfiles 유지), chrony 통계 로그 끔(기존 24개 파일은 `/root/u67_bak/chrony_log`), user journal 640, `SplitMode=none` |
| D-05 | CDB$ROOT DEFAULT, XEPDB1 DEFAULT·ORA_CIS_PROFILE 을 `password_reuse_time 365`, `password_reuse_max 10` 으로 |
| D-15 | listener.ora 에 `ADMIN_RESTRICTIONS_LISTENER = ON` 추가 → `lsnrctl reload` → `alter system register`. 이후 `lsnrctl set` 은 거부되므로 파일을 고치고 reload 한다 |
| D-04 | 조치하지 않았다. 판정 기준을 수정해(oracle_maintained='Y' 제외) 양호가 됐다 |
| 장애 조치(10/2 11:16) | sqlnet.ora `tcp.invited_nodes` 에 10.0.10.52, 10.0.10.174 추가 → `lsnrctl reload`. 9/30 설정에 두 앱 서버가 빠져 있어 9/30 08:13 재부팅 뒤 새 연결이 거부됐다 |

근거: [APPLY] fix_invited_nodes.sh, [RES1002] 3장

10/2 조치 뒤 다시 진단한 결과는 다음과 같다. 근거: [RFIX4]
- 리눅스: 양호 46, 취약 1(U-64), N/A 13, 수동확인 7
- DBMS: 양호 15, 취약 1(D-25), 수동확인 5, N/A 5

10/2 이후 db-active 를 바꾼 기록은 없다.

### 7-3. 일부러 고치지 않은 항목

| 항목 | 이유 |
|---|---|
| U-64 | Amazon Linux 2 지원 종료. AL2023 새 인스턴스로 옮겨야 하는데 사용자가 제외했다. 근거: [RES1002] 4장 |
| D-25 | Oracle XE 21c 는 보안 패치가 나오지 않는 에디션이다. 이관은 사용자가 제외했다. 근거: [RES1002] 4장 |

user_data·설계에서 생긴 취약 설정도 아래처럼 그대로 남아 있다. 근거: [UD], [OLD], [INV]
- 컨테이너를 privileged·host 네트워크로 실행한다(privileged 는 user_data 의도이고 실측하지 못함, TODO).
- `/etc/environment` 에 ORACLE_PWD 가 평문으로 있고 권한이 644 다.
- user_data 에 DB·서버 비밀번호를 템플릿으로 넣고 IMDSv1 을 허용한다.
- root 비밀번호 로그인과 team 의 NOPASSWD sudo 가 있다.
- docker.service 가 깨진 채 rc.local 로 dockerd 를 띄운다.
- XE 는 EM Express(5500)가 켜져 있다.

## 8. 스크립트로 재현할 수 없는 것

- **DB 데이터와 스키마.** ORAADMIN 의 테이블과 데이터는 앱의 JPA `ddl-auto: update` 와 DataSeeder 가 만든다. 데이터 볼륨을 9/19 스냅샷으로 만들면 9/19 이후 데이터와 DB 설정 변경(ORAADMIN_ADM, 프로파일, sqlnet.ora 등)이 없다. `baseline.sh` 8장과 7장이 확인된 설정만 다시 적용한다.
- **오프라인 컨테이너 이미지.** DB 서브넷에는 인터넷이 없어 Docker Hub 에서 받을 수 없다. 운영 이미지 다이제스트도 확보하지 못했다. docker save 결과를 `ORACLE_IMAGE_TAR` 나 `ORACLE_IMAGE_TAR_S3` 로 넘겨야 한다.
- **yum 저장소 접근.** docker, amazon-cloudwatch-agent 설치에 필요하다. S3 게이트웨이 엔드포인트 정책이 AL2 저장소 버킷을 허용하는지 확인해야 한다(TODO).
- **비밀값.** root·team·Oracle SYS/oraadmin·ORAADMIN_ADM 비밀번호는 환경변수나 SSM Parameter Store 로 넣는다. 계정에 있는 SSM 파라미터는 `/autodiag/oracle_conn`(진단 도구용)뿐이라 db-active 용 파라미터를 따로 만들어야 한다(TODO).
- **키·지갑.** EM Express 지갑(`/opt/oracle/admin/XE/xdb_wallet`), orapwXE, spfile 원본은 DB 볼륨에 있다.
- **원문을 확보하지 못한 파일.** `/etc/issue(.net)` 경고문, sqlnet.ora 나머지 내용, rc.local 1·3행, `90-cloud-init-users` 수정 내용, *-ac 파일의 faillock 인자, CloudWatch Agent 설정 JSON.
- **명령을 확보하지 못한 DB 설정.** XEPDB1 전통 감사 옵션 16개, 리스너 서비스 `FREE`·`freepdb1` 생성 방법, 9/30 `ALTER USER` 5건의 실제 문장.
- **이력.** 백업(`/root/*_bak*`, `/root/u*_before_20261002.txt`, `/root/sqlnet.ora.bak_*`, `/root/u67_bak/`), 로그, journal, lastlog.

## 9. baseline.sh 사용법

```bash
# 새 인스턴스에서 root 로 실행. os/db-active 폴더(files/ 포함)를 복사해 둔다.
export DB_PASSWORD_SSM_PARAM=/vuln-lab/db-active/db_password                  # 예시 이름(현재 없음)
export ORAADMIN_ADM_PASSWORD_SSM_PARAM=/vuln-lab/db-active/oraadmin_adm_password
export SERVER_PASSWORD_SSM_PARAM=/vuln-lab/db-active/server_password          # user_data 가 실행되지 않았을 때만 쓴다
export ORACLE_IMAGE_TAR_S3=s3://<버킷>/oracle-xe-21-slim.tar               # 오프라인 이미지
sudo -E bash baseline.sh
```

1. user_data 효과 보정. 라이브 user_data 속성은 **CRLF 줄바꿈**이다(10/6 바이트 수로 확인). 새 인스턴스에서는 `#!/bin/bash\r` 때문에 cloud-init 이 스크립트를 실행하지 못할 수 있어 이 단계에서 보정한다.
2. 호스트 oracle 계정
3. 9/28 이행조치 상태
4. 에이전트
5. rc.local 로 dockerd 기동
6. 컨테이너
7. listener.ora·sqlnet.ora
8. 9/29~9/30 DB 상태
9. 10/2 OS 조치(U-02, U-32, U-37, U-62, U-67)
10. 10/2 D-05
11. U-20(맨 마지막)
12. 확인

- 원래 명령을 확보하지 못한 단계에는 `# TODO(확인필요)` 를 달았다. 이런 단계는 증거로 확인된 결과 상태만 만든다.
- 끝나면 재부팅을 권한다. 재부팅해야 dockerd 가 운영과 같이 `rc-local.service` 아래에서 뜨고 journald `SplitMode` 가 반영된다.
- ORAADMIN_ADM 의 권한과 시노님은 ORAADMIN 테이블이 생긴 뒤(앱을 한 번 기동한 뒤) 다시 실행해야 붙는다.

## 10. 확인 필요 사항 (요약)

- 운영 컨테이너의 `--privileged` 여부, 이미지 다이제스트, Docker 버전
- CloudWatch Agent 가 지금 실제로 로그를 보내는지. 현재 DB SG 아웃바운드는 SSM 엔드포인트 SG(443)와 S3 접두사 목록뿐이고 logs 인터페이스 엔드포인트도 없어 전송이 실패할 가능성이 크다
- 9/28 이후 PasswordAuthentication 값, ec2-user 셸·잠금 상태, team 사용기간 값
- `/usr/bin/su` 소유 그룹(baseline 은 wheel 로 둔다)
