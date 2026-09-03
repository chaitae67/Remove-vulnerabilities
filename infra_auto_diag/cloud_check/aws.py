#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AWS 클라우드 취약점 진단 (SK Shieldus 2024 클라우드 보안가이드 41항목).

READ-ONLY — describe_* / list_* / get_* 만 호출한다. 리소스를 변경하지 않는다.
필요 권한: AWS 관리형 정책 `SecurityAudit` (또는 ViewOnlyAccess) 수준.

자동 판정이 가능한 항목은 boto3 로 직접 확인하고,
업무 컨텍스트가 필요한 항목(1인 1계정, 불필요한 계정, 키 보관 위치 등)은
근거를 수집해 '수동확인'(보고서에선 '인터뷰 필요')으로 분류한다.
"""
import datetime

from .base import Reporter, safe, GOOD, VULN, NA, MAN
from .aws_items import ITEMS

_SENSITIVE_PORTS = {22: "SSH", 23: "Telnet", 3389: "RDP", 3306: "MySQL",
                    5432: "PostgreSQL", 6379: "Redis", 27017: "MongoDB",
                    1433: "MSSQL", 9200: "Elasticsearch", 11211: "Memcached",
                    2049: "NFS", 5900: "VNC", 137: "NetBIOS", 445: "SMB"}
_ADMIN_POLICY_ARNS = {"arn:aws:iam::aws:policy/AdministratorAccess"}


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
    try:
        ec2 = sess.client("ec2", region_name="us-east-1")
        rs = [r["RegionName"] for r in ec2.describe_regions(AllRegions=False)["Regions"]]
        return rs or ["us-east-1"]
    except Exception:
        return [sess.region_name or "us-east-1"]


_DENY_MARKERS = ("AccessDenied", "UnauthorizedOperation", "AuthorizationError",
                 "OptInRequired", "not authorized")


def _is_denied(e):
    s = f"{type(e).__name__} {e}"
    return any(m in s for m in _DENY_MARKERS)


def _each_region(sess, service, fn):
    """모든 활성 리전에서 fn(client, region) 을 호출해 리스트를 합친다.

    권한 오류가 '모든' 리전에서 나면 PermissionError 로 올려 safe() 가 수동확인 처리한다.
    리전별 서비스 미지원(EndpointConnectionError 등)은 조용히 건너뛴다.
    """
    out, denied, ok = [], 0, 0
    regs = _regions(sess)
    for r in regs:
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


def _policy_is_admin(doc):
    """정책 문서에 Action:* / Resource:* Allow 가 있으면 True."""
    stmts = doc.get("Statement", [])
    if isinstance(stmts, dict):
        stmts = [stmts]
    for st in stmts:
        if st.get("Effect") != "Allow":
            continue
        acts = st.get("Action", [])
        acts = [acts] if isinstance(acts, str) else acts
        res = st.get("Resource", [])
        res = [res] if isinstance(res, str) else res
        if any(a == "*" or a.endswith(":*") for a in acts) and "*" in res:
            return True
    return False


# ----------------------------------------------------------------------------
def run(creds):
    sess = _session(creds)
    rep = Reporter(ITEMS)

    # 계정 식별자 — 자격증명이 유효하지 않으면 여기서 중단(엉뚱한 결과 방지)
    try:
        ident = sess.client("sts").get_caller_identity()
        acct = ident.get("Account", "unknown")
        arn = ident.get("Arn", "")
    except Exception as e:
        raise RuntimeError(
            "AWS 자격증명이 유효하지 않거나 만료되었습니다. "
            f"Access Key / Secret / 리전 / 프로필을 확인하세요.\n({type(e).__name__}: {e})")

    iam = sess.client("iam")

    # ---- 자격증명 보고서(1회 생성) : 1.8 / 1.9 에서 공용 ----
    cred_rows = _get_credential_report(iam)

    _account_mgmt(rep, sess, iam, cred_rows)
    _permission_mgmt(rep, sess, iam)
    _virtual_resource(rep, sess)
    _operation_mgmt(rep, sess)

    rep.fill_missing(MAN, "이번 버전에서 자동 점검 미지원 → 콘솔에서 수동 확인 필요")

    return {
        "host": f"AWS 계정 {acct}",
        "os": "AWS",
        "family": "cloud",
        "results": rep.results(),
    }


def _get_credential_report(iam):
    import time
    try:
        for _ in range(10):
            try:
                raw = iam.get_credential_report()["Content"].decode("utf-8", "replace")
                break
            except iam.exceptions.CredentialReportNotPresentException:
                iam.generate_credential_report()
                time.sleep(2)
            except iam.exceptions.CredentialReportExpiredException:
                iam.generate_credential_report()
                time.sleep(2)
        else:
            return []
        lines = raw.splitlines()
        hdr = lines[0].split(",")
        return [dict(zip(hdr, ln.split(","))) for ln in lines[1:]]
    except Exception:
        return []


# ============================ 1. 계정 관리 ============================
def _account_mgmt(rep, sess, iam, cred_rows):

    # 1.1 사용자 계정 관리 — 관리자 권한 다수 여부 + (불필요 계정은 인터뷰)
    def c11():
        users = iam.list_users()["Users"]
        admins = []
        for u in users:
            n = u["UserName"]
            attached = [p["PolicyArn"] for p in
                        iam.list_attached_user_policies(UserName=n)["AttachedPolicies"]]
            is_admin = any(a in _ADMIN_POLICY_ARNS for a in attached)
            if not is_admin:
                for g in iam.list_groups_for_user(UserName=n)["Groups"]:
                    ga = [p["PolicyArn"] for p in iam.list_attached_group_policies(
                        GroupName=g["GroupName"])["AttachedPolicies"]]
                    if any(a in _ADMIN_POLICY_ARNS for a in ga):
                        is_admin = True
                        break
            if is_admin:
                admins.append(n)
        ev = [f"IAM 사용자 {len(users)}명, 관리자 권한(AdministratorAccess) 보유 {len(admins)}명: "
              f"{', '.join(admins) if admins else '없음'}",
              "불필요 계정(협력사 공용/테스트/퇴직자) 존재 여부는 담당자 인터뷰로 확인 필요"]
        if len(admins) >= 2:
            rep.vuln("1.1", ev, admins)
        else:
            rep.man("1.1", ev, admins)
    safe(rep, "1.1", c11)

    # 1.2 1인 1계정 — API로 판단 불가
    def c12():
        users = [u["UserName"] for u in iam.list_users()["Users"]]
        rep.man("1.2", [f"IAM 사용자 {len(users)}명: {', '.join(users)}",
                        "동일 담당자가 복수 계정을 보유하는지는 인터뷰로 확인 필요"], users)
    safe(rep, "1.2", c12)

    # 1.3 IAM 사용자 태그(식별정보) 설정
    def c13():
        users = iam.list_users()["Users"]
        no_tag = []
        for u in users:
            tags = {t["Key"].lower(): t["Value"]
                    for t in iam.list_user_tags(UserName=u["UserName"]).get("Tags", [])}
            if not tags:
                no_tag.append(u["UserName"])
        if not users:
            rep.na("1.3", "IAM 사용자 없음")
        elif no_tag:
            rep.vuln("1.3", f"식별 태그(이름/이메일/부서 등)가 없는 IAM 사용자: {', '.join(no_tag)}", no_tag)
        else:
            rep.good("1.3", f"IAM 사용자 {len(users)}명 모두 태그 설정됨")
    safe(rep, "1.3", c13)

    # 1.4 IAM 그룹 구성원 관리 — 인터뷰
    def c14():
        groups = iam.list_groups()["Groups"]
        lines = []
        for g in groups:
            m = [u["UserName"] for u in iam.get_group(GroupName=g["GroupName"])["Users"]]
            lines.append(f"{g['GroupName']}: {', '.join(m) if m else '(구성원 없음)'}")
        rep.man("1.4", ["IAM 그룹/구성원 현황 — 불필요 계정 포함 여부 인터뷰 확인:"] + lines,
                [g["GroupName"] for g in groups])
    safe(rep, "1.4", c14)

    # 1.5 Key Pair 접근 관리 — EC2 접속 방식
    def c15():
        no_key = []
        total = 0
        for r in _regions(sess):
            ec2 = sess.client("ec2", region_name=r)
            for res in ec2.get_paginator("describe_instances").paginate(
                    Filters=[{"Name": "instance-state-name",
                              "Values": ["running", "stopped"]}]):
                for resv in res["Reservations"]:
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

    # 1.6 Key Pair 보관 위치 — 인터뷰
    rep.man("1.6", "PEM 키 파일 보관 위치(개인 PC/공용 스토리지 등)는 담당자 인터뷰로 확인")

    # 1.7 Admin Console(root) 서비스 용도 사용
    def c17():
        root = next((r for r in cred_rows if r.get("user") == "<root_account>"), None)
        ev = []
        vuln = False
        if root:
            if root.get("access_key_1_active") == "true" or root.get("access_key_2_active") == "true":
                ev.append("루트 계정에 활성 Access Key 존재 → 서비스/CLI 용도 사용 의심"); vuln = True
            last = root.get("password_last_used", "")
            ev.append(f"루트 마지막 콘솔 사용: {last or 'N/A'}")
        ev.append("루트 계정의 리소스 생성·변경 이력은 CloudTrail 로 추가 확인 필요")
        (rep.vuln if vuln else rep.man)("1.7", ev)
    safe(rep, "1.7", c17)

    # 1.8 루트 Access Key + IAM Access Key 사용주기(90일)
    def c18():
        vuln, ev = [], []
        now = datetime.datetime.now(datetime.timezone.utc)
        for r in cred_rows:
            u = r.get("user")
            if u == "<root_account>":
                if r.get("access_key_1_active") == "true" or r.get("access_key_2_active") == "true":
                    vuln.append("root Access Key 존재")
                continue
            for idx in ("1", "2"):
                if r.get(f"access_key_{idx}_active") != "true":
                    continue
                rot = r.get(f"access_key_{idx}_last_rotated", "")
                try:
                    age = (now - datetime.datetime.fromisoformat(rot.replace("Z", "+00:00"))).days
                    if age > 90:
                        vuln.append(f"{u} key{idx} {age}일 경과")
                except Exception as _e:
                    if _is_denied(_e):
                        raise
        if vuln:
            rep.vuln("1.8", ["Access Key 사용주기 미관리:"] + vuln, vuln)
        else:
            rep.good("1.8", "루트 Access Key 없음 + IAM Access Key 90일 이내 교체")
    safe(rep, "1.8", c18)

    # 1.9 MFA
    def c19():
        vuln = []
        for r in cred_rows:
            u = r.get("user")
            if u == "<root_account>":
                if r.get("mfa_active") != "true":
                    vuln.append("root 계정 MFA 미설정")
                continue
            if r.get("password_enabled") == "true" and r.get("mfa_active") != "true":
                vuln.append(f"{u} (콘솔 로그인 가능, MFA 미설정)")
        if vuln:
            rep.vuln("1.9", ["MFA 미설정:"] + vuln, vuln)
        else:
            rep.good("1.9", "루트 및 콘솔 사용 IAM 계정 모두 MFA 활성")
    safe(rep, "1.9", c19)

    # 1.10 패스워드 정책
    def c110():
        try:
            p = iam.get_account_password_policy()["PasswordPolicy"]
        except iam.exceptions.NoSuchEntityException:
            rep.vuln("1.10", "계정 암호 정책이 설정되어 있지 않음")
            return
        bad = []
        if p.get("MinimumPasswordLength", 0) < 8:
            bad.append(f"최소길이 {p.get('MinimumPasswordLength')}(<8)")
        for k, lab in [("RequireSymbols", "특수문자"), ("RequireNumbers", "숫자"),
                       ("RequireUppercaseCharacters", "대문자"),
                       ("RequireLowercaseCharacters", "소문자")]:
            if not p.get(k):
                bad.append(f"{lab} 미요구")
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
    _eks_manual(rep, sess, ["1.11", "1.12", "1.13"])


# ============================ 2. 권한 관리 ============================
def _permission_mgmt(rep, sess, iam):

    # 2.1 인스턴스(EC2) 역할 정책 — 관리자/와일드카드 부여 여부
    def c21():
        bad = []
        roles = iam.get_paginator("list_roles")
        for page in roles.paginate():
            for role in page["Roles"]:
                trust = role.get("AssumeRolePolicyDocument", {})
                s = trust.get("Statement", [])
                s = [s] if isinstance(s, dict) else s
                svc = []
                for st in s:
                    pr = st.get("Principal", {}).get("Service", [])
                    pr = [pr] if isinstance(pr, str) else pr
                    svc += pr
                if "ec2.amazonaws.com" not in svc:
                    continue
                nm = role["RoleName"]
                attached = [p["PolicyArn"] for p in iam.list_attached_role_policies(
                    RoleName=nm)["AttachedPolicies"]]
                if any(a in _ADMIN_POLICY_ARNS for a in attached):
                    bad.append(f"{nm} (AdministratorAccess)")
                    continue
                for pol in iam.list_role_policies(RoleName=nm)["PolicyNames"]:
                    doc = iam.get_role_policy(RoleName=nm, PolicyName=pol)["PolicyDocument"]
                    if _policy_is_admin(doc):
                        bad.append(f"{nm} (인라인 {pol}: Action*/Resource*)")
        if bad:
            rep.vuln("2.1", ["EC2 역할에 과도한 권한:"] + bad, bad)
        else:
            rep.good("2.1", "EC2 인스턴스 역할에 관리자/와일드카드 정책 없음")
    safe(rep, "2.1", c21)

    # 2.2 / 2.3 — 역할·정책 전수 검토는 인터뷰
    def c2x(code, label):
        cnt = len(iam.list_roles()["Roles"])
        rep.man(code, [f"IAM 역할 {cnt}개 — {label} 권한이 서비스 역할에 맞게 최소화됐는지 정책 검토 필요"])
    safe(rep, "2.2", lambda: c2x("2.2", "네트워크 서비스"))
    safe(rep, "2.3", lambda: c2x("2.3", "기타 서비스"))


# ======================= 3. 가상 리소스 관리 ========================
def _virtual_resource(rep, sess):
    regions = _regions(sess)

    # 3.1 보안그룹 ANY(전체 포트/프로토콜) 개방
    def c31():
        def scan(ec2, r):
            hits = []
            for sg in ec2.describe_security_groups()["SecurityGroups"]:
                for direction, key in (("인바운드", "IpPermissions"),
                                       ("아웃바운드", "IpPermissionsEgress")):
                    for perm in sg.get(key, []):
                        opens = any(ip.get("CidrIp") == "0.0.0.0/0"
                                    for ip in perm.get("IpRanges", []))
                        opens = opens or any(ip.get("CidrIpv6") == "::/0"
                                             for ip in perm.get("Ipv6Ranges", []))
                        if not opens:
                            continue
                        proto = perm.get("IpProtocol")
                        fr, to = perm.get("FromPort"), perm.get("ToPort")
                        if proto == "-1" or (fr == 0 and to == 65535):
                            hits.append(f"{sg['GroupId']}({r}) {direction} 전체 허용")
            return hits
        bad = _each_region(sess, "ec2", scan)
        if bad:
            rep.vuln("3.1", ["보안그룹 ANY 개방:"] + sorted(set(bad)), sorted(set(bad)))
        else:
            rep.good("3.1", "보안그룹에 전체 포트/프로토콜(0.0.0.0/0, ANY) 개방 규칙 없음")
    safe(rep, "3.1", c31)

    # 3.2 보안그룹 불필요 정책 — 민감 포트 인터넷 개방
    def c32():
        hit = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for sg in ec2.describe_security_groups()["SecurityGroups"]:
                for perm in sg.get("IpPermissions", []):
                    pub = any(ip.get("CidrIp") == "0.0.0.0/0" for ip in perm.get("IpRanges", []))
                    if not pub:
                        continue
                    fr, to = perm.get("FromPort"), perm.get("ToPort")
                    for p, name in _SENSITIVE_PORTS.items():
                        if fr is not None and to is not None and fr <= p <= to:
                            hit.append(f"{sg['GroupId']}({r}) {name}/{p} 0.0.0.0/0")
        if hit:
            rep.vuln("3.2", ["민감 포트가 인터넷(0.0.0.0/0)에 개방:"] + sorted(set(hit)), sorted(set(hit)))
        else:
            rep.man("3.2", "민감 포트의 인터넷 개방은 없음. 그 외 Source/Destination 최소화 여부는 규칙 검토 필요")
    safe(rep, "3.2", c32)

    # 3.3 네트워크 ACL 전체 허용
    def c33():
        allow_all = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for acl in ec2.describe_network_acls()["NetworkAcls"]:
                for e in acl["Entries"]:
                    if (e["RuleAction"] == "allow" and e["Protocol"] == "-1"
                            and e.get("CidrBlock") in ("0.0.0.0/0", None)
                            and e["RuleNumber"] < 32767):
                        d = "인바운드" if not e["Egress"] else "아웃바운드"
                        allow_all.append(f"{acl['NetworkAclId']}({r}) {d} 전체 허용")
        # 기본 NACL 은 원래 전체 허용이므로 '커스텀 규칙도 전체 허용'이면 취약으로 본다
        if allow_all:
            rep.man("3.3", ["네트워크 ACL 전체 허용 규칙 존재(기본 NACL 포함):"] + sorted(set(allow_all)),
                    sorted(set(allow_all)))
        else:
            rep.good("3.3", "네트워크 ACL에 0.0.0.0/0 전체 허용 규칙 없음")
    safe(rep, "3.3", c33)

    # 3.4 라우팅 테이블 ANY(0.0.0.0/0)
    def c34():
        rts = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for rt in ec2.describe_route_tables()["RouteTables"]:
                for route in rt["Routes"]:
                    if route.get("DestinationCidrBlock") == "0.0.0.0/0":
                        tgt = route.get("GatewayId") or route.get("NatGatewayId") or \
                            route.get("TransitGatewayId") or route.get("NetworkInterfaceId") or "?"
                        rts.append(f"{rt['RouteTableId']}({r}) → {tgt}")
        if rts:
            rep.man("3.4", ["0.0.0.0/0 라우팅 존재(퍼블릭 서브넷은 정상일 수 있음, 대상 검토):"] + rts, rts)
        else:
            rep.good("3.4", "0.0.0.0/0 라우팅 규칙 없음")
    safe(rep, "3.4", c34)

    # 3.5 인터넷 게이트웨이 연결 — 인터뷰
    def c35():
        igws = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for igw in ec2.describe_internet_gateways()["InternetGateways"]:
                att = [a["VpcId"] for a in igw.get("Attachments", [])]
                igws.append(f"{igw['InternetGatewayId']}({r}) → {att or '미연결'}")
        rep.man("3.5", ["IGW 목록 — 불필요 연결 여부 검토:"] + igws, igws)
    safe(rep, "3.5", c35)

    # 3.6 NAT 게이트웨이 연결 — 인터뷰
    def c36():
        nats = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for nat in ec2.describe_nat_gateways()["NatGateways"]:
                nats.append(f"{nat['NatGatewayId']}({r}) subnet={nat.get('SubnetId')} state={nat.get('State')}")
        if not nats:
            rep.na("3.6", "NAT 게이트웨이 없음")
        else:
            rep.man("3.6", ["NAT GW 목록 — 연결 리소스 목적 확인:"] + nats, nats)
    safe(rep, "3.6", c36)

    # 3.7 S3 퍼블릭 액세스
    def c37():
        s3 = sess.client("s3")
        buckets = s3.list_buckets()["Buckets"]
        if not buckets:
            rep.na("3.7", "S3 버킷 없음")
            return
        public = []
        for b in buckets:
            name = b["Name"]
            blocked = False
            try:
                pab = s3.get_public_access_block(Bucket=name)["PublicAccessBlockConfiguration"]
                blocked = all(pab.get(k) for k in ("BlockPublicAcls", "IgnorePublicAcls",
                                                   "BlockPublicPolicy", "RestrictPublicBuckets"))
            except Exception as _e:
                if _is_denied(_e):
                    raise
            if blocked:
                continue
            try:
                st = s3.get_bucket_policy_status(Bucket=name)["PolicyStatus"]
                if st.get("IsPublic"):
                    public.append(f"{name} (버킷 정책 public)")
                    continue
            except Exception as _e:
                if _is_denied(_e):
                    raise
            try:
                for g in s3.get_bucket_acl(Bucket=name)["Grants"]:
                    uri = g.get("Grantee", {}).get("URI", "")
                    if "AllUsers" in uri or "AuthenticatedUsers" in uri:
                        public.append(f"{name} (ACL {uri.split('/')[-1]})")
                        break
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if public:
            rep.vuln("3.7", ["퍼블릭 액세스 차단이 없고 공개된 버킷:"] + public, public)
        else:
            rep.good("3.7", f"S3 버킷 {len(buckets)}개 모두 퍼블릭 액세스 차단 또는 비공개")
    safe(rep, "3.7", c37)

    # 3.8 RDS 서브넷 가용영역 — 인터뷰 / NA
    def c38():
        found = []
        for r in regions:
            try:
                rds = sess.client("rds", region_name=r)
                for g in rds.describe_db_subnet_groups()["DBSubnetGroups"]:
                    azs = sorted({s["SubnetAvailabilityZone"]["Name"]
                                  for s in g["Subnets"]})
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
    _eks_manual(rep, sess, ["3.9"])

    # 3.10 ELB 연결 — 인터뷰
    def c310():
        lbs = []
        for r in regions:
            try:
                elbv2 = sess.client("elbv2", region_name=r)
                for lb in elbv2.describe_load_balancers()["LoadBalancers"]:
                    lbs.append(f"{lb['LoadBalancerName']}({r}) scheme={lb['Scheme']}")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if not lbs:
            rep.na("3.10", "로드밸런서 없음")
        else:
            rep.man("3.10", ["ELB 목록 — 연결/노출 정책 준수 여부 검토:"] + lbs, lbs)
    safe(rep, "3.10", c310)


# ========================= 4. 운영 관리 ============================
def _operation_mgmt(rep, sess):
    regions = _regions(sess)

    # 4.1 EBS 볼륨 암호화
    def c41():
        unenc, total = [], 0
        default_on = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            try:
                if ec2.get_ebs_encryption_by_default()["EbsEncryptionByDefault"]:
                    default_on.append(r)
            except Exception as _e:
                if _is_denied(_e):
                    raise
            for v in ec2.describe_volumes()["Volumes"]:
                total += 1
                if not v.get("Encrypted"):
                    unenc.append(f"{v['VolumeId']}({r})")
        if total == 0:
            rep.na("4.1", "EBS 볼륨 없음")
        elif unenc:
            rep.vuln("4.1", [f"암호화 안 된 EBS 볼륨 {len(unenc)}/{total}: " + ", ".join(unenc),
                             f"기본 암호화 활성 리전: {default_on or '없음'}"], unenc)
        else:
            rep.good("4.1", f"EBS 볼륨 {total}개 모두 암호화됨")
    safe(rep, "4.1", c41)

    # 4.2 RDS 암호화
    def c42():
        unenc, total = [], 0
        for r in regions:
            try:
                rds = sess.client("rds", region_name=r)
                for db in rds.describe_db_instances()["DBInstances"]:
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

    # 4.3 S3 암호화
    def c43():
        s3 = sess.client("s3")
        buckets = s3.list_buckets()["Buckets"]
        if not buckets:
            rep.na("4.3", "S3 버킷 없음")
            return
        no_enc = []
        for b in buckets:
            try:
                s3.get_bucket_encryption(Bucket=b["Name"])
            except Exception as e:
                if "ServerSideEncryptionConfigurationNotFoundError" in str(e):
                    no_enc.append(b["Name"])
        if no_enc:
            rep.vuln("4.3", "기본 암호화 미설정 버킷: " + ", ".join(no_enc), no_enc)
        else:
            rep.good("4.3", f"S3 버킷 {len(buckets)}개 모두 서버 측 암호화(SSE) 설정")
    safe(rep, "4.3", c43)

    # 4.4 통신구간 암호화 — ELB 리스너 TLS
    def c44():
        http_only = []
        total = 0
        for r in regions:
            try:
                elbv2 = sess.client("elbv2", region_name=r)
                for lb in elbv2.describe_load_balancers()["LoadBalancers"]:
                    total += 1
                    ls = elbv2.describe_listeners(
                        LoadBalancerArn=lb["LoadBalancerArn"])["Listeners"]
                    protos = {li["Protocol"] for li in ls}
                    has_secure = bool(protos & {"HTTPS", "TLS"})
                    # HTTP 이지만 HTTPS 로 redirect 하면 허용
                    redirect = any(
                        li["Protocol"] == "HTTP" and any(
                            a["Type"] == "redirect" and a.get("RedirectConfig", {}).get("Protocol") == "HTTPS"
                            for a in li.get("DefaultActions", []))
                        for li in ls)
                    if not has_secure and not redirect:
                        http_only.append(f"{lb['LoadBalancerName']}({r}) 리스너={sorted(protos)}")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if total == 0:
            rep.na("4.4", "로드밸런서 없음 — 통신구간 암호화는 애플리케이션 레벨에서 확인")
        elif http_only:
            rep.vuln("4.4", ["HTTPS/TLS 리스너가 없는 로드밸런서:"] + http_only, http_only)
        else:
            rep.good("4.4", f"로드밸런서 {total}개 모두 HTTPS/TLS 종단 또는 HTTPS 리다이렉트")
    safe(rep, "4.4", c44)

    # 4.5 CloudTrail 암호화(SSE-KMS)
    def c45():
        found, no_kms = [], []
        for r in regions:
            try:
                ct = sess.client("cloudtrail", region_name=r)
                for t in ct.describe_trails(includeShadowTrails=False)["trailList"]:
                    found.append(t["Name"])
                    if not t.get("KmsKeyId"):
                        no_kms.append(t["Name"])
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if not found:
            rep.na("4.5", "CloudTrail 추적 없음 (4.7 참고)")
        elif no_kms:
            rep.vuln("4.5", "SSE-KMS 암호화가 없는 CloudTrail: " + ", ".join(sorted(set(no_kms))))
        else:
            rep.good("4.5", "CloudTrail 로그가 SSE-KMS 로 암호화됨")
    safe(rep, "4.5", c45)

    # 4.6 CloudWatch Logs KMS
    def c46():
        no_kms, total = [], 0
        for r in regions:
            try:
                logs = sess.client("logs", region_name=r)
                for pg in logs.get_paginator("describe_log_groups").paginate():
                    for lg in pg["logGroups"]:
                        total += 1
                        if not lg.get("kmsKeyId"):
                            no_kms.append(f"{lg['logGroupName']}({r})")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if total == 0:
            rep.na("4.6", "CloudWatch 로그 그룹 없음")
        elif no_kms:
            rep.vuln("4.6", [f"KMS 키 미설정 로그 그룹 {len(no_kms)}/{total}"] +
                     no_kms[:20] + (["..."] if len(no_kms) > 20 else []), no_kms)
        else:
            rep.good("4.6", f"로그 그룹 {total}개 모두 KMS 키 설정")
    safe(rep, "4.6", c46)

    # 4.7 CloudTrail 관리 이벤트 로깅
    def c47():
        ok = []
        for r in regions:
            try:
                ct = sess.client("cloudtrail", region_name=r)
                for t in ct.describe_trails(includeShadowTrails=False)["trailList"]:
                    stt = ct.get_trail_status(Name=t["TrailARN"])
                    if not stt.get("IsLogging"):
                        continue
                    sels = ct.get_event_selectors(TrailName=t["TrailARN"])
                    mgmt = any(s.get("IncludeManagementEvents", True)
                               for s in sels.get("EventSelectors", [{}])) or \
                        bool(sels.get("AdvancedEventSelectors"))
                    if mgmt:
                        ok.append(f"{t['Name']} (multiRegion={t.get('IsMultiRegionTrail')})")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if ok:
            rep.good("4.7", "관리 이벤트를 기록하는 활성 CloudTrail: " + ", ".join(sorted(set(ok))))
        else:
            rep.vuln("4.7", "관리 이벤트를 기록하는 활성 CloudTrail 추적이 없음")
    safe(rep, "4.7", c47)

    # 4.8 인스턴스 로깅 — 인터뷰
    def c48():
        ec2_total = 0
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            for res in ec2.describe_instances(
                    Filters=[{"Name": "instance-state-name", "Values": ["running", "stopped"]}])["Reservations"]:
                ec2_total += len(res["Instances"])
        if ec2_total == 0:
            rep.na("4.8", "EC2 인스턴스 없음")
        else:
            rep.man("4.8", f"EC2 {ec2_total}대 — CloudWatch Agent 로 OS/앱 로그를 로그 그룹에 수집 중인지 확인 필요")
    safe(rep, "4.8", c48)

    # 4.9 RDS 로깅
    def c49():
        no_log, total = [], 0
        for r in regions:
            try:
                rds = sess.client("rds", region_name=r)
                for db in rds.describe_db_instances()["DBInstances"]:
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

    # 4.10 S3 버킷 로깅
    def c410():
        s3 = sess.client("s3")
        buckets = s3.list_buckets()["Buckets"]
        if not buckets:
            rep.na("4.10", "S3 버킷 없음")
            return
        no_log = []
        for b in buckets:
            try:
                lg = s3.get_bucket_logging(Bucket=b["Name"])
                if not lg.get("LoggingEnabled"):
                    no_log.append(b["Name"])
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if no_log:
            rep.man("4.10", ["서버 액세스 로깅 미설정 버킷(로그 보관용 버킷은 필수):"] + no_log, no_log)
        else:
            rep.good("4.10", f"S3 버킷 {len(buckets)}개 모두 서버 액세스 로깅 설정")
    safe(rep, "4.10", c410)

    # 4.11 VPC 플로우 로그
    def c411():
        missing = []
        for r in regions:
            ec2 = sess.client("ec2", region_name=r)
            vpcs = [v["VpcId"] for v in ec2.describe_vpcs()["Vpcs"]]
            fl_vpcs = {f["ResourceId"] for f in ec2.describe_flow_logs()["FlowLogs"]}
            for v in vpcs:
                if v not in fl_vpcs:
                    missing.append(f"{v}({r})")
        if missing:
            rep.vuln("4.11", "플로우 로그 미설정 VPC: " + ", ".join(missing), missing)
        else:
            rep.good("4.11", "모든 VPC에 플로우 로그 설정")
    safe(rep, "4.11", c411)

    # 4.12 로그 보관기간 (>=1년)
    def c412():
        short = []
        for r in regions:
            try:
                logs = sess.client("logs", region_name=r)
                for pg in logs.get_paginator("describe_log_groups").paginate():
                    for lg in pg["logGroups"]:
                        ret = lg.get("retentionInDays")
                        if ret is not None and ret < 365:
                            short.append(f"{lg['logGroupName']}({r}) {ret}일")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if short:
            rep.vuln("4.12", ["보관기간 1년 미만 로그 그룹:"] + short[:20] +
                     (["..."] if len(short) > 20 else []), short)
        else:
            rep.good("4.12", "로그 그룹 보관기간이 1년 이상이거나 무기한")
    safe(rep, "4.12", c412)

    # 4.13 백업 사용 여부
    def c413():
        ev = []
        has = False
        for r in regions:
            try:
                bk = sess.client("backup", region_name=r)
                plans = bk.list_backup_plans()["BackupPlansList"]
                if plans:
                    has = True
                    ev.append(f"AWS Backup 계획 {len(plans)}개({r})")
            except Exception as _e:
                if _is_denied(_e):
                    raise
            try:
                rds = sess.client("rds", region_name=r)
                auto = [d["DBInstanceIdentifier"] for d in rds.describe_db_instances()["DBInstances"]
                        if d.get("BackupRetentionPeriod", 0) > 0]
                if auto:
                    has = True
                    ev.append(f"RDS 자동 백업 {len(auto)}개({r})")
            except Exception as _e:
                if _is_denied(_e):
                    raise
        if has:
            rep.man("4.13", ev + ["백업 정책 문서/주기 적정성은 인터뷰 확인"])
        else:
            rep.vuln("4.13", "AWS Backup 계획/RDS 자동 백업 등 백업 설정이 확인되지 않음")
    safe(rep, "4.13", c413)

    # 4.14 / 4.15 EKS
    _eks_manual(rep, sess, ["4.14", "4.15"])


# --------------------------------------------------------------------------
def _eks_manual(rep, sess, codes):
    """EKS 항목: 클러스터 없으면 N/A, 있으면 kubectl 필요 → 수동확인.

    4.14(제어플레인 로깅) / 4.15(암호 암호화) 는 describe_cluster 로 자동 판정한다.
    """
    clusters = []
    for r in _regions(sess):
        try:
            eks = sess.client("eks", region_name=r)
            for name in eks.list_clusters()["clusters"]:
                clusters.append((r, name))
        except Exception as _e:
            if _is_denied(_e):
                raise

    if not clusters:
        for c in codes:
            if not rep.done(c):
                rep.na(c, "EKS 클러스터 없음")
        return

    names = [f"{n}({r})" for r, n in clusters]
    for c in codes:
        if rep.done(c):
            continue
        if c == "4.14":
            bad = []
            for r, n in clusters:
                try:
                    cl = sess.client("eks", region_name=r).describe_cluster(name=n)["cluster"]
                    types = set()
                    for lg in cl.get("logging", {}).get("clusterLogging", []):
                        if lg.get("enabled"):
                            types |= set(lg.get("types", []))
                    need = {"api", "audit", "authenticator", "controllerManager", "scheduler"}
                    if not need.issubset(types):
                        bad.append(f"{n}({r}) 활성 로그={sorted(types) or '없음'}")
                except Exception as _e:
                    if _is_denied(_e):
                        raise
            rep.vuln("4.14", ["제어 플레인 로그 유형이 일부만 활성:"] + bad, bad) if bad \
                else rep.good("4.14", "EKS 제어 플레인 로그 5종 모두 활성")
        elif c == "4.15":
            bad = []
            for r, n in clusters:
                try:
                    cl = sess.client("eks", region_name=r).describe_cluster(name=n)["cluster"]
                    if not cl.get("encryptionConfig"):
                        bad.append(f"{n}({r})")
                except Exception as _e:
                    if _is_denied(_e):
                        raise
            rep.vuln("4.15", "암호 암호화(Secrets Encryption) 미설정: " + ", ".join(bad), bad) if bad \
                else rep.good("4.15", "EKS 클러스터 암호 암호화 활성")
        else:
            rep.man(c, [f"EKS 클러스터: {', '.join(names)}",
                        "이 항목은 kubectl(클러스터 접근) 로 aws-auth/ServiceAccount/RBAC/PSS 확인 필요"], names)
