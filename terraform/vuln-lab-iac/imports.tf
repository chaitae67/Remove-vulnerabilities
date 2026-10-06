# 현재 AWS 리소스를 Terraform state 로 가져오는 import 블록 (자동 생성: _inventory/gen_imports.py)
# terraform plan 으로 '가져오기 N, 추가/변경/삭제 0' 을 확인한다. apply 는 사람이 검토 후 결정한다.

# ---------------- network ----------------
import {
  to = aws_vpc.main
  id = "vpc-086bab7aac7afcbb4"
}
import {
  to = aws_subnet.public_01
  id = "subnet-06c7b497b53efc74c"
}
import {
  to = aws_subnet.db_01
  id = "subnet-0d1c43346ef0305de"
}
import {
  to = aws_subnet.was_02
  id = "subnet-0f0b02150fab4bb3b"
}
import {
  to = aws_subnet.db_02
  id = "subnet-091b40c83ffefbdc1"
}
import {
  to = aws_subnet.web_02
  id = "subnet-0ee240e3df0bbb806"
}
import {
  to = aws_subnet.public_02
  id = "subnet-0dbd3f479eeb15420"
}
import {
  to = aws_subnet.web_01
  id = "subnet-00cf9ec7ae8b5ded6"
}
import {
  to = aws_subnet.was_01
  id = "subnet-09424e6b7917eb327"
}
import {
  to = aws_internet_gateway.main
  id = "igw-034c120f67e5e5bed"
}
import {
  to = aws_nat_gateway.main
  id = "nat-0b24c0ec71ac4a7a3"
}
import {
  to = aws_eip.nat
  id = "eipalloc-03e8359a8b90c3be5"
}
import {
  to = aws_route_table.private
  id = "rtb-08766b2358f9e9ff8"
}
import {
  to = aws_route_table_association.was_02
  id = "subnet-0f0b02150fab4bb3b/rtb-08766b2358f9e9ff8"
}
import {
  to = aws_route_table_association.was_01
  id = "subnet-09424e6b7917eb327/rtb-08766b2358f9e9ff8"
}
import {
  to = aws_route_table_association.web_02
  id = "subnet-0ee240e3df0bbb806/rtb-08766b2358f9e9ff8"
}
import {
  to = aws_route_table_association.web_01
  id = "subnet-00cf9ec7ae8b5ded6/rtb-08766b2358f9e9ff8"
}
import {
  to = aws_default_route_table.main
  id = "vpc-086bab7aac7afcbb4" # aws_default_route_table 은 VPC ID 로 import (main rtb-0e822aa18a9b5ad1d)
}
import {
  to = aws_route_table.public
  id = "rtb-0fe6f3b33e0a2ade1"
}
import {
  to = aws_route_table_association.public_02
  id = "subnet-0dbd3f479eeb15420/rtb-0fe6f3b33e0a2ade1"
}
import {
  to = aws_route_table_association.public_01
  id = "subnet-06c7b497b53efc74c/rtb-0fe6f3b33e0a2ade1"
}
import {
  to = aws_route_table.db
  id = "rtb-081e30eda25bc635d"
}
import {
  to = aws_route_table_association.db_02
  id = "subnet-091b40c83ffefbdc1/rtb-081e30eda25bc635d"
}
import {
  to = aws_route_table_association.db_01
  id = "subnet-0d1c43346ef0305de/rtb-081e30eda25bc635d"
}
import {
  to = aws_vpc_endpoint.ssm
  id = "vpce-0fb65af65b1a39033"
}
import {
  to = aws_vpc_endpoint.ssmmessages
  id = "vpce-09e91bc3ac8dda07c"
}
import {
  to = aws_vpc_endpoint.ec2messages
  id = "vpce-0ccc132985e0dadf0"
}
import {
  to = aws_vpc_endpoint.s3
  id = "vpce-06986501c33c45946"
}

# ---------------- security ----------------
import {
  to = aws_network_acl.public_acl
  id = "acl-035d806094e3f0449"
}
import {
  to = aws_network_acl.private_acl
  id = "acl-0806d33ae11451c5f"
}
import {
  to = aws_default_network_acl.default
  id = "acl-0d9888908ee91eb5e"
}
import {
  to = aws_security_group.bastion
  id = "sg-020c235d7f2ca46e0"
}
import {
  to = aws_security_group.redis
  id = "sg-0a0db4d8f2a30e0ef"
}
import {
  to = aws_security_group.db
  id = "sg-0da0952a87a601046"
}
import {
  to = aws_default_security_group.default
  id = "sg-0a4f33b6af4a36fd7"
}
import {
  to = aws_security_group.vpce_ssm
  id = "sg-0d7b7bcbe8cf7324a"
}
import {
  to = aws_security_group.web
  id = "sg-090541087ae489f84"
}
import {
  to = aws_security_group.was
  id = "sg-0b00a070406f462b6"
}
import {
  to = aws_security_group.ex_alb
  id = "sg-0c274503e8f72f9a5"
}
import {
  to = aws_security_group.in_alb
  id = "sg-0b9bb6e23f6684746"
}

# ---------------- compute ----------------
import {
  to = aws_eip.bastion
  id = "eipalloc-02ade032c09440fa7"
}
import {
  to = aws_instance.was1
  id = "i-096b9c4090b81f0f0"
}
import {
  to = aws_instance.web1
  id = "i-0640686af1bcd3002"
}
import {
  to = aws_instance.bastion
  id = "i-00243f310ea543f2d"
}
import {
  to = aws_instance.was_adm1
  id = "i-07a6c1b4525770b10"
}
import {
  to = aws_instance.web_adm1
  id = "i-0aab5eedc40f006e0"
}
import {
  to = aws_instance.db_active
  id = "i-088821e81bec61385"
}
import {
  to = aws_ebs_volume.enc_db_data
  id = "vol-0f30d7d0e32eddffe"
}
import {
  to = aws_volume_attachment.enc_db_data
  id = "/dev/sdf:vol-0f30d7d0e32eddffe:i-088821e81bec61385"
}
import {
  to = aws_key_pair.vuln_lab_key
  id = "vuln-lab-key"
}
import {
  to = aws_ebs_encryption_by_default.this
  id = "default"
}
import {
  to = aws_ebs_default_kms_key.this
  id = "arn:aws:kms:ap-northeast-2:${var.account_id}:key/fac1adb5-8f11-4b73-9a88-e0065ccacbab"
}

# ---------------- loadbalancing ----------------
import {
  to = aws_lb.in_alb
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:loadbalancer/app/in-alb/d7ed262c8bfdc271"
}
import {
  to = aws_lb.ex_alb
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:loadbalancer/app/ex-alb/7af7705c6215237b"
}
import {
  to = aws_lb_target_group.tg_was
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:targetgroup/tg-was/bf0fed11ee96642c"
}
import {
  to = aws_lb_target_group.tg_was_admin
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:targetgroup/tg-was-admin/c89cd7e019032181"
}
import {
  to = aws_lb_target_group.tg_web
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:targetgroup/tg-web/ed3be21399b9c4b6"
}
import {
  to = aws_lb_target_group.tg_web_admin
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:targetgroup/tg-web-admin/a044f46e4331bdf4"
}
import {
  to = aws_lb_listener.in_alb_8443
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener/app/in-alb/d7ed262c8bfdc271/1dad58f3cda0259e"
}
import {
  to = aws_lb_listener_rule.in_alb_8443_p10
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener-rule/app/in-alb/d7ed262c8bfdc271/1dad58f3cda0259e/eebe8a97abf3fea9"
}
import {
  to = aws_lb_listener.in_alb_443
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener/app/in-alb/d7ed262c8bfdc271/47c1e3b6d8d32e64"
}
import {
  to = aws_lb_listener_rule.in_alb_443_p1
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener-rule/app/in-alb/d7ed262c8bfdc271/47c1e3b6d8d32e64/3261c72eeea2b801"
}
import {
  to = aws_lb_listener_certificate.in_alb_443_extra1
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener/app/in-alb/d7ed262c8bfdc271/47c1e3b6d8d32e64_arn:aws:acm:ap-northeast-2:${var.account_id}:certificate/f9aa1776-e5e8-4621-8dc4-86e33c2b4e45"
}
import {
  to = aws_lb_listener_certificate.in_alb_443_extra2
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener/app/in-alb/d7ed262c8bfdc271/47c1e3b6d8d32e64_arn:aws:acm:ap-northeast-2:${var.account_id}:certificate/10c3f761-d890-4d59-b2ad-ed13ac4dd73e"
}
import {
  to = aws_lb_listener.ex_alb_80
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener/app/ex-alb/7af7705c6215237b/99c79c76bc3deaad"
}
import {
  to = aws_lb_listener.ex_alb_443
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener/app/ex-alb/7af7705c6215237b/9d90ff1235f7355d"
}
import {
  to = aws_lb_listener_rule.ex_alb_443_p10
  id = "arn:aws:elasticloadbalancing:ap-northeast-2:${var.account_id}:listener-rule/app/ex-alb/7af7705c6215237b/9d90ff1235f7355d/1bad370da39d50a5"
}
import {
  to = aws_acm_certificate.wildcard
  id = "arn:aws:acm:ap-northeast-2:${var.account_id}:certificate/f9aa1776-e5e8-4621-8dc4-86e33c2b4e45"
}
import {
  to = aws_acm_certificate.www
  id = "arn:aws:acm:ap-northeast-2:${var.account_id}:certificate/10c3f761-d890-4d59-b2ad-ed13ac4dd73e"
}
import {
  to = aws_route53_zone.main
  id = "Z04092922856I6CLWO23M"
}
import {
  to = aws_route53_record.apex_a
  id = "Z04092922856I6CLWO23M_zerodayclinic.p-e.kr_A"
}
import {
  to = aws_route53_record.admin_a
  id = "Z04092922856I6CLWO23M_admin.zerodayclinic.p-e.kr_A"
}
import {
  to = aws_route53_record.acmval_admin_cname
  id = "Z04092922856I6CLWO23M__6c25c2327227d988f7a3c11189ea178c.admin.zerodayclinic.p-e.kr_CNAME"
}
import {
  to = aws_route53_record.www_a
  id = "Z04092922856I6CLWO23M_www.zerodayclinic.p-e.kr_A"
}
import {
  to = aws_route53_record.acmval_www_cname
  id = "Z04092922856I6CLWO23M__f63c0a916846af5c70dc757c06f684f4.www.zerodayclinic.p-e.kr_CNAME"
}

# ---------------- storage ----------------
import {
  to = aws_s3_bucket.cloudtrail_logs
  id = "aws-cloudtrail-logs-${var.account_id}-425000b7"
}
import {
  to = aws_s3_bucket_server_side_encryption_configuration.cloudtrail_logs
  id = "aws-cloudtrail-logs-${var.account_id}-425000b7"
}
import {
  to = aws_s3_bucket_public_access_block.cloudtrail_logs
  id = "aws-cloudtrail-logs-${var.account_id}-425000b7"
}
import {
  to = aws_s3_bucket_policy.cloudtrail_logs
  id = "aws-cloudtrail-logs-${var.account_id}-425000b7"
}
import {
  to = aws_s3_bucket_logging.cloudtrail_logs
  id = "aws-cloudtrail-logs-${var.account_id}-425000b7"
}
import {
  to = aws_s3_bucket_ownership_controls.cloudtrail_logs
  id = "aws-cloudtrail-logs-${var.account_id}-425000b7"
}
import {
  to = aws_s3_bucket.vuln_lab_assets
  id = "vuln-lab-assets-54b7c81a"
}
import {
  to = aws_s3_bucket_versioning.vuln_lab_assets
  id = "vuln-lab-assets-54b7c81a"
}
import {
  to = aws_s3_bucket_server_side_encryption_configuration.vuln_lab_assets
  id = "vuln-lab-assets-54b7c81a"
}
import {
  to = aws_s3_bucket_public_access_block.vuln_lab_assets
  id = "vuln-lab-assets-54b7c81a"
}
import {
  to = aws_s3_bucket_policy.vuln_lab_assets
  id = "vuln-lab-assets-54b7c81a"
}
import {
  to = aws_s3_bucket_logging.vuln_lab_assets
  id = "vuln-lab-assets-54b7c81a"
}
import {
  to = aws_s3_bucket_ownership_controls.vuln_lab_assets
  id = "vuln-lab-assets-54b7c81a"
}
import {
  to = aws_s3_bucket.vuln_lab_backup
  id = "vuln-lab-backup"
}
import {
  to = aws_s3_bucket_server_side_encryption_configuration.vuln_lab_backup
  id = "vuln-lab-backup"
}
import {
  to = aws_s3_bucket_public_access_block.vuln_lab_backup
  id = "vuln-lab-backup"
}
import {
  to = aws_s3_bucket_policy.vuln_lab_backup
  id = "vuln-lab-backup"
}
import {
  to = aws_s3_bucket_logging.vuln_lab_backup
  id = "vuln-lab-backup"
}
import {
  to = aws_s3_bucket_ownership_controls.vuln_lab_backup
  id = "vuln-lab-backup"
}

# ---------------- logging ----------------
import {
  to = aws_flow_log.vpc
  id = "fl-01a5d5d2e6790d5f3"
}
import {
  to = aws_cloudtrail.zdtrail
  id = "arn:aws:cloudtrail:ap-northeast-2:${var.account_id}:trail/ZDtrail"
}
import {
  to = aws_cloudwatch_log_group.ec2_was1_windows_event
  id = "/ec2/was1/windows-event"
}
import {
  to = aws_cloudwatch_log_group.ec2_web1_windows_event
  id = "/ec2/web1/windows-event"
}
import {
  to = aws_cloudwatch_log_group.cloudtrail_manage_event
  id = "aws-cloudtrail-logs-manage_event"
}
import {
  to = aws_cloudwatch_log_group.aws_instance_logs
  id = "aws_instance_logs"
}
import {
  to = aws_kms_key.cloudwatch
  id = "468a8f29-a02e-48f5-8d0a-9c120bde084a"
}
import {
  to = aws_kms_alias.cloudwatch
  id = "alias/cloudwatch-kms"
}
import {
  to = aws_kms_key.cloudtrail
  id = "7529fb2d-1735-4fdb-b721-32a50723769f"
}
import {
  to = aws_kms_alias.cloudtrail
  id = "alias/zdclinic-3-cloudtrail"
}
import {
  to = aws_backup_plan.zd_backup
  id = "44e76592-339f-4d6d-af2a-19e012ba305b"
}
import {
  to = aws_backup_selection.zdclinic_ec2_backup
  id = "44e76592-339f-4d6d-af2a-19e012ba305b|dd44641b-7c2e-4d8f-b930-e5b014ad0154"
}
import {
  to = aws_config_configuration_recorder.default
  id = "default"
}
import {
  to = aws_config_configuration_recorder_status.default
  id = "default"
}
import {
  to = aws_config_delivery_channel.default
  id = "default"
}
import {
  to = aws_ssm_document.autodiag_dbms
  id = "AutoDiag-DBMS"
}
import {
  to = aws_ssm_document.autodiag_linux
  id = "AutoDiag-Linux"
}
import {
  to = aws_ssm_document.autodiag_windows
  id = "AutoDiag-Windows"
}

# ---------------- iam ----------------
import {
  to = aws_iam_instance_profile.ec2_app
  id = "vuln-lab-ec2-app-profile"
}
import {
  to = aws_iam_role.ec2_app
  id = "vuln-lab-ec2-app-role"
}
import {
  to = aws_iam_role_policy_attachment.ec2_app__cwagent
  id = "vuln-lab-ec2-app-role/arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
import {
  to = aws_iam_role_policy_attachment.ec2_app__ssm_core
  id = "vuln-lab-ec2-app-role/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
import {
  to = aws_iam_role_policy.ec2_app__diag_csv_s3
  id = "vuln-lab-ec2-app-role:diag-csv-s3"
}
import {
  to = aws_iam_role_policy.ec2_app__s3_app_access
  id = "vuln-lab-ec2-app-role:s3-app-access"
}
import {
  to = aws_iam_role.cloudtrail_cwlogs
  id = "CloudTrail_CloudWatchLogs_Role"
}
import {
  to = aws_iam_role_policy_attachment.cloudtrail_cwlogs__cw_access
  id = "CloudTrail_CloudWatchLogs_Role/arn:aws:iam::${var.account_id}:policy/service-role/Cloudtrail-CW-access-policy-ZDtrail-36bcec23-73f6-4043-a09b-90549f5fdf3e"
}
import {
  to = aws_iam_policy.cloudtrail_cw_access
  id = "arn:aws:iam::${var.account_id}:policy/service-role/Cloudtrail-CW-access-policy-ZDtrail-36bcec23-73f6-4043-a09b-90549f5fdf3e"
}
import {
  to = aws_iam_role.backup_default
  id = "AWSBackupDefaultServiceRole"
}
import {
  to = aws_iam_role_policy_attachment.backup_default__restores
  id = "AWSBackupDefaultServiceRole/arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}
import {
  to = aws_iam_role_policy_attachment.backup_default__backup
  id = "AWSBackupDefaultServiceRole/arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
