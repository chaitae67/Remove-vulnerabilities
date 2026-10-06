# web-adm1 — OS 구성 (2026-10-06 기준)

관리자 웹(`admin.zerodayclinic.p-e.kr`)의 Nginx 역방향 프록시 서버. 이 폴더는 인스턴스의 OS 상태를 코드로 남긴다.

| 파일 | 내용 |
|---|---|
| `user_data.tpl` | 최초 부팅 스크립트. 운영 user_data 와 바이트 단위로 같고 비밀값만 템플릿 변수다. **수정 금지**(바꾸면 인스턴스 교체 위험) |
| `baseline.sh` | 같은 AMI + user_data 로 만든 새 인스턴스를 현재 상태로 맞추는 스크립트(root, 멱등) |
| `files/clinic-admin` | `/etc/nginx/sites-available/clinic-admin` 전문(10/6 수정본) |
| `files/kisa-u20-perm.service`, `.path` | 10/2 U-20 유지 유닛 전문 |
| `files/00rsyslog.conf` | `/etc/tmpfiles.d/00rsyslog.conf` 전문(10/2) |
| `files/99-logperm.cfg` | `/etc/cloud/cloud.cfg.d/99-logperm.cfg` 전문(10/2) |
| `files/banner.FRAGMENT.txt` | 경고문 **조각**(전문 미확보) |

## 근거 자료 표기

| 표기 | 자료 (기본 경로 `C:\claude_work\infra_diag_0929\`) |
|---|---|
| [A] | `report_1001\조치명령_서버별_20261002.md` 2장 web-adm1 (10/2 조치 명령) |
| [B] | `report_1002\조치결과_보고_20261002.md` (10/2 조치 결과, 운영 변경 공지) |
| [C] | `apply_scripts\web-adm1\*.sh` + `results\apply\web-adm1\*.log` (실제 실행 스크립트와 출력) |
| [D] | `results\rfix5_web-adm1\scan.out` (10/2 03:45 UTC 조치 후 재진단) |
| [E] | `wf_result_v2.json` web-adm1 항목 (9/30 실서버 읽기 전용 조회 근거. 9/29 팀 이행조치 상태) |
| [F] | 운영자 메모: 10/6 in-alb 장애와 nginx resolver 수정 (memory `webadm-nginx-stale-alb-ip`) |
| [G] | `vuln-lab-iac\compute.tf`, `alb.tf`, `_inventory\inventory.json` (AWS 실측) |
| [H] | `os\web-adm1\user_data.tpl` |

## 1. 인스턴스·OS

| 항목 | 값 | 근거 |
|---|---|---|
| 인스턴스 | `i-0aab5eedc40f006e0`, t3.micro(RAM 929MB), 현재 **stopped** | [G], 운영 메모 |
| AMI | `ami-0f8d552e06067b477` (ubuntu-focal-20.04-amd64-server-20250624) | [G] |
| OS / 커널 | Ubuntu 20.04.6 LTS / 5.15.0-1117-aws (10/2 재부팅 후) | [C U-64_post] |
| 네트워크 | web-01 서브넷, 사설 IP 10.0.2.203, 공인 IP 없음, SG `vuln-lab-web` | [G] |
| SG | 인바운드 80←ex-alb SG, 22·3389←bastion SG / 아웃바운드 80·443 전체, 8443→in-alb SG | [G] |
| IAM | `vuln-lab-ec2-app-profile` (6대 공용 역할) | [G] |
| 디스크 | 루트 8GB gp3, 암호화됨 / IMDS `http_tokens=optional`(IMDSv1 허용) | [G] |
| 접속 | SSH 는 bastion(10.0.0.176) 경유만, SSM Session Manager(snap 에이전트) | [E U-28], [C] |

## 2. 아키텍처상 역할

```
관리자 브라우저 ─HTTPS─> ex-alb:443 (Host admin.*) ─HTTP:80─> web-adm1 nginx (tg-web-admin, /health)
   ─HTTPS:443 (Host admin.zerodayclinic.p-e.kr)─> in-alb (internal-in-alb-1262980660...) ─HTTP:8080─> was-adm1 (tg-was-admin)
```

- ex-alb 80 은 443 으로 301 리다이렉트한다. web-adm1 은 `X-Forwarded-Proto=http` 이면 301 을 한 번 더 건다 [G], [E WEB-21].
- `location /` 는 실제 클라이언트 IP **<ADMIN_IP>/32 만 허용**한다(ALB 서브넷 10.0.0.0/24·10.0.1.0/24 의 XFF 를 real_ip 로 사용) [files/clinic-admin].
- `/health` 는 nginx 가 직접 `200 ok` 를 준다(ALB 헬스체크, GET/HEAD 만) [files/clinic-admin].
- 10/6 수정: in-alb 이름을 `resolver 10.0.0.2 valid=30s` 로 30초마다 다시 조회한다. 전에는 기동 때 한 번만 조회해 in-alb 노드 IP 가 바뀌자 요청 절반이 60초 멈췄다 [F].

## 3. 설치 소프트웨어·버전

| 구성 | 버전·상태 | 근거 |
|---|---|---|
| nginx / nginx-core / nginx-common | 1.18.0-0ubuntu1.7+esm3 (9/29 재설치) | [C precheck2], [D WEB-25], [E WEB-07] |
| nginx 동적 모듈 | headers-more, image-filter, xslt, mail, stream | [E WEB-18·19] |
| Ubuntu Pro | attached, esm-infra·esm-apps·livepatch enabled (9/29 02:29 연결) | [E U-64·WEB-25], [D U-64] |
| unattended-upgrades | 켜짐(Update-Package-Lists=1, Unattended-Upgrade=1) | [E WEB-25], [D WEB-25] |
| rsyslog | 8.2001.0-1ubuntu1.3+esm1, **root 로 동작**(10/2) | [C precheck2·U-67_WEB-26] |
| PAM | libpam-modules 1.3.1-5ubuntu4.7+esm1, libpwquality1 1.4.2-1build1, libpam-pwquality | [C precheck2] |
| chrony | 3.5-6ubuntu6.2 (10/2 설치, systemd-timesyncd 제거) | [C U-65_record·U-65_chrony] |
| snap | amazon-ssm-agent, canonical-livepatch, core20, core22, lxd, snapd | [C U-20_reapply] |
| amazon-cloudwatch-agent | 설치·active (설정 미확보) | [C U-20·U-64_post] |
| imagemagick 계열 | 8:6.9.10.23+dfsg-2.1ubuntu11.11+esm16 (10/2 갱신, 설치 사유 미확인) | [C U-64] |
| 기타 | openssh-server(libwrap 연동), curl 7.68.0, telnet·ftp 클라이언트, bind9-dnsutils, rsync(서비스 조건 미충족으로 비활성) | [E U-28·U-36·U-49·U-52·U-53] |

## 4. 서비스·포트

| 포트 | 프로세스 | 비고 |
|---|---|---|
| 80/tcp, 443/tcp (0.0.0.0) | nginx (master root, worker www-data) | 443 은 자체서명 인증서. ALB 는 80 으로만 접속 [G] |
| 22/tcp | sshd | TCP Wrapper 로 10.0.0.176 만 허용 |
| 127.0.0.53:53 | systemd-resolved | 로컬 스텁 |
| 68/udp | systemd-networkd | DHCP |

근거: [E U-35·U-38·WEB-09]. 동작 서비스: nginx, rsyslog, cron, atd, chrony, snap.amazon-ssm-agent, amazon-cloudwatch-agent, kisa-u20-perm.path [C U-64_post·U-65_chrony]. `/etc/systemd/system/clinic-admin.service` 는 **disabled·inactive 잔존 유닛**이다 [C U-23].

## 5. 주요 설정 파일

| 경로 | 상태 | 근거 |
|---|---|---|
| `/etc/nginx/nginx.conf` | 패키지 기본값 + `ssl_protocols TLSv1.2 TLSv1.3` + 로그 syslog 전환(main 레벨 `error_log syslog...;` / `error_log stderr emerg;`, http 레벨 access/error_log syslog) | [C precheck2·U-67_followup], [E WEB-20] |
| `/etc/nginx/sites-available/clinic-admin` (sites-enabled 심볼릭 링크) | `files/clinic-admin` 전문, 640 root. 10/6 백업 `/root/clinic-admin.bak.20261006` | [F], [E WEB-12] |
| `/etc/nginx` | 750, 하위 설정 디렉터리 750, 설정 파일 640, conf.d 비어 있음, sites-available/default 는 비활성으로 존재 | [E WEB-05·WEB-14] |
| `/srv/clinic-admin` | 웹 루트 root:www-data 750, `error.html`(208B) 640 하나 | [E WEB-11·WEB-14·WEB-22] |
| `/etc/ssl/certs/clinic-admin.crt` / `/etc/ssl/private/clinic-admin.key` | 자체서명 CN=admin.zerodayclinic.p-e.kr, 2026-09-29~2027-09-29 / 키 600 root | [E WEB-14·WEB-20] |
| `/etc/logrotate.d/nginx` | `create 0640 root adm` | [C U-67_WEB-26] |
| `/etc/rsyslog.conf` | `$FileOwner root`, `$PrivDropToUser/Group` 주석, 640 | [C U-67_WEB-26], [D U-21] |
| `/etc/tmpfiles.d/var.conf`, `00rsyslog.conf` | wtmp 0644·btmp 0600·lastlog 0644 / `/var/log` 0755 유지 | [C U-67_WEB-26] |
| `/etc/cloud/cloud.cfg.d/99-logperm.cfg` | `syslog_fix_perms: ["root:adm"]` | [C U-67_WEB-26] |
| `/etc/chrony/chrony.conf` | 기존 pool 주석, `server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4` | [C U-65_chrony] |
| `/etc/pam.d/common-password` | pam_pwquality retry=3 → pam_pwhistory remember=4 enforce_for_root → pam_unix sha512 | [C U-02_final] |
| `/etc/pam.d/common-auth` / `common-account` | 1행 `auth required pam_tally2.so deny=5 unlock_time=120 onerr=fail audit` / `account required pam_tally2.so` | [E U-03] |
| `/etc/security/pwquality.conf` | minlen=8, minclass=3, d/u/l/ocredit=-1, enforce_for_root | [C U-02_final] |
| `/etc/login.defs` | PASS_MAX 90 / MIN 1 / WARN 7, ENCRYPT_METHOD SHA512, UMASK 022, USERGROUPS_ENAB no | [E U-02·U-13·U-30] |
| `/etc/profile` | 28~30행 `TMOUT=600` / `export TMOUT` / `umask 022` | [E U-12·U-30] |
| `/etc/hosts.allow` / `hosts.deny` | `sshd : 10.0.0.176` / `ALL : ALL` | [E U-28] |
| `/etc/ssh/sshd_config` | PermitRootLogin no, PasswordAuthentication no, UsePAM yes, Banner /etc/issue.net | [H], [E U-01·U-62] |
| `/etc/environment` | user_data 가 `DB_HOST`, `DB_USER`, `DB_PASS` 를 기록(644). 이후 제거 여부 미확인 | [H] |

## 6. 사용자·그룹

| 계정 | 내용 | 근거 |
|---|---|---|
| root | 비밀번호는 user_data(`server_password`). 기간 1/90/7, **2026-12-16 만료**(마지막 변경 9/17) | [C U-02_final], [B 5장] |
| team (1001) | /bin/bash, ED25519 키, `sudoers.d/team` NOPASSWD:ALL, 기간 1/90, 그룹 wheel(1002) | [H], [E U-02·U-06·U-08] |
| ubuntu (1000) | 클라우드 기본 계정. /usr/sbin/nologin, 잠금, authorized_keys(런치 키) 남음, lxd 그룹 | [E U-07·U-11] |
| ssm-user (1002) | SSM 에이전트 자동 생성, 잠금, `sudoers.d/ssm-agent-users` NOPASSWD | [C precheck2], [D U-07·U-63] |
| www-data (33) | nginx worker, nologin, sudo 없음 | [E WEB-09] |
| cwagent (997) | CloudWatch Agent, nologin, 홈 `/home/cwagent`(10/2 생성) | [C U-32] |
| 삭제됨(9/29) | rlagustj 계정, unused1 그룹 | [E U-07·U-09] |

## 7. 보안 설정 이력 (주요정보통신기반시설 상세가이드 기준)

### 7-1. 9/29 팀 이행조치 (10/2 이전부터 적용된 상태) — 근거 [E]
U-01 root SSH 차단, U-02 login.defs·pwquality(minlen 8, minclass 3), U-03 pam_tally2 deny=5, U-06 wheel+pam_wheel+su 4750,
U-07 rlagustj 삭제·ubuntu nologin, U-09 unused1 삭제, U-12 TMOUT=600, U-18 shadow 400, U-21 rsyslog 설정 640,
U-23 unix_chkpwd·at·newgrp·wall 특수권한 해제, U-28 TCP Wrapper, U-30 umask 022, U-37 crontab·cron.allow·at.deny·cron.d 640,
U-62 경고문·SSH 배너, U-64 Ubuntu Pro ESM 연결·apt upgrade, U-66 logrotate rotate 104,
WEB-08 client_max_body_size 10m, WEB-11 웹 루트 `/srv/clinic-admin`, WEB-12 disable_symlinks, WEB-14 권한 750/640,
WEB-16 server_tokens off·more_clear_headers, WEB-20 자체서명 TLS, WEB-21 HTTP→HTTPS, WEB-22 error_page, WEB-25 ESM nginx.

### 7-2. 10/2 조치 (9건 취약 → 0건) — 근거 [A], [B], [C], [D]
| 항목 | 적용 내용 |
|---|---|
| U-02 | pam_pwhistory remember=4, d/u/l/ocredit=-1·enforce_for_root, root `chage -m 1 -M 90 -W 7` (2회 순서검증 실패·롤백 후 3회차 적용) |
| U-20 | `/etc/systemd` 하위 파일 root 600. snap 이 부팅 때 마운트 유닛을 644 로 다시 써서 **`kisa-u20-perm.path/.service`** 로 유지 |
| U-23 | `dpkg-statoverride root tty 0755 /usr/bin/bsd-write` |
| U-32 | nologin 계정 홈 디렉터리 생성, irc 홈 `/var/lib/irc` |
| U-37 | crontab·at `root root 0750`, cron.hourly/daily/weekly/monthly `0640` (statoverride) |
| U-64 | 보안 업데이트 13건(imagemagick 6, 커널 5.15.0-1117 등) + 재부팅 |
| U-65 | systemd-timesyncd → chrony(169.254.169.123) |
| U-67·WEB-26 | rsyslog root 기록, tmpfiles 덮어쓰기, cloud-init 로그 root:adm, **nginx 로그 syslog 전환**(main 레벨 error_log 포함), `/var/log/nginx` root:adm 750(statoverride), 이전 로그 `/root/u67_bak/nginx_logs/` |
| WEB-07 | 기본 html 2개를 `/root/backup_web07/` 로 이동 |

### 7-3. 10/6 변경 — 근거 [F]
`clinic-admin` 의 `proxy_pass` 를 `resolver 10.0.0.2 valid=30s ipv6=off; set $inalb ...; proxy_pass https://$inalb:443; proxy_connect_timeout 5s;` 로 바꿨다. 검증 36회 모두 200.

## 8. 남은 항목

- **취약 0건** (10/2 재진단) [B], [D].
- 수동확인(인터뷰 필요): U-07(ssm-user 사용 여부), U-09, U-15, U-23, U-25, U-33, U-64(패치 정책), U-66(로그 정책. 9/30 검토에서는 정책 미수립으로 취약 판단 [E]), WEB-10(프록시 필요성), WEB-25(패치 정책) [D].
- 운영 주의 [B 5장]
  - nginx 로그는 `/var/log/syslog`(tag=nginx)에 있다. `journalctl -t nginx` 로는 보이지 않는다 [F].
  - rsyslog 가 root 권한으로 돈다(U-67 조치의 대가).
  - systemd·cron·at·pam 패키지를 갱신하면 권한이 되돌아갈 수 있어 패치 뒤 다시 진단한다. statoverride 를 건 항목은 유지된다.
  - nginx 를 재설치·갱신하면 기본 html 이 다시 생긴다(WEB-07 재점검).
- 보안 확인 필요: user_data 가 웹 계층 `/etc/environment` 에 DB 비밀번호를 644 로 남긴다(현재 존재 여부 미확인). team 계정은 NOPASSWD sudo 다 [H].

## 9. 스크립트로 재현되지 않는 것

| 대상 | 이유·대처 |
|---|---|
| Ubuntu Pro 연결 | 토큰이 필요하다. `UBUNTU_PRO_TOKEN` 또는 SSM `/vuln-lab/ubuntu-pro-token`(이름은 `UBUNTU_PRO_TOKEN_SSM_PARAM` 으로 변경 가능, SecureString, aws CLI 필요 - 기본 AMI 에는 없음, **현재 계정에 없음 → 만들어야 함**, 인스턴스 역할은 `/vuln-lab/*` 읽기 허용). 연결 시각·machine-token 은 새로 생긴다 |
| TLS 개인키·인증서 | 새로 만든다(지문·유효기간이 달라짐). 키 알고리즘은 미확보(스크립트는 RSA 2048 로 만들고 TODO 표시) |
| `/srv/clinic-admin/error.html` | 내용 미확보. `files/error.html` 을 넣으면 배포한다 |
| 경고문 전문 | 조각만 확보(`files/banner.FRAGMENT.txt`). 전문을 `files/banner.txt` 로 넣으면 우선 배포. 없으면 조각(생략부호 `…` 포함)이 그대로 배포돼 **재구축한 경고문 문구는 운영과 다르다** |
| nginx.conf 의 다른 9/29 수정 | 1~15행·35~50행과 ssl_protocols 만 확인됨 |
| CloudWatch Agent 설정 | 설정 json·로그 대상 미확보. 스크립트는 설치만 하고 기동하지 않는다(로그 그룹 `aws_instance_logs` 가 있으나 연결 근거 없음) |
| `clinic-admin.service` 잔존 유닛 | 내용 미확보, 비활성이라 재현하지 않음 |
| 패키지·커널 정확한 버전 | ESM 저장소가 계속 갱신되므로 실행 시점 최신으로 설치된다 |
| 백업·이력 파일 | `/root/u67_bak`, `/root/backup_web07`, `*.bak_u02_*`, 이전 nginx 로그, 9/28 `clinic-admin.backup-v5`(위치 미상), bash_history 등 |
| 호스트 고유값 | SSH 호스트 키, machine-id, wheel GID(실서버 1002), ssm-user UID |
| 앱 | web-adm1 에는 앱 바이너리·데이터가 없다(프록시 전용, `/opt/clinic` 은 빈 디렉터리) [E U-15·U-31] |

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
# 새 인스턴스(같은 AMI + user_data) 에서, SSM 세션으로
sudo -i
export UBUNTU_PRO_TOKEN=...      # 또는 SSM /vuln-lab/ubuntu-pro-token 사용 (aws CLI 필요)
bash /path/to/os/web-adm1/baseline.sh      # files/ 폴더와 함께 복사
REBOOT=1 bash /path/to/os/web-adm1/baseline.sh   # 커널 갱신 후 재부팅까지
```

- 스크립트는 단계마다 근거를 주석으로 단다. `# TODO(확인필요)` 는 근거 자료로 확정하지 못한 부분이다.
- 운영 인스턴스에는 실행하지 않는다(이미 같은 상태이며, 인증서 재발급 등 부작용 가능). 실서버 상태와 다르면 실서버를 기준으로 이 폴더를 고친다.
