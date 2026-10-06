# bastion — OS 구성 (2026-10-06 기준)

vuln-lab VPC 의 SSH 점프 서버. 관리자 PC → bastion → web-adm1·was-adm1·db-active(SSH), web1·was1(RDP) 경로의 입구다. 이 폴더는 인스턴스의 OS 상태를 코드로 남긴다.

| 파일 | 내용 |
|---|---|
| `user_data.tpl` | 최초 부팅 스크립트. 운영 user_data 와 바이트 단위로 같고 비밀값만 템플릿 변수다. **수정 금지** |
| `baseline.sh` | 같은 AMI + user_data 로 만든 새 인스턴스를 현재 상태로 맞추는 스크립트(root, 멱등) |
| `files/hosts.allow` | `/etc/hosts.allow` 전문(10/2 조치 후) |
| `files/banner.FRAGMENT.txt` | 경고문 **조각**(전문 미확보) |

## 근거 자료 표기

| 표기 | 자료 (기본 경로 `C:\claude_work\infra_diag_0929\`) |
|---|---|
| [A] | `report_1001\조치명령_서버별_20261002.md` 1장 bastion (10/2 조치 명령) |
| [B] | `report_1002\조치결과_보고_20261002.md` (10/2 조치 결과) |
| [C] | `apply_scripts\bastion\*.sh` + `results\apply\bastion\*.log` (실제 실행 스크립트와 출력) |
| [D] | `results\rfix4_bastion\scan.out` (10/2 02:43 UTC 조치 후 재진단) |
| [E] | `wf_result_v2.json` bastion 항목 (9/30 실서버 읽기 전용 조회 근거. 9/28~29 팀 이행조치 상태) |
| [G] | `vuln-lab-iac\compute.tf`, `_inventory\inventory.json` (AWS 실측) |
| [H] | `os\bastion\user_data.tpl` |

## 1. 인스턴스·OS

| 항목 | 값 | 근거 |
|---|---|---|
| 인스턴스 | `i-00243f310ea543f2d`, t3.micro, 현재 **stopped** | [G] |
| AMI | `ami-0f68da0073476cce5` (debian-11-amd64-20260821-2577) | [G] |
| OS / 커널 | Debian 11.11 (bullseye) / 5.10.0-46-cloud-amd64 (5.10.262-1) | [C 00_precheck], [D U-64], [E U-64] |
| 네트워크 | public-01 서브넷, 사설 IP 10.0.0.176, EIP **<BASTION_EIP>** | [G] |
| SG `vuln-lab-bastion` | 인바운드 22 ← <ADMIN_IP>/32 + EC2 Instance Connect 접두사 목록 `pl-00ec8fd779e5b4175`(13.209.1.56/29) / 아웃바운드 22·3389 → 10.0.0.0/16, 80·443 → 전체 | [G] |
| IAM | `vuln-lab-ec2-app-profile` (6대 공용 역할) | [G] |
| 디스크 | 루트 8GB gp3, 암호화됨 / IMDS `http_tokens=optional` | [G] |
| 접속 | SSH(team 키) + SSM Session Manager(deb 에이전트) | [C 99_postcheck] |

## 2. 아키텍처상 역할

```
관리자 PC(<ADMIN_IP>) ─SSH 22─> bastion(<BASTION_EIP>) ─SSH 22─> web-adm1 10.0.2.203 / was-adm1 10.0.10.52 / db-active 10.0.20.184
                                                    └─RDP 3389─> web1 / was1
```

- 웹 계층 서버의 TCP Wrapper 는 SSH 를 bastion(10.0.0.176)에서만 받는다(web-adm1 `sshd : 10.0.0.176`) [E web-adm1 U-28].
- 최근 7일 SSH 성공(10/2 기준): team@<ADMIN_IP> 838회, team@<TEAM_IP_2> 9회, team@<TEAM_IP_3> 4회. 10/2 조치 뒤 뒤의 두 곳은 TCP Wrapper 로 막힌다 [C U-28-check].
- EC2 Instance Connect 대역(13.209.1.56/29)은 hosts.allow 와 SG(관리형 접두사 목록 `pl-00ec8fd779e5b4175`) 양쪽에서 허용된다 [G].

## 3. 설치 소프트웨어·버전

| 구성 | 버전·상태 | 근거 |
|---|---|---|
| openssh-server | libwrap 연동(ldd 확인), 0.0.0.0:22·[::]:22 | [C 00_precheck·U-28] |
| libpam-modules | 1.4.0-9+deb11u2 (pam_faillock, pam_pwhistory) | [E U-03] |
| libpam-pwquality, nftables | 9/28 설치(apt history). nftables 룰셋은 비어 있음 | [E U-64·U-28] |
| chrony | AMI 기본, `server 169.254.169.123 prefer iburst`(파일 mtime 2026-08-21) | [E U-65] |
| rsyslog, journald | 배포 기본 규칙, journald 영구 저장 | [E U-66] |
| unattended-upgrades | 켜짐(20auto-upgrades 1/1). 단 bullseye-security 는 2026-08-31 이후 갱신 없음 | [E U-64] |
| user_data 패키지 | netcat-openbsd, telnet, dnsutils(bind9-host 9.16.50-1~deb11u6), awscli | [H], [E U-49] |
| amazon-ssm-agent | deb 서비스 active (snap 아님) | [C 99_postcheck] |
| amazon-cloudwatch-agent | active, 유닛 `/etc/systemd/system/amazon-cloudwatch-agent.service` (설정 미확보) | [C U-20·99_postcheck] |
| /opt/jdk, /opt/maven, /opt/aws | 존재(root:root 755). team 의 .bashrc PATH 가 /opt/jdk/bin·maven 사용, ~/.m2 있음. 버전 미확보 | [E U-14·U-15·U-31·U-33] |
| 없음 | at, MTA, FTP·NFS·SNMP·DNS 서버, inetd | [E U-34~U-61] |

## 4. 서비스·포트

| 포트 | 프로세스 |
|---|---|
| 22/tcp (0.0.0.0, ::) | sshd (TCP Wrapper 적용) |
| 127.0.0.1:323, [::1]:323 /udp | chronyd (클라이언트 전용) |
| 68/udp, 546/udp | dhclient |

근거: [E U-35·U-38]. 타이머: apt-daily(-upgrade), logrotate, man-db, systemd-tmpfiles-clean, e2scrub_all, fstrim [C 99_postcheck].

## 5. 주요 설정 파일

| 경로 | 상태 | 근거 |
|---|---|---|
| `/etc/hosts.allow` | `files/hosts.allow` 전문: `#U28_ROLLBACK# sshd : <ADMIN_IP>` + `sshd: <ADMIN_IP>, 13.209.1.56/255.255.255.248` (조치 전 파일이 46바이트로 앞 줄 + `sshd: ALL` 과 정확히 일치함을 확인) | [C U-28·U-28-check], [E U-28] |
| `/etc/hosts.deny` | `ALL: ALL` (9/29 04:43) | [C], [E U-28] |
| `/etc/pam.d/common-password` | `password    requisite    pam_pwquality.so retry=3` → pam_pwhistory remember=4 use_authtok enforce_for_root → pam_unix obscure use_authtok try_first_pass yescrypt | [C U-02] |
| `/etc/security/pwquality.conf` | minlen=8, d/u/l/ocredit=-1, enforce_for_root | [C 00_precheck] |
| `/etc/pam.d/common-auth`, `common-account`, `/etc/security/faillock.conf` | faillock preauth/authfail/authsucc, account 1행 pam_faillock, deny=5·unlock_time=600·fail_interval=900 | [E U-03] |
| `/etc/pam.d/su` | pam_wheel group=wheel, `/usr/bin/su` 4750 root:wheel | [E U-06·U-09·U-23] |
| `/etc/login.defs` | PASS_MAX 90 / MIN 1 / WARN 7 / MIN_LEN 8, ENCRYPT_METHOD SHA512, UMASK 022 | [E U-02·U-13·U-30], [D U-02] |
| `/etc/profile.d/tmout.sh`, `/etc/profile` 35~36행 | TMOUT=600 readonly + /etc/profile 중복 대입(로그인 때 readonly 경고) | [E U-12], [D U-12] |
| `/etc/issue`, `/etc/issue.net`, `/etc/motd` + sshd `Banner /etc/issue.net`, `PrintMotd no` | 경고문(조각만 확보) | [E U-62] |
| `/etc/ssh/sshd_config` | PermitRootLogin no, PasswordAuthentication no, UsePAM yes, ClientAliveInterval 120 / CountMax 3 | [H], [E U-01·U-12] |
| `/etc/tmpfiles.d/var.conf` | 패키지 복사본 + wtmp 0644·btmp 0600(9/28) + lastlog 0644(10/2) | [C U-67], [E U-67] |
| `/etc/rsyslog.conf`, `rsyslog.d/21-cloudinit.conf` | root 640, 규칙은 배포 기본값 | [E U-21·U-66] |
| `/etc/crontab`, `/etc/cron.allow`(root), `/etc/cron.d/*` | 640. cron.daily·weekly 안의 스크립트도 640 | [E U-37], [C 00_precheck] |

## 6. 사용자·그룹

| 계정 | 내용 | 근거 |
|---|---|---|
| root | 비밀번호는 user_data(`server_password`), SSH 직접 로그인 차단, 기간 1/90 | [H], [E U-01·U-02] |
| admin (1000) | Debian 클라우드 기본 계정. /bin/bash, 비밀번호 잠금, **authorized_keys(런치 키) 있음**, wheel·sudo·adm 그룹, `sudoers.d/90-cloud-init-users` NOPASSWD:ALL, 로그인 이력 없음 | [E U-07·U-08] |
| team (1001) | /bin/bash, ED25519 키(운영 접속 계정), `sudoers.d/team` NOPASSWD:ALL, 기간 1/90, wheel 아님(su 불가) | [H], [C U-28-check], [E U-02·U-06] |
| ssm-user (1002) | /bin/sh, `sudoers.d/ssm-agent-users` NOPASSWD:ALL | [E U-08·U-11] |
| cwagent (997) | nologin, 홈 `/home/cwagent`(10/2 생성) | [C U-32] |
| 그룹 | wheel(1002, 구성원 admin), ssm-user(1003) | [E U-09] |

## 7. 보안 설정 이력 (주요정보통신기반시설 상세가이드 기준)

### 7-1. 9/28~29 팀 이행조치 (10/2 이전 상태) — 근거 [E]
U-01 root SSH 차단, U-02 login.defs·pwquality·pwhistory·기간 1/90, U-03 pam_faillock deny=5, U-06 wheel+pam_wheel+su 4750,
U-12 TMOUT=600, U-18 shadow 400, U-21 rsyslog 설정 640, U-23 unix_chkpwd·wall·write·newgrp 특수권한 해제,
U-37 crontab 750·/etc/crontab 640·cron.allow, U-62 경고문·SSH 배너, U-67 wtmp/btmp 권한(tmpfiles·logrotate).
U-28 은 9/29 에 `sshd : <ADMIN_IP>` 로 제한했다가 `sshd: ALL` 로 되돌린 상태였다.

### 7-2. 10/2 조치 (7건 취약 → 1건) — 근거 [A], [B], [C], [D]
| 항목 | 적용 내용 |
|---|---|
| U-02 | common-password 에 pam_pwquality 추가(pwhistory 앞), pam_unix use_authtok try_first_pass |
| U-20 | `/etc/systemd` 하위 9개 파일 root 600 (bastion 은 유지 유닛 없음) |
| U-28 | hosts.allow `sshd: ALL` → `sshd: <ADMIN_IP>, 13.209.1.56/255.255.255.248` |
| U-32 | nologin 계정 홈 디렉터리 생성, irc 홈 `/run/ircd` → `/var/lib/irc` |
| U-37 | cron.hourly/daily/weekly/monthly `root root 0640` (statoverride) |
| U-67 | `/etc/tmpfiles.d/var.conf` lastlog 0664 → 0644 |

## 8. 남은 항목 (의도적 미조치)

| 항목 | 상태 | 이유 |
|---|---|---|
| **U-64** | 취약 | Debian 11 지원 종료(bullseye LTS 2026-08-31 종료, ELTS 없음). 11→12→13 업그레이드는 사용자가 제외 [B 4장]. 업그레이드 절차는 [A] U-64 참고. 업그레이드 뒤 sshd 의 libwrap 연동이 빠지면 U-28 을 방화벽 방식으로 바꿔야 한다 [A] |
| U-07 / U-08 | 수동확인 | admin(키 로그인 가능, NOPASSWD sudo, 미사용)이 남아 있다. 9/30 검토는 취약으로 판단 [E], 10/2 조치 범위 밖 |
| U-03 | 양호 | 단, `baseline.sh` 는 common-auth faillock 줄을 자동 적용하지 않는다(아래 9장) |
| U-66 | 수동확인 | 로그 정책 미수립(9/30 검토 취약) [E], [D] |
| 기타 수동확인 | U-09, U-15, U-23, U-25, U-33 | [D] |

운영 주의: cron 패키지를 갱신하면 statoverride(`root crontab 2755`)에 따라 crontab 이 2755 로 돌아간다(9/28 조치가 chmod 방식) [E U-37]. 패키지 갱신 뒤 다시 진단한다 [B 5장].

## 9. 스크립트로 재현되지 않는 것

| 대상 | 이유·대처 |
|---|---|
| common-auth faillock 4줄 | 근거에 모듈 순서만 있고 제어 문자열(`[success=N ...]`)이 불완전하다. 잘못 넣으면 비밀번호 인증이 모두 실패할 수 있어 `TODO(확인필요)` 로 남겼다. 실서버 파일 확인 후 추가 |
| 경고문 전문, tmout.sh 줄 형식, pam_wheel 줄 원문, hosts.deny 의 주석 | 조각·요지만 확보. 스크립트는 확인된 값만 넣는다. `files/banner.txt` 가 없으면 조각(`banner.FRAGMENT.txt`, 생략부호 `…` 포함)을 그대로 배포하므로 **재구축한 경고문 문구는 운영과 다르다** |
| ClientAliveInterval 설정 위치 | 실효값(120/3)만 확인. 다를 때만 sshd_config 에 넣는다 |
| JDK·Maven(/opt), team 의 .bashrc·~/.m2 | 버전·출처 미확보 |
| CloudWatch Agent 설정, SSM 에이전트 버전 | 미확보. 스크립트는 AWS 공식 경로로 설치만(CloudWatch 는 기동 안 함) |
| admin 계정의 런치 키 | AMI·cloud-init 이 `vuln-lab-key` 로 다시 만든다(키 쌍은 Terraform 범위) |
| 호스트 고유값 | SSH 호스트 키, machine-id, wheel GID(1002)·ssm-user UID |
| 백업·이력 | `/root/u*_before_*`, `/root/u67_bak/var.conf`, `/etc/hosts.allow.bak*`, `*.bak_u02_*`, 접속 로그 |

## 10. 사용법

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

```bash
# 새 인스턴스(같은 AMI + user_data) 에서, SSM 세션으로 (적용 후 SSH 는 <ADMIN_IP>·EIC 대역만 허용)
sudo -i
bash /path/to/os/bastion/baseline.sh      # files/ 폴더와 함께 복사
```

- 비밀값은 필요 없다(root/team 비밀번호는 user_data 템플릿이 처리).
- 운영 인스턴스에는 실행하지 않는다. 실서버 상태와 다르면 실서버를 기준으로 이 폴더를 고친다.
