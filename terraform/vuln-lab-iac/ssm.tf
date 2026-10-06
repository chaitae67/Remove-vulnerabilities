# =============================================================================
# SSM Run Command 문서 : KISA 기준 자동 취약점 진단 (S3 tools/ 의 스크립트 실행 -> CSV 를 results/ 업로드)
#   문서 본문 : ssm/<문서명>.json (라이브와 바이트 동일, 비밀값 없음)
# =============================================================================

# Linux 서버 (인프라+웹)
resource "aws_ssm_document" "autodiag_linux" {
  name            = "AutoDiag-Linux"
  document_type   = "Command"
  document_format = "JSON"
  content         = file("${path.module}/ssm/AutoDiag-Linux.json")
}

# Windows 서버 (인프라+웹)
resource "aws_ssm_document" "autodiag_windows" {
  name            = "AutoDiag-Windows"
  document_type   = "Command"
  document_format = "JSON"
  content         = file("${path.module}/ssm/AutoDiag-Windows.json")
}

# DB 서버 (Linux 인프라 + Oracle 컨테이너 내부 DBMS)
resource "aws_ssm_document" "autodiag_dbms" {
  name            = "AutoDiag-DBMS"
  document_type   = "Command"
  document_format = "JSON"
  content         = file("${path.module}/ssm/AutoDiag-DBMS.json")
}
