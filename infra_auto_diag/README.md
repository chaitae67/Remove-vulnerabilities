# infra_auto_diag — 취약점 빼기 팀 인프라/클라우드 진단 도구 (CLI)

서버(Linux/Windows)와 클라우드(AWS/Azure/GCP/Naver)의 기술적 취약점을 점검하고
KISA 주통기 / SK Shieldus 클라우드 보안가이드 양식으로 결과를 뽑는다.

> **구성 변경 안내**: SSH 기반 GUI(`kisa_gui.py`)와 그 부속 모듈은 제거되었다.
> 현재는 **클라우드 진단 CLI(`cloud_scan.py`)** 와 **서버에서 직접 실행하는 점검 스크립트**로 구성된다.
> 자동 판정을 실제로 검증·유지하는 대상은 **AWS** 이며, Azure/GCP/Naver 코드는 참고용으로 남겨둔 상태(미검증)다.

## 설치

```bash
pip install -r requirements.txt          # 최소: openpyxl + boto3 (AWS)
```

- Python 3.9+
- 점검할 CSP 의 SDK 만 설치해도 된다(미설치 시 해당 provider 만 비활성). NCP 는 표준 라이브러리만 사용.

## 클라우드 진단 — `cloud_scan.py`

터미널에서 바로 실행 → 진단 → CSV/엑셀 저장까지 한 번에. GUI/SSH 불필요, **읽기 전용**(`describe_* / list_* / get_*` 만 호출).

**클라우드 쉘에서 키 없이 그대로** (권장 — 쉘에 이미 로그인된 자격을 자동 사용):

```bash
# AWS CloudShell
python cloud_scan.py aws
# GCP Cloud Shell (프로젝트는 환경변수에서 자동 인식)
python cloud_scan.py gcp
# Azure Cloud Shell
python cloud_scan.py azure --subscription-id <구독ID>
```

**키를 직접 줄 때** (쉘 밖 / CI):

```bash
python cloud_scan.py aws   --access-key AKIA... --secret-key ... --region ap-northeast-2
python cloud_scan.py azure --tenant-id .. --client-id .. --client-secret .. --subscription-id ..
python cloud_scan.py gcp   --sa-key sa.json --project my-proj
python cloud_scan.py naver --access-key .. --secret-key .. --region KR   # 또는 env NCP_ACCESS_KEY/NCP_SECRET_KEY
```

- AWS/Azure/GCP 는 인자를 비우면 **쉘 기본 자격증명(ambient: CloudShell/역할/`az login`/ADC)** 을 자동 사용.
- 네이버(NCP)는 쉘 기본자격이 없어 키가 필요 → 인자·환경변수, 없으면 실행 중 물어본다.
- 끝나면 콘솔에 항목별 판정 요약을 찍고, **항상 CSV** 를 저장하며, 해당 CSP 보고서 양식(`보고서_양식_*.xlsx`)이 있으면 엑셀도 채워 저장한다(`-o` 로 경로 지정, `--no-excel` 로 엑셀 생략).
- ⚠ 보안: **비밀키를 명령행 인자로 주면 `ps`/셸 히스토리/CI 로그에 노출**된다. 가능하면 환경변수나 ambient 자격을 사용하라(실행 시 경고를 출력한다).

### 필요 권한 (읽기 전용)

| CSP | 권한 | 비고 |
|---|---|---|
| AWS | 관리형 정책 **`SecurityAudit`** | Access Key 또는 `~/.aws` 프로필 |
| Azure | 구독 **`Reader`** (서비스 주체) + (선택) Graph **`Directory.Read.All`** | Tenant/Client/Secret + Subscription ID |
| GCP | **`roles/iam.securityReviewer`** + **`roles/viewer`** | 서비스계정 JSON 키 + Project ID |
| Naver | 서브 계정 API 인증키 + Server/VPC 조회 권한 | Access Key/Secret Key |

> Azure AD 항목·GCP Cloud ID 항목 등 조직 관리 권한이 필요한 항목은 자동 판정이 안 되면 "인터뷰 필요" 로 표기된다.
> 자격증명이 유효하지 않으면 진단이 즉시 중단된다(엉뚱한 "양호" 방지).

## 서버 점검 스크립트 (대상 서버에서 직접 실행)

`kisa_unix_check.sh`(Linux, U-01~U-67) / `kisa_win_check.ps1`(Windows, W-01~W-64)는
점검 대상 서버에 올려 **직접 실행**한다(READ-ONLY, 자동 조치 없음). 별도 파이썬 패키지 불필요.

```bash
# Linux (root/sudo 권장 — shadow/sshd -T/iptables 등 정확 판독)
sudo bash kisa_unix_check.sh --json result.json

# Windows (관리자 PowerShell — secedit/SAM ACL/감사정책)
powershell -ExecutionPolicy Bypass -File kisa_win_check.ps1 -Json result.json
```

- 콘솔에 판정 요약을 출력하고, `--json`/`-Json` 로 결과 JSON 을 남긴다.
- `.sh` 는 LF 개행이어야 한다(저장소 `.gitattributes` 로 강제). Windows 에서 편집 시 CRLF 로 바뀌면 원격/직접 bash 실행이 깨진다.
- `.ps1` 은 UTF-8 **BOM** 이어야 PowerShell 5.1 에서 한글이 안 깨진다.

## 판정값

| 스크립트/점검 | 보고서 기재 | 의미 |
|---|---|---|
| 양호 | 양호 | 기준 충족 |
| 취약 | 취약 (빨강) | 기준 미충족 |
| N/A | 양호 | 점검 대상 리소스 없음 |
| 수동확인 | 인터뷰 필요 (파랑) | 정책·업무 컨텍스트 필요 |

## 파일 구성

```
cloud_scan.py         클라우드 진단 CLI (진단 → CSV/엑셀 저장)
cloud_check/          클라우드 진단 엔진 (CSP별 분리, 읽기 전용)
  __init__.py           run(provider, creds) 디스패처
  base.py               Reporter / 상태 상수 / safe() 래퍼
  aws.py    aws_items.py    AWS 41항목  (검증 대상)
  azure.py  azure_items.py  Azure 41항목 (참고용·미검증)
  gcp.py    gcp_items.py    GCP 52항목  (참고용·미검증)
  ncp.py    ncp_items.py    Naver 31항목(자체 양식·미검증)
kisa_unix_check.sh    Linux 서버 점검 (U-01~U-67, 계열 자동분기)
kisa_win_check.ps1    Windows 서버 점검 (W-01~W-64, UTF-8 BOM 필수)
보고서_양식_*.xlsx    결과 엑셀 양식 (cloud_scan 이 클라우드 양식을 사용)
```
