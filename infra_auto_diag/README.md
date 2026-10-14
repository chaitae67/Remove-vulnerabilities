# infra_auto_diag — 취약점 빼기 팀 인프라 진단 자동화

서버(리눅스·윈도우)·웹서버·DBMS·클라우드의 기술적 취약점을 **명령 몇 줄로 한 번에 점검**하고, 그 결과로 공식 양식 결과보고서(xlsx)를 만드는 도구.

- **판정 기준:** 서버·웹서버·DBMS는 KISA 「주요정보통신기반시설 기술적 취약점 분석·평가 방법 상세가이드」(2026)의 판단 기준과 점검 방법만 쓴다. 클라우드는 SK Shieldus 클라우드 보안가이드(2024, AWS·Azure·GCP)와 네이버 클라우드 양식 v1.2를 따른다.
- **점검은 읽기 전용이다.** 설정을 바꾸거나 자동 조치하지 않는다.
- **진단 대상(vuln-lab, AWS ap-southeast-2)**
  - 리눅스: bastion, web-adm1, was-adm1, db-active
  - 윈도우: web1, was1
  - 웹서버: web-adm1(Nginx), web1·was1(IIS), was-adm1(Spring Boot 내장 Tomcat)
  - DBMS: db-active의 Docker 컨테이너 `oracle-xe`(Oracle XE 21c)

## 1. 전체 흐름

```
분석 PC ── ① aws ssm send-command ──► 태그(AutoDiag=linux/windows/db)가 붙은 서버 전부
                                        S3 tools/ 에서 스캐너를 받아 점검(root/SYSTEM) → S3 results/ 에 CSV 업로드
분석 PC ◄── ③ aws s3 sync ─────────── S3 results/ 의 CSV
          python makereport_all.py   → reports_out/ 에 결과보고서 4종(리눅스·윈도우·Webserver·DBMS) + 요약 표
분석 PC ── ④ python cloudscan_all.py aws → reports_out/ 에 클라우드 결과보고서
```

S3: `s3://vuln-lab-backup-293936503010/infra-auto-diag/` — `tools/`(서버가 받아 가는 스캐너), `results/`(서버가 올린 CSV, 누적)

## 2. 실행 (`infra_auto_diag` 폴더, PowerShell)

준비물: `aws` CLI(진단 계정 자격증명), Python 3 + `pip install -r requirements.txt`(보고서는 `lxml`, AWS 점검은 `boto3`). SSM 문서 등록·태그·IAM 같은 1회 준비는 [`ssm/README.md`](ssm/README.md)에 있다.

```powershell
# 1) 자동 진단 — 태그가 붙은 서버 전부에서 동시에 점검
aws ssm send-command --region ap-southeast-2 --document-name AutoDiag-Linux   --targets Key=tag:AutoDiag,Values=linux
aws ssm send-command --region ap-southeast-2 --document-name AutoDiag-Windows --targets Key=tag:AutoDiag,Values=windows
aws ssm send-command --region ap-southeast-2 --document-name AutoDiag-DBMS    --targets Key=tag:AutoDiag,Values=db
```

```powershell
# 2) 완료 확인 (Status 가 Success 가 될 때까지)
aws ssm list-commands --region ap-southeast-2 --query "Commands[0:3].{Doc:DocumentName,Status:Status,Targets:TargetCount,Done:CompletedCount}" --output table
```

```powershell
# 3) 엑셀 보고서 (끝에 진단 결과 요약 표 자동 출력)
Remove-Item .\csv_files\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item .\reports_out\* -Recurse -Force -ErrorAction SilentlyContinue
aws s3 sync s3://vuln-lab-backup-293936503010/infra-auto-diag/results/ csv_files --exclude "*" --include "*.csv" --only-show-errors
python makereport_all.py csv_files
explorer reports_out
```

```powershell
# 4) 클라우드
python cloudscan_all.py aws --region ap-southeast-2
explorer reports_out
```

- **3) 대신 한 번에:** `powershell -ExecutionPolicy Bypass -File merge_local.ps1` — S3 CSV 받기 + EC2 Name 태그로 `hostmap.json` 갱신 + 보고서 생성을 한 번에 한다. 서버를 새로 만들어 IP가 바뀌었으면 이쪽을 쓴다.
- **보고서의 서버 이름:** `makereport_all.py`는 현재 폴더의 `hostmap.json`(IP → EC2 Name)을 자동으로 읽어 진단대상을 `ip-10-0-0-144` 대신 `web-adm1`처럼 적는다.
- `list-commands`가 자주 제한(Throttling)되면 명령 ID별로 `aws ssm list-command-invocations --command-id <ID> --details`로 본다.

**나오는 파일**(`reports_out/`, 공식 양식 그대로):

```
(자동화진단)리눅스_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx       리눅스 최대 4대
(자동화진단)윈도우_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx       윈도우 최대 2대
(자동화진단)Webserver_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx     Nginx·IIS·Tomcat
(자동화진단)DBMS_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx         DB마다 1개
(자동화진단)클라우드_서버_취약점진단_결과보고서_AWS_<계정>_<YYMMDDHHMM>.xlsx
```

- 같은 호스트(클라우드는 계정)를 다시 스캔하면 최신 스캔만 반영한다. 내용이 같으면 새로 만들지 않는다(최신본 기록: `reports_out/.report_version.json`).
- 요약 시트(2-x)의 점수와 차트는 상세 시트(3-x)를 참조하는 수식이다. 엑셀에서 열 때 계산된다.
- 웹서버 양식은 소프트웨어별 칸 수가 정해져 있어(IIS 1대, Tomcat 2대 등) 넘는 대상은 보고서에서 빠지고 콘솔에 경고가 나온다. 빠진 대상도 요약 표에는 들어간다.

## 3. 폴더 구성

```
infra_auto_diag/
├─ kisa_all_check.ps1     서버·웹서버 점검 — 리눅스(bash)·윈도우(PowerShell) 겸용 단일 파일, src/ 스캐너 4개 내장
├─ db_oracle_check.sh     DBMS(Oracle) 점검 — 도커 컨테이너 자동 감지
├─ makereport_all.py      CSV → 결과보고서 xlsx — 보고서 엔진 + 공식 양식 8종 내장 단일 파일
├─ cloudscan_all.py       클라우드 점검(AWS·Azure·GCP·Naver) → 결과보고서 xlsx — 단일 파일
├─ merge_local.ps1        3단계 일괄 실행(S3 CSV 받기 + hostmap 갱신 + 보고서)
├─ hostmap.json           IP → EC2 Name (보고서 진단대상 이름)
├─ requirements.txt       파이썬 패키지
├─ ssm/                   SSM Run Command 문서 3개(Linux·Windows·DBMS) + 1회 준비 안내
├─ s3_manual/             SSM 없이 서버에서 직접 점검 + S3 업로드(s3report.sh / .ps1)
└─ src/                   소스 코드 — 위 단일 파일들은 여기서 빌드한다
   ├─ kisa_unix_check.sh      리눅스 서버 U-01~U-67 (RHEL·Debian 계열 자동 분기)
   ├─ kisa_win_check.ps1      윈도우 서버 W-01~W-64
   ├─ web_linux_check.sh      웹서버 Nginx·리눅스 Tomcat WEB-01~WEB-26
   ├─ web_windows_check.ps1   웹서버 IIS·윈도우 Tomcat WEB-01~WEB-26
   ├─ cloud_scan.py, cloud_check/   클라우드 점검 CLI와 CSP별 점검 코드(aws·azure·gcp·ncp + *_items 항목 정의)
   ├─ make_reports.py         폴더 안 CSV/JSON → 종류별 보고서 일괄 생성 + 요약 표
   ├─ make_report.py          종류 하나 변환 CLI
   ├─ server_report.py        양식 채우기 엔진(lxml)
   ├─ tpl_xml.py              xlsx XML 직접 편집(로고·도형·3D 차트 보존)
   ├─ infra_report.py         간이 보고서(lxml 없을 때 클라우드 폴백)
   ├─ 보고서_양식_*.xlsx       공식 결과보고서 양식 8종
   ├─ build_allinone.py       스캐너 4개 → ../kisa_all_check.ps1
   ├─ build_report_onefile.py 보고서 코드 + 양식 → ../makereport_all.py
   ├─ build_onefile.py        클라우드 코드 + 양식 → ../cloudscan_all.py
   └─ build_server_templates.py · build_cloud_templates.py · make_blank_template.py · patch_interview_bg.py   양식 생성·수리
```

- **소스를 고치면 단일 파일을 다시 만든다:** `python src/build_allinone.py` / `python src/build_report_onefile.py` / `python src/build_onefile.py`. 스캐너를 고쳤으면 S3 `tools/`에도 다시 올린다([`ssm/README.md`](ssm/README.md)).
- 서버·웹서버·DB 점검은 셸/PowerShell만 쓴다(서버에 파이썬 불필요). 파이썬은 클라우드 점검과 보고서 생성에만 쓴다.

## 4. 진단 항목

| 분류 | 실행 파일 (소스) | 항목 |
|---|---|---|
| 리눅스 서버 | `kisa_all_check.ps1` (`src/kisa_unix_check.sh`) | U-01~U-67 |
| 윈도우 서버 | `kisa_all_check.ps1` (`src/kisa_win_check.ps1`) | W-01~W-64 |
| 웹서버 | `kisa_all_check.ps1` (`src/web_linux_check.sh`, `src/web_windows_check.ps1`) | WEB-01~WEB-26 |
| DBMS | `db_oracle_check.sh` | D-01~D-26 (Oracle) |
| 클라우드 | `cloudscan_all.py` (`src/cloud_scan.py`, `src/cloud_check/`) | AWS 41 · Azure 41 · GCP 52 · Naver 31 |

## 5. 판정 기준

- **가이드 기준만 쓴다.** 판정 조건은 상세가이드의 판단 기준·점검 방법과 점검 및 조치 사례에서만 가져온다. 가이드에 없는 조건이나 권장은 판정과 근거 문구에 넣지 않는다.
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

## 6. 개별 실행 (SSM 없이)

스크립트 파일 하나만 서버에 올려 실행해도 된다. 결과는 현재 폴더에 CSV로 남는다(웹·DB는 HTML도).

```bash
sudo bash kisa_all_check.ps1                                    # 리눅스: 서버 + 감지된 웹서버
sudo bash kisa_all_check.ps1 --only web --target tomcat --app-url http://localhost:8080
sudo bash db_oracle_check.sh                                    # Oracle(도커 컨테이너 자동 감지)
```

```powershell
powershell -ExecutionPolicy Bypass -File kisa_all_check.ps1     # 윈도우(관리자): 서버 + 감지된 웹서버
```

- **통합본 옵션:** `--only all|infra|web`, `-o/--out-dir`, `--no-save`, `--no-color`, `--force-web`, 웹 옵션(`--target`, `--app-url`, `--app-jar` 등). 윈도우는 `-Only`, `-OutDir`, `-NoSave`.
- **DB 옵션:** `--container <이름>`, `--pdb <이름>`, `--conn "<접속문자열>"`, 기관 정책 값 `--pw-life-max`, `--login-fail-max`(10), `--reuse-max-min`(10), `--reuse-time-min`(365).
- **종료코드:** 0 = 취약 없음, 1 = 취약 있음, 2 = 실행 오류.
- 서버에서 점검 후 S3 업로드까지 하려면 [`s3_manual/`](s3_manual/README.md)의 `s3report.sh` / `s3report.ps1`을 쓴다.
- 보고서 옵션: `python makereport_all.py <폴더> -o <출력폴더> --hostmap <파일> --project <사업명> --date YYYY-MM-DD`, 파일명이 규칙과 다르면 `--kind linux|windows|web|dbms`.

## 7. 클라우드 점검 상세 — `cloudscan_all.py`

읽기 전용 API(`describe_*`, `list_*`, `get_*`. AWS는 자격 증명 보고서 생성 포함)만 호출한다.

```bash
python cloudscan_all.py aws --region ap-southeast-2          # 기본 자격증명(CloudShell 등)
python cloudscan_all.py aws --profile <프로필> --all-regions
python cloudscan_all.py azure --subscription-id <구독ID>
python cloudscan_all.py gcp
python cloudscan_all.py naver                                 # env NCP_ACCESS_KEY / NCP_SECRET_KEY
```

- lxml이 없거나 `--no-excel`이면 xlsx 대신 CSV(`cloud_<CSP>_<시각>.csv`)로 저장한다.
- 자격증명이 유효하지 않으면 즉시 중단하고, 권한이 모자란 항목은 인터뷰 필요로 나온다.

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

## 8. 개발 메모

- **인코딩·줄바꿈:** `*.sh`와 `kisa_all_check.ps1`은 LF(`.gitattributes`) — 통합본은 bash로도 실행하기 때문이다. `src/kisa_win_check.ps1`·`src/web_windows_check.ps1`은 UTF-8 BOM + CRLF(Windows PowerShell 5.1 한글). `merge_local.ps1`, `s3_manual/s3report.ps1`, `ssm/*.json`은 ASCII만 쓴다.
- **bash 4.2 호환:** db-active(Amazon Linux 2)의 bash 4.2에서도 돌아야 한다. 수정 후 `bash -n`으로 확인한다.
- **양식 xlsx는 openpyxl로 열어 저장하지 않는다.** 표지 로고, 그래프 제목 도형, 3D 원형 설정이 사라진다.
- `csv_files/`, `reports_out/`은 실제 스캔 결과(호스트·IP 포함)가 들어가는 로컬 작업 폴더라 저장소에 올리지 않는다.
