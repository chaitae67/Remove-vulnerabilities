# logging 도메인 추가 import 블록 (imports.tf 에 없는 리소스)

# 백업 계획(zd-backup)의 대상 볼트 - 계획과 함께 콘솔에서 생성됨
import {
  to = aws_backup_vault.default
  id = "Default"
}
