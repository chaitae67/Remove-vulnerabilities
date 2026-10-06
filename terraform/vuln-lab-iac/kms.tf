# =============================================================================
# KMS 고객 관리형 키 (자동 키 교체 비활성 - 라이브 설정 그대로)
#   키 정책 원문 : policies/kms_*.json
# =============================================================================

# CloudWatch Logs 로그 그룹 암호화용
resource "aws_kms_key" "cloudwatch" {
  enable_key_rotation = false
  policy              = templatefile("${path.module}/policies/kms_cloudwatch.json", { account_id = var.account_id })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "cloudwatch" {
  name          = "alias/cloudwatch-kms"
  target_key_id = aws_kms_key.cloudwatch.key_id
}

# CloudTrail 로그 파일(S3) 암호화용 - CloudTrail 콘솔이 생성한 정책
resource "aws_kms_key" "cloudtrail" {
  enable_key_rotation = false
  policy              = templatefile("${path.module}/policies/kms_cloudtrail.json", { account_id = var.account_id })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/zdclinic-3-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}
