# =============================================================================
# 출력값 (리소스 diff 에 영향 없음)
# =============================================================================

# ---- 로드밸런서 --------------------------------------------------------------
output "ex_alb_dns_name" {
  description = "외부 ALB DNS (zerodayclinic.p-e.kr / www / admin 별칭 대상)"
  value       = aws_lb.ex_alb.dns_name
}

output "in_alb_dns_name" {
  description = "내부 ALB DNS (web -> was 구간)"
  value       = aws_lb.in_alb.dns_name
}

# ---- 접속 지점 ---------------------------------------------------------------
output "bastion_public_ip" {
  description = "bastion 고정 공인 IP (EIP)"
  value       = aws_eip.bastion.public_ip
}

output "nat_public_ip" {
  description = "NAT 게이트웨이 고정 공인 IP (사설 서브넷 아웃바운드)"
  value       = aws_eip.nat.public_ip
}

# ---- 네트워크 ----------------------------------------------------------------
output "vpc_id" {
  description = "vuln-lab VPC ID"
  value       = aws_vpc.main.id
}

output "subnet_ids" {
  description = "서브넷 ID (계층별)"
  value = {
    public_01 = aws_subnet.public_01.id
    public_02 = aws_subnet.public_02.id
    web_01    = aws_subnet.web_01.id
    web_02    = aws_subnet.web_02.id
    was_01    = aws_subnet.was_01.id
    was_02    = aws_subnet.was_02.id
    db_01     = aws_subnet.db_01.id
    db_02     = aws_subnet.db_02.id
  }
}

# ---- 인스턴스 ----------------------------------------------------------------
output "instance_ids" {
  description = "EC2 인스턴스 ID"
  value = {
    bastion   = aws_instance.bastion.id
    web1      = aws_instance.web1.id
    web_adm1  = aws_instance.web_adm1.id
    was1      = aws_instance.was1.id
    was_adm1  = aws_instance.was_adm1.id
    db_active = aws_instance.db_active.id
  }
}

output "instance_private_ips" {
  description = "EC2 사설 IP (db-active sqlnet.ora invited_nodes, hosts.allow 등에서 사용)"
  value = {
    bastion   = aws_instance.bastion.private_ip
    web1      = aws_instance.web1.private_ip
    web_adm1  = aws_instance.web_adm1.private_ip
    was1      = aws_instance.was1.private_ip
    was_adm1  = aws_instance.was_adm1.private_ip
    db_active = aws_instance.db_active.private_ip
  }
}

# ---- 기타 --------------------------------------------------------------------
output "route53_name_servers" {
  description = "Route 53 호스티드 존 네임서버 (도메인 등록처에 위임)"
  value       = aws_route53_zone.main.name_servers
}

output "os_baseline_documents" {
  description = "enable_os_baseline = true 일 때 생성되는 OS 기준선 SSM 문서 이름"
  value = var.enable_os_baseline ? [
    aws_ssm_document.os_baseline_bastion[0].name,
    aws_ssm_document.os_baseline_web_adm1[0].name,
    aws_ssm_document.os_baseline_was_adm1[0].name,
    aws_ssm_document.os_baseline_db_active[0].name,
    aws_ssm_document.os_baseline_web1[0].name,
    aws_ssm_document.os_baseline_was1[0].name,
  ] : []
}
