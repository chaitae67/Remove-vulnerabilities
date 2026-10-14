# SSM Run Command — 여러 서버를 한 번에 진단

각 서버에 로그인하지 않고, **분석 PC에서 명령 한 줄로 태그가 붙은 서버 전부를 점검**한다.
서버는 S3 `tools/` 에서 스캐너를 인스턴스 IAM 역할로 내려받아 실행하고, 결과 CSV 를 S3 `results/` 에 올린다.

| 문서 | 대상 태그 | 하는 일 | 올라가는 CSV |
|---|---|---|---|
| `AutoDiag-Linux.json` | `AutoDiag=linux` | `kisa_all_check.ps1` (인프라 + 감지된 웹서버) | `server_linux_*`, `web_linux_*` |
| `AutoDiag-Windows.json` | `AutoDiag=windows` | `kisa_all_check.ps1` (인프라 + 감지된 웹서버) | `server_windows_*`, `web_windows_*` |
| `AutoDiag-DBMS.json` | `AutoDiag=db` | `kisa_all_check.ps1 --only infra` + `db_oracle_check.sh` (Oracle 컨테이너 안에서 `docker exec`, OS 인증 `/ as sysdba` — 비밀번호 불필요) | `server_linux_*`, `db_oracle_*` |

- 파라미터: `S3Base`(기본 `s3://vuln-lab-backup-293936503010/infra-auto-diag`). DBMS 문서는 `Container`(기본 `oracle-xe`)도 받는다.
- SSM 은 Linux 는 root, Windows 는 SYSTEM 으로 실행하므로 관리자 권한이 필요한 점검이 그대로 동작한다.
- 스캐너는 인스턴스 역할로 S3 에서 받는다. 사람이 서버에 로그인해 실행하지 않는다.

## 1회 준비

전제: 대상 인스턴스가 SSM 관리 대상(에이전트 + IAM 역할 `AmazonSSMManagedInstanceCore`)이고, 역할에 S3 `tools/` 읽기·`results/` 쓰기 권한이 있으며, 인스턴스에 `aws` CLI 가 있다.

```powershell
cd infra_auto_diag
$S3 = "s3://vuln-lab-backup-293936503010/infra-auto-diag"

# 1) 스캐너를 S3 tools/ 에 올린다 (스캐너를 고칠 때마다 다시)
aws s3 cp kisa_all_check.ps1 "$S3/tools/"
aws s3 cp db_oracle_check.sh "$S3/tools/"

# 2) 대상 인스턴스에 태그 (대상에서 빼려면 태그만 지우면 된다)
aws ec2 create-tags --resources <리눅스 인스턴스 ID들> --tags Key=AutoDiag,Value=linux
aws ec2 create-tags --resources <윈도우 인스턴스 ID들> --tags Key=AutoDiag,Value=windows
aws ec2 create-tags --resources <DB 인스턴스 ID>       --tags Key=AutoDiag,Value=db

# 3) SSM 문서 등록 (이미 있으면 update-document)
aws ssm create-document --name AutoDiag-Linux   --document-type Command --document-format JSON --content file://ssm/AutoDiag-Linux.json
aws ssm create-document --name AutoDiag-Windows --document-type Command --document-format JSON --content file://ssm/AutoDiag-Windows.json
aws ssm create-document --name AutoDiag-DBMS    --document-type Command --document-format JSON --content file://ssm/AutoDiag-DBMS.json
#   수정 시: aws ssm update-document --name AutoDiag-Linux --document-version '$LATEST' --document-format JSON --content file://ssm/AutoDiag-Linux.json
```

SSM 연결 확인:

```powershell
aws ssm describe-instance-information --query "InstanceInformationList[].[InstanceId,PingStatus,IPAddress,PlatformName]" --output table
```

## 실행·확인

실행 명령은 상위 [README](../README.md) 1~2단계를 따른다. 서버별 상태는 명령 ID 로 본다:

```powershell
aws ssm list-command-invocations --command-id <CommandId> --details --query "CommandInvocations[].{Instance:InstanceId,Status:Status}" --output table
```

- 버킷이 다른 계정에서 쓰려면 `--parameters S3Base=s3://<버킷>/infra-auto-diag` 를 붙이거나 문서의 기본값을 바꿔 등록한다.
- 컨테이너 이름이 다르면 DBMS 문서에 `--parameters Container=<이름>`.
- Oracle 점검은 시스템 뷰 쿼리라 가볍다(파일 순회 없음, timeout 300).
