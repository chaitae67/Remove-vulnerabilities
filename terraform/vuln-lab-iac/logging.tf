# =============================================================================
# 로깅·감사 : VPC 플로우 로그 / CloudTrail / CloudWatch 로그 그룹
#   - 암호화 키 : kms.tf,  IAM 역할 : iam.tf,  로그 버킷 : storage.tf
# =============================================================================

locals {
  # 추적 ARN 은 IAM 역할 신뢰정책 조건에도 쓰인다 (역할 <-> 추적 순환 참조 방지용 문자열)
  trail_name = "ZDtrail"
  trail_arn  = "arn:aws:cloudtrail:${var.region}:${var.account_id}:trail/ZDtrail"
}

# -----------------------------------------------------------------------------
# VPC 플로우 로그 : 허용(ACCEPT) 트래픽 -> S3 vuln-lab-backup/vpc_flow_log/ (10분 집계, 기본 v2 포맷)
# -----------------------------------------------------------------------------
resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ACCEPT"
  log_destination_type     = "s3"
  log_destination          = "${aws_s3_bucket.vuln_lab_backup.arn}/vpc_flow_log/"
  log_format               = "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status}"
  max_aggregation_interval = 600

  destination_options {
    file_format                = "plain-text"
    hive_compatible_partitions = false
    per_hour_partition         = false
  }

  tags = {
    Name = "flow-log"
  }
}

# -----------------------------------------------------------------------------
# CloudTrail : 멀티 리전, 로그 파일 무결성 검증, KMS 암호화, CloudWatch Logs 연동, 관리 이벤트만 기록
# -----------------------------------------------------------------------------
resource "aws_cloudtrail" "zdtrail" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  kms_key_id                    = aws_kms_key.cloudtrail.arn
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  enable_logging                = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail_manage_event.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cwlogs.arn

  advanced_event_selector {
    name = "관리 이벤트 선택기"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  # 신규 구축 시 버킷 정책·CW 권한이 먼저 있어야 추적 생성이 성공한다
  depends_on = [
    aws_s3_bucket_policy.cloudtrail_logs,
    aws_iam_role_policy_attachment.cloudtrail_cwlogs__cw_access,
  ]

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# CloudWatch 로그 그룹 : 모두 KMS(alias/cloudwatch-kms) 암호화, 365일 보관
# -----------------------------------------------------------------------------
# CloudTrail 관리 이벤트
resource "aws_cloudwatch_log_group" "cloudtrail_manage_event" {
  name              = "aws-cloudtrail-logs-manage_event"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.cloudwatch.arn

  lifecycle {
    prevent_destroy = true
  }
}

# EC2 CloudWatch Agent 로그
resource "aws_cloudwatch_log_group" "aws_instance_logs" {
  name              = "aws_instance_logs"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.cloudwatch.arn

  lifecycle {
    prevent_destroy = true
  }
}

# web1 Windows 이벤트 로그
resource "aws_cloudwatch_log_group" "ec2_web1_windows_event" {
  name              = "/ec2/web1/windows-event"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.cloudwatch.arn

  lifecycle {
    prevent_destroy = true
  }
}

# was1 Windows 이벤트 로그
resource "aws_cloudwatch_log_group" "ec2_was1_windows_event" {
  name              = "/ec2/was1/windows-event"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.cloudwatch.arn

  lifecycle {
    prevent_destroy = true
  }
}
