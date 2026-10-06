provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # 안전장치: 지정한 vuln-lab 계정이 아니면 plan/apply 자체가 실패한다.
  #   (공개 저장소 버전이라 계정 ID 는 변수로 받는다. 로컬 원본은 리터럴로 고정)
  allowed_account_ids = [var.account_id]
}
