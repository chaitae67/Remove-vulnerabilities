# infra_auto_diag — 취약점 빼기 팀 인프라 진단 자동화 툴

서버(Linux/Windows)와 클라우드(AWS/Azure/GCP)의 기술적 취약점을 점검하고
KISA 주통기 / SK Shieldus 클라우드 보안가이드 양식으로 결과 엑셀을 뽑는 GUI 도구.

## 설치

```bash
git clone <repo>
cd infra_auto_diag
pip install -r requirements.txt
python kisa_gui.py
```

- Python 3.9+ / Tkinter 포함 배포판
- `requirements.txt` 의 `boto3` 는 AWS 진단용. Azure/GCP 는 해당 단계에서 주석 해제.
- 서버 진단만 쓸 거면 `paramiko`, `openpyxl` 만 있어도 됨.

## 진단 대상별 사용법

### Linux / Windows 서버 (SSH)
1. "진단 대상" 에서 `Linux 서버` 또는 `Windows 서버` 선택
2. IP/호스트 · 계정 · 비밀번호(또는 SSH 키) 입력, 필요 시 게이트웨이 설정
3. `▶ 점검 실행` → 결과 표에서 행 더블클릭으로 최종판정 조정 → `엑셀로 추출`
4. 점검 스크립트(`kisa_unix_check.sh` / `kisa_win_check.ps1`)는 READ-ONLY.
   root/sudo(또는 관리자)로 실행해야 shadow·sshd -T·secedit 등이 정확히 읽힘.

### AWS / Azure / GCP (API)
1. "진단 대상" 에서 `AWS` / `Azure` / `GCP` 선택
2. `자격증명 설정` 버튼 → 키 입력 (또는 환경 자격증명 사용)
3. `▶ 클라우드 진단` → 표/엑셀은 서버와 동일하게 사용

클라우드 진단은 **읽기 전용** (`describe_* / list_* / get_*` 만 호출). 리소스를 변경하지 않음.

#### 필요 권한 (읽기 전용)

| CSP | 권한 | 비고 |
|---|---|---|
| AWS | 관리형 정책 **`SecurityAudit`** 를 진단용 IAM 사용자/역할에 연결 | Access Key 또는 `~/.aws` 프로필 |
| Azure | 구독 **`Reader`** 역할 (서비스 주체) | Tenant/Client/Secret + Subscription ID |
| GCP | **`roles/iam.securityReviewer`** + **`roles/viewer`** | 서비스계정 JSON 키 + Project ID |

> 자격증명이 유효하지 않으면 진단이 즉시 중단된다(엉뚱한 "양호" 결과 방지).
> 권한이 일부 모자라면 해당 항목은 "인터뷰 필요(수동확인)" 로 표기된다.

## 판정값

| 스크립트/점검 | 보고서 기재 | 의미 |
|---|---|---|
| 양호 | 양호 | 기준 충족 |
| 취약 | 취약 (빨강) | 기준 미충족 |
| N/A | 양호 | 점검 대상 리소스 없음 |
| 수동확인 | 인터뷰 필요 (파랑) | 정책·업무 컨텍스트 필요 |

## 파일 구성

```
kisa_gui.py          메인 GUI (App 클래스, SSH 실행, 결과 표)
common.py            공용 상수/헬퍼
excel_export.py      엑셀 추출 (서버 양식 = zip/XML 직접편집, 클라우드 = openpyxl)
gateway_dialog.py    게이트웨이(bastion) 설정
detail_dialog.py     행 더블클릭 상세/최종판정
cloud_dialog.py      클라우드 자격증명 입력
cloud_check/         클라우드 진단 (CSP별 분리)
  __init__.py          run(provider, creds) 디스패처
  base.py              Reporter / 상태 상수 / safe() 래퍼
  aws.py  aws_items.py  AWS 41항목 (SK Shieldus 2024 가이드)
  azure.py  gcp.py       (2·3단계 예정)
kisa_unix_check.sh   Linux 서버 점검 (U-01~U-67, 계열 자동분기)
kisa_win_check.ps1   Windows 서버 점검 (W-01~W-64, UTF-8 BOM 필수)
보고서_양식_*.xlsx    결과 엑셀 양식
```

## 개발 메모

- Windows 점검 스크립트(`.ps1`)는 **UTF-8 BOM** 이어야 PowerShell 5.1 에서 한글이 안 깨진다.
- 서버 엑셀 양식은 차트가 있어 openpyxl 로 열었다 저장하면 깨진다 → `excel_export.py`
  가 zip/워크시트 XML 만 직접 편집한다. 클라우드 양식은 차트가 없어 openpyxl 직접 사용.
- 클라우드 진단은 GUI 프로세스 안에서 스레드로 실행된다(SSH 없음).
