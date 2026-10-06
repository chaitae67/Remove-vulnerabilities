# =============================================================================
# 로드밸런싱 (ALB) - 외부 ex-alb / 내부 in-alb
#   인터넷 -> ex-alb:80  (HTTPS 301 리다이렉트)
#   인터넷 -> ex-alb:443 -> tg-web(web1:80)        | Host admin.* -> tg-web-admin(web-adm1:80)
#   WEB    -> in-alb:8443 -> tg-was(was1:8080)     | Host admin.* -> tg-was-admin(was-adm1:8080)
#   WEB    -> in-alb:443  -> tg-was(was1:8080)     | Host admin.* -> tg-was-admin(was-adm1:8080)
#   인증서: www 인증서(기본) / in-alb:443 에는 와일드카드·www 인증서 추가 (dns_acm.tf)
#
#   ※ 리스너 forward 동작은 실제 상태와 같게 target_group_arn + forward 블록을 함께 둔다
#     (provider 5.100.0 은 리스너에서 한쪽만 쓰면 diff 발생, 리스너 규칙은 target_group_arn 만으로 일치).
#     stickiness 는 비활성이며 duration 0(미설정)은 생략, 3600 으로 저장된 곳만 명시한다.
# =============================================================================

locals {
  # ALB 계열 공통 태그 (Name 은 리소스별로 병합)
  lb_tags = {
    Env     = "lab-insecure"
    Owner   = "sk104-32-team-3"
    Project = "vuln-lab"
  }

  # 관리자 화면 호스트 헤더 (호스트 기반 라우팅 조건)
  lb_admin_host = "admin.${local.dns_domain}"
}

# -----------------------------------------------------------------------------
# 로드밸런서
# -----------------------------------------------------------------------------

# 외부 ALB - public 서브넷 2개, 인터넷 연결
resource "aws_lb" "ex_alb" {
  name               = "ex-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ex_alb.id]
  subnets            = [aws_subnet.public_01.id, aws_subnet.public_02.id]

  drop_invalid_header_fields = true # 비정상 헤더 필드 제거
  enable_deletion_protection = true # 콘솔/API 삭제 방지
  desync_mitigation_mode     = "defensive"

  # 접근 로그 -> vuln-lab-backup 버킷 (prefix 없음)
  access_logs {
    bucket  = aws_s3_bucket.vuln_lab_backup.bucket
    enabled = true
  }

  tags = merge(local.lb_tags, { Name = "ex-alb" })

  lifecycle {
    prevent_destroy = true
  }
}

# 내부 ALB - WAS 서브넷 2개, WEB -> WAS 구간
resource "aws_lb" "in_alb" {
  name               = "in-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.in_alb.id]
  subnets            = [aws_subnet.was_01.id, aws_subnet.was_02.id]

  drop_invalid_header_fields = true
  enable_deletion_protection = true
  desync_mitigation_mode     = "defensive"

  access_logs {
    bucket  = aws_s3_bucket.vuln_lab_backup.bucket
    enabled = true
  }

  tags = merge(local.lb_tags, { Name = "in-alb" })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 대상 그룹 (instance 타입, HTTP)
# -----------------------------------------------------------------------------

# 사용자 WEB (web1:80)
resource "aws_lb_target_group" "tg_web" {
  name        = "tg-web"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/health"
    matcher             = "200,302"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = merge(local.lb_tags, { Name = "tg-web" })
}

# 관리자 WEB (web-adm1:80)
resource "aws_lb_target_group" "tg_web_admin" {
  name        = "tg-web-admin"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = merge(local.lb_tags, { Name = "tg-web-admin" })
}

# 사용자 WAS (was1:8080)
resource "aws_lb_target_group" "tg_was" {
  name        = "tg-was"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/"
    matcher             = "200-499"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = merge(local.lb_tags, { Name = "tg-was" })
}

# 관리자 WAS (was-adm1:8080)
resource "aws_lb_target_group" "tg_was_admin" {
  name        = "tg-was-admin"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/"
    matcher             = "200-499"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = merge(local.lb_tags, { Name = "tg-was-admin" })
}

# -----------------------------------------------------------------------------
# 대상 등록 (각 대상 그룹 1대씩, describe-target-health 로 확인)
#   ※ provider 5.100.0 은 aws_lb_target_group_attachment import 미지원.
#     라이브에는 이미 등록돼 있지만 인스턴스가 중지 상태라 RegisterTargets 가
#     실패할 수 있다(EC2 대상은 running 이어야 등록 가능).
#     -> 기본값(manage_tg_attachments = false)에서는 만들지 않아 첫 apply 는 import 전용.
#        인스턴스를 기동한 뒤 true 로 바꿔 apply 하면 state 에 편입된다.
# -----------------------------------------------------------------------------

locals {
  tg_attachments = {
    tg_web_web1           = { tg = aws_lb_target_group.tg_web.arn, target = aws_instance.web1.id, port = 80 }
    tg_web_admin_web_adm1 = { tg = aws_lb_target_group.tg_web_admin.arn, target = aws_instance.web_adm1.id, port = 80 }
    tg_was_was1           = { tg = aws_lb_target_group.tg_was.arn, target = aws_instance.was1.id, port = 8080 }
    tg_was_admin_was_adm1 = { tg = aws_lb_target_group.tg_was_admin.arn, target = aws_instance.was_adm1.id, port = 8080 }
  }
}

resource "aws_lb_target_group_attachment" "this" {
  for_each = var.manage_tg_attachments ? local.tg_attachments : {}

  target_group_arn = each.value.tg
  target_id        = each.value.target
  port             = each.value.port
}

# -----------------------------------------------------------------------------
# 리스너 - ex-alb
# -----------------------------------------------------------------------------

# HTTP -> HTTPS 301 리다이렉트 (host/path/query 유지)
resource "aws_lb_listener" "ex_alb_80" {
  load_balancer_arn = aws_lb.ex_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.lb_tags
}

# HTTPS 443 - 기본: tg-web
resource "aws_lb_listener" "ex_alb_443" {
  load_balancer_arn = aws_lb.ex_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.www.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_web.arn

    forward {
      target_group {
        arn    = aws_lb_target_group.tg_web.arn
        weight = 1
      }
    }
  }

  tags = local.lb_tags
}

# Host admin.* -> tg-web-admin
resource "aws_lb_listener_rule" "ex_alb_443_p10" {
  listener_arn = aws_lb_listener.ex_alb_443.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_web_admin.arn
  }

  condition {
    host_header {
      values = [local.lb_admin_host]
    }
  }

  tags = local.lb_tags
}

# -----------------------------------------------------------------------------
# 리스너 - in-alb
# -----------------------------------------------------------------------------

# HTTPS 8443 - 기본: tg-was
resource "aws_lb_listener" "in_alb_8443" {
  load_balancer_arn = aws_lb.in_alb.arn
  port              = 8443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.www.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_was.arn

    forward {
      target_group {
        arn    = aws_lb_target_group.tg_was.arn
        weight = 1
      }
    }
  }

  tags = local.lb_tags
}

# Host admin.* -> tg-was-admin
resource "aws_lb_listener_rule" "in_alb_8443_p10" {
  listener_arn = aws_lb_listener.in_alb_8443.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_was_admin.arn
  }

  condition {
    host_header {
      values = [local.lb_admin_host]
    }
  }

  tags = local.lb_tags
}

# HTTPS 443 - 기본: tg-was (PQ 하이브리드 TLS 정책, 태그 없음)
resource "aws_lb_listener" "in_alb_443" {
  load_balancer_arn = aws_lb.in_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
  certificate_arn   = aws_acm_certificate.www.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_was.arn

    forward {
      target_group {
        arn    = aws_lb_target_group.tg_was.arn
        weight = 1
      }
      stickiness {
        enabled  = false
        duration = 3600
      }
    }
  }
}

# Host admin.* -> tg-was-admin (태그 없음)
resource "aws_lb_listener_rule" "in_alb_443_p1" {
  listener_arn = aws_lb_listener.in_alb_443.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_was_admin.arn

    forward {
      target_group {
        arn    = aws_lb_target_group.tg_was_admin.arn
        weight = 1
      }
      stickiness {
        enabled  = false
        duration = 3600
      }
    }
  }

  condition {
    host_header {
      values = [local.lb_admin_host]
    }
  }
}

# in-alb:443 추가 인증서 (SNI) - 와일드카드
resource "aws_lb_listener_certificate" "in_alb_443_extra1" {
  listener_arn    = aws_lb_listener.in_alb_443.arn
  certificate_arn = aws_acm_certificate.wildcard.arn
}

# in-alb:443 추가 인증서 (SNI) - www (기본 인증서와 동일 ARN 이 추가 목록에도 등록되어 있음)
resource "aws_lb_listener_certificate" "in_alb_443_extra2" {
  listener_arn    = aws_lb_listener.in_alb_443.arn
  certificate_arn = aws_acm_certificate.www.arn
}
