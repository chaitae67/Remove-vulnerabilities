# infra_auto_diag — 취약점 빼기 팀 인프라 진단 자동화 (스크립트)

서버(Linux/Windows)와 클라우드(AWS/Azure/GCP/Naver)의 기술적 취약점을 점검하는 **스크립트 모음**.
KISA 주통기 / SK Shieldus·네이버 클라우드 보안가이드 기준. GUI 없이 터미널/서버에서 바로 실행한다.

- **클라우드**: `python cloud_scan.py <csp>` — 클라우드 쉘/로컬에서 실행 → 결과 CSV(+선택 xlsx)
- **서버**: 대상 서버에서 `kisa_unix_check.sh` / `kisa_win_check.ps1` 직접 실행

---

## 클라우드 진단 — `cloud_scan.py`

읽기 전용(`describe_* / list_* / get_*` 만 호출)으로 리소스를 변경하지 않는다.

### 클라우드 쉘에서 키 없이 그대로 (권장)

쉘에 이미 로그인된 자격(ambient)을 자동 사용한다. 스크립트만 올리면 된다.

```bash
# AWS CloudShell
python cloud_scan.py aws
# GCP Cloud Shell (프로젝트는 환경변수에서 자동 인식)
python cloud_scan.py gcp
# Azure Cloud Shell
python cloud_scan.py azure --subscription-id <구독ID>
```

### 키를 직접 줄 때 (쉘 밖 / CI)

```bash
python cloud_scan.py aws   --access-key AKIA... --secret-key ... --region ap-northeast-2
python cloud_scan.py azure --tenant-id .. --client-id .. --client-secret .. --subscription-id ..
python cloud_scan.py gcp   --sa-key sa.json --project my-proj
python cloud_scan.py naver --access-key .. --secret-key .. --region KR   # 또는 env NCP_ACCESS_KEY/NCP_SECRET_KEY
```

- AWS/Azure/GCP 는 인자를 비우면 **쉘 기본 자격증명**(CloudShell/역할/`az login`/ADC)을 자동 사용.
- 네이버(NCP)는 쉘 기본자격이 없어 키가 필요 → 인자·환경변수, 없으면 실행 중 물어본다.
- **AWS 는 기본적으로 지정 리전만** 스캔(빠름). 전 리전은 `--all-regions`.
- 끝나면 콘솔에 항목별 판정 요약을 찍고, **CSV** 로 저장한다(현재 폴더, ASCII 파일명).
  `openpyxl` 과 보고서 양식(`보고서_양식_*.xlsx`)이 있으면 xlsx 도 함께 저장.
  (`-o` 저장 경로, `--no-excel` xlsx 생략, `--all-regions` 전 리전)

### 단일 파일로 실행 (`cloudscan_all.py`) — 파일 하나만 올리면 끝

`cloud_check/` 패키지를 통째로 내장한 **단일 파일**. 폴더·zip 없이 이거 하나만 올려서 실행하면
스스로 풀어서 돌아간다(결과는 CSV — 양식 xlsx 도 불필요).

```bash
python cloudscan_all.py aws         # 클라우드 쉘에서 키 없이 그대로
python cloudscan_all.py naver --access-key .. --secret-key ..
```
- 옵션·자격증명은 `cloud_scan.py` 와 동일.
- 코드를 고치면 `python build_onefile.py` 로 재생성한다.

### 설치

```bash
pip install -r requirements.txt      # 점검할 CSP 것만 설치해도 됨
```
- CSV 저장은 설치 불필요(표준 라이브러리). xlsx 저장에만 `openpyxl` 필요.
- AWS CloudShell 등에는 boto3/SDK 가 대개 미리 깔려 있어 그대로 실행된다.

### 필요 권한 (읽기 전용)

| CSP | 권한 | 자격증명 |
|---|---|---|
| AWS | 관리형 정책 **`SecurityAudit`** | Access Key / 역할 / `~/.aws` 프로필 |
| Azure | 구독 **`Reader`** + (선택) Graph **`Directory.Read.All`** | Tenant/Client/Secret + Subscription ID |
| GCP | **`roles/iam.securityReviewer`** + **`roles/viewer`** | 서비스계정 JSON 키 + Project ID |
| Naver | 서브계정 API 인증키 + Server/VPC 조회 권한 | Access Key / Secret Key |

> 자격증명이 유효하지 않으면 진단이 즉시 중단된다(엉뚱한 "양호" 방지).
> 권한이 일부 모자라면 해당 항목은 "인터뷰 필요(수동확인)" 로 표기된다.
> Azure AD 항목·GCP Cloud ID/Google 계정 항목은 Graph/Admin SDK 권한이 없으면 인터뷰 필요로 처리.

---

## 서버 진단 — 서버에서 직접 실행

대상 서버에 스크립트를 올려 실행한다(READ-ONLY, 자동 조치 없음).

```bash
# Linux (root/sudo 권장 — shadow·sshd -T 등 정확히 읽힘)
sudo bash kisa_unix_check.sh          # U-01 ~ U-67, RHEL/Debian 계열 자동분기

# Windows (관리자 PowerShell)
powershell -ExecutionPolicy Bypass -File kisa_win_check.ps1   # W-01 ~ W-64
```

- 실행하면 콘솔에 판정+근거를 찍고, **결과 CSV 를 자동 저장**한다(현재 폴더, 엑셀에서 바로 열림):
  `server_linux_<host>_<날짜>.csv` / `server_windows_<host>_<날짜>.csv`.
  경로 지정은 Linux `--csv <파일>` / Windows `-Csv <파일>`, 저장 생략은 `--no-save` / `-NoSave`.
- `.ps1` 은 **UTF-8 BOM** 이어야 PowerShell 5.1 에서 한글이 안 깨진다.
- 서버가 사설망이면, 생성된 CSV 를 SCP/파일전송으로 내려받으면 된다(클라우드 쉘과 동일).

---

## 판정값

| 점검 | 보고서 기재 | 의미 |
|---|---|---|
| 양호 | 양호 | 기준 충족 |
| 취약 | 취약 | 기준 미충족 |
| N/A | 양호 | 점검 대상 리소스 없음 |
| 수동확인 | 인터뷰 필요 | 정책·업무 컨텍스트 필요 |

## 파일 구성

```
cloud_scan.py        클라우드 진단 CLI (진입점 → CSV/엑셀 저장)
cloud_check/         클라우드 진단 코어 (CSP별 분리, GUI/SSH 비의존)
  __init__.py          run(provider, creds) 디스패처
  base.py              Reporter / 상태 상수 / safe() 래퍼
  aws.py    aws_items.py    AWS 41항목 (SK Shieldus 2024 가이드)
  azure.py  azure_items.py  Azure 41항목
  gcp.py    gcp_items.py    GCP 52항목
  ncp.py    ncp_items.py    Naver(NCP) 31항목 (네이버 양식 v1.2)
kisa_unix_check.sh   Linux 서버 점검 (U-01~U-67, 계열 자동분기)
kisa_win_check.ps1   Windows 서버 점검 (W-01~W-64, UTF-8 BOM 필수)
보고서_양식_*.xlsx    클라우드 결과 엑셀 양식 (AWS/Azure/GCP/Naver)
requirements.txt     클라우드 CLI 의존성 (CSP별 SDK + openpyxl)
```

## 개발 메모

- `cloud_scan.py` / `cloud_check/` 는 tkinter·SSH 에 의존하지 않는 **독립 실행** 코드다.
- AWS 는 `_regions()` 가 기본적으로 세션 리전만 반환(빠름). 전 리전은 `CLOUD_SCAN_ALL_REGIONS=1`.
- 네이버(NCP)는 Open API 를 HMAC-SHA256 서명으로 호출(표준 라이브러리 urllib). 정책/인터뷰성 항목은 수동확인.
- 결과 저장은 CSV(표준 라이브러리, utf-8-sig)를 기본으로 하고, 양식+openpyxl 이 있으면 xlsx 를 추가한다.
