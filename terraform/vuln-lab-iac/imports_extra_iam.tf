# vuln-lab 관련 IAM 사용자 (공개 저장소 버전: 운영진 개인 사용자 3명 제외)/그룹/정책 연결/멤버십 import (iam.tf 하단). 자격증명(키/MFA/로그인)은 제외

import {
  to = aws_iam_user.vuln_lab_app_user
  id = "vuln-lab-app-user"
}

import {
  to = aws_iam_user.terraform_admin
  id = "terraform-admin"
}

import {
  to = aws_iam_user_policy_attachment.team["vuln_lab_app_user__view_only"]
  id = "vuln-lab-app-user/arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}

import {
  to = aws_iam_user_policy_attachment.team["vuln_lab_app_user__security_audit"]
  id = "vuln-lab-app-user/arn:aws:iam::aws:policy/SecurityAudit"
}

import {
  to = aws_iam_user_policy_attachment.team["terraform_admin__ec2_full"]
  id = "terraform-admin/arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

import {
  to = aws_iam_user_policy_attachment.team["terraform_admin__s3_full"]
  id = "terraform-admin/arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

import {
  to = aws_iam_group.app_ops
  id = "AppOps"
}

import {
  to = aws_iam_group.audit
  id = "Audit"
}

import {
  to = aws_iam_group.infra_management
  id = "infra_Management"
}

import {
  to = aws_iam_group_policy_attachment.team["app_ops__ec2_read"]
  id = "AppOps/arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

import {
  to = aws_iam_group_policy_attachment.team["app_ops__cw_read"]
  id = "AppOps/arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

import {
  to = aws_iam_group_policy_attachment.team["audit__view_only"]
  id = "Audit/arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}

import {
  to = aws_iam_group_policy_attachment.team["audit__security_audit"]
  id = "Audit/arn:aws:iam::aws:policy/SecurityAudit"
}

import {
  to = aws_iam_group_policy_attachment.team["infra_management__ec2_full"]
  id = "infra_Management/arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

import {
  to = aws_iam_group_policy_attachment.team["infra_management__s3_full"]
  id = "infra_Management/arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

import {
  to = aws_iam_user_group_membership.vuln_lab_app_user
  id = "vuln-lab-app-user/Audit"
}

import {
  to = aws_iam_account_password_policy.this
  id = "iam-account-password-policy"
}
