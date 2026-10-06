# =============================================================================
# AWS Backup (일일 백업) / AWS Config (계정 단위 설정 기록기)
# =============================================================================

# -----------------------------------------------------------------------------
# 백업 볼트 : 기본 볼트 "Default" (AWS 관리형 키 alias/aws/backup 로 암호화 - kms_key_arn 생략 시 동일)
#   import 블록 : imports_extra_logging.tf
# -----------------------------------------------------------------------------
resource "aws_backup_vault" "default" {
  name = "Default"

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 백업 계획 : 매일 05:00(KST) 시작, 35일 보관
# -----------------------------------------------------------------------------
resource "aws_backup_plan" "zd_backup" {
  name = "zd-backup"

  rule {
    rule_name                    = "DailyBackups"
    target_vault_name            = aws_backup_vault.default.name
    schedule                     = "cron(0 5 ? * * *)"
    schedule_expression_timezone = "Asia/Seoul"
    start_window                 = 480
    completion_window            = 10080

    lifecycle {
      delete_after = 35
    }
  }

  # 라이브에는 S3 고급 백업 설정(BackupACLs/BackupObjectTags = enabled)이 있으나
  # provider 5.100 은 advanced_backup_setting.resource_type 으로 "EC2" 만 허용 -> 코드 표현 불가, 변경 무시
  lifecycle {
    ignore_changes = [advanced_backup_setting]
  }
}

# 백업 대상 선택 : 이름과 달리 지원되는 "모든" 리소스(*) 대상 - 라이브 그대로
resource "aws_backup_selection" "zdclinic_ec2_backup" {
  name         = "zdclinic-ec2-backup"
  plan_id      = aws_backup_plan.zd_backup.id
  iam_role_arn = aws_iam_role.backup_default.arn
  resources    = ["*"]
}

# -----------------------------------------------------------------------------
# AWS Config : IAM 리소스 유형만 제외하고 연속 기록, 현재 기록기는 "중지" 상태
# -----------------------------------------------------------------------------
resource "aws_config_configuration_recorder" "default" {
  name     = "default"
  role_arn = "arn:aws:iam::${var.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"

  recording_group {
    all_supported = false

    exclusion_by_resource_types {
      resource_types = ["AWS::IAM::Group", "AWS::IAM::Policy", "AWS::IAM::Role", "AWS::IAM::User"]
    }

    recording_strategy {
      use_only = "EXCLUSION_BY_RESOURCE_TYPES"
    }
  }

  recording_mode {
    recording_frequency = "CONTINUOUS"
  }
}

# 전달 채널 : 계정 공용 버킷 (vuln-lab 범위 밖이라 이름 그대로 사용)
resource "aws_config_delivery_channel" "default" {
  name           = "default"
  s3_bucket_name = "config-bucket-${var.account_id}"

  depends_on = [aws_config_configuration_recorder.default]
}

resource "aws_config_configuration_recorder_status" "default" {
  name       = aws_config_configuration_recorder.default.name
  is_enabled = false

  depends_on = [aws_config_delivery_channel.default]
}
