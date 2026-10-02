# infra_auto_diag — 취약점 빼기 팀 인프라 진단 자동화

서버(리눅스·윈도우)·웹서버·DBMS·클라우드의 기술적 취약점을 점검하는 스크립트와, 그 결과로 공식 양식 결과보고서(xlsx)를 만드는 도구 모음.

- **판정 기준:** 서버·웹서버·DBMS는 KISA 「주요정보통신기반시설 기술적 취약점 분석·평가 방법 상세가이드」(2026)의 판단 기준과 점검 방법만 쓴다. 클라우드는 SK Shieldus 클라우드 보안가이드(2024, AWS·Azure·GCP)와 네이버 클라우드 양식 v1.2를 따른다.
- **점검은 읽기 전용이다.** 설정을 바꾸거나 자동 조치하지 않는다.
- **이 환경의 대상**
  - 리눅스: bastion, web-adm1, was-adm1, db-active
  - 윈도우: web1, was1
  - 웹서버: web-adm1(Nginx), web1(IIS), was-adm1·was1(Spring Boot 내장 Tomcat, was1은 nssm 서비스)
  - DBMS: db-active의 Docker 컨테이너 `oracle-xe`(Oracle XE 21c)

## 1. 표준 절차 — SSM으로 점검 → S3 수집 → 분석 PC에서 보고서

```
분석 PC ── aws ssm send-command ──► 각 서버(Linux root / Windows SYSTEM)
                                     S3 tools/ 에서 스캐너를 받아 점검 → S3 results/ 에 CSV 업로드
분석 PC ◄── merge_local.ps1 ──────── S3 results/ 의 CSV 전부
          → reports_out/ 에 결과보고서 4종(xlsx)  (-Upload 를 붙이면 S3 reports/ 에도 올림)
```

S3 구조(`s3://vuln-lab-backup/infra-auto-diag/`):

| 경로 | 내용 |
|---|---|
| `tools/` | 서버가 받아 가는 스캐너: `kisa_all_check.ps1`, `db_oracle_check.sh` |
| `results/` | 각 서버가 올린 원본 CSV(누적) |
| `reports/` | 병합 결과보고서 xlsx와 `.report_version.json` |

### 1-1. 스캐너를 고쳤다면: 재생성 → S3 `tools/` 갱신

```powershell
cd infra_auto_diag
python build_allinone.py                      # 원본 스캐너 4개 → kisa_all_check.ps1 재생성
aws s3 cp kisa_all_check.ps1 s3://vuln-lab-backup/infra-auto-diag/tools/
aws s3 cp db_oracle_check.sh s3://vuln-lab-backup/infra-auto-diag/tools/
```

- 버킷 버전 관리가 꺼져 있다. 덮어쓰기 전에 기존 파일을 받아 두면 되돌릴 수 있다.
- 서버는 실행할 때마다 `tools/`에서 새로 받으므로, 올린 뒤에 점검을 다시 돌리면 새 판이 적용된다.

### 1-2. 점검 실행 (명령 3개)

```powershell
aws ssm send-command --document-name AutoDiag-Linux   --targets Key=tag:AutoDiag,Values=linux   --comment "KISA linux scan"
aws ssm send-command --document-name AutoDiag-Windows --targets Key=tag:AutoDiag,Values=windows --comment "KISA windows scan"
aws ssm send-command --document-name AutoDiag-DBMS    --targets Key=tag:AutoDiag,Values=db      --comment "KISA db scan"
```

| SSM 문서 | 대상 태그 | 하는 일 | 올라가는 CSV |
|---|---|---|---|
| `AutoDiag-Linux` | `AutoDiag=linux` | 인프라 + 감지된 웹서버 점검 | `server_linux_*`, `web_linux_*` |
| `AutoDiag-Windows` | `AutoDiag=windows` | 인프라 + 감지된 웹서버 점검 | `server_windows_*`, `web_windows_*` |
| `AutoDiag-DBMS` | `AutoDiag=db` | 인프라(`--only infra`) + Oracle 점검. Oracle은 컨테이너 안에서 `docker exec`와 OS 인증(`/ as sysdba`)으로 점검하므로 비밀번호가 필요 없다 | `server_linux_*`, `db_oracle_*` |

진행 확인(`list-commands`는 자주 제한(Throttling)되므로 명령 ID별로 본다):

```powershell
aws ssm list-command-invocations --command-id <CommandId> --details --query "CommandInvocations[].{Instance:InstanceId,Status:Status}" --output table
```

- 문서 등록·태그·IAM 역할 같은 1회 준비는 [`ssm/README.md`](ssm/README.md)에 있다.
- 문서 파라미터: `S3Base`(기본 `s3://vuln-lab-backup/infra-auto-diag`). DBMS 문서에는 `Container`(기본 `oracle-xe`)도 있다.

### 1-3. 보고서 병합 (분석 PC)

```powershell
cd infra_auto_diag
powershell -ExecutionPolicy Bypass -File merge_local.ps1            # S3 results/ → reports_out/
powershell -ExecutionPolicy Bypass -File merge_local.ps1 -Upload    # S3 reports/ 에도 올림
```

**하는 일**

1. S3 `results/`의 CSV를 `csv_files/`로 받는다.
   - 받기에 실패하면 그 자리에서 멈춘다. `csv_files/`에 남은 옛 CSV로 보고서를 만들지 않는다.
2. EC2 Name 태그로 `hostmap.json`(IP→이름)을 만든다.
   - 보고서 진단대상에 OS 호스트명(`ip-10-0-0-5`) 대신 EC2 Name(`web-adm1`)이 들어간다.
   - 조회에 실패하면 기존 `hostmap.json`을 그대로 쓴다.
3. `make_reports.py`로 보고서를 만든다. 이 파일이 없는 폴더에서는 단일 파일판 `makereport_all.py`를 쓴다.
4. 끝에 대상별 양호·취약·인터뷰 개수와 양호율 표를 출력한다.

**옵션**

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `-S3Base` | `s3://<버킷>/infra-auto-diag` | S3 경로 전체 지정 |
| `-Bucket` | `vuln-lab-backup` | 버킷 이름만 지정. 기본 버킷에 접근할 수 없으면 `vuln-lab-backup-<계정ID>`를 찾는다 |
| `-AwsProfile` | (CLI 기본 프로필) | 모든 aws 호출에 쓸 프로필(다른 계정으로 전환할 때) |
| `-Region` | (프로필의 리전) | EC2 Name 조회 리전 |
| `-Csv` / `-Out` | `csv_files` / `reports_out` | 로컬 입력·출력 폴더 |
| `-Upload` | 꺼짐 | 보고서와 `.report_version.json`을 S3 `reports/`에 올림 |

**필요한 것:** `aws` CLI(PATH에 있어야 함), python3 + `lxml`. 권한은 S3 읽기, EC2 `DescribeInstances`, `-Upload` 시 S3 쓰기다.

**나오는 파일**(`reports_out/`, 공식 양식 그대로):

```
(자동화진단)리눅스_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx     리눅스 최대 4대
(자동화진단)윈도우_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx     윈도우 최대 2대
(자동화진단)Webserver_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx   Nginx·IIS·Tomcat(Tomcat 최대 2대)
(자동화진단)DBMS_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx       DB마다 1개
(자동화진단)클라우드_서버_취약점진단_결과보고서_<CSP>_<계정>_<YYMMDDHHMM>.xlsx
```

- 같은 호스트(클라우드는 계정)를 다시 스캔하면 최신 스캔만 반영한다.
- 내용이 바뀌면 그 시각의 새 파일이 생기고 옛 파일은 남는다. 내용이 같으면 새로 만들지 않는다.
  - 최신본 기록은 `reports_out/.report_version.json`에 있다.
- 요약 시트(2-x)의 점수와 차트는 상세 시트(3-x)를 참조하는 수식이다. 엑셀에서 열 때 계산된다.

## 2. 진단 분류

| 분류 | 스크립트 | 항목 |
|---|---|---|
| 리눅스 서버 | `kisa_unix_check.sh` | U-01~U-67 (RHEL·Debian 계열 자동 분기) |
| 윈도우 서버 | `kisa_win_check.ps1` | W-01~W-64 |
| 웹서버 | `web_linux_check.sh`(Nginx·Tomcat) / `web_windows_check.ps1`(IIS·Tomcat) | WEB-01~WEB-26 |
| DBMS | `db_oracle_check.sh` | D-01~D-26 (Oracle) |
| 통합 | `kisa_all_check.ps1` — 위 서버·웹서버 스캐너 4개를 내장한 단일 파일, bash·PowerShell 겸용 | U·W·WEB |
| 클라우드 | `cloudscan_all.py`(단일 파일) / `cloud_scan.py` | AWS 41 · Azure 41 · GCP 52 · Naver 31 |

- 웹서버 스크립트는 OS별로 둘로 나뉘지만 항목 코드(WEB-01~26)는 같다.
- 서버·웹서버·DB 스크립트는 셸/PowerShell만 쓴다(파이썬 불필요). 파이썬은 클라우드 점검과 보고서 생성에만 쓴다.

## 3. 판정 기준

- **가이드 기준만 쓴다.** 판정 조건은 상세가이드의 판단 기준·점검 방법과 점검 및 조치 사례에서만 가져온다. 가이드에 없는 조건이나 권장(예: 클라우드 SG 별도 점검, 프로토콜 대체 권고)은 판정과 근거 문구에 넣지 않는다.
- **숫자 기준이 가이드에 없으면 기관 정책 값을 옵션으로 받는다.** 예: Oracle D-03 비밀번호 사용기간은 `--pw-life-max <일>`을 줄 때만 비교하고, 없으면 인터뷰 필요다.
- **정책 수립·담당자 판단이 필요한 항목은 근거를 남기고 인터뷰 필요로 둔다.** 예: 패치 정책(WEB-25), 감사 정책(D-26), 불필요 그룹·숨김 파일 검토(U-09, U-33).
- **가이드 단서는 그대로 반영한다.** 예: W-18은 목록 하단 단서(p.203)에 따라, Microsoft 지침상 끄면 안 되는 Cryptographic Services를 판정에서 빼고 그 근거를 결과에 적는다.

| 점검 결과 | 보고서 기재 | 의미 | 점수 |
|---|---|---|---|
| 양호 | 양호 | 기준 충족 | 분자·분모 |
| 취약 | 취약 | 기준 미충족 | 분모 |
| N/A | N/A | 점검 대상 리소스·서비스 없음 | 제외 |
| 수동확인 | 인터뷰 필요 | 정책·업무 맥락 확인 필요 | 제외 |
| (결과 없음) | 인터뷰 필요 | 스캔 결과에 그 항목이 없음 → 재점검 필요(콘솔에 경고) | 제외 |

보안 적용율 = 양호 / (양호 + 취약). 모든 보고서에 공통이다.

## 4. SSM 없이 서버에서 직접 실행

스크립트 파일 하나만 올려 실행한다(EC2 Instance Connect, RDP 등). 결과는 현재 폴더에 CSV로 남는다(웹·DB는 HTML도).

```bash
# 리눅스 — 통합본(서버 + 감지된 웹서버)
sudo bash kisa_all_check.ps1
sudo bash kisa_all_check.ps1 --only infra -o /tmp/kisa_result
sudo bash kisa_all_check.ps1 --only web --target tomcat --app-url http://localhost:8080

# Oracle — 호스트에 sqlplus가 없고 Oracle이 도커 컨테이너면 자동으로 컨테이너 안에서 점검
sudo bash db_oracle_check.sh
bash db_oracle_check.sh --conn "sys/<비밀번호>@//localhost:1521/XEPDB1 as sysdba"
```

```powershell
# 윈도우(관리자 PowerShell) — 통합본
powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1
powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1 -Only infra -OutDir C:\kisa_result
```

- **통합본 옵션**
  - `--only all|infra|web`
  - `-o/--out-dir`
  - `--no-save`, `--no-color`, `--force-web`
  - 웹 옵션(`--target`, `--app-url`, `--app-jar` 등)은 웹 스캐너로 그대로 넘긴다.
  - 윈도우는 `-Only`, `-OutDir`, `-NoSave`로 쓴다.
- **종료코드:** 0 = 취약 없음, 1 = 취약 있음, 2 = 실행 오류.
- **개별 스캐너:** 따로 돌려도 된다(`kisa_unix_check.sh`, `kisa_win_check.ps1`, `web_linux_check.sh`, `web_windows_check.ps1`). 저장 경로는 `--csv`/`--json`(윈도우 `-Csv`/`-Json`)로 정한다.
- **DB 옵션**
  - `--container <이름>`, `--pdb <이름>`
  - 기관 정책 값: `--pw-life-max`, `--login-fail-max`(10), `--reuse-max-min`(10), `--reuse-time-min`(365)
- **SSM 없이 S3로 올리려면** `s3report.sh` / `s3report.ps1`을 쓴다(`--no-report`면 점검 후 CSV 업로드만). 자세한 내용은 [`S3진단_사용안내.md`](S3진단_사용안내.md)에 있다.

| 결과 파일 | 이름 |
|---|---|
| 리눅스 | `server_linux_<호스트>_<YYYYMMDD_HHMM>.csv` |
| 리눅스 웹 | `web_linux_<nginx\|tomcat>_<호스트>_<YYYYMMDD_HHMM>.csv` / `.html` |
| 윈도우 | `server_windows_<호스트>_<YYYYMMDD_HHMM>.csv` |
| 윈도우 웹 | `web_windows_<iis\|tomcat>_<호스트>_<YYYYMMDD_HHMM>.csv` / `.html` |
| DBMS | `db_oracle_<호스트>_<YYYYMMDD_HHMM>.csv` / `.html` |

## 5. 보고서 직접 만들기 (S3 없이)

CSV/JSON을 한 폴더에 모아 변환한다. 파일명으로 종류를 구분한다.

```bash
python make_reports.py <입력폴더>                          # → ./reports_out/
python make_reports.py <입력폴더> -o <출력폴더> --hostmap hostmap.json
python make_reports.py --kind linux a.csv b.csv           # 파일명이 규칙과 다를 때 종류 지정
python makereport_all.py <입력폴더>                        # 단일 파일판(양식·변환 코드 내장), 옵션 동일
```

- **필요한 것:** 파이썬3 + `lxml`. 양식 xlsx(`보고서_양식_*.xlsx`)에 값만 채우므로 표지 로고·차트·서식이 공식 결과보고서와 같다.
- **호스트맵:** `--hostmap`을 주지 않아도 입력 폴더나 현재 폴더의 `hostmap.json`을 찾아 쓴다.
- **양식 수용량:**
  - 리눅스는 4대, 윈도우는 2대를 넘으면 파일을 나눠 저장한다(`_(2)` 접미사).
  - 웹서버 양식은 소프트웨어별 칸(Tomcat 2대 등)을 넘는 대상이 보고서에서 빠진다(예: IIS 2대째). 빠진 대상도 끝에 출력하는 요약 표에는 들어간다.
  - 대상이 칸보다 적으면 빈 칸은 숨기고 평균에서 뺀다.
- **종류 하나만 직접 만들 때:** `make_report.py`를 쓴다. 예: `python make_report.py linux --result a.json b.json --ip <IP> <IP>`. 표지 정보는 `--project`, `--docno`, `--date`로 넣는다.

## 6. 클라우드 진단 — `cloudscan_all.py` / `cloud_scan.py`

읽기 전용 API(`describe_*`, `list_*`, `get_*`. AWS는 자격 증명 보고서 생성 포함)만 호출한다.

```bash
python cloudscan_all.py aws                          # CloudShell 등 쉘의 기본 자격증명 사용
python cloudscan_all.py aws --profile <프로필> --region ap-northeast-2
python cloudscan_all.py azure --subscription-id <구독ID>
python cloudscan_all.py gcp                          # 프로젝트는 환경변수에서 인식
python cloudscan_all.py naver --access-key .. --secret-key ..   # NCP는 키 필요(env NCP_ACCESS_KEY/NCP_SECRET_KEY 가능)
```

- **결과 저장:** 기본으로 `reports_out/`에 공식 양식 xlsx를 저장한다. lxml이 없는 등 xlsx를 만들 수 없거나 `--no-excel`이면 CSV(`cloud_<CSP>_<시각>.csv`)로 저장한다.
- **AWS 리전:** 기본은 지정(세션) 리전만 본다. 전 리전은 `--all-regions`다.
- **권한·자격증명이 부족할 때**
  - 자격증명이 유효하지 않으면 즉시 중단한다.
  - 권한이 모자란 항목은 인터뷰 필요로 나온다.
- **옵션과 자격증명:** `cloud_scan.py`와 `cloudscan_all.py`가 같다. 설치는 `pip install -r requirements.txt`로 하고, 점검할 CSP 것만 깔아도 된다.

| CSP | 필요 권한(읽기 전용) |
|---|---|
| AWS | `SecurityAudit` + 아래 인라인 정책, 또는 `ReadOnlyAccess` |
| Azure | 구독 `Reader` + (선택) Graph `Directory.Read.All` |
| GCP | `roles/iam.securityReviewer` + `roles/viewer` |
| Naver | 서브계정 API 인증키 + Server/VPC 조회 권한 |

AWS `SecurityAudit`에는 Backup·DLM 조회 권한이 없어 4.13이 인터뷰 필요로 나온다. 아래 정책을 함께 붙이면 자동 판정된다.

```json
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Resource": "*", "Action": [
  "backup:ListBackupPlans", "backup:GetBackupPlan", "backup:ListBackupSelections",
  "backup:ListProtectedResources", "dlm:GetLifecyclePolicies"]}]}
```

## 7. 파일 구성

배포물(dist)과 그걸 만드는 소스(src)의 관계는 [`구조_한눈에.md`](구조_한눈에.md)에 정리돼 있다.

```
[점검 스크립트]
kisa_unix_check.sh       리눅스 서버 (U-01~67)
kisa_win_check.ps1       윈도우 서버 (W-01~64)
web_linux_check.sh       웹서버 Nginx·리눅스 Tomcat (WEB-01~26)
web_windows_check.ps1    웹서버 IIS·윈도우 Tomcat (WEB-01~26)
db_oracle_check.sh       Oracle (D-01~26, 도커 컨테이너 자동 감지)
kisa_all_check.ps1       위 서버·웹 스캐너 4개 통합본 — 자동 생성(build_allinone.py), LF 필수
cloud_scan.py, cloud_check/   클라우드 점검 CLI와 CSP별 코어
cloudscan_all.py         클라우드 단일 파일판 — 자동 생성(build_onefile.py)

[운영 자동화]
ssm/AutoDiag-*.json      SSM 문서(Linux·Windows·DBMS), ssm/README.md 는 1회 준비 안내
merge_local.ps1          분석 PC: S3 results/ → 보고서 병합(-Upload 로 S3 reports/)
s3report.sh / .ps1       SSM 없이 서버에서 점검 + S3 업로드(+보고서)
hostmap.json             IP → EC2 Name (merge_local.ps1 이 갱신)

[보고서]
make_reports.py          폴더 안 CSV/JSON → 종류별 보고서 일괄 생성 + 요약 표
make_report.py           종류 하나 변환 CLI
server_report.py         양식 채우기 엔진(lxml)
tpl_xml.py               xlsx XML 직접 편집 도구(로고·도형·3D 차트 보존)
makereport_all.py        보고서 단일 파일판 — 자동 생성(build_report_onefile.py)
infra_report.py          간이 보고서(lxml 없을 때 클라우드 폴백)
보고서_양식_*.xlsx        공식 결과보고서 양식 8종(Linux/Windows/DBMS/Webserver/AWS/Azure/GCP/Naver)

[양식 생성·수리]
build_server_templates.py   공식 결과보고서 → 서버·웹·DB 양식
build_cloud_templates.py    DBMS 양식 → 클라우드 양식
make_blank_template.py      데이터가 든 공식 보고서 → 빈 양식
patch_interview_bg.py       양식의 '인터뷰 필요' 주황 배경 제거
```

## 8. 개발 메모

- **원본을 고치면 단일 파일판을 다시 만든다.**
  - 스캐너 4개(`kisa_unix_check.sh`, `kisa_win_check.ps1`, `web_linux_check.sh`, `web_windows_check.ps1`) → `python build_allinone.py`
  - 보고서 코드(`make_reports.py` 등)·양식 → `python build_report_onefile.py`
  - 클라우드 코드·양식 → `python build_onefile.py`
- **바뀐 스캐너를 서버에 적용하려면** S3 `tools/`에 다시 올린다(1-1).
- **인코딩·줄바꿈**
  - `*.sh`와 `kisa_all_check.ps1`은 LF다(`.gitattributes`). 통합본은 bash로도 실행하기 때문이다.
  - `kisa_win_check.ps1`과 `web_windows_check.ps1`은 UTF-8 BOM + CRLF다. Windows PowerShell 5.1이 한글을 바로 읽게 하기 위해서다.
  - `merge_local.ps1`, `s3report.ps1`, `ssm/*.json`은 ASCII만 쓴다. PowerShell 5.1과 AWS CLI(cp949)의 인코딩 문제를 피하기 위해서다.
- **bash 4.2 호환:** db-active(Amazon Linux 2)의 bash 4.2에서도 돌아야 한다. 수정 후 `bash -n`으로 확인한다. 큰 디렉터리 순회는 DB 서버에 부하를 주므로 피한다.
- **양식 xlsx는 openpyxl로 열어 저장하지 않는다.** 표지 로고, 그래프 제목 도형, 3D 원형 설정이 사라진다. 양식 재생성 순서는 `build_server_templates.py` → `build_cloud_templates.py` → `build_onefile.py`다.
- **로컬 폴더:** `csv_files/`, `reports_out/`은 로컬 작업 폴더(git 제외)다.
