# =============================================================================
# 네트워크 : VPC / 서브넷 / 게이트웨이 / 라우팅 / VPC 엔드포인트
#   - vuln-lab VPC 10.0.0.0/16, 2개 AZ(2a, 2c) x 4계층(public / web / was / db)
#   - 보안그룹(SG)·NACL 은 security.tf
# =============================================================================

locals {
  # 네트워크·보안 리소스 공통 태그 (Name 은 리소스별로 merge)
  net_tags = {
    Env     = "lab-insecure"
    Owner   = "sk104-32-team-3"
    Project = "vuln-lab"
  }
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.net_tags, { Name = "vuln-lab-vpc" })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 서브넷 (모두 공인 IP 자동할당 OFF)
#   public : 외부 ALB, Bastion(EIP), NAT GW
#   web    : Web 서버(DMZ, 공인 IP 없음)
#   was    : WAS 서버, 내부 ALB
#   db     : DB 서버, SSM 인터페이스 엔드포인트
# -----------------------------------------------------------------------------
resource "aws_subnet" "public_01" {
  vpc_id            = aws_vpc.main.id
  availability_zone = "ap-northeast-2a"
  cidr_block        = "10.0.0.0/24"

  tags = merge(local.net_tags, { Name = "public-01" })
}

resource "aws_subnet" "public_02" {
  vpc_id            = aws_vpc.main.id
  availability_zone = "ap-northeast-2c"
  cidr_block        = "10.0.1.0/24"

  tags = merge(local.net_tags, { Name = "public-02" })
}

resource "aws_subnet" "web_01" {
  vpc_id            = aws_vpc.main.id
  availability_zone = "ap-northeast-2a"
  cidr_block        = "10.0.2.0/24"

  tags = merge(local.net_tags, { Name = "web-01" })
}

resource "aws_subnet" "web_02" {
  vpc_id            = aws_vpc.main.id
  availability_zone = "ap-northeast-2c"
  cidr_block        = "10.0.3.0/24"

  tags = merge(local.net_tags, { Name = "web-02" })
}

resource "aws_subnet" "was_01" {
  vpc_id            = aws_vpc.main.id
  availability_zone = "ap-northeast-2a"
  cidr_block        = "10.0.10.0/24"

  tags = merge(local.net_tags, { Name = "was-01" })
}

resource "aws_subnet" "was_02" {
  vpc_id            = aws_vpc.main.id
  availability_zone = "ap-northeast-2c"
  cidr_block        = "10.0.11.0/24"

  tags = merge(local.net_tags, { Name = "was-02" })
}

resource "aws_subnet" "db_01" {
  vpc_id            = aws_vpc.main.id
  availability_zone = "ap-northeast-2a"
  cidr_block        = "10.0.20.0/24"

  tags = merge(local.net_tags, { Name = "db-01" })
}

resource "aws_subnet" "db_02" {
  vpc_id            = aws_vpc.main.id
  availability_zone = "ap-northeast-2c"
  cidr_block        = "10.0.21.0/24"

  tags = merge(local.net_tags, { Name = "db-02" })
}

# -----------------------------------------------------------------------------
# 인터넷 게이트웨이 / NAT 게이트웨이
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.net_tags, { Name = "vuln-lab-igw" })
}

# NAT 용 고정 공인 IP (외부로 나가는 private 계층 트래픽의 출발지 IP)
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.net_tags, { Name = "vuln-lab-nat-eip" })

  lifecycle {
    prevent_destroy = true
  }
}

# 단일 NAT (public-01, 2a) - web/was 계층 아웃바운드용
resource "aws_nat_gateway" "main" {
  connectivity_type = "public"
  allocation_id     = aws_eip.nat.id
  subnet_id         = aws_subnet.public_01.id

  tags = merge(local.net_tags, { Name = "vuln-lab-nat" })

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# 라우팅 테이블
#   main(기본) : local 경로만, 명시적 연결 서브넷 없음
#   public     : 0.0.0.0/0 -> IGW        (public-01/02)
#   private    : 0.0.0.0/0 -> NAT GW     (web-01/02, was-01/02)
#   db         : local 만 + S3 게이트웨이 엔드포인트 경로 (db-01/02, 인터넷 경로 없음)
# -----------------------------------------------------------------------------
resource "aws_default_route_table" "main" {
  default_route_table_id = aws_vpc.main.default_route_table_id

  # local 경로 외 경로 없음
  route = []
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.net_tags, { Name = "rt-public" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.net_tags, { Name = "rt-private" })
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id

  # 인터넷 경로 없음. S3 프리픽스 경로는 aws_vpc_endpoint.s3 (route_table_ids) 가 관리
  route = []

  tags = { Name = "db-sub-rt" }
}

# 라우팅 테이블 연결
resource "aws_route_table_association" "public_01" {
  subnet_id      = aws_subnet.public_01.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_02" {
  subnet_id      = aws_subnet.public_02.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "web_01" {
  subnet_id      = aws_subnet.web_01.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "web_02" {
  subnet_id      = aws_subnet.web_02.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "was_01" {
  subnet_id      = aws_subnet.was_01.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "was_02" {
  subnet_id      = aws_subnet.was_02.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db_01" {
  subnet_id      = aws_subnet.db_01.id
  route_table_id = aws_route_table.db.id
}

resource "aws_route_table_association" "db_02" {
  subnet_id      = aws_subnet.db_02.id
  route_table_id = aws_route_table.db.id
}

# -----------------------------------------------------------------------------
# VPC 엔드포인트
#   - SSM 인터페이스 3종(ssm / ssmmessages / ec2messages) : db-01 에 배치,
#     인터넷 경로가 없는 DB 서버도 Session Manager 접속 가능 (정책 = 기본 전체 허용)
#   - S3 게이트웨이 : db 라우팅 테이블 전용, 진단 경로·SSM 버킷만 허용
# -----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.db_01.id]
  security_group_ids  = [aws_security_group.vpce_ssm.id]

  tags = { Name = "vuln-lab-vpce-ssm" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.db_01.id]
  security_group_ids  = [aws_security_group.vpce_ssm.id]

  tags = { Name = "vuln-lab-vpce-ssmmessages" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.db_01.id]
  security_group_ids  = [aws_security_group.vpce_ssm.id]

  tags = { Name = "vuln-lab-vpce-ec2messages" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.db.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 진단 결과 업로드/다운로드 경로만 허용
        Sid       = "DiagPathOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject"]
        Resource  = "${aws_s3_bucket.vuln_lab_backup.arn}/infra-auto-diag/*"
      },
      {
        # SSM Agent·패치 등 AWS 관리 버킷 읽기
        Sid       = "SsmServiceBuckets"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource = [
          "arn:aws:s3:::aws-ssm-${var.region}/*",
          "arn:aws:s3:::amazon-ssm-${var.region}/*",
          "arn:aws:s3:::amazon-ssm-packages-${var.region}/*",
          "arn:aws:s3:::${var.region}-birdwatcher-prod/*",
          "arn:aws:s3:::aws-ssm-document-attachments-${var.region}/*",
          "arn:aws:s3:::aws-ssm-distributor-file-${var.region}/*",
          "arn:aws:s3:::patch-baseline-snapshot-${var.region}/*",
        ]
      },
    ]
  })

  tags = { Name = "vuln-lab-vpce-s3" }
}
