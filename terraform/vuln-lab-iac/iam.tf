# =============================================================================
# IAM (vuln-lab 관련 역할만)
#   - EC2 앱 역할/인스턴스 프로파일 : SSM 접속, CloudWatch Agent, 진단 결과 S3 업로드
#   - CloudTrail -> CloudWatch Logs 전달 역할
#   - AWS Backup 기본 서비스 역할
# =============================================================================

# -----------------------------------------------------------------------------
# EC2 앱 역할 + 인스턴스 프로파일 (전체 EC2 공용)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ec2_app" {
  name = "vuln-lab-ec2-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Env     = "lab-insecure"
    Owner   = "sk104-32-team-3"
    Project = "vuln-lab"
  }
}

resource "aws_iam_instance_profile" "ec2_app" {
  name = "vuln-lab-ec2-app-profile"
  role = aws_iam_role.ec2_app.name

  tags = {
    Env     = "lab-insecure"
    Owner   = "sk104-32-team-3"
    Project = "vuln-lab"
  }
}

# AWS 관리형 정책 : SSM Session Manager / Run Command
resource "aws_iam_role_policy_attachment" "ec2_app__ssm_core" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# AWS 관리형 정책 : CloudWatch Agent 로그/지표 전송
resource "aws_iam_role_policy_attachment" "ec2_app__cwagent" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# 인라인 : 자동 진단 도구 다운로드(tools/) 및 결과 업로드(results/ reports/ ssm-output/)
resource "aws_iam_role_policy" "ec2_app__diag_csv_s3" {
  name = "diag-csv-s3"
  role = aws_iam_role.ec2_app.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadTools"
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.vuln_lab_backup.arn}/infra-auto-diag/tools/*"
      }, {
      Sid    = "WriteResults"
      Effect = "Allow"
      Action = "s3:PutObject"
      Resource = [
        "${aws_s3_bucket.vuln_lab_backup.arn}/infra-auto-diag/results/*",
        "${aws_s3_bucket.vuln_lab_backup.arn}/infra-auto-diag/reports/*",
        "${aws_s3_bucket.vuln_lab_backup.arn}/infra-auto-diag/ssm-output/*",
      ]
    }]
  })
}

# 인라인 : 앱 자산 버킷(vuln-lab-assets-*) 읽기/쓰기, SSM 파라미터(/vuln-lab/*) 조회
resource "aws_iam_role_policy" "ec2_app__s3_app_access" {
  name = "s3-app-access"
  role = aws_iam_role.ec2_app.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = ["arn:aws:s3:::vuln-lab-assets-*", "arn:aws:s3:::vuln-lab-assets-*/*"]
      }, {
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = "arn:aws:ssm:*:*:parameter/vuln-lab/*"
    }]
  })
}

# -----------------------------------------------------------------------------
# CloudTrail -> CloudWatch Logs 전달 역할 (CloudTrail 콘솔 생성)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "cloudtrail_cwlogs" {
  name        = "CloudTrail_CloudWatchLogs_Role"
  path        = "/service-role/"
  description = "Role for config CloudWathLogs for trail ZDtrail"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
          "aws:SourceArn"     = local.trail_arn
        }
      }
    }]
  })
}

resource "aws_iam_policy" "cloudtrail_cw_access" {
  name        = "Cloudtrail-CW-access-policy-ZDtrail-36bcec23-73f6-4043-a09b-90549f5fdf3e"
  path        = "/service-role/"
  description = "Policy for config CloudWathLogs for trail ZDtrail, created by CloudTrail console"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AWSCloudTrailCreateLogStream2014110"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream"]
      Resource = ["${aws_cloudwatch_log_group.cloudtrail_manage_event.arn}:log-stream:${var.account_id}_CloudTrail_${var.region}*"]
      }, {
      Sid      = "AWSCloudTrailPutLogEvents20141101"
      Effect   = "Allow"
      Action   = ["logs:PutLogEvents"]
      Resource = ["${aws_cloudwatch_log_group.cloudtrail_manage_event.arn}:log-stream:${var.account_id}_CloudTrail_${var.region}*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudtrail_cwlogs__cw_access" {
  role       = aws_iam_role.cloudtrail_cwlogs.name
  policy_arn = aws_iam_policy.cloudtrail_cw_access.arn
}

# -----------------------------------------------------------------------------
# AWS Backup 기본 서비스 역할 (백업/복원 AWS 관리형 정책)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "backup_default" {
  name        = "AWSBackupDefaultServiceRole"
  path        = "/service-role/"
  description = "Provides AWS Backup permission to create backups and perform restores on your behalf across AWS services"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup_default__backup" {
  role       = aws_iam_role.backup_default.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_default__restores" {
  role       = aws_iam_role.backup_default.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# =============================================================================
# 팀이 프로젝트 중 만든 IAM 사용자/그룹 (2026-08-25 ~ 09-21, 주통기 IAM 조치 포함)
#   - 사용자 태그에 개인정보(부서/직책/이름/이메일)가 있어 코드에 넣지 않는다
#     -> tags 는 ignore_changes (라이브 값 유지). vuln-lab-app-user 만 프로젝트 태그 명시
#   - 액세스 키, MFA, 콘솔 로그인 프로필은 자격증명이라 관리하지 않는다
#   - [공개 저장소 버전] 운영진 개인 IAM 사용자 3명과 그 정책 연결·그룹 멤버십은 뺐다
#     (로컬 원본 스냅샷에만 있다). 그룹 AppOps / infra_Management 정의는 그대로 둔다
#   - 교육기관 제공(Admin, CostManagers, student*, CostManager, sk104_32_team_3)과
#     GRP-IAC-DIAG(2026-04, 프로젝트 이전 생성)는 제외 (README 6장)
# =============================================================================

locals {
  # 사용자 -> AWS 관리형 정책 (직접 연결)
  iam_team_user_policies = {
    vuln_lab_app_user__view_only      = { user = "vuln_lab_app_user", arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess" }
    vuln_lab_app_user__security_audit = { user = "vuln_lab_app_user", arn = "arn:aws:iam::aws:policy/SecurityAudit" }
    terraform_admin__ec2_full         = { user = "terraform_admin", arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess" }
    terraform_admin__s3_full          = { user = "terraform_admin", arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess" }
  }

  # 그룹 -> AWS 관리형 정책
  iam_team_group_policies = {
    app_ops__ec2_read          = { group = "app_ops", arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess" }
    app_ops__cw_read           = { group = "app_ops", arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess" }
    audit__view_only           = { group = "audit", arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess" }
    audit__security_audit      = { group = "audit", arn = "arn:aws:iam::aws:policy/SecurityAudit" }
    infra_management__ec2_full = { group = "infra_management", arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess" }
    infra_management__s3_full  = { group = "infra_management", arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess" }
  }

  iam_team_users = {
    vuln_lab_app_user = aws_iam_user.vuln_lab_app_user.name
    terraform_admin   = aws_iam_user.terraform_admin.name
  }

  iam_team_groups = {
    app_ops          = aws_iam_group.app_ops.name
    audit            = aws_iam_group.audit.name
    infra_management = aws_iam_group.infra_management.name
  }
}

# ---- 사용자 ------------------------------------------------------------------
# 예전 vuln-lab 모듈이 만든 앱 사용자 (현재는 감사용 읽기 권한으로 축소)
resource "aws_iam_user" "vuln_lab_app_user" {
  name = "vuln-lab-app-user"

  tags = {
    Env     = "lab-insecure"
    Owner   = "sk104-32-team-3"
    Project = "vuln-lab"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags] # 라이브에는 개인정보 태그가 추가로 있다
  }
}

# Terraform/CLI 작업용 (aws profile myprofile)
resource "aws_iam_user" "terraform_admin" {
  name = "terraform-admin"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags]
  }
}

resource "aws_iam_user_policy_attachment" "team" {
  for_each = local.iam_team_user_policies

  user       = local.iam_team_users[each.value.user]
  policy_arn = each.value.arn
}

# ---- 그룹 (역할 분리: 운영 조회 / 감사 / 인프라 관리) -------------------------
resource "aws_iam_group" "app_ops" {
  name = "AppOps"
}

resource "aws_iam_group" "audit" {
  name = "Audit"
}

resource "aws_iam_group" "infra_management" {
  name = "infra_Management"
}

resource "aws_iam_group_policy_attachment" "team" {
  for_each = local.iam_team_group_policies

  group      = local.iam_team_groups[each.value.group]
  policy_arn = each.value.arn
}

# ---- 그룹 멤버십 (비배타적: 다른 그룹 소속에는 영향 없음) ----------------------
resource "aws_iam_user_group_membership" "vuln_lab_app_user" {
  user   = aws_iam_user.vuln_lab_app_user.name
  groups = [aws_iam_group.audit.name]
}
