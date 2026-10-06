# =============================================================================
# DNS(Route 53) / 인증서(ACM) - zerodayclinic.p-e.kr
#   apex·admin·www A(별칭) -> ex-alb
#   ACM 인증서 2개: 와일드카드(*.도메인 + apex), www(www + admin) - 모두 DNS 검증, AMAZON_ISSUED
#   ※ 와일드카드 인증서의 검증 CNAME(_6ba46706...)은 현재 존에 없음 (자동 갱신 시 재검증 필요)
#   ※ aws_acm_certificate_validation 은 import 불가 리소스라 두지 않는다.
# =============================================================================

locals {
  dns_domain = "zerodayclinic.p-e.kr"

  # www 인증서 DNS 검증 정보 (도메인명 -> 레코드 name/value)
  acm_www_dvo = {
    for o in aws_acm_certificate.www.domain_validation_options : o.domain_name => o
  }
}

# -----------------------------------------------------------------------------
# 호스팅 존
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "main" {
  name = local.dns_domain

  tags = merge(local.lb_tags, { Name = "vuln-lab-zone" })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# ACM 인증서
# -----------------------------------------------------------------------------

# 와일드카드 - in-alb:443 추가 인증서
resource "aws_acm_certificate" "wildcard" {
  domain_name               = "*.${local.dns_domain}"
  subject_alternative_names = ["*.${local.dns_domain}", local.dns_domain]
  validation_method         = "DNS"

  lifecycle {
    prevent_destroy = true
  }
}

# www + admin - 모든 HTTPS 리스너의 기본 인증서
resource "aws_acm_certificate" "www" {
  domain_name               = "www.${local.dns_domain}"
  subject_alternative_names = ["admin.${local.dns_domain}", "www.${local.dns_domain}"]
  validation_method         = "DNS"

  tags = merge(local.lb_tags, { Name = "vuln-lab-acm-cert" })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 레코드 - 서비스 (ex-alb 별칭)
# -----------------------------------------------------------------------------

resource "aws_route53_record" "apex_a" {
  zone_id = aws_route53_zone.main.zone_id
  name    = local.dns_domain
  type    = "A"

  alias {
    name                   = aws_lb.ex_alb.dns_name
    zone_id                = aws_lb.ex_alb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www_a" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.${local.dns_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.ex_alb.dns_name
    zone_id                = aws_lb.ex_alb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "admin_a" {
  zone_id = aws_route53_zone.main.zone_id
  name    = local.lb_admin_host
  type    = "A"

  alias {
    name                   = aws_lb.ex_alb.dns_name
    zone_id                = aws_lb.ex_alb.zone_id
    evaluate_target_health = true
  }
}

# -----------------------------------------------------------------------------
# 레코드 - www 인증서 DNS 검증 CNAME
# -----------------------------------------------------------------------------

resource "aws_route53_record" "acmval_www_cname" {
  zone_id = aws_route53_zone.main.zone_id
  name    = local.acm_www_dvo["www.${local.dns_domain}"].resource_record_name
  type    = "CNAME"
  ttl     = 60
  records = [local.acm_www_dvo["www.${local.dns_domain}"].resource_record_value]
}

resource "aws_route53_record" "acmval_admin_cname" {
  zone_id = aws_route53_zone.main.zone_id
  name    = local.acm_www_dvo[local.lb_admin_host].resource_record_name
  type    = "CNAME"
  ttl     = 60
  records = [local.acm_www_dvo[local.lb_admin_host].resource_record_value]
}
