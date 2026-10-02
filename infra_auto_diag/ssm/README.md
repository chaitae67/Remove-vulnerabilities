# SSM Run Command 로 취약점 진단 (중앙 실행)

각 서버에 로그인하지 않고, **중앙에서 태그로 대상을 골라** 점검을 실행한다.
스캐너(`kisa_all_check.ps1`)는 S3 `tools/` 에서 인스턴스 IAM 역할로 내려받아 실행하고,
결과 CSV 는 S3 `results/` 로 올린다. 보고서 병합은 분석 PC 의 `merge_local.ps1` 로 한다.

전제: 대상 인스턴스가 SSM 관리대상(에이전트 + IAM 역할 `AmazonSSMManagedInstanceCore` + SSM 엔드포인트 통신)이고,
CSV 업로드용으로 인스턴스에 `aws` CLI 가 있어야 한다(문서가 없으면 설치 시도).

## 1) 스캐너를 S3 에 올려둔다 (분석 PC, 갱신 시마다)

```powershell
cd C:\Users\EZ\repo-remove-vuln\infra_auto_diag
aws s3 cp kisa_all_check.ps1 s3://vuln-lab-backup/infra-auto-diag/tools/
```

## 2) 대상 인스턴스에 태그를 붙인다 (1회)

```powershell
# Windows 2대
aws ec2 create-tags --resources i-0640686af1bcd3002 i-096b9c4090b81f0f0 --tags Key=AutoDiag,Value=windows
# Linux 3대 (web-adm, bastion, was-adm)
aws ec2 create-tags --resources i-0aab5eedc40f006e0 i-00243f310ea543f2d i-07a6c1b4525770b10 --tags Key=AutoDiag,Value=linux
# db(Amazon Linux 2)는 linux 가 아니라 db 태그 → 아래 AutoDiag-DBMS 절 참고
```

## 3) SSM 문서 등록 (1회, 이후 수정 시 update-document)

```powershell
cd C:\Users\EZ\repo-remove-vuln\infra_auto_diag
aws ssm create-document --name AutoDiag-Linux   --document-type Command --document-format JSON --content file://ssm/AutoDiag-Linux.json
aws ssm create-document --name AutoDiag-Windows --document-type Command --document-format JSON --content file://ssm/AutoDiag-Windows.json
# 문서를 고쳤을 때:
#   aws ssm update-document --name AutoDiag-Linux --document-version '$LATEST' --document-format JSON --content file://ssm/AutoDiag-Linux.json
```

## 4) 실행 (중앙에서, 태그로 대상 지정)

```powershell
aws ssm send-command --document-name AutoDiag-Linux   --targets Key=tag:AutoDiag,Values=linux   --comment "KISA linux scan"
aws ssm send-command --document-name AutoDiag-Windows --targets Key=tag:AutoDiag,Values=windows --comment "KISA windows scan"
```

진행/결과 확인:
```powershell
# 방금 명령들의 요약
aws ssm list-commands --query "Commands[0:5].{Id:CommandId,Doc:DocumentName,Status:Status,Targets:TargetCount}" --output table
# 특정 명령의 서버별 상태
aws ssm list-command-invocations --command-id <CommandId> --details --query "CommandInvocations[].{Instance:InstanceId,Status:Status}" --output table
```

## 5) 보고서 병합 (분석 PC)

```powershell
cd C:\Users\EZ\repo-remove-vuln\infra_auto_diag
powershell -ExecutionPolicy Bypass -File merge_local.ps1        # S3 results/ → 보고서 (-Upload 로 S3 reports/ 공유)
```

## db(Oracle) — 컨테이너 안에서 자동 점검 (`AutoDiag-DBMS`)

이 환경의 Oracle 은 **도커 컨테이너(`oracle-xe`, Oracle XE 21c)** 안에서 돌고 **호스트엔 sqlplus 가 없다.**
그래서 문서가 호스트에서 **`docker exec` 로 컨테이너 안에 들어가** `db_oracle_check.sh` 를 실행한다.
컨테이너 안 **OS 인증(`/ as sysdba`)** 을 쓰므로 **비밀번호가 필요 없다**(Parameter Store 불필요). 인프라 점검도
함께 한다(`kisa_all_check.ps1 --only infra`, U-26 /dev 순회 수정 후 bash 4.2 에서도 안전). 결과는 리눅스 보고서와 DBMS 보고서로 나뉜다.

준비(1회):
```powershell
# 1) db 가 SSM 관리대상(Online)인지 확인
aws ssm describe-instance-information --query "InstanceInformationList[].[InstanceId,IPAddress,PlatformName]" --output table
# 2) db 인스턴스에 태그
aws ec2 create-tags --resources <db-instance-id> --tags Key=AutoDiag,Value=db
# 3) 문서 등록(이미 있으면 update-document)
aws ssm create-document --name AutoDiag-DBMS --document-type Command --document-format JSON --content file://ssm/AutoDiag-DBMS.json
```

실행(다른 서버와 똑같이 명령 한 번, SSH 불필요):
```powershell
aws ssm send-command --document-name AutoDiag-DBMS --targets Key=tag:AutoDiag,Values=db --comment "KISA db scan"
```

- 컨테이너 이름이 다르면 `--parameters Container=<이름>` 로 지정.
- db IAM 역할 권한: `s3:GetObject/PutObject`(tools/·results/). → `db_oracle_db_*.csv` 가 올라가 DBMS 보고서가 된다.
- Oracle 점검은 시스템 뷰 쿼리라 가벼워 DB 를 위협하지 않는다(파일순회 없음, timeout 300).

## 참고

- **대상에서 빼려면** 그 인스턴스의 `AutoDiag` 태그를 지우면 된다(문서 수정 불필요).
- SSM 은 Linux 는 root, Windows 는 SYSTEM 으로 실행하므로 sudo/관리자 권한이 필요한 점검이 그대로 동작한다.
- 스캐너를 S3 에서 받는 것은 **인스턴스 역할 기반 내부 접근**이며(퍼블릭 인터넷 아님, S3 VPC 엔드포인트로 제한 가능), 사람이 서버에 로그인해 실행하지 않는다.
