# vuln-lab-iac : vuln-lab 운영 인프라 Terraform 코드

제로데이 클리닉(32기 3팀) **vuln-lab** 운영 환경을 Terraform 코드로 옮긴 것이다.
대상은 AWS 계정 `<ACCOUNT_ID>`, 리전 `ap-northeast-2`, VPC `vpc-086bab7aac7afcbb4` 이다.
2026-10-06 기준 라이브 상태와 **diff 0** 이 되도록 맞췄다.

- 대상: AWS 리소스 149개 import (+ 선택 리소스: ALB target group attachment 4개, OS 기준선 SSM 문서 6개). 서버 6대의 OS 설정은 `os/<host>/` 에 스크립트로 정리했다.
- 검증 결과 (`_work/plan_final.log`):
  `Plan: 149 to import, 0 to add, 0 to change, 0 to destroy.` (공개 저장소 버전 기준, 2026-10-06 재검증)
  - `aws_lb_target_group_attachment` 4개는 provider 5.100.0 이 import 하지 못하고, 인스턴스가 중지 상태라 등록(RegisterTargets)도 실패할 수 있다.
    그래서 `manage_tg_attachments = false`(기본) 로 두어 plan 에 나오지 않는다. 자세한 내용은 4장 참고.

> **경고** : 예전 모듈 `C:\claude_work\vuln-lab` 에서는 **절대 `terraform apply` 를 실행하지 않는다.**
> 그 모듈의 state 는 2026-08-26 시점에 멈춰 있다. 이후 콘솔과 스크립트로 바꾼 리소스를 삭제하거나 재생성(교체)하려 든다.
> 운영 인프라는 이 디렉터리(`vuln-lab-iac`)로만 관리한다.

> **이 디렉터리의 용도: 2026-10-06 기준 vuln-lab 현 상태를 Terraform 코드로 보존한 스냅샷이다. apply 하지 않는다.**
> - 운영 변경 수단이 아니라 기록이다. 당시 AWS 설정(149개 리소스)과 서버 6대의 OS 구성을 코드로 남겼다.
> - `terraform plan` 은 조회 전용이라 언제든 돌려도 된다. 결과가 `0 to change` 가 아니면 그 사이 라이브가 바뀐 것이다(스냅샷과 현재 비교 용도).
> - 4장(apply)·5장(재구축)은 나중에 이 스냅샷으로 환경을 다시 만들 때를 위한 참고다.

> **공개 저장소 버전 안내**
> 이 저장소는 public 이라 로컬 원본 스냅샷에서 아래 정보를 가리고 올렸다. 실제 값은 팀 로컬 원본(`C:\claude_workuln-lab-iac`)에만 있다.
> - AWS 계정 ID, 관리자 공인 IP·대역 → Terraform 변수 `account_id`, `admin_ip_cidr`, `admin_net_cidr` (기본값 없음, `terraform.tfvars.example` 참고). KMS 키 정책은 `templatefile()` 로 계정 ID 를 넣는다.
> - 문서·OS 파일(`os/`)의 같은 값은 자리표시자로 바꿨다: `<ACCOUNT_ID>`, `<ADMIN_IP>`, `<ADMIN_NET_CIDR>`, `<BASTION_EIP>`, `<TEAM_IP_2>`, `<TEAM_IP_3>`. `os/*/baseline.*` 와 `files/` 를 실제로 쓸 때는 이 자리를 실제 값으로 바꿔야 한다.
> - 운영진 개인 IAM 사용자 3명(사용자·정책 연결 6·그룹 멤버십 2, import 11개)은 뺐다. 그래서 import 수가 로컬 원본 160개 → 149개다.
> - `_inventory/inventory.json`(계정 전체 조회 원본), plan 로그, state, 비밀값 파일은 올리지 않는다. `_inventory/inventory.py` 는 계정 ID 를 환경변수 `AWS_ACCOUNT_ID` 로 받는다.
> - 비밀번호는 원래부터 코드에 없다(`server_password`, `db_password` 변수).

---

## 1. 디렉터리 구성

| 경로 | 내용 |
|---|---|
| `versions.tf`, `providers.tf` | Terraform >= 1.5, `hashicorp/aws = 5.100.0` 고정. `allowed_account_ids` 로 다른 계정에서는 실행되지 않는다 |
| `variables.tf` | 리전·프로필·계정 ID, 비밀 변수 `server_password` / `db_password` (sensitive) |
| `imports.tf` | 라이브 리소스 import 블록 124개 (`_inventory/gen_imports.py` 로 생성) |
| `imports_extra_network.tf` | SG egress 규칙 import 8개 (SG 상호참조 순환을 끊으려고 별도 리소스로 분리) |
| `imports_extra_logging.tf` | 백업 볼트 `Default` import 1개 |
| `imports_extra_iam.tf` | vuln-lab 관련 IAM 사용자 2(vuln-lab-app-user, terraform-admin)·그룹 3·정책 연결 10·그룹 멤버십 1 import 16개. 운영진 개인 사용자 3명은 공개 저장소 버전에서 뺐다(아래 안내) |
| `network.tf` | VPC, 서브넷 8개, IGW, NAT GW와 EIP, 라우팅 테이블·연결, VPC 엔드포인트(SSM 3개, S3 Gateway) |
| `security.tf` | NACL 3개, 보안그룹 9개(default 포함), 분리한 egress 규칙 8개 |
| `compute.tf` | EC2 6대, 키페어, EBS 기본 암호화·KMS, DB 데이터 볼륨과 연결, bastion EIP |
| `alb.tf` | 외부/내부 ALB, 대상 그룹 4개, 리스너, 규칙, 추가 인증서. attachment 4개는 `manage_tg_attachments` 로 선택 |
| `dns_acm.tf` | Route 53 호스티드 존 `zerodayclinic.p-e.kr`, 레코드 5개, ACM 인증서 2개 |
| `storage.tf` | S3 버킷 3개(assets / backup / cloudtrail-logs)와 정책·암호화·로깅·퍼블릭 차단·버전관리 |
| `logging.tf` | VPC Flow Log, CloudTrail `ZDtrail`, CloudWatch 로그 그룹 4개 |
| `kms.tf` + `policies/*.json` | CloudWatch 용·CloudTrail 용 KMS 키, 별칭, 키 정책 원문 |
| `backup_config.tf` | AWS Backup(볼트·플랜 `zd-backup`·선택), AWS Config 레코더·전송 채널 |
| `ssm.tf` + `ssm/*.json` | 자동 진단 Run Command 문서 3개(AutoDiag-Linux/Windows/DBMS). 라이브와 바이트 단위로 같다 |
| `iam.tf` | vuln-lab EC2 역할·인스턴스 프로파일·인라인 정책, CloudTrail→CWLogs 역할, Backup 기본 역할, vuln-lab 관련 IAM 사용자(vuln-lab-app-user, terraform-admin)·그룹(AppOps, Audit, infra_Management)·관리형 정책 연결·멤버십. 사용자 태그(개인정보)는 `ignore_changes`, 키·MFA·로그인 프로필은 관리하지 않음 |
| `os_baseline.tf` | (선택) `os/<host>/baseline.*` 를 감싼 SSM 문서 6개. 기본 비활성 |
| `outputs.tf` | ALB DNS, bastion/NAT 공인 IP, VPC·서브넷 ID, 인스턴스 ID·사설 IP, NS |
| `terraform.tfvars.example` | 변수 예시 (자리표시만 있음) |
| `os/<host>/user_data.tpl` | 라이브 user_data 원본 템플릿. 렌더링 결과가 라이브와 바이트 단위로 같다. **수정 금지** |
| `os/<host>/baseline.(sh\|ps1)`, `files/`, `README.md` | 서버별 OS 기준선: 9/28~10/2 팀 조치와 10/2 취약점 조치를 재현하는 멱등 스크립트. 근거와 재현 불가 항목은 각 README 에 있다 |
| `_inventory/` | 라이브 조회·import 블록 생성 스크립트 (`inventory.json` 은 gitignore). user_data 원문(평문 비밀번호 포함)은 저장소 밖 `C:\claude_work\vuln-lab-iac-private\userdata\` 로 옮겼다. `os_static.py` 는 화면에 sha256·길이만 출력하고 원문은 `_work/userdata/` 에만 쓴다 |
| `_work/` | 작업 산출물(plan 로그, 주소 매핑). **gitignore 대상, 공유 금지** (plan 로그에는 user_data SHA1 해시와 IAM 사용자 개인정보 태그가 들어 있다) |

서버 6대:

| 호스트 | OS | 서브넷 | 사설 IP | 역할 |
|---|---|---|---|---|
| bastion | Debian 11 | public_01 | 10.0.0.176 | SSH 점프 (EIP) |
| web1 | Windows Server 2019 | web_01 | 10.0.2.8 | 고객 웹 IIS+ARR 리버스 프록시 |
| web-adm1 | Ubuntu 20.04 | web_01 | 10.0.2.203 | 관리자 웹 nginx 프록시 |
| was1 | Windows Server 2019 | was_01 | 10.0.10.174 | 고객 Spring Boot (nssm) |
| was-adm1 | Rocky Linux 8.10 | was_01 | 10.0.10.52 | 관리자 Spring Boot |
| db-active | Amazon Linux 2 | db_01 | 10.0.20.184 | Oracle XE 21 컨테이너 |

인스턴스는 일부러 **중지 상태**로 둔다. plan/apply 는 인스턴스를 시작하지 않는다.

---

## 2. 사전 준비

1. Terraform 1.5 이상 (작업에 쓴 버전: `C:\claude_work\terraform.exe` v1.15)
2. AWS CLI 자격증명 프로필 `default` (= sk104_32_team_3). 조회 권한이 있어야 한다
3. provider 설치: 네트워크가 되면 `terraform init`. 오프라인이면
   `terraform init -input=false -plugin-dir=<기존 .terraform/providers 경로>`
4. 비밀값 파일 만들기 (**git 에 올리지 않는다**, `*.tfvars` 는 gitignore 대상):
   ```bash
   cp terraform.tfvars.example secret.auto.tfvars
   # secret.auto.tfvars 의 <...> 자리에 실제 server_password / db_password 를 입력
   ```
   두 값은 `os/<host>/user_data.tpl` 렌더링에만 쓴다. 인스턴스에는 `ignore_changes = [user_data]` 가 걸려 있어서
   값이 틀려도 plan 결과는 같다. 그래도 재구축할 때는 올바른 값이 필요하다.

## 3. plan 실행 (읽기 전용)

```bash
cd C:/claude_work/vuln-lab-iac
terraform plan -input=false -lock=false
# 기대 결과: Plan: 149 to import, 0 to add, 0 to change, 0 to destroy.
```

- 변수가 sensitive 라서 plan 출력에 비밀번호가 나오지 않는다. user_data 는 SHA1 해시로만 표시된다.
  - 단, `web1`·`was1` 의 user_data 는 템플릿과 바이트 단위로 같고 모르는 값은 `server_password` 하나뿐이다. 따라서 **plan 로그(또는 state) + 이 저장소가 있으면 오프라인 비밀번호 추측이 가능**하다.
    plan 로그·state 는 공유하지 않고, 실습 환경을 다시 만들 때 `server_password` 를 바꾼다.
  - import 대상 IAM 사용자의 태그(부서/직책/이름/이메일)도 plan 출력에 그대로 나온다. 로그를 공유하지 않는다.
- 계정 보호: `providers.tf` 의 `allowed_account_ids = [var.account_id]` 라서 tfvars 에 넣은 계정이 아니면 실행되지 않는다(공개 저장소 버전은 계정 ID 를 코드에 두지 않는다).
- `change` 나 `destroy` 가 하나라도 나오면 콘솔에서 누군가 라이브를 바꾼 것이다. 코드와 라이브 중 어느 쪽이 맞는지 먼저 확인한다.

## 4. (참고) apply 하면 생기는 일 — 스냅샷 용도에서는 실행하지 않음

이 스냅샷은 **apply 하지 않는 것을 전제**로 만들었다. 이 코드를 만들면서 apply 는 한 번도 실행하지 않았다. 아래는 나중에 이 코드로 state 를 만들거나 재구축할 때의 참고다.

- **import 149개** : 라이브 리소스를 Terraform state 에 기록만 한다. AWS 리소스는 바뀌지 않는다.
- **ALB 대상 등록 4개 (`aws_lb_target_group_attachment.this`)** : 기본값 `manage_tg_attachments = false` 에서는 만들지 않는다(plan 에 나오지 않음).
  - provider 5.100.0 은 이 리소스의 import 를 지원하지 않는다.
  - 대상(web1:80, web-adm1:80, was1:8080, was-adm1:8080)은 라이브에 이미 등록돼 있다. 하지만 4대 모두 중지 상태라
    `describe-target-health` 가 `unused / Target.InvalidState` 다. ELBv2 는 EC2 대상이 running 일 때만 등록을 받으므로,
    중지 상태에서 apply 하면 import 133개 뒤에 이 4개만 실패해 **부분 적용 상태**가 된다.
  - state 에 편입하려면: 인스턴스를 기동한 뒤 `-var manage_tg_attachments=true` 로 apply 한다(이미 등록된 대상이라 RegisterTargets 는 사실상 변화 없음).
    기동하지 않을 거라면 계속 false 로 둔다. 라이브 등록은 그대로 유지된다.
- apply 를 한 번 하고 나면 state 파일(`terraform.tfstate`)이 생긴다. 이 파일에는 리소스 속성(user_data SHA1 해시, IAM 사용자 태그 포함)이 들어간다. **공유하지 말고, 원격 백엔드(S3 + KMS 암호화, 버킷 접근 제한)로 옮긴다.**
- 중요한 리소스(VPC, NAT EIP, 인스턴스, EBS, S3, KMS, CloudTrail, 로그 그룹, Route 53 존, ACM, ALB, 백업 볼트, 팀 IAM 사용자)에는
  `lifecycle { prevent_destroy = true }` 가 걸려 있다. 삭제나 교체가 필요한 plan 은 에러로 멈춘다.

### 4.1 이 모듈이 관리하는 계정/리전 단일 설정

아래는 vuln-lab 전용이 아니라 리전(또는 계정)에 하나뿐인 설정이다. 라이브와 diff 0 으로 import 만 하므로 apply 자체는 영향이 없다.
다만 **코드를 바꿔 apply 하거나 destroy 하면 같은 계정·리전을 쓰는 다른 팀에도 그대로 적용된다.**

| 리소스 | 범위 | 바꾸거나 지우면 |
|---|---|---|
| `aws_ebs_encryption_by_default`, `aws_ebs_default_kms_key` | 리전 | 리전의 모든 새 EBS 볼륨 암호화 여부·기본 키가 바뀐다 |
| `aws_config_configuration_recorder`, `_delivery_channel`, `_recorder_status` (2025-12 이전부터 있음, 프로젝트 이전 설정) | 리전 | 리전 전체 Config 기록이 바뀐다. 현재 레코더는 정지 상태다 |

반대로 계정 단위 S3 Public Access Block, IAM 비밀번호 정책, AWS Backup 리전 설정, DHCP 옵션 세트는 **관리하지 않는다**(6장).
기준: vuln-lab 이 실제로 쓰고 라이브 값이 이미 이 프로젝트 기준으로 맞춰진 것만 import 했고, 다른 팀 정책에 가까운 계정 공용 설정은 뺐다.

## 5. 새 환경에 재구축할 때 (참고)

이 코드는 **현재 운영 계정을 그대로 기술하는 것**이 목적이다. 다른 계정이나 리전에 새로 만들려면 아래를 조정한다.

1. `imports*.tf` 3개 파일 삭제 (새 환경에는 import 할 대상이 없다)
2. `account_id`·`region`·S3 버킷 이름(전역 유일)·도메인 수정. 정책 JSON(`policies/`, `storage.tf`)에 들어 있는 계정 ID도 함께 바꾼다
3. `ignore_changes` 검토
   - `aws_instance.*` : `user_data` 는 템플릿 렌더링 결과라서 새로 만들 때는 그대로 쓰인다. 운영 중 비밀번호를 바꾼 뒤 교체되는 것을 막는 용도라서 유지를 권장한다
   - `aws_key_pair.vuln_lab_key` : `public_key` 는 provider 가 import 때 state 에 쓰지 않아서 무시하도록 했다. 새로 만들 때는 그대로 쓰인다
   - `aws_backup_plan.zd_backup` : 라이브의 S3 `advanced_backup_setting`(BackupACLs/ObjectTags) 을 provider 5.100 은 표현하지 못한다. **새로 만들면 이 설정은 빠진다**. 콘솔에서 추가하거나 provider 를 올린 뒤 코드에 넣는다
4. `prevent_destroy` : 실습 환경을 정리(destroy)하려면 해당 리소스의 블록을 먼저 지운다. ALB 는 `enable_deletion_protection = true` 도 꺼야 한다
5. `enable_os_baseline = true` : 호스트별 OS 기준선 SSM 문서 6개(`vuln-lab-OSBaseline-<host>`)가 생긴다.
   association 은 만들지 않는다. 인스턴스 부팅과 user_data 가 끝난 뒤 사람이 직접 Run Command 로 실행한다.
   - Linux 문서 파라미터 `ExtraEnv` : 비밀이 아닌 환경변수만 넣는다(예: `DB_PASSWORD_SSM_PARAM=/vuln-lab/db_password REBOOT=1`).
     키 이름에 PASSWORD/PASSWD/PWD/TOKEN/SECRET 가 들어가면 `*_SSM_PARAM` 형태만 허용한다(allowedPattern). 모든 리눅스 baseline 은 `<이름>_SSM_PARAM` 규칙을 쓴다
     (db-active: `DB_PASSWORD_SSM_PARAM`·`SERVER_PASSWORD_SSM_PARAM`·`ORAADMIN_ADM_PASSWORD_SSM_PARAM`, was-adm1: `DB_PASSWORD_SSM_PARAM` 등, web-adm1: `UBUNTU_PRO_TOKEN_SSM_PARAM`)
   - Windows 문서 파라미터 `ScriptArgs` : `baseline.ps1` 인자(예: `-Reboot -UrlRewriteMsi C:\pkg\rewrite.msi`)
   - 비밀값(Ubuntu Pro 토큰, ZD_RDP·DB 비밀번호 등)은 SSM SecureString 으로 따로 만들고 이름만 넘긴다. 필요한 비밀값 목록은 각 `os/<host>/README.md` 에 있다
   - **운영 중인 db-active 에는 진단·기준선 스크립트를 돌리지 않는다** (9/29 과부하 이력)
6. 알려진 재구축 이슈 (운영에는 영향 없음)
   - `os/*/user_data.tpl` 은 라이브와 같게 CRLF 줄바꿈이다. 리눅스 새 인스턴스에서는 `#!/bin/bash\r` 때문에 cloud-init 이 스크립트를 실행하지 못할 수 있다.
     db-active `baseline.sh` 만 user_data 효과를 스스로 재현한다. web-adm1·bastion·was-adm1 은 user_data 미실행(team 계정 없음)을 감지하면 바로 멈추고,
     각 `os/<host>/README.md` 10장의 수동 절차(user_data 를 `tr -d '\r'` 후 실행)를 먼저 해야 한다. 근본적으로 고치려면 compute.tf 에서 `replace(templatefile(...), "\r\n", "\n")` 로 바꾼다(운영 plan 은 ignore_changes 때문에 영향 없음)
   - db-active user_data 는 AL2023(dnf)을 전제로 썼지만 AMI 는 AL2 다. 운영에서는 docker 를 yum 으로 설치하고 rc.local 로 띄웠고, baseline.sh 가 이 상태를 재현한다
   - DB 데이터 볼륨 `snapshot_id` 는 2026-09-19 스냅샷이다. 그 이후 DB 변경 내용은 들어 있지 않다
   - 인스턴스 6대의 **루트 볼륨도 2026-09-19 암호화 복사 스냅샷에서 복원**된 것이다(예: `snap-0abb2d3fe9e424d2a` enc-was1-root, `snap-01dadf56687796720` enc-web1-root).
     compute.tf 의 AMI ID 는 최초 기동 계보일 뿐이다. 코드로 새로 만들면 AMI 원본 OS 디스크가 생기므로 `os/<host>/baseline.*` 로 OS 상태를 맞춘다
   - AWS Config 전송 채널의 버킷 `config-bucket-<ACCOUNT_ID>` 는 **존재하지 않는다**(head-bucket 404). 새로 만들 때는 이 버킷(및 config.amazonaws.com 쓰기 정책)을 먼저 만들어야 전송 채널 생성이 성공한다.
     새 계정에서는 `AWSServiceRoleForConfig` 서비스 연결 역할도 먼저 있어야 레코더를 만들 수 있다
   - 리전을 바꾸면 `storage.tf` ALB 로그 버킷 정책의 ELB 로그 전달 계정 `600734575887`(서울 리전 전용)도 해당 리전 값으로 바꾼다
   - 와일드카드 ACM 인증서의 DNS 검증 CNAME 이 호스티드 존에 없다. 인증서는 ISSUED 상태지만 자동 갱신 전에 다시 추가해야 한다(`dns_acm.tf` 주석)
   - S3 SSE 의 `BlockedEncryptionTypes = [SSE-C]` 는 provider 5.100 스키마에 없어서 코드에 넣지 못했다(plan 영향 없음)

---

## 6. 제외 항목 (코드에 넣지 않은 것과 이유)

| 항목 | 제외 이유 |
|---|---|
| 교육기관 제공 IAM 사용자/그룹/정책 (사용자 CostManager·sk104_32_team_3, 그룹 Admin·CostManagers·student*, 고객 관리형 정책 studentAdmin·student_*) | 교육 제공자가 관리하는 계정 공용 자원. vuln-lab 소유가 아니다 (팀이 만든 사용자·그룹은 `iam.tf` 에서 관리) |
| IAM 그룹 `GRP-IAC-DIAG` | 2026-04 생성(프로젝트 이전), 구성원 없음. 다른 과정/팀 자원 |
| 팀 IAM 사용자의 액세스 키·MFA 장치·콘솔 로그인 프로필, 개인정보 태그 | 자격증명·개인정보라 코드/state 에 넣지 않는다(태그는 `ignore_changes`) |
| 다른 팀의 Lambda/EKS/EventBridge 용 IAM 역할 | 같은 계정을 쓰는 다른 팀 자원 |
| 계정 단위 S3 Public Access Block | 공유 계정 전체에 적용되는 설정. 이 모듈이 관리하면 다른 팀에 영향을 준다 (버킷 단위 차단은 포함) |
| AWS 관리형 EFS 자동 백업 플랜 | AWS 서비스가 자동으로 만들고 관리한다 |
| ALB 서비스 관리형 EIP | ELB 서비스가 할당·관리한다. 사용자가 관리할 수 없다 |
| `AnthropicVerification` IAM 역할 | 임시 검증용 역할 |
| SSM 파라미터 `/autodiag/oracle_conn` | SecureString 이다. import 하면 비밀값이 state 에 평문으로 저장된다 |
| SSM 문서 `SSM-SessionManagerRunShell` | 2022년부터 있던 계정 공용 Session Manager 기본 설정 |
| SSM association `SystemAssociationForSsmAgentUpdate`(문서 AWS-UpdateSSMAgent, rate(14 days), 전체 인스턴스), `AWS-QuickSetup-SSM-EnableExplorer` | 2022~2023년 계정 공용 Quick Setup 설정 |
| IAM 계정 비밀번호 정책 | 계정 공용 설정 |
| 미사용 역할 `EC2-SSM-CWAgent-Role`, `CloudWatchAgentServerRole` | 어떤 vuln-lab 인스턴스에도 연결돼 있지 않다 |
| S3 객체, DB 데이터, 애플리케이션 바이너리(jar 등) | 인프라가 아닌 데이터·산출물. Terraform 관리 대상이 아니다 |
| 자동 진단 도구 S3 객체 6개 `s3://vuln-lab-backup/infra-auto-diag/tools/` (cloudscan_all.py, db_oracle_check.sh, kisa_all_check.ps1, makereport_all.py, s3report.ps1, s3report.sh, 2026-09-30~10-02) | `ssm/AutoDiag-*.json` 문서가 실행하는 도구다. 수 MB 크기 스크립트라 코드에 넣지 않았다. 원본 소스는 팀 저장소 `Remove-vulnerabilities/infra_auto_diag/`(업로드본과 동일 여부는 미확인). 재구축 시 AutoDiag 문서를 쓰려면 이 경로에 먼저 업로드한다 |
| AWS Backup 복구 지점(볼트 Default 255개), 자체 소유 EBS 스냅샷(284개), 수동 AMI(web1-clone-image, web1-team-clone, was1-team-clone) | 백업·이미지 데이터. AWS Backup 이 관리하거나 일회성 산출물이다 |
| `aws_acm_certificate_validation` | 실제 AWS 리소스가 아니라 검증 대기 동작이다. import 할 수 없다 |
| GuardDuty, WAF, Security Hub, Inspector2, Macie | 계정(리전)에서 사용하지 않는다 (Security Hub 미구독, Inspector2 DISABLED, Macie 미활성) |
| Config 전송 버킷 `config-bucket-<ACCOUNT_ID>` | **버킷이 존재하지 않는다**(head-bucket 404). 전송 채널이 이름만 참조한다. 라이브 Config 전송은 이미 끊긴 상태(레코더도 정지)이고, 재구축 시 버킷을 먼저 만들어야 한다(5장) |
| AWS Backup 리전 설정(리소스 유형 opt-in: EC2/EBS/S3/EFS 등 true, EKS/DSQL/Redshift Serverless false) | 리전 공용 설정. `zd-backup` 선택이 `resources = ["*"]` 라서 실제 백업 대상은 이 설정에 좌우된다 |
| DHCP 옵션 세트 `dopt-0a191fff3e8014604` (ap-northeast-2.compute.internal, AmazonProvidedDNS) | 리전에 하나뿐인 계정 공용 세트. 새 VPC 는 기본으로 이 세트와 같은 값을 쓴다 |
| 서비스 연결 역할 `AWSServiceRoleForConfig`, `AWSServiceRoleForBackup`, `AWSServiceRoleForElasticLoadBalancing` 등 | AWS 가 만들고 관리하는 계정 공용 역할. 코드는 ARN 으로만 참조한다(Config 레코더 role_arn) |

---

## 7. 안전 수칙 요약

- 이 디렉터리에서 apply 할지는 사용자가 plan 결과를 확인하고 정한다. 예전 모듈 `C:\claude_work\vuln-lab` 에서는 apply 를 하지 않는다.
- `secret.auto.tfvars`, `_work/`, `*.tfstate`, `*.tfplan`(plan -out 파일에는 sensitive 변수 평문이 들어간다) 는 커밋하거나 공유하지 않는다.
- 이 폴더는 아직 git 저장소가 아니다. `.gitignore` 는 압축·복사에는 효과가 없으므로 폴더째 공유할 때는 `_work/` 를 빼고 보낸다.
- `os/<host>/user_data.tpl` 은 라이브와 바이트 단위로 같은 템플릿이다. 수정하면 재구축 결과가 운영과 달라진다.
- `.gitattributes` 가 `user_data.tpl`, `ssm/*.json`, `policies/*.json` 의 줄바꿈 변환을 막는다(라이브와 바이트 단위로 같게 유지).
