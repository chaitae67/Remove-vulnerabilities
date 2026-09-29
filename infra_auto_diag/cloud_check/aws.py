#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AWS 클라우드 취약점 진단 (SK Shieldus 2024 클라우드 보안가이드 41항목).

READ-ONLY — describe_* / list_* / get_* 만 호출한다. 리소스를 변경하지 않는다.
필요 권한: AWS 관리형 정책 `SecurityAudit` (또는 ViewOnlyAccess) 수준.

자동 판정이 가능한 항목은 boto3 로 직접 확인하고,
업무 컨텍스트가 필요한 항목(1인 1계정, 불필요한 계정, 키 보관 위치 등)은
근거를 수집해 '수동확인'(보고서에선 '인터뷰 필요')으로 분류한다.
조회 권한이 없어 확인하지 못한 항목은 '양호'가 아니라 '수동확인'으로 둔다.
"""
import datetime

from .base import Reporter, safe, GOOD, VULN, NA, MAN
from .aws_items import ITEMS

_SENSITIVE_PORTS = {22: "SSH", 23: "Telnet", 3389: "RDP", 3306: "MySQL",
                    5432: "PostgreSQL", 6379: "Redis", 27017: "MongoDB",
                    1433: "MSSQL", 9200: "Elasticsearch", 11211: "Memcached",
                    2049: "NFS", 5900: "VNC", 137: "NetBIOS", 445: "SMB"}
_ADMIN_ARN = "arn:aws:iam::aws:policy/AdministratorAccess"
_AWS_POLICY_PREFIX = "arn:aws:iam::aws:policy/"
_ANY4, _ANY6 = "0.0.0.0/0", "::/0"

# 1.3 사용자 식별 태그로 인정하는 키(부분 일치, 소문자 비교)
_ID_TAG_HINTS = ("name", "mail", "dept", "department", "team", "owner", "employee",
                 "이름", "성명", "이메일", "메일", "부서", "소속", "사번")

# 2.x — 서비스 역할의 신뢰 주체(서비스)로 분류, 액션 접두어로 서비스 전체권한 근거 수집
_INSTANCE_TRUST = {"ec2", "ecs", "ecs-tasks", "eks", "eks-fargate-pods", "eks-nodegroup",
                   "ecr", "elasticfilesystem", "rds", "s3"}
_NETWORK_TRUST = {"apigateway", "vpc-flow-logs", "cloudfront", "route53", "directconnect",
                  "appmesh", "servicediscovery", "elasticloadbalancing", "globalaccelerator"}
_CAT_ACTIONS = {
    "2.1": ("인스턴스 서비스", {"ec2", "ecs", "ecr", "eks", "elasticfilesystem", "rds", "s3"}),
    "2.2": ("네트워크 서비스", {"ec2", "cloudfront", "route53", "apigateway", "directconnect",
                          "appmesh", "servicediscovery"}),
    "2.3": ("기타 서비스", {"organizations", "cloudwatch", "logs", "autoscaling", "cloudformation",
                        "cloudtrail", "config", "ssm", "guardduty", "inspector", "inspector2",
                        "sso", "acm", "kms", "waf", "wafv2", "waf-regional", "shield",
                        "securityhub", "datapipeline", "glue", "kafka", "backup"}),
}


def _session(creds):
    import boto3
    mode = (creds.get("mode") or "").lower()
    if mode == "profile" and creds.get("profile"):
        return boto3.Session(profile_name=creds["profile"],
                             region_name=creds.get("region") or None)
    if creds.get("access_key") and creds.get("secret_key"):
        return boto3.Session(
            aws_access_key_id=creds["access_key"],
            aws_secret_access_key=creds["secret_key"],
            aws_session_token=creds.get("session_token") or None,
            region_name=creds.get("region") or "us-east-1")
    # 환경 자격증명(EC2 role / env / ~/.aws) 사용
    return boto3.Session(region_name=creds.get("region") or None)


def _regions(sess):
    import os
    # 기본은 세션(지정) 리전만 조회 → 빠름. 전 리전 스캔은 CLOUD_SCAN_ALL_REGIONS=1 로 opt-in.
    if str(os.environ.get("CLOUD_SCAN_ALL_REGIONS", "")).lower() not in ("1", "true", "yes", "all"):
        if sess.region_name:
            return [sess.region_name]
    try:
        ec2 = sess.client("ec2", region_name="us-east-1")
        rs = [r["RegionName"] for r in ec2.describe_regions(AllRegions=False)["Regions"]]
        return rs or [sess.region_name or "us-east-1"]
    except Exception:
        return [sess.region_name or "us-east-1"]


_DENY_MARKERS = ("AccessDenied", "UnauthorizedOperation", "AuthorizationError",
                 "OptInRequired", "not authorized")


def _is_denied(e):
    s = f"{type(e).__name__} {e}"
    return any(m in s for m in _DENY_MARKERS)


def _pages(client, op, key, **kw):
    """목록 조회 — 페이지네이션을 지원하는 API 는 끝까지 모은다(IAM 100건 제한 등 누락 방지)."""
    if client.can_paginate(op):
        out = []
        for page in client.get_paginator(op).paginate(**kw):
            out.extend(page.get(key, []))
        return out
    return getattr(client, op)(**kw).get(key, [])


def _each_region(sess, regions, service, fn):
    """모든 대상 리전에서 fn(client, region) 을 호출해 리스트를 합친다.

    권한 오류가 '모든' 리전에서 나면 PermissionError 로 올려 safe() 가 수동확인 처리한다.
    리전별 서비스 미지원(EndpointConnectionError 등)은 조용히 건너뛴다.
    """
    out, denied, ok = [], 0, 0
    for r in regions:
        try:
            out.extend(fn(sess.client(service, region_name=r), r) or [])
            ok += 1
        except Exception as e:
            if _is_denied(e):
                denied += 1
            # 그 외(리전 미지원 등)는 skip
    if denied and ok == 0:
        raise PermissionError(f"{service}: 모든 리전에서 권한 부족으로 조회 불가")
    return out


# ---- IAM 정책 문서 해석 ----------------------------------------------------------
def _as_list(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def _statements(doc):
    if not isinstance(doc, dict):
        return []
    st = doc.get("Statement", [])
    return [st] if isinstance(st, dict) else [s for s in st if isinstance(s, dict)]


def _doc_admin(doc):
    """Allow + Action "*" + Resource "*" 가 있으면 관리자(전체권한) 정책."""
    for st in _statements(doc):
        if st.get("Effect") == "Allow" and "*" in _as_list(st.get("Action")) \
                and "*" in _as_list(st.get("Resource")):
            return True
    return False


def _doc_wildcards(doc):
    """Resource "*" 에 대해 '서비스:*' 로 허용된 서비스 접두어 집합(관리자는 아니지만 서비스 전체권한)."""
    out = set()
    for st in _statements(doc):
        if st.get("Effect") != "Allow" or "*" not in _as_list(st.get("Resource")):
            continue
        for a in _as_list(st.get("Action")):
            if ":" in a and a.endswith(":*"):
                out.add(a.split(":", 1)[0].lower())
    return out


def _trusted_services(role):
    """역할 신뢰 정책의 서비스 주체 접두어(ec2, lambda ...). Principal 이 "*" 문자열이어도 안전."""
    doc = role.get("AssumeRolePolicyDocument") or {}
    if isinstance(doc, str):
        import json
        import urllib.parse
        try:
            doc = json.loads(urllib.parse.unquote(doc))
        except Exception:
            doc = {}
    out = set()
    for st in _statements(doc):
        pr = st.get("Principal")
        if isinstance(pr, dict):
            for s in _as_list(pr.get("Service")):
                out.add(str(s).split(".", 1)[0].lower())
    return out


class _IamView:
    """IAM 주체(사용자/그룹/역할)의 연결 정책을 한 번씩만 조회해 분석한다(1.1 / 2.x / 4.8 공용)."""

    def __init__(self, iam):
        self.iam = iam
        self._docs, self._groups = {}, {}
        self._users = self._roles = None

    def managed_doc(self, arn):
        if arn not in self._docs:
            p = self.iam.get_policy(PolicyArn=arn)["Policy"]
            v = self.iam.get_policy_version(PolicyArn=arn, VersionId=p["DefaultVersionId"])
            self._docs[arn] = v["PolicyVersion"]["Document"]
        return self._docs[arn]

    def analyze(self, attached, inline):
        """attached=[정책 ARN], inline=[(이름, 문서)] → 관리자/고위험/FullAccess/서비스 전체권한 분류."""
        a = {"admin": [], "high": [], "full": [], "wild": set(), "names": set(), "docs": []}
        for arn in attached:
            name = arn.split("/")[-1]
            a["names"].add(name)
            if arn == _ADMIN_ARN:
                a["admin"].append("AdministratorAccess")
            elif arn.startswith(_AWS_POLICY_PREFIX):
                if name == "IAMFullAccess":
                    a["high"].append(name)          # 스스로 권한 상승이 가능한 고위험 권한
                elif name.endswith("FullAccess") or name == "PowerUserAccess":
                    a["full"].append(name)
            else:                                    # 고객 관리형 — 문서까지 확인
                doc = self.managed_doc(arn)
                a["docs"].append(doc)
                if _doc_admin(doc):
                    a["admin"].append(f"{name}(고객관리형 *:*)")
                a["wild"] |= _doc_wildcards(doc)
        for pname, doc in inline:
            a["docs"].append(doc)
            if _doc_admin(doc):
                a["admin"].append(f"{pname}(인라인 *:*)")
            a["wild"] |= _doc_wildcards(doc)
        return a

    def group(self, gname):
        if gname not in self._groups:
            iam = self.iam
            att = [p["PolicyArn"] for p in
                   _pages(iam, "list_attached_group_policies", "AttachedPolicies", GroupName=gname)]
            inl = [(p, iam.get_group_policy(GroupName=gname, PolicyName=p)["PolicyDocument"])
                   for p in _pages(iam, "list_group_policies", "PolicyNames", GroupName=gname)]
            self._groups[gname] = self.analyze(att, inl)
        return self._groups[gname]

    def users(self):
        if self._users is None:
            iam, out = self.iam, []
            for u in _pages(iam, "list_users", "Users"):
                n = u["UserName"]
                att = [p["PolicyArn"] for p in
                       _pages(iam, "list_attached_user_policies", "AttachedPolicies", UserName=n)]
                inl = [(p, iam.get_user_policy(UserName=n, PolicyName=p)["PolicyDocument"])
                       for p in _pages(iam, "list_user_policies", "PolicyNames", UserName=n)]
                groups = [g["GroupName"] for g in
                          _pages(iam, "list_groups_for_user", "Groups", UserName=n)]
                out.append({"name": n, "own": self.analyze(att, inl),
                            "group_a": {g: self.group(g) for g in groups}})
            self._users = out
        return self._users

    def roles(self):
        if self._roles is None:
            iam, out = self.iam, []
            for r in _pages(iam, "list_roles", "Roles"):
                n = r["RoleName"]
                if r.get("Path", "").startswith("/aws-service-role/") or n.startswith("AWSServiceRoleFor"):
                    continue                         # 서비스 연결 역할(AWS 관리)은 제외
                att = [p["PolicyArn"] for p in
                       _pages(iam, "list_attached_role_policies", "AttachedPolicies", RoleName=n)]
                inl = [(p, iam.get_role_policy(RoleName=n, PolicyName=p)["PolicyDocument"])
                       for p in _pages(iam, "list_role_policies", "PolicyNames", RoleName=n)]
                out.append({"name": n, "trust": _trusted_services(r), "a": self.analyze(att, inl)})
            self._roles = out
        return self._roles


# ---- 공용 조회(캐시) --------------------------------------------------------------
def _trails(ctx):
    """스캔 리전에서 보이는 CloudTrail 추적(다른 리전을 홈으로 둔 멀티리전 추적 포함, ARN 기준 중복 제거)."""
    c = ctx["cache"]
    if "trails" not in c:
        seen = {}
        for r in ctx["regions"]:
            try:
                ct = ctx["sess"].client("cloudtrail", region_name=r)
                for t in ct.describe_trails(includeShadowTrails=True)["trailList"]:
                    seen.setdefault(t["TrailARN"], t)
            except Exception as e:
                if _is_denied(e):
                    raise
        c["trails"] = list(seen.values())
    return c["trails"]


def _elbv2(ctx, r):
    c = ctx["cache"].setdefault("elbv2", {})
    if r not in c:
        cli = ctx["sess"].client("elbv2", region_name=r)
        c[r] = (cli, _pages(cli, "describe_load_balancers", "LoadBalancers"))
    return c[r]


def _classic_elbs(ctx, r):
    c = ctx["cache"].setdefault("elb", {})
    if r not in c:
        cli = ctx["sess"].client("elb", region_name=r)
        c[r] = (cli, _pages(cli, "describe_load_balancers", "LoadBalancerDescriptions"))
    return c[r]


def _lb_attrs(ctx, cli, arn):
    c = ctx["cache"].setdefault("lb_attrs", {})
    if arn not in c:
        c[arn] = {a["Key"]: a["Value"] for a in
                  cli.describe_load_balancer_attributes(LoadBalancerArn=arn)["Attributes"]}
    return c[arn]


def _listeners(ctx, cli, arn):
    c = ctx["cache"].setdefault("listeners", {})
    if arn not in c:
        c[arn] = _pages(cli, "describe_listeners", "Listeners", LoadBalancerArn=arn)
    return c[arn]


def _ssl_protocols(ctx, cli, policy):
    c = ctx["cache"].setdefault("sslpol", {})
    if policy not in c:
        try:
            p = cli.describe_ssl_policies(Names=[policy])["SslPolicies"]
            c[policy] = set(p[0].get("SslProtocols", [])) if p else set()
        except Exception as e:
            if _is_denied(e):
                raise
            c[policy] = set()
    return c[policy]


def _sg_peers(perm):
    """보안그룹 규칙의 상대방 목록 [(표기, 인터넷여부)] — CIDR/IPv6/SG 참조/Prefix List."""
    out = []
    for ip in perm.get("IpRanges", []):
        out.append((ip.get("CidrIp"), ip.get("CidrIp") == _ANY4))
    for ip in perm.get("Ipv6Ranges", []):
        out.append((ip.get("CidrIpv6"), ip.get("CidrIpv6") == _ANY6))
    for g in perm.get("UserIdGroupPairs", []):
        out.append((f"SG:{g.get('GroupId')}", False))
    for p in perm.get("PrefixListIds", []):
        out.append((f"PL:{p.get('PrefixListId')}", False))
    return out


def _cap(lines, n=40):
    return lines[:n] + ([f"... 외 {len(lines) - n}건"] if len(lines) > n else [])


def _route_target(route):
    return (route.get("GatewayId") or route.get("NatGatewayId") or route.get("TransitGatewayId")
            or route.get("VpcPeeringConnectionId") or route.get("InstanceId")
            or route.get("NetworkInterfaceId") or route.get("EgressOnlyInternetGatewayId")
            or route.get("VpcEndpointId") or route.get("LocalGatewayId")
            or route.get("CarrierGatewayId") or route.get("CoreNetworkArn") or "?")


# 라우팅 대상 중 게이트웨이(IGW·NAT·송신전용 IGW·VGW·TGW·로컬/캐리어 게이트웨이·Cloud WAN 코어 네트워크)
_GATEWAY_TARGETS = ("igw-", "nat-", "eigw-", "vgw-", "tgw-", "lgw-", "cagw-", "arn:aws:networkmanager:")


def _vpc_net(ctx, r):
    """리전별 VPC 네트워크 구성(라우팅 테이블·서브넷·인스턴스·RDS 배치) — 3.5/3.6 공용 캐시.

    rt_of: 서브넷 -> 적용 라우팅 테이블(명시 연결이 없으면 VPC 기본 테이블)
    rds_in: 서브넷 -> RDS 식별자(서브넷 그룹 기준). RDS 조회 권한이 없으면 None.
    """
    c = ctx["cache"].setdefault("vpcnet", {})
    if r not in c:
        sess = ctx["sess"]
        ec2 = sess.client("ec2", region_name=r)
        rts = _pages(ec2, "describe_route_tables", "RouteTables")
        subnets = {s["SubnetId"]: s for s in _pages(ec2, "describe_subnets", "Subnets")}
        insts = [i for resv in _pages(ec2, "describe_instances", "Reservations",
                                      Filters=[{"Name": "instance-state-name",
                                                "Values": ["running", "stopped"]}])
                 for i in resv["Instances"]]
        rds_in = {}
        try:
            for db in _pages(sess.client("rds", region_name=r), "describe_db_instances", "DBInstances"):
                for s in (db.get("DBSubnetGroup") or {}).get("Subnets", []):
                    rds_in.setdefault(s["SubnetIdentifier"], []).append(db["DBInstanceIdentifier"])
        except Exception as e:
            if not _is_denied(e):
                raise
            rds_in = None
        main_rt, explicit = {}, {}
        for rt in rts:
            for a in rt.get("Associations", []):
                if a.get("Main"):
                    main_rt[rt.get("VpcId")] = rt["RouteTableId"]
                elif a.get("SubnetId"):
                    explicit[a["SubnetId"]] = rt["RouteTableId"]
        rt_of = {sid: explicit.get(sid) or main_rt.get(s.get("VpcId")) for sid, s in subnets.items()}
        c[r] = {"rts": rts, "subnets": subnets, "insts": insts, "rds_in": rds_in, "rt_of": rt_of}
    return c[r]


_S3_PAB_KEYS = ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")


def _bucket_exposure(s3, name):
    """(상태, 사유) — blocked: 퍼블릭 액세스 차단 / public: 모든 사람·외부 계정에 공개 / private."""
    try:
        pab = s3.get_public_access_block(Bucket=name)["PublicAccessBlockConfiguration"]
        if all(pab.get(k) for k in _S3_PAB_KEYS):
            return "blocked", "버킷 퍼블릭 액세스 차단"
    except Exception as e:
        if _is_denied(e) or "NoSuchPublicAccessBlockConfiguration" not in str(e):
            raise
    try:
        if s3.get_bucket_policy_status(Bucket=name)["PolicyStatus"].get("IsPublic"):
            return "public", "버킷 정책 public"
    except Exception as e:
        if _is_denied(e) or "NoSuchBucketPolicy" not in str(e):
            raise
    acl = s3.get_bucket_acl(Bucket=name)
    owner = acl.get("Owner", {}).get("ID")
    for g in acl.get("Grants", []):
        gr = g.get("Grantee", {})
        uri = gr.get("URI", "")
        if "AllUsers" in uri or "AuthenticatedUsers" in uri:
            return "public", f"ACL {uri.split('/')[-1]}: {g.get('Permission')}"
        if gr.get("Type") == "CanonicalUser" and owner and gr.get("ID") != owner:
            return "public", f"ACL 외부 계정 {gr.get('ID', '')[:12]}…: {g.get('Permission')}"
    return "private", ""


def _s3_exposure(ctx):
    """버킷별 노출 상태 {이름: (상태, 사유)}, 계정 PAB 메모, 계정 PAB 전체 차단 여부 — 3.7·1.6 공용 캐시.
    외부 계정 ACL 공유도 '다수 접근 가능'으로 보아 public 으로 분류한다. 판정 못 한 버킷은 unknown."""
    c = ctx["cache"]
    if "s3exp" not in c:
        sess = ctx["sess"]
        s3 = sess.client("s3")
        names = [b["Name"] for b in s3.list_buckets()["Buckets"]]
        note, acct_all = [], False
        try:
            s3c = sess.client("s3control", region_name=sess.region_name or "us-east-1")
            acfg = s3c.get_public_access_block(AccountId=ctx["acct"])["PublicAccessBlockConfiguration"]
            acct_all = all(acfg.get(k) for k in _S3_PAB_KEYS)
            if not acct_all:
                note.append("계정 수준 퍼블릭 액세스 차단: 일부만 설정")
        except Exception as e:
            if _is_denied(e):
                note.append("계정 수준 퍼블릭 액세스 차단 조회 권한 없음(s3:GetAccountPublicAccessBlock)")
            elif "NoSuchPublicAccessBlockConfiguration" in str(e):
                note.append("계정 수준 퍼블릭 액세스 차단: 미설정")
            else:
                note.append(f"계정 수준 퍼블릭 액세스 차단 조회 실패({type(e).__name__})")
        res = {}
        for name in names:
            if acct_all:
                res[name] = ("blocked", "계정 수준 퍼블릭 액세스 차단")
                continue
            try:
                res[name] = _bucket_exposure(s3, name)
            except Exception as e:
                if _is_denied(e):
                    raise
                res[name] = ("unknown", type(e).__name__)
        c["s3exp"] = (res, note, acct_all)
    return c["s3exp"]


_KEY_EXT = (".pem", ".ppk", ".key")
_KEY_NAMES = ("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")


def _key_files(s3, bucket, cap=20000):
    """버킷에서 키 파일로 보이는 객체 키 목록과 검사 상한 도달 여부. 객체 내용은 읽지 않는다.
    인증서로 보이는 이름(cert/chain/public, ca*)은 제외한다."""
    hits, n = [], 0
    pages = (s3.get_paginator("list_objects_v2").paginate(Bucket=bucket)
             if s3.can_paginate("list_objects_v2") else [s3.list_objects_v2(Bucket=bucket)])
    for page in pages:
        for o in page.get("Contents", []):
            n += 1
            base = o["Key"].rsplit("/", 1)[-1].lower()
            if (base.endswith(_KEY_EXT) or base in _KEY_NAMES) and not (
                    any(t in base for t in ("cert", "chain", "public")) or base.startswith("ca")):
                hits.append(o["Key"])
            if n >= cap:
                return hits, True
    return hits, False


# ----------------------------------------------------------------------------
def run(creds):
    sess = _session(creds)
    rep = Reporter(ITEMS)

    # 계정 식별자 — 자격증명이 유효하지 않으면 여기서 중단(엉뚱한 결과 방지)
    try:
        ident = sess.client("sts").get_caller_identity()
        acct = ident.get("Account", "unknown")
    except Exception as e:
        raise RuntimeError(
            "AWS 자격증명이 유효하지 않거나 만료되었습니다. "
            f"Access Key / Secret / 리전 / 프로필을 확인하세요.\n({type(e).__name__}: {e})")

    iam = sess.client("iam")
    regions = _regions(sess)
    ctx = {"sess": sess, "iam": iam, "acct": acct, "regions": regions,
           "view": _IamView(iam), "cache": {}}
    # ---- 자격증명 보고서(1회 생성) : 1.7 / 1.8 / 1.9 공용. 실패하면 err 에 사유 ----
    ctx["cred_rows"], ctx["cred_err"] = _get_credential_report(iam)

    _account_mgmt(rep, ctx)
    _permission_mgmt(rep, ctx)
    _virtual_resource(rep, ctx)
    _operation_mgmt(rep, ctx)

    rep.fill_missing(MAN, "이번 버전에서 자동 점검 미지원 → 콘솔에서 수동 확인 필요")

    scope = ", ".join(regions) if len(regions) <= 3 else f"전 리전 {len(regions)}개"
    return {
        "host": f"AWS 계정 {acct} (리전: {scope})",
        "os": "AWS",
        "family": "cloud",
        "results": rep.results(),
    }


def _get_credential_report(iam):
    """(행 목록, None) 또는 (None, 실패사유). 실패를 빈 목록으로 숨기지 않는다(거짓 양호 방지)."""
    import time
    try:
        for _ in range(10):
            try:
                raw = iam.get_credential_report()["Content"].decode("utf-8", "replace")
                break
            except (iam.exceptions.CredentialReportNotPresentException,
                    iam.exceptions.CredentialReportExpiredException):
                iam.generate_credential_report()
                time.sleep(2)
            except iam.exceptions.CredentialReportNotReadyException:
                time.sleep(2)
        else:
            return None, "자격증명 보고서 생성 대기 시간 초과"
        lines = raw.splitlines()
        hdr = lines[0].split(",")
        rows = [dict(zip(hdr, ln.split(","))) for ln in lines[1:]]
        if not rows:
            return None, "자격증명 보고서가 비어 있음"
        return rows, None
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"


# ============================ 1. 계정 관리 ============================
def _account_mgmt(rep, ctx):
    sess, iam, view = ctx["sess"], ctx["iam"], ctx["view"]
    rows, cerr = ctx["cred_rows"], ctx["cred_err"]

    def cred_unavailable(code):
        rep.man(code, "IAM 자격증명 보고서를 조회할 수 없어 판정 불가 → 수동 확인 필요 "
                      "(iam:GenerateCredentialReport / iam:GetCredentialReport 권한 확인). "
                      f"사유: {cerr}")

    # 1.1 사용자 계정 관리 — 관리자급 권한 다수 여부 + (불필요 계정은 인터뷰)
    def c11():
        users = view.users()
        admins, full = [], []
        for u in users:
            src = u["own"]["admin"] + u["own"]["high"]
            for g, ga in u["group_a"].items():
                src += [f"{x}@그룹:{g}" for x in ga["admin"] + ga["high"]]
            if src:
                admins.append((u["name"], f"{u['name']}({', '.join(src)})"))
                continue
            fl = u["own"]["full"] + [f"{x}@그룹:{g}" for g, ga in u["group_a"].items()
                                     for x in ga["full"]]
            if fl:
                full.append(f"{u['name']}({', '.join(fl)})")
        ev = [f"IAM 사용자 {len(users)}명, 관리자급 권한(AdministratorAccess·IAMFullAccess·"
              f"*:* 정책, 그룹 경유 포함) 보유 {len(admins)}명"] + [a[1] for a in admins]
        if full:
            ev.append("서비스 FullAccess/PowerUser 보유(관리자급 아님, 적정성 검토): " + "; ".join(full))
        suspect = [u["name"] for u in users
                   if any(k in u["name"].lower() for k in ("test", "temp", "tmp", "guest", "demo"))]
        if suspect:
            ev.append("테스트/임시 계정 의심(이름 기준): " + ", ".join(suspect))
        ev.append("불필요 계정(협력사 공용/퇴직·휴직자) 존재 여부는 담당자 인터뷰로 확인 필요")
        names = [a[0] for a in admins]
        (rep.vuln if len(admins) >= 2 else rep.man)("1.1", ev, names)
    safe(rep, "1.1", c11)

    # 1.2 1인 1계정 — API로 판단 불가
    def c12():
        users = [u["UserName"] for u in _pages(iam, "list_users", "Users")]
        rep.man("1.2", [f"IAM 사용자 {len(users)}명: {', '.join(users)}",
                        "동일 담당자가 복수 계정을 보유하는지(서비스별 계정 생성 포함)는 인터뷰로 확인 필요"],
                users)
    safe(rep, "1.2", c12)

    # 1.3 IAM 사용자 식별 태그(이름/이메일/부서 등)
    def c13():
        users = _pages(iam, "list_users", "Users")
        if not users:
            rep.na("1.3", "IAM 사용자 없음")
            return
        bad = []
        for u in users:
            keys = [t["Key"] for t in _pages(iam, "list_user_tags", "Tags", UserName=u["UserName"])]
            if not any(h in k.lower() for k in keys for h in _ID_TAG_HINTS):
                bad.append((u["UserName"], f"{u['UserName']}(태그: {', '.join(keys) if keys else '없음'})"))
        note = "※ AWS Organizations·AD 연동으로 사용자를 관리하면 태그가 없어도 양호로 볼 수 있음(가이드 비고)"
        if bad:
            rep.vuln("1.3", ["사용자 식별 태그(이름/이메일/부서 등)가 없는 IAM 사용자:"]
                     + [b[1] for b in bad] + [note], [b[0] for b in bad])
        else:
            rep.good("1.3", f"IAM 사용자 {len(users)}명 모두 식별 태그(이름/이메일/부서 등) 설정됨")
    safe(rep, "1.3", c13)

    # 1.4 IAM 그룹 구성원 관리 — 인터뷰
    def c14():
        groups = _pages(iam, "list_groups", "Groups")
        lines = []
        for g in groups:
            m = [u["UserName"] for u in _pages(iam, "get_group", "Users", GroupName=g["GroupName"])]
            lines.append(f"{g['GroupName']}: {', '.join(m) if m else '(구성원 없음)'}")
        if not groups:
            rep.na("1.4", "IAM 그룹 없음")
            return
        rep.man("1.4", ["IAM 그룹/구성원 현황 — 불필요 계정 포함 여부 인터뷰 확인:"] + lines,
                [g["GroupName"] for g in groups])
    safe(rep, "1.4", c14)

    # 1.5 Key Pair 접근 관리 — EC2 접속 방식
    def c15():
        no_key, total = [], 0
        for r in ctx["regions"]:
            ec2 = sess.client("ec2", region_name=r)
            for resv in _pages(ec2, "describe_instances", "Reservations",
                               Filters=[{"Name": "instance-state-name",
                                         "Values": ["running", "stopped"]}]):
                for i in resv["Instances"]:
                    total += 1
                    if not i.get("KeyName"):
                        no_key.append(f"{i['InstanceId']}({r})")
        if total == 0:
            rep.na("1.5", "EC2 인스턴스 없음")
        elif no_key:
            rep.man("1.5", [f"EC2 {total}대 중 Key Pair 미지정 {len(no_key)}대: {', '.join(no_key)}",
                            "SSM/패스워드 등 대체 접속 수단 여부 인터뷰 확인"], no_key)
        else:
            rep.good("1.5", f"EC2 {total}대 모두 Key Pair(PEM) 기반 접속")
    safe(rep, "1.5", c15)

    # 1.6 Key Pair 보관 관리 — PC·공유폴더·EC2 내부 보관 위치는 API 로 알 수 없어 인터뷰.
    #   단, 다수 접근이 가능한 버킷(퍼블릭/외부 계정 공유)에서 키 파일이 발견되면 취약으로 판정한다.
    def c16():
        res, _note, _acct_all = _s3_exposure(ctx)
        s3 = sess.client("s3")
        exposed, kept, unknown, partial = [], [], [], []
        for name, (st, why) in res.items():
            try:
                hits, cut = _key_files(s3, name)
            except Exception as e:
                unknown.append(f"{name}({'권한 없음' if _is_denied(e) else type(e).__name__})")
                continue
            if cut:
                partial.append(name)
            if not hits:
                continue
            line = f"{name}: {', '.join(hits[:5])}" + (f" 외 {len(hits) - 5}개" if len(hits) > 5 else "")
            if st == "public":
                exposed.append(f"{line} [{why}]")
            else:
                kept.append(line + (" [공개 여부 확인 불가]" if st == "unknown" else ""))
        ev = [f"S3 버킷 {len(res)}개에서 키 파일(*.pem·*.ppk·*.key·id_rsa 등, 인증서 이름 제외) 검색"]
        if kept:
            ev += ["비공개 버킷에 보관된 키 파일(가이드 권장: 프라이빗 S3):"] + kept
        if partial:
            ev.append("객체가 많아 일부만 검사한 버킷: " + ", ".join(partial))
        if unknown:
            ev.append("객체 목록 조회 불가(s3:ListBucket): " + ", ".join(unknown))
        if exposed:
            rep.vuln("1.6", ["다수 접근이 가능한 버킷(퍼블릭/외부 계정 공유)에 키 파일 보관:"] + exposed + ev,
                     [e.split(":")[0] for e in exposed])
        else:
            rep.man("1.6", ev + ["PC·공유폴더·EC2 루트(/) 디렉터리 등 S3 외 보관 위치는 담당자 인터뷰로 확인"])
    safe(rep, "1.6", c16)

    # 1.7 Admin Console(root) 서비스 용도 사용
    def c17():
        if cerr:
            cred_unavailable("1.7")
            return
        root = next((r for r in rows if r.get("user") == "<root_account>"), None)
        ev, vuln = [], False
        if root:
            if root.get("access_key_1_active") == "true" or root.get("access_key_2_active") == "true":
                ev.append("루트 계정에 활성 Access Key 존재 → 서비스/CLI 용도 사용 의심")
                vuln = True
            ev.append(f"루트 마지막 콘솔 사용: {root.get('password_last_used') or 'N/A'}")
        ev.append("루트 계정의 리소스 생성·변경 이력은 CloudTrail 로 추가 확인 필요")
        (rep.vuln if vuln else rep.man)("1.7", ev)
    safe(rep, "1.7", c17)

    # 1.8 루트 Access Key + IAM Access Key 사용주기(60일)
    def c18():
        if cerr:
            cred_unavailable("1.8")
            return
        vuln, idle = [], []
        now = datetime.datetime.now(datetime.timezone.utc)

        def age(ts):
            try:
                return (now - datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))).days
            except Exception:
                return None
        for r in rows:
            u = r.get("user")
            if u == "<root_account>":
                if r.get("access_key_1_active") == "true" or r.get("access_key_2_active") == "true":
                    vuln.append("root Access Key 존재")
                continue
            for idx in ("1", "2"):
                if r.get(f"access_key_{idx}_active") != "true":
                    continue
                a = age(r.get(f"access_key_{idx}_last_rotated", ""))
                if a is not None and a > 60:
                    vuln.append(f"{u} key{idx} {a}일 경과 (기준 60일)")
                used = age(r.get(f"access_key_{idx}_last_used_date", ""))
                if used is not None and used > 30:
                    idle.append(f"{u} key{idx} 마지막 사용 {used}일 전")
        tail = (["참고: 마지막 활동 30일 초과 키(가이드 관리주기 기준) — " + ", ".join(idle)]
                if idle else [])
        if vuln:
            rep.vuln("1.8", ["Access Key 사용주기 미관리:"] + vuln + tail, vuln)
        else:
            rep.good("1.8", ["루트 Access Key 없음 + IAM Access Key 60일 이내 교체"] + tail)
    safe(rep, "1.8", c18)

    # 1.9 MFA
    def c19():
        if cerr:
            cred_unavailable("1.9")
            return
        vuln = []
        for r in rows:
            u = r.get("user")
            if u == "<root_account>":
                if r.get("mfa_active") != "true":
                    vuln.append("root 계정 MFA 미설정")
                continue
            if r.get("password_enabled") == "true" and r.get("mfa_active") != "true":
                vuln.append(f"{u} (콘솔 로그인 가능, MFA 미설정)")
        tail = []
        try:
            if sess.client("sso-admin").list_instances().get("Instances"):
                tail.append("IAM Identity Center(SSO) 사용 중 — SSO 로그인 사용자의 MFA 는 Identity Center "
                            "설정에서 확인(가이드 비고: SSO 인증 사용 시 양호 처리 가능)")
        except Exception:
            pass
        if vuln:
            rep.vuln("1.9", ["MFA 미설정:"] + vuln + tail, vuln)
        else:
            rep.good("1.9", ["루트 및 콘솔 사용 IAM 계정 모두 MFA 활성"] + tail)
    safe(rep, "1.9", c19)

    # 1.10 패스워드 정책
    def c110():
        try:
            p = iam.get_account_password_policy()["PasswordPolicy"]
        except iam.exceptions.NoSuchEntityException:
            rep.vuln("1.10", "계정 암호 정책이 설정되어 있지 않음")
            return
        bad = []
        minlen = p.get("MinimumPasswordLength", 0)
        classes = sum(bool(p.get(k)) for k in ("RequireSymbols", "RequireNumbers",
                      "RequireUppercaseCharacters", "RequireLowercaseCharacters"))
        # 가이드 복잡성: 문자 3종 이상 조합 시 8자 이상, 2종 조합 시 10자 이상
        if classes >= 3:
            if minlen < 8:
                bad.append(f"최소길이 {minlen}(3종 조합 시 8자 이상 필요)")
        elif classes == 2:
            if minlen < 10:
                bad.append(f"최소길이 {minlen}(2종 조합 시 10자 이상 필요)")
        else:
            bad.append(f"문자 조합 {classes}종(최소 2종 이상 필요)")
        if not p.get("MaxPasswordAge"):
            bad.append("만료기간 미설정")
        elif p.get("MaxPasswordAge", 999) > 90:
            bad.append(f"만료 {p.get('MaxPasswordAge')}일(>90)")
        if not p.get("PasswordReusePrevention"):
            bad.append("재사용 제한 미설정")
        if bad:
            rep.vuln("1.10", "암호 정책 미흡: " + ", ".join(bad))
        else:
            rep.good("1.10", "복잡성/만료/재사용 제한 정책 설정됨")
    safe(rep, "1.10", c110)

    # 1.11 ~ 1.13 EKS (kubectl 필요)
    _eks_manual(rep, ctx, ["1.11", "1.12", "1.13"])


# ============================ 2. 권한 관리 ============================
def _permission_mgmt(rep, ctx):
    view = ctx["view"]

    def cat_of(role):
        t = role["trust"]
        if t & _INSTANCE_TRUST:
            return "2.1"
        if t & _NETWORK_TRUST:
            return "2.2"
        return "2.3" if t else None          # None = 사람/계정이 맡는 역할

    # 2.1 인스턴스 / 2.2 네트워크 / 2.3 기타 서비스 — 서비스 역할의 과도 권한
    def c2x(code):
        label, prefixes = _CAT_ACTIONS[code]
        roles = view.roles()
        over, wild = [], []
        for r in roles:
            a = r["a"]
            if cat_of(r) == code and a["admin"]:
                over.append((r["name"], f"{r['name']} (신뢰: {', '.join(sorted(r['trust']))} / "
                                        f"{', '.join(a['admin'])})"))
            w = sorted(a["wild"] & prefixes)
            if w:
                wild.append(f"{r['name']}: {', '.join(x + ':*' for x in w)}")
        high = [u["name"] for u in view.users()
                if u["own"]["high"] or any(ga["high"] for ga in u["group_a"].values())]
        high += [f"역할:{r['name']}" for r in roles if r["a"]["high"]]
        tail = []
        if wild:
            tail += [f"{label} 전체권한(서비스:*) 부여 역할 — 역할에 맞는지 검토:"] + _cap(wild, 30)
        if high:
            tail.append("IAMFullAccess 보유(인프라 관리자에 한해 최소 인원 유지 필요): " + ", ".join(high))
        if over:
            rep.vuln(code, [f"{label}용 역할에 관리자 권한(AdministratorAccess/*:*) 부여:"]
                     + [o[1] for o in over] + tail, [o[0] for o in over])
        else:
            rep.man(code, [f"{label}용 역할에 관리자 권한 부여 없음. "
                           "역할별 최소 권한 여부는 정책 검토 필요"] + tail)
    for code in ("2.1", "2.2", "2.3"):
        safe(rep, code, lambda c=code: c2x(c))


# ======================= 3. 가상 리소스 관리 ========================
def _virtual_resource(rep, ctx):
    sess, regions = ctx["sess"], ctx["regions"]

    # 3.1 보안그룹 인/아웃바운드 포트 Any — 가이드: 소스와 무관하게 포트 Any 허용이면 취약
    def c31():
        def scan(ec2, r):
            hits = []
            for sg in _pages(ec2, "describe_security_groups", "SecurityGroups"):
                tag = f"{sg['GroupId']}({sg.get('GroupName', '')},{r})"
                for direction, key, arrow in (("인바운드", "IpPermissions", "←"),
                                              ("아웃바운드", "IpPermissionsEgress", "→")):
                    for perm in sg.get(key, []):
                        fr, to = perm.get("FromPort"), perm.get("ToPort")
                        if not (str(perm.get("IpProtocol")) == "-1" or (fr == 0 and to == 65535)):
                            continue
                        for peer, internet in _sg_peers(perm):
                            hits.append((internet, f"{tag} {direction} 포트 Any {arrow} {peer} "
                                                   f"[{'인터넷' if internet else '내부'}]"))
            return hits
        hits = sorted(set(_each_region(sess, regions, "ec2", scan)), key=lambda h: (not h[0], h[1]))
        if not hits:
            rep.good("3.1", "보안그룹 인/아웃바운드에 포트 Any(전체 포트/프로토콜) 규칙 없음")
            return
        lines = [h[1] for h in hits]
        n_net = sum(1 for h in hits if h[0])
        ev = [f"포트 Any 규칙 {len(lines)}건 (인터넷 {n_net}건 / 내부·SG참조 {len(lines) - n_net}건)",
              "※ 가이드 3.1 은 소스와 무관하게 인/아웃바운드 포트 Any 허용을 취약으로 판정"]
        rep.vuln("3.1", ev + _cap(lines), sorted({ln.split(" ")[0] for ln in lines}))
    safe(rep, "3.1", c31)

    # 3.2 보안그룹 불필요 Source/Destination — 인터넷에서 민감 포트(ALL 규칙·IPv6 포함)
    def c32():
        hit, egress_any = [], set()
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for sg in _pages(ec2, "describe_security_groups", "SecurityGroups"):
                tag = f"{sg['GroupId']}({sg.get('GroupName', '')},{r})"
                for perm in sg.get("IpPermissions", []):
                    srcs = [p for p, net in _sg_peers(perm) if net]
                    if not srcs:
                        continue
                    proto = str(perm.get("IpProtocol"))
                    fr, to = perm.get("FromPort"), perm.get("ToPort")
                    for src in srcs:
                        if proto == "-1":
                            hit.append(f"{tag} 모든 트래픽(민감 포트 전체 포함) ← {src}")
                        elif proto in ("tcp", "udp", "6", "17") and fr is not None and to is not None:
                            for p, name in _SENSITIVE_PORTS.items():
                                if fr <= p <= to:
                                    hit.append(f"{tag} {name}/{p} ← {src}")
                for perm in sg.get("IpPermissionsEgress", []):
                    if any(net for _, net in _sg_peers(perm)):
                        egress_any.add(tag)
        eg = ([f"참고: 아웃바운드 목적지가 0.0.0.0/0·::/0 인 SG {len(egress_any)}개 — "
               "불필요한 Destination 인지 검토 필요"] if egress_any else [])
        if hit:
            hit = sorted(set(hit))
            rep.vuln("3.2", ["불필요한 Source(인터넷 0.0.0.0/0·::/0)에서 민감 포트 개방:"] + _cap(hit) + eg,
                     sorted({h.split(" ")[0] for h in hit}))
        else:
            rep.man("3.2", ["인터넷(0.0.0.0/0·::/0)에서 민감 포트로 들어오는 규칙 없음. "
                            "그 외 Source/Destination 최소화 여부는 규칙 검토 필요"] + eg)
    safe(rep, "3.2", c32)

    # 3.3 네트워크 ACL 전체 허용 — 가이드: 모든 트래픽 허용이면 취약(기본 NACL 포함)
    def c33():
        allow_all = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for acl in _pages(ec2, "describe_network_acls", "NetworkAcls"):
                subnets = [a.get("SubnetId") for a in acl.get("Associations", [])]
                if not subnets:
                    continue                          # 서브넷 미연결 NACL 은 트래픽에 영향 없음
                for e in acl["Entries"]:
                    if e["RuleAction"] != "allow" or str(e["Protocol"]) != "-1" \
                            or e["RuleNumber"] >= 32767:
                        continue
                    cidr = e.get("CidrBlock") or e.get("Ipv6CidrBlock")
                    if cidr not in (_ANY4, _ANY6):
                        continue
                    d = "아웃바운드" if e["Egress"] else "인바운드"
                    allow_all.append(f"{acl['NetworkAclId']}({r}{', 기본 NACL' if acl.get('IsDefault') else ''}) "
                                     f"{d} 규칙#{e['RuleNumber']} 모든 트래픽 {cidr} 허용 "
                                     f"(연결 서브넷 {len(subnets)}개)")
        if allow_all:
            rep.vuln("3.3", ["네트워크 ACL 모든 트래픽 허용 규칙:"] + sorted(set(allow_all)) +
                     ["※ 가이드: 보안그룹 포트·소스도 ANY 허용이면 중요도 '상'으로 상향 가능"],
                     sorted({a.split("(")[0] for a in allow_all}))
        else:
            rep.good("3.3", "서브넷에 연결된 네트워크 ACL 에 모든 트래픽 허용 규칙 없음")
    safe(rep, "3.3", c33)

    # 3.4 라우팅 테이블 ANY — 가이드: 라우팅 테이블 내 ANY 정책이 설정되어 있으면 취약.
    #   비고: 게이트웨이 및 아웃바운드 통신이 필요한 경우 ANY 허용은 양호 처리 가능
    #   → 대상이 게이트웨이인 ANY 경로는 양호, 그 외 대상(피어링·인스턴스·ENI·엔드포인트 등)의 ANY 경로는 취약
    def c34():
        bad, ok = [], []
        for r in regions:
            for rt in _pages(sess.client("ec2", region_name=r), "describe_route_tables", "RouteTables"):
                rid = rt["RouteTableId"]
                for route in rt["Routes"]:
                    dst = route.get("DestinationCidrBlock") or route.get("DestinationIpv6CidrBlock")
                    if dst not in (_ANY4, _ANY6):
                        continue
                    tgt = _route_target(route)
                    label = (f"{rid}({r}) {dst} → {tgt}"
                             + (" [blackhole]" if route.get("State") == "blackhole" else ""))
                    (ok if tgt.startswith(_GATEWAY_TARGETS) else bad).append(label)
        exc = (["가이드 비고(게이트웨이·아웃바운드 통신)에 따라 양호 처리한 게이트웨이 대상 ANY 경로:"] + ok
               if ok else [])
        if bad:
            rep.vuln("3.4", ["게이트웨이가 아닌 대상으로 설정된 ANY 경로:"] + bad + exc,
                     sorted({b.split("(")[0] for b in bad}))
        elif ok:
            rep.good("3.4", exc)
        else:
            rep.good("3.4", "ANY(0.0.0.0/0·::/0) 라우팅 규칙 없음")
    safe(rep, "3.4", c34)

    # 3.5 인터넷 게이트웨이 연결 관리 — '불필요하게 연결된 NAT' 여부는 판단이 필요해 인터뷰.
    #   NAT 별 배치 서브넷의 IGW 경로 여부와 그 NAT 를 쓰는 라우팅 테이블을 근거로 제시
    def c35():
        nat_lines, igw_lines, names = [], [], []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for g in _pages(ec2, "describe_internet_gateways", "InternetGateways"):
                att = ", ".join(a["VpcId"] for a in g.get("Attachments", [])) or "VPC 미연결"
                igw_lines.append(f"{g['InternetGatewayId']}({r}) → {att}")
            nats = [n for n in _pages(ec2, "describe_nat_gateways", "NatGateways")
                    if n.get("State") not in ("deleted", "deleting", "failed")]
            if not nats:
                continue
            net = _vpc_net(ctx, r)
            rt_by = {rt["RouteTableId"]: rt for rt in net["rts"]}
            for n in nats:
                nid, sid = n["NatGatewayId"], n.get("SubnetId")
                names.append(nid)
                rt = rt_by.get(net["rt_of"].get(sid))
                igw = bool(rt) and any(
                    _route_target(ro).startswith("igw-") and ro.get("State") != "blackhole"
                    and (ro.get("DestinationCidrBlock") or ro.get("DestinationIpv6CidrBlock")) in (_ANY4, _ANY6)
                    for ro in rt["Routes"])
                using = sorted(t["RouteTableId"] for t in net["rts"]
                               if any(ro.get("NatGatewayId") == nid and ro.get("State") != "blackhole"
                                      for ro in t["Routes"]))
                nat_lines.append(f"{nid}({r}, {n.get('ConnectivityType', 'public')}, subnet={sid}): "
                                 f"배치 서브넷의 IGW 경로 {'있음' if igw else '없음'} / "
                                 f"이 NAT 를 쓰는 라우팅 테이블: {', '.join(using) or '없음'}")
        igw_ev = (["인터넷 게이트웨이:"] + igw_lines) if igw_lines else []
        if not names:
            rep.na("3.5", ["NAT 게이트웨이 없음"] + igw_ev)
            return
        rep.man("3.5", ["인터넷 게이트웨이에 불필요하게 연결된 NAT 게이트웨이가 있는지 담당자 확인:"]
                + nat_lines + igw_ev, names)
    safe(rep, "3.5", c35)

    # 3.6 NAT 게이트웨이 연결 관리 — '목적 확인'은 업무 판단이라 인터뷰. NAT 별 경유 리소스를 근거로 제시
    def c36():
        info, warn, notes, names = [], [], [], []
        for r in regions:
            nats = [n for n in _pages(sess.client("ec2", region_name=r), "describe_nat_gateways", "NatGateways")
                    if n.get("State") not in ("deleted", "deleting", "failed")]
            if not nats:
                continue
            net = _vpc_net(ctx, r)
            if net["rds_in"] is None:
                notes.append(f"RDS 조회 권한 없음({r}) — NAT 경유 RDS 미확인")
            rds_in = net["rds_in"] or {}
            nat_rts = {}                                    # NAT -> 그 NAT 를 경로로 쓰는 라우팅 테이블
            for rt in net["rts"]:
                for ro in rt["Routes"]:
                    if ro.get("NatGatewayId") and ro.get("State") != "blackhole":
                        nat_rts.setdefault(ro["NatGatewayId"], set()).add(rt["RouteTableId"])
            for n in nats:
                nid = n["NatGatewayId"]
                names.append(nid)
                subs = sorted(s for s, rid in net["rt_of"].items() if rid in nat_rts.get(nid, set()))
                insts = []
                for i in net["insts"]:
                    if i.get("SubnetId") not in subs:
                        continue
                    nm = next((t["Value"] for t in i.get("Tags", []) if t.get("Key") == "Name"), "")
                    insts.append(f"{i['InstanceId']}({nm})" if nm else i["InstanceId"])
                    if "db" in nm.lower():
                        warn.append(f"{nid}: DB 추정 인스턴스 {i['InstanceId']}({nm}) 가 NAT 로 외부 통신 가능(이름 기준)")
                dbs = sorted({d for s in subs for d in rds_in.get(s, [])})
                if dbs:
                    warn.append(f"{nid}: RDS {', '.join(dbs)} 가 NAT 로 외부 통신 가능")
                info.append(f"{nid}({r}): 경유 서브넷 {len(subs)}개 / 인스턴스 {len(insts)}대"
                            + (f": {', '.join(insts[:15])}" if insts else "")
                            + (f" / RDS: {', '.join(dbs)}" if dbs else ""))
        if not names:
            rep.na("3.6", "NAT 게이트웨이 없음")
            return
        ev = ["NAT GW 경유 리소스 — 외부 통신이 필요한 리소스인지(목적) 담당자 확인:"] + info
        if warn:
            ev += ["⚠ 가이드 비고: DBMS·개인정보 서비스 등 외부 오픈 금지 대상인지 확인 필요"] + warn
        rep.man("3.6", ev + notes, names)
    safe(rep, "3.6", c36)

    # 3.7 S3 퍼블릭 액세스 — 계정/버킷 퍼블릭 액세스 차단, 버킷 정책, ACL(모든 사람·외부 계정)
    def c37():
        res, note, acct_all = _s3_exposure(ctx)
        if not res:
            rep.na("3.7", "S3 버킷 없음")
            return
        if acct_all:
            rep.good("3.7", f"계정 수준 '모든 퍼블릭 액세스 차단' 활성 → S3 버킷 {len(res)}개 모두 보호")
            return
        public = [f"{n} ({why})" for n, (st, why) in res.items() if st == "public"]
        unknown = [f"{n} ({why})" for n, (st, why) in res.items() if st == "unknown"]
        if public:
            rep.vuln("3.7", ["퍼블릭 액세스 차단이 없고 모든 사람/외부 계정에 공개된 버킷:"] + public
                     + note + (["확인 불가: " + ", ".join(unknown)] if unknown else []),
                     [p.split(" ")[0] for p in public])
        elif unknown:
            rep.man("3.7", ["일부 버킷의 공개 설정을 확인하지 못함: " + ", ".join(unknown)] + note)
        else:
            rep.good("3.7", [f"S3 버킷 {len(res)}개 모두 퍼블릭 액세스 차단 또는 소유자 전용 ACL"] + note)
    safe(rep, "3.7", c37)

    # 3.8 RDS 서브넷 가용영역 — 인터뷰 / NA
    def c38():
        found = []
        for r in regions:
            try:
                rds = sess.client("rds", region_name=r)
                for g in _pages(rds, "describe_db_subnet_groups", "DBSubnetGroups"):
                    azs = sorted({s["SubnetAvailabilityZone"]["Name"] for s in g["Subnets"]})
                    found.append(f"{g['DBSubnetGroupName']}({r}) AZ={azs}")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if not found:
            rep.na("3.8", "RDS 서브넷 그룹 없음")
        else:
            rep.man("3.8", ["RDS 서브넷 그룹 — 불필요 AZ 포함 여부 검토:"] + found, found)
    safe(rep, "3.8", c38)

    # 3.9 EKS Pod 보안 — kubectl
    _eks_manual(rep, ctx, ["3.9"])

    # 3.10 ELB 제어 정책(ELB.1~16) 준수
    def c310():
        total, viol, passed, notes = 0, [], [], []
        for r in regions:
            try:
                cli, lbs = _elbv2(ctx, r)
            except Exception as e:
                if _is_denied(e):
                    raise
                cli, lbs = None, []
            web_acls = None
            if any(lb.get("Type") == "application" for lb in lbs):
                try:
                    web_acls = sess.client("wafv2", region_name=r).list_web_acls(
                        Scope="REGIONAL").get("WebACLs", [])
                except Exception:
                    notes.append(f"WAF(wafv2) 조회 불가({r}) — ELB.16 미판정")
            waf = sess.client("wafv2", region_name=r) if web_acls else None
            for lb in lbs:
                typ = lb.get("Type")
                if typ not in ("application", "network", "gateway"):
                    continue
                total += 1
                arn, name = lb["LoadBalancerArn"], lb["LoadBalancerName"]
                attrs = _lb_attrs(ctx, cli, arn)
                probs = []
                if typ == "application":
                    for li in _listeners(ctx, cli, arn):
                        if li["Protocol"] == "HTTP" and not any(
                                a["Type"] == "redirect" and a.get("RedirectConfig", {}).get("Protocol") == "HTTPS"
                                for a in li.get("DefaultActions", [])):
                            probs.append(f"ELB.1 HTTP:{li['Port']} → HTTPS 리디렉션 없음")
                    if attrs.get("routing.http.drop_invalid_header_fields.enabled") != "true":
                        probs.append("ELB.4 잘못된 HTTP 헤더 삭제 비활성")
                    if attrs.get("access_logs.s3.enabled") != "true":
                        probs.append("ELB.5 액세스 로깅 비활성")
                    mode = attrs.get("routing.http.desync_mitigation_mode", "defensive")
                    if mode not in ("defensive", "strictest"):
                        probs.append(f"ELB.12 비동기화 완화 모드={mode}(방어/엄격 필요)")
                    if waf:
                        try:
                            if not waf.get_web_acl_for_resource(ResourceArn=arn).get("WebACL"):
                                probs.append("ELB.16 WAF Web ACL 미연결(WAF 사용 중)")
                        except Exception:
                            notes.append(f"{name}: WAF 연결 조회 불가 — ELB.16 미판정")
                if attrs.get("deletion_protection.enabled") != "true":
                    probs.append("ELB.6 삭제 방지 비활성")
                azs = len(lb.get("AvailabilityZones", []))
                if azs < 2:
                    probs.append(f"ELB.13 가용영역 {azs}개(2개 이상 필요)")
                label = f"{name}({typ},{r})"
                (viol if probs else passed).append(f"{label}: {', '.join(probs)}" if probs else label)
            # Classic Load Balancer
            try:
                ccli, clbs = _classic_elbs(ctx, r)
            except Exception as e:
                if _is_denied(e):
                    raise
                clbs = []
            for lb in clbs:
                total += 1
                name = lb["LoadBalancerName"]
                a = ccli.describe_load_balancer_attributes(LoadBalancerName=name)["LoadBalancerAttributes"]
                probs = []
                protos = {ld["Listener"]["Protocol"].upper() for ld in lb.get("ListenerDescriptions", [])}
                if not protos & {"HTTPS", "SSL"}:
                    probs.append("ELB.3 프런트엔드 HTTPS/SSL 리스너 없음")
                if not a.get("AccessLog", {}).get("Enabled"):
                    probs.append("ELB.5 액세스 로깅 비활성")
                if not a.get("ConnectionDraining", {}).get("Enabled"):
                    probs.append("ELB.7 Connection Draining 비활성")
                if not a.get("CrossZoneLoadBalancing", {}).get("Enabled"):
                    probs.append("ELB.9 영역 간 로드밸런싱 비활성")
                if len(lb.get("AvailabilityZones", [])) < 2:
                    probs.append("ELB.10 가용영역 2개 미만")
                desync = next((x.get("Value") for x in a.get("AdditionalAttributes", [])
                               if x.get("Key") == "elb.http.desyncmitigationmode"), "defensive")
                if desync not in ("defensive", "strictest"):
                    probs.append(f"ELB.14 비동기화 완화 모드={desync}")
                label = f"{name}(classic,{r})"
                (viol if probs else passed).append(f"{label}: {', '.join(probs)}" if probs else label)
        if total == 0:
            rep.na("3.10", "로드밸런서 없음")
        elif viol:
            rep.vuln("3.10", ["ELB 제어 정책 미준수:"] + viol + notes +
                     ["※ 가이드 비고: 연결 서비스/Third-Party 여부에 따라 예외 인정 가능(인터뷰)"],
                     [v.split("(")[0] for v in viol])
        else:
            rep.good("3.10", [f"로드밸런서 {total}개 ELB 제어 정책 준수: " + ", ".join(passed)] + notes)
    safe(rep, "3.10", c310)


# ========================= 4. 운영 관리 ============================
def _operation_mgmt(rep, ctx):
    sess, regions = ctx["sess"], ctx["regions"]

    # 4.1 EBS 볼륨 암호화
    def c41():
        unenc, total, default_on = [], 0, []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            try:
                if ec2.get_ebs_encryption_by_default()["EbsEncryptionByDefault"]:
                    default_on.append(r)
            except Exception as _e:
                if _is_denied(_e):
                    raise
            for v in _pages(ec2, "describe_volumes", "Volumes"):
                total += 1
                if not v.get("Encrypted"):
                    unenc.append(f"{v['VolumeId']}({r},{v.get('State')})")
        if total == 0:
            rep.na("4.1", "EBS 볼륨 없음")
        elif unenc:
            rep.vuln("4.1", [f"암호화 안 된 EBS 볼륨 {len(unenc)}/{total}: " + ", ".join(unenc),
                             f"기본 암호화 활성 리전: {default_on or '없음'}"],
                     [u.split("(")[0] for u in unenc])
        else:
            rep.good("4.1", f"EBS 볼륨 {total}개 모두 암호화됨")
    safe(rep, "4.1", c41)

    # 4.2 RDS 암호화
    def c42():
        unenc, total = [], 0
        for r in regions:
            try:
                rds = sess.client("rds", region_name=r)
                for db in _pages(rds, "describe_db_instances", "DBInstances"):
                    total += 1
                    if not db.get("StorageEncrypted"):
                        unenc.append(f"{db['DBInstanceIdentifier']}({r})")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if total == 0:
            rep.na("4.2", "RDS 인스턴스 없음")
        elif unenc:
            rep.vuln("4.2", "암호화 안 된 RDS: " + ", ".join(unenc), unenc)
        else:
            rep.good("4.2", f"RDS {total}개 모두 스토리지 암호화")
    safe(rep, "4.2", c42)

    # 4.3 S3 암호화 — 권한 오류는 '암호화됨'으로 간주하지 않는다
    def c43():
        s3 = sess.client("s3")
        buckets = s3.list_buckets()["Buckets"]
        if not buckets:
            rep.na("4.3", "S3 버킷 없음")
            return
        no_enc, unknown = [], []
        for b in buckets:
            try:
                s3.get_bucket_encryption(Bucket=b["Name"])
            except Exception as e:
                if "ServerSideEncryptionConfigurationNotFoundError" in str(e):
                    no_enc.append(b["Name"])
                elif _is_denied(e):
                    raise
                else:
                    unknown.append(f"{b['Name']}({type(e).__name__})")
        if no_enc:
            rep.vuln("4.3", "기본 암호화(SSE-S3/SSE-KMS) 미설정 버킷: " + ", ".join(no_enc), no_enc)
        elif unknown:
            rep.man("4.3", "기본 암호화 설정을 확인하지 못한 버킷: " + ", ".join(unknown))
        else:
            rep.good("4.3", f"S3 버킷 {len(buckets)}개 모두 서버 측 암호화(SSE-S3/SSE-KMS) 설정")
    safe(rep, "4.3", c43)

    # 4.4 통신구간 암호화 — LB 리스너 TLS(1.2 이상 정책), Classic ELB 포함
    def c44():
        total, plain, weak, unclear = 0, [], [], []
        for r in regions:
            try:
                cli, lbs = _elbv2(ctx, r)
            except Exception as e:
                if _is_denied(e):
                    raise
                lbs = []
            for lb in lbs:
                typ = lb.get("Type")
                if typ == "gateway":
                    continue
                total += 1
                name = f"{lb['LoadBalancerName']}({typ},{r})"
                ls = _listeners(ctx, cli, lb["LoadBalancerArn"])
                protos = {li["Protocol"] for li in ls}
                secure = [li for li in ls if li["Protocol"] in ("HTTPS", "TLS")]
                redirect = any(
                    li["Protocol"] == "HTTP" and any(
                        a["Type"] == "redirect" and a.get("RedirectConfig", {}).get("Protocol") == "HTTPS"
                        for a in li.get("DefaultActions", []))
                    for li in ls)
                if not secure and not redirect:
                    if typ == "network":
                        unclear.append(f"{name} 리스너={sorted(protos)} (TCP/UDP 패스스루 — 백엔드 TLS 확인 필요)")
                    else:
                        plain.append(f"{name} 리스너={sorted(protos)}")
                for li in secure:
                    pol = li.get("SslPolicy") or ""
                    old = _ssl_protocols(ctx, cli, pol) & {"TLSv1", "TLSv1.1"} if pol else set()
                    if old:
                        weak.append(f"{name} {li['Protocol']}:{li['Port']} {pol} ({'/'.join(sorted(old))} 허용)")
            try:
                ccli, clbs = _classic_elbs(ctx, r)
            except Exception as e:
                if _is_denied(e):
                    raise
                clbs = []
            for lb in clbs:
                total += 1
                protos = {ld["Listener"]["Protocol"].upper() for ld in lb.get("ListenerDescriptions", [])}
                if not protos & {"HTTPS", "SSL"}:
                    plain.append(f"{lb['LoadBalancerName']}(classic,{r}) 리스너={sorted(protos)}")
        if total == 0:
            rep.man("4.4", "로드밸런서 없음 — 서버 원격 접근(VPN/SSH)·관리 접속(TLS 1.2 이상) 등 "
                           "통신구간 암호화 적용 여부는 인터뷰로 확인")
        elif plain or weak:
            ev = []
            if plain:
                ev += ["HTTPS/TLS 리스너(또는 HTTPS 리다이렉트)가 없는 로드밸런서:"] + plain
            if weak:
                ev += ["TLS 1.0/1.1 을 허용하는 보안 정책(가이드: TLS 1.2 이상):"] + weak
            rep.vuln("4.4", ev + unclear, [x.split("(")[0] for x in plain + weak])
        elif unclear:
            rep.man("4.4", unclear)
        else:
            rep.good("4.4", f"로드밸런서 {total}개 모두 HTTPS/TLS(1.2 이상) 종단 또는 HTTPS 리다이렉트")
    safe(rep, "4.4", c44)

    # 4.5 CloudTrail 암호화(SSE-KMS)
    def c45():
        trails = _trails(ctx)
        if not trails:
            rep.na("4.5", "CloudTrail 추적 없음 (4.7 참고)")
            return
        no_kms = [f"{t['Name']}(홈:{t.get('HomeRegion', '?')})" for t in trails if not t.get("KmsKeyId")]
        if no_kms:
            rep.vuln("4.5", ["SSE-KMS 암호화가 없는 CloudTrail(기본 SSE-S3):"] + no_kms,
                     [n.split("(")[0] for n in no_kms])
        else:
            rep.good("4.5", f"CloudTrail {len(trails)}개 모두 SSE-KMS 로 암호화됨")
    safe(rep, "4.5", c45)

    # 4.6 CloudWatch Logs KMS
    def c46():
        no_kms, total = [], 0
        for r in regions:
            try:
                logs = sess.client("logs", region_name=r)
                for lg in _pages(logs, "describe_log_groups", "logGroups"):
                    total += 1
                    if not lg.get("kmsKeyId"):
                        no_kms.append(f"{lg['logGroupName']}({r})")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if total == 0:
            rep.na("4.6", "CloudWatch 로그 그룹 없음")
        elif no_kms:
            rep.vuln("4.6", [f"KMS 키 미설정 로그 그룹 {len(no_kms)}/{total}"] + _cap(no_kms, 20), no_kms)
        else:
            rep.good("4.6", f"로그 그룹 {total}개 모두 KMS 키 설정")
    safe(rep, "4.6", c46)

    # 4.7 CloudTrail 관리 이벤트 로깅 (멀티리전 추적은 홈 리전에서 상태 조회)
    def c47():
        ok, off = [], []
        for t in _trails(ctx):
            home = t.get("HomeRegion") or regions[0]
            ct = sess.client("cloudtrail", region_name=home)
            label = f"{t['Name']}(홈:{home}, 멀티리전={t.get('IsMultiRegionTrail')})"
            if not ct.get_trail_status(Name=t["TrailARN"]).get("IsLogging"):
                off.append(f"{label} 로깅 중지")
                continue
            sels = ct.get_event_selectors(TrailName=t["TrailARN"])
            mgmt = any(s.get("IncludeManagementEvents", True) for s in sels.get("EventSelectors") or [])
            mgmt = mgmt or any(
                any(f.get("Field") == "eventCategory" and "Management" in (f.get("Equals") or [])
                    for f in a.get("FieldSelectors", []))
                for a in sels.get("AdvancedEventSelectors") or [])
            (ok if mgmt else off).append(label if mgmt else f"{label} 관리 이벤트 미기록")
        if ok:
            rep.good("4.7", ["관리 이벤트를 기록하는 활성 CloudTrail: " + ", ".join(sorted(ok))]
                     + (["참고: " + ", ".join(off)] if off else []))
        else:
            rep.vuln("4.7", ["관리 이벤트를 기록하는 활성 CloudTrail 추적이 없음"] + off)
    safe(rep, "4.7", c47)

    # 4.8 인스턴스 로깅 — 가이드: CloudWatch 로그 스트림으로 보관하고 있는지. 실행 중인 인스턴스마다 스트림 존재 확인
    #   CloudWatch Agent 기본 스트림 이름 = 인스턴스 ID. 호스트명(ip-10-0-1-5…)으로 지정한 경우도 인정.
    def c48():
        running, stopped = [], 0
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for resv in _pages(ec2, "describe_instances", "Reservations",
                               Filters=[{"Name": "instance-state-name", "Values": ["running", "stopped"]}]):
                for i in resv["Instances"]:
                    if (i.get("State") or {}).get("Name", "running") == "running":
                        running.append((r, i))
                    else:
                        stopped += 1
        if not running:
            rep.na("4.8", f"실행 중인 EC2 인스턴스 없음(중지 {stopped}대)")
            return
        skip = ("/aws/lambda/", "/aws/rds/", "/aws/eks/", "/aws/codebuild/", "/aws/apigateway/")
        streams = {}                                        # 리전 -> [(스트림명, 로그그룹)]
        for r in sorted({r for r, _ in running}):
            logs = sess.client("logs", region_name=r)
            found = []
            for g in _pages(logs, "describe_log_groups", "logGroups"):
                gname = g["logGroupName"]
                if gname.startswith(skip):                  # 인스턴스 로그가 들어가지 않는 서비스 로그 그룹
                    continue
                for s in _pages(logs, "describe_log_streams", "logStreams", logGroupName=gname):
                    found.append((s["logStreamName"], gname))
            streams[r] = found
        ok, missing = [], []
        for r, i in running:
            iid = i["InstanceId"]
            host = (i.get("PrivateDnsName") or "").split(".")[0]
            name = next((t["Value"] for t in i.get("Tags", []) if t.get("Key") == "Name"), "")
            label = f"{iid}({name})" if name else iid
            hits = [s for s in streams.get(r, []) if iid in s[0] or (host and s[0].startswith(host))]
            if hits:
                ok.append(f"{label} [{', '.join(sorted({h[1] for h in hits}))[:80]}]")
            else:
                missing.append(label + ("" if i.get("IamInstanceProfile") else " — IAM 역할 없음(에이전트 전송 불가)"))
        ev = [f"실행 중 EC2 {len(running)}대 중 로그 스트림 보관 {len(ok)}대 / 스트림 없음 {len(missing)}대"]
        if missing:
            ev += ["CloudWatch 로그 스트림이 없는 인스턴스:"] + missing
        if ok:
            ev.append("보관 중: " + ", ".join(ok[:20]))
        if missing:
            rep.vuln("4.8", ev + ["※ 스트림 이름을 인스턴스 ID/호스트명으로 매칭함 — 임의 이름으로 수집 중이면 "
                                  "근거 확인 후 양호 처리"],
                     [x.split(" ")[0].split("(")[0] for x in missing])
        else:
            rep.good("4.8", ev)
    safe(rep, "4.8", c48)

    # 4.9 RDS 로깅
    def c49():
        no_log, total = [], 0
        for r in regions:
            try:
                rds = sess.client("rds", region_name=r)
                for db in _pages(rds, "describe_db_instances", "DBInstances"):
                    total += 1
                    if not db.get("EnabledCloudwatchLogsExports"):
                        no_log.append(f"{db['DBInstanceIdentifier']}({r})")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if total == 0:
            rep.na("4.9", "RDS 인스턴스 없음")
        elif no_log:
            rep.vuln("4.9", "CloudWatch 로그 내보내기 미설정 RDS: " + ", ".join(no_log), no_log)
        else:
            rep.good("4.9", f"RDS {total}개 모두 CloudWatch 로그 내보내기 설정")
    safe(rep, "4.9", c49)

    # 4.10 S3 버킷 로깅 — 가이드: '로그를 보관하고 있는 버킷'의 서버 액세스 로깅
    def c410():
        s3 = sess.client("s3")
        names = [b["Name"] for b in s3.list_buckets()["Buckets"]]
        if not names:
            rep.na("4.10", "S3 버킷 없음")
            return
        logging_on, why, notes = {}, {}, []
        for n in names:
            try:
                le = s3.get_bucket_logging(Bucket=n).get("LoggingEnabled")
                logging_on[n] = bool(le)
                if le and le.get("TargetBucket"):
                    why.setdefault(le["TargetBucket"], set()).add("다른 버킷 액세스 로그 대상")
            except Exception as e:
                if _is_denied(e):
                    raise
                logging_on[n] = None

        def mark(bucket, reason):
            why.setdefault(bucket, set()).add(reason)
        try:
            for t in _trails(ctx):
                if t.get("S3BucketName"):
                    mark(t["S3BucketName"], "CloudTrail 로그")
        except Exception:
            notes.append("CloudTrail 조회 불가 — 로그 버킷 식별 일부 누락 가능")
        for r in regions:
            try:
                for f in _pages(sess.client("ec2", region_name=r), "describe_flow_logs", "FlowLogs"):
                    if f.get("LogDestinationType") == "s3" and f.get("LogDestination"):
                        mark(f["LogDestination"].split(":::", 1)[-1].split("/")[0], "VPC 플로우 로그")
            except Exception:
                notes.append(f"플로우 로그 조회 불가({r})")
            try:
                cli, lbs = _elbv2(ctx, r)
                for lb in lbs:
                    at = _lb_attrs(ctx, cli, lb["LoadBalancerArn"])
                    if at.get("access_logs.s3.enabled") == "true" and at.get("access_logs.s3.bucket"):
                        mark(at["access_logs.s3.bucket"], "ELB 액세스 로그")
            except Exception:
                notes.append(f"ELB 조회 불가({r})")
        for n in names:
            if "log" in n.lower() or "trail" in n.lower():
                mark(n, "이름에 log/trail 포함")
        why = {b: v for b, v in why.items() if b in logging_on}      # 이 계정 버킷만
        if not why:
            no = [n for n, v in logging_on.items() if v is False]
            rep.man("4.10", ["로그 보관 버킷을 식별하지 못함 — 로그 저장 위치 확인 필요 "
                             "(가이드: 로그를 보관하는 버킷의 서버 액세스 로깅)"]
                    + ([f"참고: 서버 액세스 로깅 미설정 버킷 {len(no)}/{len(names)}: " + ", ".join(no[:30])]
                       if no else []) + notes)
            return
        missing = [f"{b}({'/'.join(sorted(why[b]))})" for b in sorted(why) if logging_on.get(b) is False]
        unknown = [b for b in sorted(why) if logging_on.get(b) is None]
        if missing:
            rep.vuln("4.10", ["서버 액세스 로깅이 없는 로그 보관 버킷:"] + missing + notes,
                     [m.split("(")[0] for m in missing])
        elif unknown:
            rep.man("4.10", ["로그 보관 버킷의 로깅 설정 확인 불가: " + ", ".join(unknown)] + notes)
        else:
            rep.good("4.10", [f"로그 보관 버킷 {len(why)}개 모두 서버 액세스 로깅 설정: "
                              + ", ".join(sorted(why))] + notes)
    safe(rep, "4.10", c410)

    # 4.11 VPC 플로우 로그
    def c411():
        missing = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            vpcs = [v["VpcId"] for v in _pages(ec2, "describe_vpcs", "Vpcs")]
            fl_vpcs = {f["ResourceId"] for f in _pages(ec2, "describe_flow_logs", "FlowLogs")}
            missing += [f"{v}({r})" for v in vpcs if v not in fl_vpcs]
        if missing:
            rep.vuln("4.11", "플로우 로그 미설정 VPC: " + ", ".join(missing), missing)
        else:
            rep.good("4.11", "모든 VPC에 플로우 로그 설정")
    safe(rep, "4.11", c411)

    # 4.12 로그 보관기간 (>=1년)
    def c412():
        short, total = [], 0
        for r in regions:
            try:
                logs = sess.client("logs", region_name=r)
                for lg in _pages(logs, "describe_log_groups", "logGroups"):
                    total += 1
                    ret = lg.get("retentionInDays")
                    if ret is not None and ret < 365:
                        short.append(f"{lg['logGroupName']}({r}) {ret}일")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if total == 0:
            rep.man("4.12", "CloudWatch 로그 그룹 없음 — 서비스 로그 보관 위치(S3 등)와 보관기간(1년 이상) 확인 필요")
        elif short:
            rep.vuln("4.12", ["보관기간 1년 미만 로그 그룹:"] + _cap(short, 20), short)
        else:
            rep.good("4.12", f"로그 그룹 {total}개 모두 보관기간 1년 이상 또는 무기한")
    safe(rep, "4.12", c412)

    # 4.13 백업 사용 여부 — AWS 의 '백업 정책'(AWS Backup 계획: 규칙+대상 선택 / 활성 DLM 스냅샷 정책)이 있으면 양호
    #   권한이 없어 확인 못 한 소스는 '없음'으로 단정하지 않는다(수동확인).
    def c413():
        ev, notes, unknown, has = [], [], [], False
        for r in regions:
            bk = sess.client("backup", region_name=r)
            try:
                for p in _pages(bk, "list_backup_plans", "BackupPlansList"):
                    pid, pname = p["BackupPlanId"], p.get("BackupPlanName") or p["BackupPlanId"]
                    rules = bk.get_backup_plan(BackupPlanId=pid)["BackupPlan"].get("Rules", [])
                    sels = _pages(bk, "list_backup_selections", "BackupSelectionsList", BackupPlanId=pid)
                    desc = []
                    for ru in rules:
                        keep = (ru.get("Lifecycle") or {}).get("DeleteAfterDays")
                        desc.append(f"{ru.get('RuleName')}({ru.get('ScheduleExpression', '수동')}, "
                                    f"{'보존 ' + str(keep) + '일' if keep else '보존 무기한'})")
                    if rules and sels:
                        has = True
                        ev.append(f"AWS Backup 계획 {pname}({r}): 규칙 {', '.join(desc)} / 백업 대상 선택 {len(sels)}개")
                    else:
                        notes.append(f"AWS Backup 계획 {pname}({r}): 규칙 {len(rules)}개·대상 선택 {len(sels)}개 "
                                     "→ 실제 백업 대상 없음")
                prot = _pages(bk, "list_protected_resources", "Results")
                if prot:
                    types = sorted({x.get("ResourceType", "?") for x in prot})
                    ev.append(f"백업 보호 중인 리소스 {len(prot)}개({r}): {', '.join(types)}")
            except Exception as e:
                if not _is_denied(e):
                    raise
                unknown.append(f"AWS Backup({r})")
            try:
                pol = sess.client("dlm", region_name=r).get_lifecycle_policies().get("Policies", [])
                on = [p for p in pol if p.get("State") == "ENABLED"]
                if on:
                    has = True
                    ev.append(f"EBS 스냅샷 수명주기(DLM) 정책 {len(on)}개 활성({r})")
                elif pol:
                    notes.append(f"DLM 정책 {len(pol)}개 모두 비활성({r})")
            except Exception as e:
                if not _is_denied(e):
                    raise
                unknown.append(f"DLM({r})")
            try:
                dbs = _pages(sess.client("rds", region_name=r), "describe_db_instances", "DBInstances")
                if dbs:
                    auto = sum(1 for d in dbs if d.get("BackupRetentionPeriod", 0) > 0)
                    notes.append(f"참고: RDS 자동 백업 {auto}/{len(dbs)}개({r}) — 백업 정책으로는 보지 않음")
            except Exception as e:
                if not _is_denied(e):
                    raise
        tail = ["※ 백업 절차·담당자·보존기한·소산 등 정책 문서는 가이드 참고사항(필요 시 인터뷰로 보완)"]
        if has:
            rep.good("4.13", ev + notes + tail)
        elif unknown:
            rep.man("4.13", ["백업 정책을 확인할 권한이 없는 소스: " + ", ".join(unknown)] + ev + notes)
        else:
            rep.vuln("4.13", ["AWS Backup 계획(규칙+대상)·DLM 스냅샷 정책 등 백업 정책이 없음"] + ev + notes + tail)
    safe(rep, "4.13", c413)

    # 4.14 / 4.15 EKS
    _eks_manual(rep, ctx, ["4.14", "4.15"])


# --------------------------------------------------------------------------
def _eks_manual(rep, ctx, codes):
    """EKS 항목: 클러스터 없으면 N/A, 있으면 kubectl 필요 → 수동확인.

    4.14(제어플레인 로깅) / 4.15(암호 암호화) 는 describe_cluster 로 자동 판정한다.
    EKS 조회 권한이 없으면 전체 스캔을 멈추지 않고 해당 항목만 수동확인으로 둔다.
    """
    sess = ctx["sess"]
    denied_msg = "EKS 조회 권한 부족(eks:ListClusters/DescribeCluster) → 수동 확인 필요"
    clusters = []
    for r in ctx["regions"]:
        try:
            clusters += [(r, n) for n in _pages(sess.client("eks", region_name=r), "list_clusters", "clusters")]
        except Exception as _e:
            if _is_denied(_e):
                for c in codes:
                    if not rep.done(c):
                        rep.man(c, denied_msg)
                return

    if not clusters:
        for c in codes:
            if not rep.done(c):
                rep.na(c, "EKS 클러스터 없음")
        return

    names = [f"{n}({r})" for r, n in clusters]
    desc = ctx["cache"].setdefault("eks", {})

    def describe(r, n):
        if (r, n) not in desc:
            desc[(r, n)] = sess.client("eks", region_name=r).describe_cluster(name=n)["cluster"]
        return desc[(r, n)]
    for c in codes:
        if rep.done(c):
            continue
        try:
            if c == "4.14":
                bad = []
                need = {"api", "audit", "authenticator", "controllerManager", "scheduler"}
                for r, n in clusters:
                    types = set()
                    for lg in describe(r, n).get("logging", {}).get("clusterLogging", []):
                        if lg.get("enabled"):
                            types |= set(lg.get("types", []))
                    if not need.issubset(types):
                        bad.append(f"{n}({r}) 활성 로그={sorted(types) or '없음'}")
                if bad:
                    rep.vuln("4.14", ["제어 플레인 로그 유형(5종) 중 일부만 활성:"] + bad, bad)
                else:
                    rep.good("4.14", "EKS 제어 플레인 로그 5종 모두 활성")
            elif c == "4.15":
                bad = [f"{n}({r})" for r, n in clusters if not describe(r, n).get("encryptionConfig")]
                if bad:
                    rep.vuln("4.15", "암호 암호화(Secret encryption) 미설정: " + ", ".join(bad), bad)
                else:
                    rep.good("4.15", "EKS 클러스터 암호 암호화 활성")
            else:
                rep.man(c, [f"EKS 클러스터: {', '.join(names)}",
                            "이 항목은 kubectl(클러스터 접근) 로 aws-auth/ServiceAccount/RBAC/PSS 확인 필요"],
                        names)
        except Exception as _e:
            if _is_denied(_e):
                rep.man(c, denied_msg)
            else:
                rep.man(c, f"EKS 조회 중 오류 ({type(_e).__name__}): {_e}")
