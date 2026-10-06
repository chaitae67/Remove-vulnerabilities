variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 프로필 (sk104_32_team_3 = default)"
  type        = string
  default     = "default"
}

variable "account_id" {
  description = "vuln-lab AWS 계정 ID (공개 저장소라 기본값 없음 - 로컬 tfvars 로 지정, 다른 계정 실행 방지에도 쓰임)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "12자리 AWS 계정 ID 를 넣는다."
  }
}

variable "admin_ip_cidr" {
  description = "관리자 공인 IP /32 (bastion SG SSH 허용) - 공개 저장소라 기본값 없음"
  type        = string
}

variable "admin_net_cidr" {
  description = "관리자 대역 /24 (public NACL SSH 허용) - 공개 저장소라 기본값 없음"
  type        = string
}

# ---------------------------------------------------------------------------
# 비밀값 (OS user_data 템플릿에서 사용) - 값은 코드에 두지 않는다.
#   예: terraform.tfvars.example 를 복사해 secret.auto.tfvars 로 만들고 값 입력 (gitignore 대상)
# ---------------------------------------------------------------------------
variable "server_password" {
  description = "리눅스 root/team 계정 및 Windows Administrator 초기 비밀번호 (user_data)"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Oracle XE 관리자/앱 계정 비밀번호 및 앱 서버 DB_PASS (user_data)"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# ALB 대상 등록 관리 여부 (import 불가 리소스)
#   false(기본) : 코드에서 만들지 않음 -> plan 은 import 전용 (라이브 등록은 그대로)
#   true        : 인스턴스 기동 후에만 켤 것 (중지 상태면 RegisterTargets 실패)
# ---------------------------------------------------------------------------
variable "manage_tg_attachments" {
  description = "ALB 대상 그룹 attachment 4개를 Terraform 으로 관리할지 여부"
  type        = bool
  default     = false
}
