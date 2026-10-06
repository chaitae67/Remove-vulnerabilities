# =============================================================================
# 스토리지 (S3)
#   - cloudtrail_logs : CloudTrail(ZDtrail) 로그 + S3 서버 액세스 로그 최종 수집
#   - vuln_lab_assets : 앱 자산 버킷 (EC2 앱 역할만 접근, 버전관리 사용)
#   - vuln_lab_backup : ALB 액세스 로그 / VPC 플로우 로그 / 진단 결과 보관
#
# 서버 액세스 로그 흐름: assets -> backup -> cloudtrail_logs -> cloudtrail_logs(자기 자신)
#
# 참고
#   - 라이브 점검(읽기 전용) 결과 lifecycle·CORS·알림·가속·요청자 지불·객체 잠금·
#     웹사이트·복제·인텔리전트 티어링·분석·인벤토리·메트릭 설정은 3개 버킷 모두 없음
#     → 추가 리소스/임포트 불필요. 버전관리는 assets 만 Enabled(나머지는 미사용).
#   - 버킷 ACL 은 BucketOwnerEnforced(ACL 비활성)라 aws_s3_bucket_acl 을 두지 않는다.
#   - 라이브 SSE 규칙의 BlockedEncryptionTypes(SSE-C 차단)는 provider 5.100.0 스키마에
#     없어 코드로 표현하지 않는다(plan 영향 없음).
# =============================================================================

locals {
  # ZDtrail ARN - aws_cloudtrail 이 이 버킷/정책에 의존할 수 있어 순환 참조를 피하려고 이름으로 조합
  s3_zdtrail_arn = "arn:aws:cloudtrail:${var.region}:${var.account_id}:trail/ZDtrail"
}

# -----------------------------------------------------------------------------
# 1) CloudTrail 로그 버킷
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "aws-cloudtrail-logs-${var.account_id}-425000b7"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    bucket_key_enabled = false
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 서버 액세스 로그: 자기 자신의 AWSLogs/ 접두사로 기록
resource "aws_s3_bucket_logging" "cloudtrail_logs" {
  bucket        = aws_s3_bucket.cloudtrail_logs.id
  target_bucket = aws_s3_bucket.cloudtrail_logs.id
  target_prefix = "AWSLogs/"

  target_object_key_format {
    simple_prefix {}
  }
}

# CloudTrail 쓰기 + S3 서버 액세스 로그 수신 허용 (Sid 는 콘솔 생성값 유지)
resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck20150319-c29d48a9-687c-4858-86ca-2e33ed666e88"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail_logs.arn
        Condition = {
          StringEquals = { "AWS:SourceArn" = local.s3_zdtrail_arn }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite20150319-dd535f7e-b8d3-43df-8cec-b3f377b7be97"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = local.s3_zdtrail_arn
            "s3:x-amz-acl"  = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "S3PolicyStmt-DO-NOT-MODIFY-1789797290087"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail_logs.arn}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = "${var.account_id}" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# 2) 앱 자산 버킷
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "vuln_lab_assets" {
  bucket = "vuln-lab-assets-54b7c81a"

  tags = {
    Env     = "lab-insecure"
    Owner   = "sk104-32-team-3"
    Project = "vuln-lab"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "vuln_lab_assets" {
  bucket = aws_s3_bucket.vuln_lab_assets.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "vuln_lab_assets" {
  bucket = aws_s3_bucket.vuln_lab_assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "vuln_lab_assets" {
  bucket = aws_s3_bucket.vuln_lab_assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vuln_lab_assets" {
  bucket = aws_s3_bucket.vuln_lab_assets.id

  rule {
    bucket_key_enabled = false
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 서버 액세스 로그 -> backup 버킷 루트
resource "aws_s3_bucket_logging" "vuln_lab_assets" {
  bucket        = aws_s3_bucket.vuln_lab_assets.id
  target_bucket = aws_s3_bucket.vuln_lab_backup.id
  target_prefix = ""

  target_object_key_format {
    simple_prefix {}
  }
}

# EC2 앱 역할만 객체 읽기/쓰기/삭제/목록 허용
resource "aws_s3_bucket_policy" "vuln_lab_assets" {
  bucket = aws_s3_bucket.vuln_lab_assets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EC2RoleOnly"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.ec2_app.arn }
        Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.vuln_lab_assets.arn,
          "${aws_s3_bucket.vuln_lab_assets.arn}/*",
        ]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# 3) 백업/로그 보관 버킷 (ALB 액세스 로그, VPC 플로우 로그, 진단 결과)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "vuln_lab_backup" {
  bucket = "vuln-lab-backup"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "vuln_lab_backup" {
  bucket = aws_s3_bucket.vuln_lab_backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "vuln_lab_backup" {
  bucket = aws_s3_bucket.vuln_lab_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vuln_lab_backup" {
  bucket = aws_s3_bucket.vuln_lab_backup.id

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 서버 액세스 로그 -> CloudTrail 로그 버킷 루트
resource "aws_s3_bucket_logging" "vuln_lab_backup" {
  bucket        = aws_s3_bucket.vuln_lab_backup.id
  target_bucket = aws_s3_bucket.cloudtrail_logs.id
  target_prefix = ""

  target_object_key_format {
    simple_prefix {}
  }
}

# ALB 액세스 로그 / VPC 플로우 로그(delivery.logs) / S3 서버 액세스 로그 쓰기 허용
resource "aws_s3_bucket_policy" "vuln_lab_backup" {
  bucket = aws_s3_bucket.vuln_lab_backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 600734575887 = ap-northeast-2 리전 ELB 서비스 계정
        Sid       = "ALBLogsAcct"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::600734575887:root" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.vuln_lab_backup.arn}/AWSLogs/${var.account_id}/*"
      },
      {
        Sid       = "ALBLogsService"
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.vuln_lab_backup.arn}/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid       = "AWSLogDeliveryWrite1"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.vuln_lab_backup.arn}/AWSLogs/${var.account_id}/*"
        Condition = {
          ArnLike = { "aws:SourceArn" = "arn:aws:logs:ap-northeast-2:${var.account_id}:*" }
          StringEquals = {
            "aws:SourceAccount" = "${var.account_id}"
            "s3:x-amz-acl"      = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "AWSLogDeliveryAclCheck1"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.vuln_lab_backup.arn
        Condition = {
          ArnLike      = { "aws:SourceArn" = "arn:aws:logs:ap-northeast-2:${var.account_id}:*" }
          StringEquals = { "aws:SourceAccount" = "${var.account_id}" }
        }
      },
      {
        # VPC 플로우 로그 (vpc_flow_log/ 접두사)
        Sid       = "AWSLogDeliveryWrite2"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.vuln_lab_backup.arn}/vpc_flow_log/AWSLogs/${var.account_id}/*"
        Condition = {
          ArnLike = { "aws:SourceArn" = "arn:aws:logs:ap-northeast-2:${var.account_id}:*" }
          StringEquals = {
            "aws:SourceAccount" = "${var.account_id}"
            "s3:x-amz-acl"      = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "S3PolicyStmt-DO-NOT-MODIFY-1790056852366"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.vuln_lab_backup.arn}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = "${var.account_id}" }
        }
      },
    ]
  })
}
