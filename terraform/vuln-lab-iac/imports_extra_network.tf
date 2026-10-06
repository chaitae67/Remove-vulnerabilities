# 네트워크 도메인 추가 import 블록
#   security.tf 에서 분리형으로 관리하는 SG 아웃바운드 규칙 (sgr-*)
#   (web / was / in_alb / ex_alb 의 egress - SG 상호 참조 순환 방지용)

import {
  to = aws_vpc_security_group_egress_rule.ex_alb_to_web
  id = "sgr-0f6996730bfb99c4d"
}

import {
  to = aws_vpc_security_group_egress_rule.web_http
  id = "sgr-06597a40efd560fbe"
}
import {
  to = aws_vpc_security_group_egress_rule.web_https
  id = "sgr-046ca964b548b2262"
}
import {
  to = aws_vpc_security_group_egress_rule.web_to_in_alb
  id = "sgr-08fd2e481ddb51bb1"
}

import {
  to = aws_vpc_security_group_egress_rule.in_alb_to_was
  id = "sgr-05f0e44b51e7ff2de"
}

import {
  to = aws_vpc_security_group_egress_rule.was_http
  id = "sgr-07a941c9efd08432a"
}
import {
  to = aws_vpc_security_group_egress_rule.was_https
  id = "sgr-0b329bef94384bf35"
}
import {
  to = aws_vpc_security_group_egress_rule.was_to_db
  id = "sgr-04dff3e15dd805b0b"
}
