# =============================================================================
# (선택) OS 기준선 SSM 문서 : os/<host>/baseline.(sh|ps1) + files/ 를 Run Command 문서로 감싼다
#   - 기본값 enable_os_baseline = false -> 리소스 0개 (현재 운영 계정 plan 은 계속 zero-diff)
#   - 새 환경 재구축 시 true 로 켜면 호스트별 문서 6개가 생긴다. 연결(association)은 만들지 않는다.
#     실행은 사람이 직접 : aws ssm send-command --document-name vuln-lab-OSBaseline-<host> --targets ...
#   - 스크립트·파일은 base64gzip 으로 문서에 넣는다 (SSM 문서 64KB 제한, '{{' 치환 충돌 회피).
#     호스트에서 /root/vuln-lab-baseline (Windows: C:\vuln-lab-baseline) 에 풀고 baseline 을 실행한다.
#   - 비밀값은 문서·파라미터에 넣지 않는다. 스크립트는 env 또는 SSM SecureString 이름으로 비밀값을 읽는다.
# =============================================================================

variable "enable_os_baseline" {
  description = "true 면 os/<host>/baseline 스크립트를 담은 SSM Command 문서를 만든다 (기본 false: 운영 plan zero-diff 유지)"
  type        = bool
  default     = false
}

locals {
  os_baseline_tags = {
    Project = "vuln-lab"
    Owner   = "sk104-32-team-3"
    Purpose = "os-baseline"
  }

  # 리눅스 호스트 / 윈도우 호스트 구분
  os_baseline_linux   = ["bastion", "web-adm1", "was-adm1", "db-active"]
  os_baseline_windows = ["web1", "was1"]

  # 호스트별 files/ 목록 (상대경로)
  os_baseline_files = {
    for h in concat(local.os_baseline_linux, local.os_baseline_windows) :
    h => fileset("${path.module}/os/${h}/files", "**")
  }

  # ---- 리눅스 : aws:runShellScript 본문 -------------------------------------
  os_baseline_linux_cmd = {
    for h in local.os_baseline_linux : h => concat(
      [
        "set -eu",
        "umask 077",
        "D=/root/vuln-lab-baseline",
        "rm -rf \"$D\" && mkdir -p \"$D/files\"",
      ],
      flatten([
        for f in sort(tolist(local.os_baseline_files[h])) : [
          "mkdir -p \"$(dirname \"$D/files/${f}\")\"",
          "printf '%s' '${base64gzip(file("${path.module}/os/${h}/files/${f}"))}' | base64 -d | gunzip > \"$D/files/${f}\"",
        ]
      ]),
      [
        "printf '%s' '${base64gzip(file("${path.module}/os/${h}/baseline.sh"))}' | base64 -d | gunzip > \"$D/baseline.sh\"",
        "cd \"$D\"",
        "env {{ ExtraEnv }} bash \"$D/baseline.sh\"",
      ]
    )
  }

  # ---- 윈도우 : aws:runPowerShellScript 본문 ---------------------------------
  os_baseline_windows_cmd = {
    for h in local.os_baseline_windows : h => concat(
      [
        "$ErrorActionPreference = 'Stop'",
        "$D = 'C:\\vuln-lab-baseline'",
        "if (Test-Path $D) { Remove-Item -Recurse -Force $D }",
        "New-Item -ItemType Directory -Force -Path \"$D\\files\" | Out-Null",
        "function Expand-B64Gz([string]$b64, [string]$path) {",
        "  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null",
        "  $in = New-Object IO.MemoryStream(,[Convert]::FromBase64String($b64))",
        "  $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)",
        "  $ms = New-Object IO.MemoryStream; $gz.CopyTo($ms); $gz.Close()",
        "  $bytes = $ms.ToArray()",
        "  # ensure UTF-8 BOM: PowerShell 5.1 reads BOM-less .ps1 as ANSI",
        "  if ($path -like '*.ps1' -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { $bytes = [byte[]](0xEF,0xBB,0xBF) + $bytes }",
        "  [IO.File]::WriteAllBytes($path, $bytes)",
        "}",
      ],
      [
        for f in sort(tolist(local.os_baseline_files[h])) :
        "Expand-B64Gz '${base64gzip(file("${path.module}/os/${h}/files/${f}"))}' \"$D\\files\\${replace(f, "/", "\\")}\""
      ],
      [
        "Expand-B64Gz '${base64gzip(file("${path.module}/os/${h}/baseline.ps1"))}' \"$D\\baseline.ps1\"",
        "Set-Location $D",
        "& \"$D\\baseline.ps1\" {{ ScriptArgs }}",
      ]
    )
  }

  # ExtraEnv 허용 패턴 : KEY=VALUE 공백 구분.
  #   키에 PASSWORD/PASSWD/PWD/TOKEN/SECRET 가 들어가면 *_SSM_PARAM(SSM 이름 전달)만 허용
  #   -> 비밀값 평문이 Run Command 이력·CloudTrail 에 남는 것을 막는다
  os_baseline_extraenv_pair    = "(?:[A-Za-z_][A-Za-z0-9_]*_SSM_PARAM=[A-Za-z0-9_./-]*|(?![A-Za-z0-9_]*(?i:PASSWORD|PASSWD|PWD|TOKEN|SECRET))[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./:,@+-]*)"
  os_baseline_extraenv_pattern = "^$|^${local.os_baseline_extraenv_pair}( ${local.os_baseline_extraenv_pair})*$"

  # ---- 문서 본문 (schemaVersion 2.2) ----------------------------------------
  os_baseline_linux_doc = {
    for h in local.os_baseline_linux : h => jsonencode({
      schemaVersion = "2.2"
      description   = "vuln-lab ${h} OS 기준선 적용 (os/${h}/baseline.sh). 비밀값은 *_SSM_PARAM(SSM SecureString 이름)으로만 전달. 호스트별 변수 이름은 os/${h}/README.md 참고."
      parameters = {
        ExtraEnv = {
          type           = "String"
          description    = "비밀이 아닌 환경변수만 KEY=VALUE 공백 구분 (예: DB_PASSWORD_SSM_PARAM=/vuln-lab/x REBOOT=1). PASSWORD/TOKEN/SECRET 키는 *_SSM_PARAM 만 허용"
          default        = ""
          allowedPattern = local.os_baseline_extraenv_pattern
        }
      }
      mainSteps = [{
        action = "aws:runShellScript"
        name   = "applyBaseline"
        precondition = {
          StringEquals = ["platformType", "Linux"]
        }
        inputs = {
          timeoutSeconds = "3600"
          runCommand     = local.os_baseline_linux_cmd[h]
        }
      }]
    })
  }

  os_baseline_windows_doc = {
    for h in local.os_baseline_windows : h => jsonencode({
      schemaVersion = "2.2"
      description   = "vuln-lab ${h} OS 기준선 적용 (os/${h}/baseline.ps1). 비밀값은 SSM SecureString 이름 또는 env 로만 전달."
      parameters = {
        ScriptArgs = {
          type           = "String"
          description    = "baseline.ps1 인자 (예: -Reboot -UrlRewriteMsi C:\\pkg\\rewrite.msi). 비밀값 직접 입력 금지"
          default        = ""
          allowedPattern = "^$|^[-A-Za-z0-9_:\\\\./ ]*$"
        }
      }
      mainSteps = [{
        action = "aws:runPowerShellScript"
        name   = "applyBaseline"
        precondition = {
          StringEquals = ["platformType", "Windows"]
        }
        inputs = {
          timeoutSeconds = "3600"
          runCommand     = local.os_baseline_windows_cmd[h]
        }
      }]
    })
  }
}

# ---- 리눅스 호스트 ------------------------------------------------------------

# bastion (Debian 11)
resource "aws_ssm_document" "os_baseline_bastion" {
  count           = var.enable_os_baseline ? 1 : 0
  name            = "vuln-lab-OSBaseline-bastion"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"
  content         = local.os_baseline_linux_doc["bastion"]
  tags            = local.os_baseline_tags
}

# web-adm1 (Ubuntu 20.04, nginx 관리자 웹 프록시)
resource "aws_ssm_document" "os_baseline_web_adm1" {
  count           = var.enable_os_baseline ? 1 : 0
  name            = "vuln-lab-OSBaseline-web-adm1"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"
  content         = local.os_baseline_linux_doc["web-adm1"]
  tags            = local.os_baseline_tags
}

# was-adm1 (Rocky Linux 8.10, clinic-admin Spring Boot)
resource "aws_ssm_document" "os_baseline_was_adm1" {
  count           = var.enable_os_baseline ? 1 : 0
  name            = "vuln-lab-OSBaseline-was-adm1"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"
  content         = local.os_baseline_linux_doc["was-adm1"]
  tags            = local.os_baseline_tags
}

# db-active (Amazon Linux 2, Oracle XE 컨테이너) - 운영 DB 에는 실행 금지(과부하 이력), 재구축 시에만
resource "aws_ssm_document" "os_baseline_db_active" {
  count           = var.enable_os_baseline ? 1 : 0
  name            = "vuln-lab-OSBaseline-db-active"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"
  content         = local.os_baseline_linux_doc["db-active"]
  tags            = local.os_baseline_tags
}

# ---- 윈도우 호스트 ------------------------------------------------------------

# web1 (Windows Server 2019, IIS + ARR 리버스 프록시)
resource "aws_ssm_document" "os_baseline_web1" {
  count           = var.enable_os_baseline ? 1 : 0
  name            = "vuln-lab-OSBaseline-web1"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"
  content         = local.os_baseline_windows_doc["web1"]
  tags            = local.os_baseline_tags
}

# was1 (Windows Server 2019, clinic-customer nssm 서비스)
resource "aws_ssm_document" "os_baseline_was1" {
  count           = var.enable_os_baseline ? 1 : 0
  name            = "vuln-lab-OSBaseline-was1"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"
  content         = local.os_baseline_windows_doc["was1"]
  tags            = local.os_baseline_tags
}
