# infra_auto_diag — 취약점 빼기 팀 인프라 진단 자동화 (스크립트)

클라우드·서버·웹서버·DBMS 의 기술적 취약점을 점검하는 **스크립트 모음**.
KISA 주통기 / SK Shieldus·네이버 클라우드 보안가이드 기준. GUI 없이 터미널/서버에서 바로 실행한다.
각 스크립트는 **파일 하나만 대상에 올리면** 돌아가고(설치 불필요), 끝나면 **CSV + (셀프) HTML 리포트**를 남긴다.

## 진단 분류(4 + DB)

| 분류 | 실행 스크립트 | 대상 | 항목 |
|---|---|---|---|
| **클라우드** | `cloudscan_all.py` (단일파일) 또는 `cloud_scan.py` | AWS/Azure/GCP/Naver | CSP별 |
| **리눅스** | `kisa_unix_check.sh` | Linux 서버 | U-01~U-67 |
| **윈도우** | `kisa_win_check.ps1` | Windows 서버 | W-01~W-64 |
| **웹서버** | `web_linux_check.sh` (Nginx·Tomcat) / `web_windows_check.ps1` (IIS) | web·was | WEB-01~WEB-26 |
| DBMS | `db_oracle_check.sh` | Oracle DB | D-01~D-26 |

> 웹서버는 소프트웨어가 OS를 걸쳐 있어(IIS=Windows, Nginx/Tomcat=Linux) 리눅스용 `.sh` + 윈도우용 `.ps1`
> 두 파일로 나뉘지만 **항목 코드(WEB-01~26)는 동일**하다. 서버(리눅스/윈도우)·웹서버·DB 스크립트는
> 점검을 대상에서 셸/파워셸로 직접 수행하므로 **파이썬이 필요 없다**(클라우드만 파이썬).
>
> 이 환경 대상: web-adm1(Nginx 1.18.0) · web1(IIS 10.0) · was1/was-adm1(Tomcat 10.1.31, Spring Boot 내장) · db(Oracle XE 21c).

### 대상에 어떻게 넣고 돌리나 (SSH 없이)

EC2 콘솔의 **인스턴스 연결(EC2 Instance Connect)** 또는 RDP 로 접속해, 해당 파일 하나만 올려서 실행하면 된다.

```bash
# 리눅스 계열(서버/웹서버/DB) — 붙여넣기로 올려도 됨
sudo bash kisa_unix_check.sh                 # 리눅스 서버
sudo bash web_linux_check.sh                 # 웹서버(Nginx/Tomcat 자동감지)
bash db_oracle_check.sh --conn "sys/pw@//localhost:1521/XEPDB1 as sysdba"   # Oracle
```
```powershell
# 윈도우 계열(서버/웹서버)
powershell -ExecutionPolicy Bypass -File kisa_win_check.ps1        # 윈도우 서버
powershell -ExecutionPolicy Bypass -File web_windows_check.ps1     # 웹서버(IIS/Tomcat 자동감지)
powershell -ExecutionPolicy Bypass -File web_windows_check.ps1 -Target tomcat -AppJar C:\app.jar -AppUrl http://localhost:8080
```
> `web_windows_check.ps1` 은 IIS 와 **Windows 의 Spring Boot 내장 Tomcat(nssm)** 을 자동 감지한다.
> 웹서버 대상: web1(IIS)·was1(Windows Tomcat)=`.ps1`, web-adm1(Nginx)·was-adm1(Linux Tomcat)=`web_linux_check.sh`.
결과는 현재 폴더에 `*.csv` 와 `*.html`(브라우저로 바로 열리는 리포트)로 남는다. 사설망이면 그 파일만 내려받으면 된다.

### 정형 보고서(양식 xlsx)로 만들기

CSV/HTML 외에 **표지/진단대상/요약그래프(레이더)/요약결과/상세** 5시트 보고서가 필요하면, 대상에서 `--json` 으로
결과를 뽑아 워크스테이션(파이썬 + `pip install lxml`)에서 `make_report.py` 로 변환한다.
모든 종류가 같은 폴더의 **공식 양식 파일**(`보고서_양식_Linux/Windows/DBMS/Webserver/AWS/Azure/GCP/Naver.xlsx`)에
값만 채우는 방식이라 표지 로고·차트·서식이 공식 결과보고서와 같다.

```bash
# 1) 각 대상에서 JSON 출력 (서버마다 1개)
sudo bash kisa_unix_check.sh --json bastion.json      # 각 리눅스 서버에서
python cloudscan_all.py aws --json aws.json
bash db_oracle_check.sh --conn "sys/pw@//localhost:1521/XEPDB1 as sysdba" --json db.json

# 2) JSON → 보고서 xlsx
#   리눅스/윈도우는 여러 서버 JSON 을 나열하면 공식 양식처럼 "한 파일에 서버별 열"로 합쳐진다.
python make_report.py linux \
  --result bastion.json web-adm1.json was-adm1.json db.json \
  --ip   3.38.228.213 15.165.55.44 10.0.10.61 10.0.20.139 \
  --role "서버 관리용 호스트" "관리자용 웹 서버" "관리자용 WAS 서버" "DB"
python make_report.py windows --result web1.json was1.json --ip 13.124.134.131 10.0.10.226
python make_report.py web  --result web1.json web-adm1.json was1.json was-adm1.json   # IIS/Nginx/Tomcat 자동 구분
python make_report.py nginx --result web-adm1.json                                     # 소프트웨어 직접 지정
python make_report.py dbms --result db.json  --host db
python make_report.py aws  --result aws.json                     # 클라우드(cloud_scan --json 결과)

# 표지 문서정보(선택)
python make_report.py linux --result a.json --project 제로데이클리닉 --docno XXXXX-VA-2026001 --date 2026-09-29
```
> 리눅스는 서버 4대, 윈도우는 2대, Tomcat 은 2대까지 한 보고서에 열로 합쳐진다(공식 다중서버 양식).
> 더 많으면 `report_..._1.xlsx`, `_2.xlsx` 로 나눠 저장한다. 대상이 칸보다 적으면 빈 칸은 숨겨지고 평균에서 빠진다.
> 진단하지 않은 웹 소프트웨어(예: Nginx 만 진단)의 2-x/3-x 시트는 숨겨진다.
> 2-2 요약·영역별 점수·3D 막대/원형/레이더 차트는 3-1 상세를 채우면 **수식으로 자동 계산**된다(엑셀에서 열 때).
> 윈도우 스크립트가 만든 JSON(BOM 포함)도 그대로 읽는다.

---

## 클라우드 진단 — `cloud_scan.py`

읽기 전용(`describe_* / list_* / get_*`, AWS 는 자격 증명 보고서 생성 `iam:GenerateCredentialReport` 포함)으로 리소스를 변경하지 않는다.

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
  `lxml` 이 있으면 **공식 양식 보고서 xlsx**(`보고서_양식_<CSP>.xlsx`: 표지/진단대상/요약그래프/요약결과/상세)도
  함께 생성한다 — 진단대상 칸에는 계정 ID·리전·구분이 들어간다(NCP 는 `--account <계정ID>` 로 지정).
  lxml 이 없으면 간이 보고서(openpyxl)로 저장된다.
  (`-o` 저장 경로, `--no-excel` xlsx 생략, `--all-regions` 전 리전)

### 단일 파일로 실행 (`cloudscan_all.py`) — 파일 하나만 올리면 끝

`cloud_check/` 패키지를 통째로 내장한 **단일 파일**. 폴더·zip 없이 이거 하나만 올려서 실행하면
스스로 풀어서 돌아간다(공식 양식·보고서 생성 코드도 내장 → lxml 있으면 공식 양식 xlsx, 없으면 CSV/간이 xlsx).

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
- CSV 저장은 설치 불필요(표준 라이브러리). 공식 양식 xlsx 는 `lxml`, 간이 xlsx 는 `openpyxl` 필요.
- AWS CloudShell 등에는 boto3/SDK 가 대개 미리 깔려 있어 그대로 실행된다.

### 필요 권한 (읽기 전용)

| CSP | 권한 | 자격증명 |
|---|---|---|
| AWS | 관리형 정책 **`SecurityAudit`** + 4.13용 인라인 정책(아래), 또는 **`ReadOnlyAccess`** | Access Key / 역할 / `~/.aws` 프로필 |
| Azure | 구독 **`Reader`** + (선택) Graph **`Directory.Read.All`** | Tenant/Client/Secret + Subscription ID |
| GCP | **`roles/iam.securityReviewer`** + **`roles/viewer`** | 서비스계정 JSON 키 + Project ID |
| Naver | 서브계정 API 인증키 + Server/VPC 조회 권한 | Access Key / Secret Key |

AWS `SecurityAudit` 에는 AWS Backup·DLM 조회 권한이 없어, 그대로 쓰면 4.13 이 "인터뷰 필요"로 나온다.
아래 인라인 정책을 함께 붙이면 자동 판정된다.

```json
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Resource": "*", "Action": [
  "backup:ListBackupPlans", "backup:GetBackupPlan", "backup:ListBackupSelections",
  "backup:ListProtectedResources", "dlm:GetLifecyclePolicies"]}]}
```

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

#### 보고서 양식(다중시트 xlsx) 만들기 — `make_report.py`

CSV 외에 **표지/진단대상/요약그래프/요약결과/상세** 5시트 보고서(양식 그대로, 차트 포함)를 만든다.
점검을 `--json` 으로 뽑아서 양식에 채운다(양식 `보고서_양식_Linux.xlsx` / `_Windows.xlsx` 필요, `pip install lxml`).

```bash
# 1) 대상 서버에서 JSON 출력
sudo bash kisa_unix_check.sh --json result.json
powershell -File kisa_win_check.ps1 -Json result.json

# 2) JSON → 보고서 양식 엑셀 (양식이 있는 곳에서)
python make_report.py linux   --result result.json --ip 3.38.228.213
python make_report.py windows --result result.json --ip 10.0.0.5
```
- 표지 작성일은 자동, 진단대상(호스트/IP/OS)·상세(판정·근거)·요약·그래프가 채워진다(행 높이는 근거 길이에 맞춤).
- 판정 색: 취약=굵은 빨강, N/A=회색 기울임, 인터뷰 필요=주황 채움(조건부서식).

---

## 판정값

| 점검 | 보고서 기재 | 의미 | 점수 |
|---|---|---|---|
| 양호 | 양호 | 기준 충족 | 분자·분모 |
| 취약 | 취약 | 기준 미충족 | 분모 |
| N/A | N/A | 점검 대상 리소스/서비스 없음 | 제외 |
| 수동확인 | 인터뷰 필요 | 정책·업무 컨텍스트 필요(담당자 확인) | 제외 |

보안 적용율 = 양호 / (양호 + 취약) — 리눅스·윈도우·DBMS·웹서버·클라우드 모든 보고서 공통.

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
web_linux_check.sh   웹서버(Nginx/리눅스 Tomcat) 점검 (WEB-01~26, 자동감지, CSV/JSON/HTML)
web_windows_check.ps1 웹서버(IIS/윈도우 Tomcat) 점검 (WEB-01~26, 자동감지, UTF-8 BOM 필수)
db_oracle_check.sh   DBMS(Oracle) 점검 (D-01~26, sqlplus, CSV/JSON/HTML)
make_report.py       진단 JSON → 공식 양식 보고서 xlsx (linux/windows/dbms/web/aws/azure/gcp/naver)
server_report.py     보고서 양식 채우기 코어(모든 종류 공통, lxml)
infra_report.py      간이 보고서 생성(lxml 없을 때 클라우드 폴백)
보고서_양식_*.xlsx    공식 결과보고서 양식 (Linux/Windows/DBMS/Webserver/AWS/Azure/GCP/Naver)
build_server_templates.py  공식 결과보고서(결과보고서/주통기) → Linux/Windows/DBMS/Webserver 양식 생성(결함 수리 포함)
build_cloud_templates.py   DBMS 양식 → AWS/Azure/GCP/NCP 양식 생성(항목·영역 수에 맞춰 표 재구성)
tpl_xml.py           양식 xlsx 를 XML 수준에서 고치는 도구(openpyxl 저장 안 함 → 로고·도형·3D 차트 보존)
requirements.txt     클라우드 CLI 의존성 (CSP별 SDK + openpyxl)
```

## 개발 메모

- `cloud_scan.py` / `cloud_check/` 는 tkinter·SSH 에 의존하지 않는 **독립 실행** 코드다.
- AWS 는 `_regions()` 가 기본적으로 세션 리전만 반환(빠름). 전 리전은 `CLOUD_SCAN_ALL_REGIONS=1`.
- 네이버(NCP)는 Open API 를 HMAC-SHA256 서명으로 호출(표준 라이브러리 urllib). 정책/인터뷰성 항목은 수동확인.
- 결과 저장은 CSV(표준 라이브러리, utf-8-sig)를 기본으로 하고, 양식+lxml 이 있으면 공식 양식 xlsx 를 추가한다.
- 양식 재생성 순서: `python build_server_templates.py` → `python build_cloud_templates.py`(DBMS 양식을 원본으로 씀)
  → `python build_onefile.py`(cloudscan_all.py 에 새 양식 내장). 양식은 openpyxl 로 열어 저장하지 말 것
  (표지 로고·그래프 제목 도형·3D 원형 설정이 사라진다).
