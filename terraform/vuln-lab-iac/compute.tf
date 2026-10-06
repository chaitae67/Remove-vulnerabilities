###############################################################################
# compute.tf - EC2 인스턴스 / EBS / 키페어 / EIP
#   - 6대 인스턴스 모두 현재 중지(stopped) 상태 -> instance_state 는 관리하지 않음
#   - OS 초기화 스크립트(user_data)는 os/<host>/user_data.tpl 템플릿(운영값과 바이트 동일)
###############################################################################

locals {
  # 인스턴스·키페어·EIP 공통 태그
  compute_tags = {
    Env     = "lab-insecure"
    Owner   = "sk104-32-team-3"
    Project = "vuln-lab"
  }
}

# -----------------------------------------------------------------------------
# EBS 암호화 기본 설정 (리전 단위) - AWS 관리형 키 alias/aws/ebs 사용
# -----------------------------------------------------------------------------
data "aws_kms_alias" "aws_ebs" {
  name = "alias/aws/ebs"
}

resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_ebs_default_kms_key" "this" {
  key_arn = data.aws_kms_alias.aws_ebs.target_key_arn
}

# -----------------------------------------------------------------------------
# SSH 키페어 (공개키만 등록, 개인키는 코드/저장소에 두지 않음)
# -----------------------------------------------------------------------------
resource "aws_key_pair" "vuln_lab_key" {
  key_name   = "vuln-lab-key"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDFNFVhLuRlVlAWNDY5Qd4LH5X+OYIdENoeeAOp27gYfe5B+rQcehuwZOa0cUOjASSsFVz4/Wy+XB6u1nyuCIc/BoZzLPhwI8ed9SoTiHwrcFEUlDPNpMZZxhvgvOWgOIU46tpwdslwl/R95mX9Jd8NtaplQBcsyHISvx3G8XfNpAIvYmFIFaLWhUS9fGbecj9XmznSCQsA01OSg9UHBqcF7gWHREcT9W2SOkq74L5v2udi6mE+8z9vBL5urP4zqYYwY90gVT9Z3rEWeEsDFzyIJ7prWVbGYPi3o+uieFJWTuJGJhnkQguPub3Ds+3tXjwNiFt21qPO/Fxr2OKfrkRr vuln-lab-key"
  tags       = local.compute_tags

  lifecycle {
    # import 시 provider 가 public_key 를 state 에 채우지 않아 강제 교체(diff)가 생김 -> 무시
    # (값은 운영 키페어 공개키와 동일, 신규 구축 시에만 사용됨)
    ignore_changes = [public_key]
  }
}

# =============================================================================
# EC2 인스턴스
#   공통: 인스턴스 프로파일 vuln-lab-ec2-app-profile, 키페어 vuln-lab-key,
#         IMDSv1 허용(http_tokens=optional, 운영값 그대로), T3 크레딧 unlimited,
#         루트 볼륨 gp3 + alias/aws/ebs 암호화, 종료 시 볼륨 보존
#   lifecycle:
#     - user_data 는 최초 부팅 시에만 실행됨. 변경하면 운영 인스턴스가
#       중지/시작(stop/start)되므로 변경 사항을 무시한다.
#     - prevent_destroy 로 실수에 의한 삭제/교체를 차단한다.
# =============================================================================

# --- Public 서브넷: Bastion (Debian 11) --------------------------------------
resource "aws_instance" "bastion" {
  ami                         = "ami-0f68da0073476cce5" # debian-11-amd64-20260821-2577
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public_01.id
  private_ip                  = "10.0.0.176"
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_app.name
  key_name                    = aws_key_pair.vuln_lab_key.key_name

  user_data = templatefile("${path.module}/os/bastion/user_data.tpl", {
    server_password = var.server_password
    db_password     = var.db_password
  })

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    kms_key_id            = aws_ebs_default_kms_key.this.key_arn
    delete_on_termination = false
    tags = {
      Name = "enc-bastion"
    }
  }

  tags = merge(local.compute_tags, {
    Name     = "bastion"
    AutoDiag = "linux"
  })

  lifecycle {
    # user_data 는 최초 부팅 때만 실행 - 변경 시 운영 인스턴스 stop/start 유발하므로 무시
    # (user_data_replace_on_change 는 import 시 state 에 null 로 들어와 생기는 무의미한 diff 방지)
    ignore_changes  = [user_data, user_data_replace_on_change]
    prevent_destroy = true
  }
}

# --- WEB 서브넷: web1 (Windows Server 2019) -----------------------------------
resource "aws_instance" "web1" {
  ami                    = "ami-0ae94fb345ba94c74" # Windows_Server-2019-English-Full-Base-2026.09.09
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.web_01.id
  private_ip             = "10.0.2.8"
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_app.name
  key_name               = aws_key_pair.vuln_lab_key.key_name

  user_data = templatefile("${path.module}/os/web1/user_data.tpl", {
    server_password = var.server_password
  })

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = aws_ebs_default_kms_key.this.key_arn
    delete_on_termination = false
    tags = {
      Name = "enc-web1"
    }
  }

  tags = merge(local.compute_tags, {
    Name     = "web1"
    AutoDiag = "windows"
  })

  lifecycle {
    # user_data 는 최초 부팅 때만 실행 - 변경 시 운영 인스턴스 stop/start 유발하므로 무시
    # (user_data_replace_on_change 는 import 시 state 에 null 로 들어와 생기는 무의미한 diff 방지)
    ignore_changes  = [user_data, user_data_replace_on_change]
    prevent_destroy = true
  }
}

# --- WEB 서브넷: web-adm1 (Ubuntu 20.04) --------------------------------------
resource "aws_instance" "web_adm1" {
  ami                    = "ami-0f8d552e06067b477" # ubuntu-focal-20.04-amd64-server-20250624
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.web_01.id
  private_ip             = "10.0.2.203"
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_app.name
  key_name               = aws_key_pair.vuln_lab_key.key_name

  user_data = templatefile("${path.module}/os/web-adm1/user_data.tpl", {
    server_password = var.server_password
    db_password     = var.db_password
  })

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    kms_key_id            = aws_ebs_default_kms_key.this.key_arn
    delete_on_termination = false
    tags = {
      Name = "enc-web-adm1"
    }
  }

  tags = merge(local.compute_tags, {
    Name     = "web-adm1"
    AutoDiag = "linux"
  })

  lifecycle {
    # user_data 는 최초 부팅 때만 실행 - 변경 시 운영 인스턴스 stop/start 유발하므로 무시
    # (user_data_replace_on_change 는 import 시 state 에 null 로 들어와 생기는 무의미한 diff 방지)
    ignore_changes  = [user_data, user_data_replace_on_change]
    prevent_destroy = true
  }
}

# --- WAS 서브넷: was1 (Windows Server 2019) -----------------------------------
resource "aws_instance" "was1" {
  ami                    = "ami-0ae94fb345ba94c74" # Windows_Server-2019-English-Full-Base-2026.09.09
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.was_01.id
  private_ip             = "10.0.10.174"
  vpc_security_group_ids = [aws_security_group.was.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_app.name
  key_name               = aws_key_pair.vuln_lab_key.key_name
  ebs_optimized          = true

  user_data = templatefile("${path.module}/os/was1/user_data.tpl", {
    server_password = var.server_password
  })

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = aws_ebs_default_kms_key.this.key_arn
    delete_on_termination = false
    tags = {
      Name = "enc-was1"
    }
  }

  tags = merge(local.compute_tags, {
    Name     = "was1"
    AutoDiag = "windows"
  })

  lifecycle {
    # user_data 는 최초 부팅 때만 실행 - 변경 시 운영 인스턴스 stop/start 유발하므로 무시
    # (user_data_replace_on_change 는 import 시 state 에 null 로 들어와 생기는 무의미한 diff 방지)
    ignore_changes  = [user_data, user_data_replace_on_change]
    prevent_destroy = true
  }
}

# --- WAS 서브넷: was-adm1 (Rocky Linux 8.10) ----------------------------------
resource "aws_instance" "was_adm1" {
  ami                    = "ami-015dc263f405fc73c" # Rocky-8-EC2-Base-8.10-20260625.x86_64
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.was_01.id
  private_ip             = "10.0.10.52"
  vpc_security_group_ids = [aws_security_group.was.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_app.name
  key_name               = aws_key_pair.vuln_lab_key.key_name
  ebs_optimized          = true

  user_data = templatefile("${path.module}/os/was-adm1/user_data.tpl", {
    server_password = var.server_password
    db_password     = var.db_password
  })

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 12
    encrypted             = true
    kms_key_id            = aws_ebs_default_kms_key.this.key_arn
    delete_on_termination = false
    tags = {
      Name = "enc-was-adm1"
    }
  }

  tags = merge(local.compute_tags, {
    Name     = "was-adm1"
    AutoDiag = "linux"
  })

  lifecycle {
    # user_data 는 최초 부팅 때만 실행 - 변경 시 운영 인스턴스 stop/start 유발하므로 무시
    # (user_data_replace_on_change 는 import 시 state 에 null 로 들어와 생기는 무의미한 diff 방지)
    ignore_changes  = [user_data, user_data_replace_on_change]
    prevent_destroy = true
  }
}

# --- DB 서브넷: db-active (Amazon Linux 2, Oracle XE) -------------------------
#   데이터 볼륨(/dev/sdf)은 아래 aws_ebs_volume + aws_volume_attachment 로 별도 관리
#   (ebs_block_device 와 혼용 금지)
resource "aws_instance" "db_active" {
  ami                    = "ami-0d84f865d3f4728e2" # amzn2-ami-hvm-2.0.20260914.1-x86_64-gp2
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.db_01.id
  private_ip             = "10.0.20.184"
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_app.name
  key_name               = aws_key_pair.vuln_lab_key.key_name

  user_data = templatefile("${path.module}/os/db-active/user_data.tpl", {
    server_password = var.server_password
    db_password     = var.db_password
  })

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = aws_ebs_default_kms_key.this.key_arn
    delete_on_termination = false
    tags = {
      Name = "enc-db-root"
    }
  }

  tags = merge(local.compute_tags, {
    Name     = "db-active"
    AutoDiag = "db"
  })

  lifecycle {
    # user_data 는 최초 부팅 때만 실행 - 변경 시 운영 인스턴스 stop/start 유발하므로 무시
    # (user_data_replace_on_change 는 import 시 state 에 null 로 들어와 생기는 무의미한 diff 방지)
    ignore_changes  = [user_data, user_data_replace_on_change]
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# DB 데이터 볼륨 (암호화 사본) - 비암호화 스냅샷 snap-0acbe6991b5c6159c 에서 생성
# -----------------------------------------------------------------------------
resource "aws_ebs_volume" "enc_db_data" {
  availability_zone = "ap-northeast-2a"
  type              = "gp3"
  size              = 20
  iops              = 3000
  throughput        = 125
  encrypted         = true
  kms_key_id        = aws_ebs_default_kms_key.this.key_arn
  snapshot_id       = "snap-0acbe6991b5c6159c"

  tags = {
    Name = "enc-db-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "enc_db_data" {
  device_name = "/dev/sdf"
  instance_id = aws_instance.db_active.id
  volume_id   = aws_ebs_volume.enc_db_data.id
}

# -----------------------------------------------------------------------------
# Bastion 고정 공인 IP (EIP)
# -----------------------------------------------------------------------------
resource "aws_eip" "bastion" {
  domain   = "vpc"
  instance = aws_instance.bastion.id

  tags = merge(local.compute_tags, {
    Name = "vuln-lab-bastion-eip"
  })

  lifecycle {
    prevent_destroy = true
  }
}
