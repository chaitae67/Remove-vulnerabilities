# =============================================================================
# 네트워크 보안 : NACL / 보안그룹(SG)
#   - 서브넷 단위 NACL : public-acl(public 계층), private-acl(web/was/db 계층),
#     기본 NACL 은 규칙·연결 없음(미사용)
#   - SG 체인 : 인터넷 -> ex-alb -> web -> in-alb -> was -> db / redis
#     관리 접속 : 관리자 IP -> bastion -> web/was/db (SSH/RDP)
# =============================================================================

locals {
  admin_ip_cidr  = var.admin_ip_cidr  # 관리자 공인 IP (bastion SG SSH 허용)
  admin_net_cidr = var.admin_net_cidr # 관리자 대역 (public NACL SSH 허용)
}

# -----------------------------------------------------------------------------
# NACL (상태 비저장 - 응답 트래픽용 임시포트 1024-65535 규칙 포함)
# -----------------------------------------------------------------------------
resource "aws_network_acl" "public_acl" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.public_01.id, aws_subnet.public_02.id]

  # --- 인바운드 ---
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  ingress {
    rule_no    = 101
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }
  ingress {
    rule_no    = 102
    action     = "allow"
    protocol   = "tcp"
    cidr_block = local.admin_net_cidr
    from_port  = 22
    to_port    = 22
  }
  ingress {
    rule_no    = 103
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 22
    to_port    = 22
  }
  ingress {
    rule_no    = 104
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # --- 아웃바운드 ---
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  egress {
    rule_no    = 101
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }
  egress {
    rule_no    = 102
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 22
    to_port    = 22
  }
  egress {
    rule_no    = 103
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 3389
    to_port    = 3389
  }
  egress {
    rule_no    = 104
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  tags = merge(local.net_tags, { Name = "public-acl" })
}

resource "aws_network_acl" "private_acl" {
  vpc_id = aws_vpc.main.id
  subnet_ids = [
    aws_subnet.web_01.id, aws_subnet.web_02.id,
    aws_subnet.was_01.id, aws_subnet.was_02.id,
    aws_subnet.db_01.id, aws_subnet.db_02.id,
  ]

  # --- 인바운드 (VPC 내부 + 응답 트래픽) ---
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 22
    to_port    = 22
  }
  ingress {
    rule_no    = 101
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 3389
    to_port    = 3389
  }
  ingress {
    rule_no    = 102
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 80
    to_port    = 80
  }
  ingress {
    rule_no    = 103
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 8080
    to_port    = 8080
  }
  ingress {
    rule_no    = 104
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 1521
    to_port    = 1521
  }
  ingress {
    rule_no    = 105
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }
  ingress {
    rule_no    = 106
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 443
    to_port    = 443
  }

  # --- 아웃바운드 ---
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  egress {
    rule_no    = 101
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }
  egress {
    rule_no    = 102
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 1521
    to_port    = 1521
  }
  egress {
    rule_no    = 103
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 1024
    to_port    = 65535
  }

  tags = merge(local.net_tags, { Name = "private-acl" })
}

# 기본 NACL - 연결 서브넷·허용 규칙 없음 (기본 * deny 만 남은 상태 유지)
resource "aws_default_network_acl" "default" {
  default_network_acl_id = aws_vpc.main.default_network_acl_id
}

# -----------------------------------------------------------------------------
# 보안그룹
#   - 인바운드 : 각 SG 안에 인라인으로 선언 (출발지 SG 는 리소스 참조)
#   - 아웃바운드 : web / was / in_alb / ex_alb 는 SG 끼리 서로 참조(순환)하므로
#     인라인 대신 aws_vpc_security_group_egress_rule 로 분리 (아래 egress 규칙 절)
# -----------------------------------------------------------------------------

# 기본 SG - 모든 규칙 제거(deny all)
resource "aws_default_security_group" "default" {
  vpc_id  = aws_vpc.main.id
  ingress = []
  egress  = []

  tags = merge(local.net_tags, { Name = "default-deny-all" })
}

resource "aws_security_group" "bastion" {
  name        = "vuln-lab-bastion"
  description = "Bastion - SSH from admin IP only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from admin CIDR only"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [local.admin_ip_cidr]
  }
  ingress {
    # EC2 Instance Connect (com.amazonaws.ap-northeast-2.ec2-instance-connect, AWS 관리형)
    protocol        = "tcp"
    from_port       = 22
    to_port         = 22
    prefix_list_ids = ["pl-00ec8fd779e5b4175"]
  }

  egress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "SSH to internal subnets"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress {
    description = "RDP to internal subnets"
    protocol    = "tcp"
    from_port   = 3389
    to_port     = 3389
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  tags = merge(local.net_tags, { Name = "sg-bastion" })
}

resource "aws_security_group" "ex_alb" {
  name        = "vuln-lab-ex-alb"
  description = "External ALB - internet HTTP/HTTPS only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS from internet"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  # 아웃바운드: aws_vpc_security_group_egress_rule.ex_alb_to_web

  tags = merge(local.net_tags, { Name = "sg-ex-alb" })
}

resource "aws_security_group" "web" {
  name        = "vuln-lab-web"
  description = "Web DMZ - ALB inbound, no public IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from external ALB only"
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.ex_alb.id]
  }
  ingress {
    description     = "SSH from bastion only"
    protocol        = "tcp"
    from_port       = 22
    to_port         = 22
    security_groups = [aws_security_group.bastion.id]
  }
  ingress {
    description     = "RDP from bastion only"
    protocol        = "tcp"
    from_port       = 3389
    to_port         = 3389
    security_groups = [aws_security_group.bastion.id]
  }
  # 아웃바운드: aws_vpc_security_group_egress_rule.web_*

  tags = merge(local.net_tags, { Name = "sg-web" })
}

resource "aws_security_group" "in_alb" {
  name        = "vuln-lab-in-alb"
  description = "Internal ALB - web tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol        = "tcp"
    from_port       = 443
    to_port         = 443
    security_groups = [aws_security_group.web.id]
  }
  ingress {
    description     = "HTTPS from web DMZ only"
    protocol        = "tcp"
    from_port       = 8443
    to_port         = 8443
    security_groups = [aws_security_group.web.id]
  }
  # 아웃바운드: aws_vpc_security_group_egress_rule.in_alb_to_was

  tags = merge(local.net_tags, { Name = "sg-in-alb" })
}

resource "aws_security_group" "was" {
  name        = "vuln-lab-was"
  description = "WAS - internal ALB inbound only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from internal ALB only"
    protocol        = "tcp"
    from_port       = 8080
    to_port         = 8080
    security_groups = [aws_security_group.in_alb.id]
  }
  ingress {
    description     = "SSH from bastion only"
    protocol        = "tcp"
    from_port       = 22
    to_port         = 22
    security_groups = [aws_security_group.bastion.id]
  }
  ingress {
    description     = "RDP from bastion only"
    protocol        = "tcp"
    from_port       = 3389
    to_port         = 3389
    security_groups = [aws_security_group.bastion.id]
  }
  # 아웃바운드: aws_vpc_security_group_egress_rule.was_*

  tags = merge(local.net_tags, { Name = "sg-was" })
}

resource "aws_security_group" "db" {
  name        = "vuln-lab-db"
  description = "DB - WAS inbound only, Docker API removed"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Oracle from WAS only"
    protocol        = "tcp"
    from_port       = 1521
    to_port         = 1521
    security_groups = [aws_security_group.was.id]
  }
  ingress {
    description     = "SSH from bastion only"
    protocol        = "tcp"
    from_port       = 22
    to_port         = 22
    security_groups = [aws_security_group.bastion.id]
  }

  # 인터넷 경로 없음 - S3 게이트웨이·SSM 엔드포인트로만 443 허용
  egress {
    description     = "S3 gateway endpoint"
    protocol        = "tcp"
    from_port       = 443
    to_port         = 443
    prefix_list_ids = [aws_vpc_endpoint.s3.prefix_list_id]
  }
  egress {
    description     = "SSM Endpoint"
    protocol        = "tcp"
    from_port       = 443
    to_port         = 443
    security_groups = [aws_security_group.vpce_ssm.id]
  }

  tags = merge(local.net_tags, { Name = "sg-db" })
}

resource "aws_security_group" "redis" {
  name        = "vuln-lab-redis"
  description = "Redis - WAS inbound only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis from WAS only"
    protocol        = "tcp"
    from_port       = 6379
    to_port         = 6379
    security_groups = [aws_security_group.was.id]
  }

  # 아웃바운드 규칙 없음
  egress = []

  tags = merge(local.net_tags, { Name = "sg-redis" })
}

# SSM 인터페이스 엔드포인트용 (태그 없음)
resource "aws_security_group" "vpce_ssm" {
  name        = "vuln-lab-vpce-ssm"
  description = "SSM interface endpoints (443 from VPC)"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------------------
# 보안그룹 아웃바운드 규칙 (분리형)
#   web <-> ex_alb, web <-> in_alb, in_alb <-> was, was <-> db 가 서로 참조하므로
#   인라인으로 두면 의존성 순환이 생긴다. 해당 SG 의 egress 는 전부 여기서만 관리한다.
#   (import 블록: imports_extra_network.tf)
# -----------------------------------------------------------------------------

# ex_alb -> web
resource "aws_vpc_security_group_egress_rule" "ex_alb_to_web" {
  security_group_id            = aws_security_group.ex_alb.id
  description                  = "HTTP to web DMZ only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.web.id
}

# web -> 인터넷(NAT) 80/443, web -> in_alb 8443
resource "aws_vpc_security_group_egress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "web_https" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "web_to_in_alb" {
  security_group_id            = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 8443
  to_port                      = 8443
  referenced_security_group_id = aws_security_group.in_alb.id
}

# in_alb -> was
resource "aws_vpc_security_group_egress_rule" "in_alb_to_was" {
  security_group_id            = aws_security_group.in_alb.id
  description                  = "HTTP to WAS only"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.was.id
}

# was -> 인터넷(NAT) 80/443, was -> db 1521
resource "aws_vpc_security_group_egress_rule" "was_http" {
  security_group_id = aws_security_group.was.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "was_https" {
  security_group_id = aws_security_group.was.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "was_to_db" {
  security_group_id            = aws_security_group.was.id
  description                  = "Oracle to DB only"
  ip_protocol                  = "tcp"
  from_port                    = 1521
  to_port                      = 1521
  referenced_security_group_id = aws_security_group.db.id
}
