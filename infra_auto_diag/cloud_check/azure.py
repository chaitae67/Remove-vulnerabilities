#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Azure 클라우드 취약점 진단 (SK Shieldus 2024 클라우드 보안가이드 41항목).

READ-ONLY — list/get 만 호출. 리소스를 변경하지 않는다.
필요 권한:
  - 구독 `Reader` (서비스 주체)                       → 리소스/설정 조회
  - (선택) Microsoft Graph `Directory.Read.All`       → AD 사용자/MFA/게스트 항목
    없으면 AD 관련 항목은 '수동확인' 으로 표기.

pip: azure-identity azure-mgmt-resource azure-mgmt-authorization
     azure-mgmt-network azure-mgmt-storage azure-mgmt-compute
     azure-mgmt-monitor azure-mgmt-containerservice
"""
from .base import Reporter, safe, GOOD, VULN, NA, MAN
from .azure_items import ITEMS

_ANY_SRC = {"*", "0.0.0.0/0", "internet", "any"}
_SENSITIVE_PORTS = ("22", "3389", "3306", "5432", "6379", "27017", "1433", "9200", "445", "23")


def _credential(creds):
    if creds.get("tenant_id") and creds.get("client_id") and creds.get("client_secret"):
        from azure.identity import ClientSecretCredential
        return ClientSecretCredential(creds["tenant_id"], creds["client_id"],
                                      creds["client_secret"])
    from azure.identity import DefaultAzureCredential
    return DefaultAzureCredential(exclude_interactive_browser_credential=True)


def run(creds):
    cred = _credential(creds)
    sub = creds.get("subscription_id") or ""

    # 자격/구독 유효성 확인
    try:
        from azure.mgmt.resource import SubscriptionClient
        subs = {s.subscription_id: s.display_name
                for s in SubscriptionClient(cred).subscriptions.list()}
        if not sub:
            if len(subs) == 1:
                sub = next(iter(subs))
            else:
                raise RuntimeError(f"구독 ID를 지정하세요. 접근 가능한 구독: {list(subs)}")
        if sub not in subs:
            raise RuntimeError(f"구독 {sub} 에 접근할 수 없습니다. 접근 가능: {list(subs)}")
        sub_name = subs.get(sub, sub)
    except RuntimeError:
        raise
    except Exception as e:
        raise RuntimeError(
            "Azure 자격증명이 유효하지 않습니다. Tenant/Client/Secret/Subscription 확인.\n"
            f"({type(e).__name__}: {e})")

    rep = Reporter(ITEMS)
    ctx = {"cred": cred, "sub": sub}

    _account(rep, ctx, creds)
    _permission(rep, ctx)
    _network(rep, ctx)
    _operation(rep, ctx)

    rep.fill_missing(MAN, "이번 버전 자동 점검 미지원 → Azure Portal 에서 수동 확인")
    return {"host": f"Azure 구독 {sub_name} ({sub})", "os": "Azure",
            "family": "cloud", "results": rep.results()}


# ---- Microsoft Graph (AD) --------------------------------------------------
def _graph_get(cred, path):
    """Graph REST GET. 권한 없으면 예외."""
    import json
    import urllib.request
    tok = cred.get_token("https://graph.microsoft.com/.default").token
    url = "https://graph.microsoft.com/v1.0" + path
    out, nxt = [], url
    while nxt:
        req = urllib.request.Request(nxt, headers={"Authorization": f"Bearer {tok}"})
        data = json.loads(urllib.request.urlopen(req, timeout=30).read())
        out += data.get("value", [])
        nxt = data.get("@odata.nextLink")
    return out


def _account(rep, ctx, creds):
    cred = ctx["cred"]

    def graph_users():
        return _graph_get(cred, "/users?$select=displayName,userPrincipalName,userType,"
                                "jobTitle,department,mobilePhone,accountEnabled")

    # 1.1 AD 전역관리자 다수 / 불필요 계정
    def c11():
        roles = _graph_get(cred, "/directoryRoles")
        ga = next((r for r in roles if r.get("displayName") in
                   ("전역 관리자", "Global Administrator")), None)
        admins = []
        if ga:
            admins = [m.get("userPrincipalName") or m.get("displayName")
                      for m in _graph_get(cred, f"/directoryRoles/{ga['id']}/members")]
        ev = [f"전역 관리자 {len(admins)}명: {', '.join(a for a in admins if a) or '없음'}",
              "불필요 계정(퇴직/테스트/외부) 존재 여부는 인터뷰 확인"]
        (rep.vuln if len(admins) >= 2 else rep.man)("1.1", ev, admins)
    safe(rep, "1.1", c11)

    # 1.2 프로필 필수 항목
    def c12():
        users = graph_users()
        bad = [u["userPrincipalName"] for u in users
               if u.get("userType") == "Member" and not (u.get("jobTitle") and u.get("department"))]
        if not users:
            rep.na("1.2", "AD 사용자 없음")
        elif bad:
            rep.vuln("1.2", f"프로필(직책/부서 등) 미작성: {', '.join(bad[:30])}", bad)
        else:
            rep.good("1.2", f"AD 멤버 {len(users)}명 프로필 필수 항목 작성됨")
    safe(rep, "1.2", c12)

    # 1.3 그룹 소유자/구성원
    def c13():
        groups = _graph_get(cred, "/groups?$select=displayName,id")
        bad = []
        for g in groups:
            owners = _graph_get(cred, f"/groups/{g['id']}/owners?$select=id")
            members = _graph_get(cred, f"/groups/{g['id']}/members?$select=id")
            if not owners or not members:
                bad.append(f"{g['displayName']}(소유자 {len(owners)}, 구성원 {len(members)})")
        if not groups:
            rep.na("1.3", "AD 그룹 없음")
        elif bad:
            rep.vuln("1.3", ["소유자 또는 구성원이 없는 그룹:"] + bad, bad)
        else:
            rep.good("1.3", f"AD 그룹 {len(groups)}개 모두 소유자·구성원 설정됨")
    safe(rep, "1.3", c13)

    # 1.4 게스트 사용자
    def c14():
        guests = [u["userPrincipalName"] for u in graph_users()
                  if u.get("userType") == "Guest"]
        if guests:
            rep.vuln("1.4", f"게스트 사용자 {len(guests)}명: {', '.join(guests[:30])}", guests)
        else:
            rep.good("1.4", "게스트 사용자 계정 없음")
    safe(rep, "1.4", c14)

    # 1.5 암호 재설정 규칙 — 정책(SSPR) 확인은 인터뷰
    rep.man("1.5", "AD 암호 재설정(SSPR) 규칙이 사내 기준에 맞는지 정책 확인 필요")

    # 1.6 SSH Key 접근 관리 — 인터뷰
    rep.man("1.6", "SSH 키 생성/변경/삭제 권한이 관리자·소유자로 제한됐는지 RBAC/정책 확인 필요")

    # 1.7 MFA
    def c17():
        # per-user MFA 상태는 보고서 API(beta) 필요 → CA 정책 존재로 근거
        rows = _graph_get(cred, "/reports/authenticationMethods/userRegistrationDetails"
                                "?$select=userPrincipalName,isMfaRegistered")
        no_mfa = [r["userPrincipalName"] for r in rows if not r.get("isMfaRegistered")]
        if not rows:
            rep.man("1.7", "MFA 등록 현황 조회 불가 → 조건부 액세스/보안 기본값 정책 확인 필요")
        elif no_mfa:
            rep.vuln("1.7", f"MFA 미등록 사용자 {len(no_mfa)}명: {', '.join(no_mfa[:30])}", no_mfa)
        else:
            rep.good("1.7", f"AD 사용자 {len(rows)}명 모두 MFA 등록")
    safe(rep, "1.7", c17)

    # 1.8 MFA 계정 잠금 정책 — 인터뷰
    rep.man("1.8", "스마트 잠금(임계값/기간)이 사내 정책에 맞는지 Entra ID 인증 방법 설정 확인")

    # 1.9 패스워드 정책 — 인터뷰
    rep.man("1.9", "암호 보호(사용자 지정 금지 목록, 온-프렘 적용 등) 정책 준수 여부 확인")

    # 1.10 / 1.11 AKS
    _aks(rep, ctx, ["1.10", "1.11"])


def _permission(rep, ctx):
    cred, sub = ctx["cred"], ctx["sub"]

    # 2.1 구독 IAM 역할 — 광범위 역할(소유자/기여자 등) 사용자 직접 할당
    def c21():
        from azure.mgmt.authorization import AuthorizationManagementClient
        cli = AuthorizationManagementClient(cred, sub)
        broad = {"owner", "contributor", "user access administrator"}
        defs = {d.name: (d.role_name or "").lower()
                for d in cli.role_definitions.list(f"/subscriptions/{sub}")}
        hits = []
        for a in cli.role_assignments.list_for_subscription():
            rid = (a.role_definition_id or "").split("/")[-1]
            rn = defs.get(rid, "")
            if rn in broad and getattr(a, "principal_type", "") == "User":
                hits.append(f"{a.principal_id[:8]}… → {rn}")
        if hits:
            rep.vuln("2.1", ["사용자에게 광범위 역할(소유자/기여자 등) 직접 할당:"] + hits, hits)
        else:
            rep.good("2.1", "구독 수준에 사용자 직접 광범위 역할 할당 없음(그룹/서비스주체 위임)")
    safe(rep, "2.1", c21)

    # 2.2 리소스 그룹 IAM — 인터뷰(목적 적합성)
    def c22():
        from azure.mgmt.resource import ResourceManagementClient
        rgs = [g.name for g in ResourceManagementClient(cred, sub).resource_groups.list()]
        rep.man("2.2", [f"리소스 그룹 {len(rgs)}개 — 역할 할당이 목적에 맞는지 검토: "
                        + ", ".join(rgs[:40])], rgs)
    safe(rep, "2.2", c22)

    # 2.3 AD 역할 권한 — 인터뷰
    rep.man("2.3", "AD 관리 역할(디렉터리 역할) 부여가 업무 목적에 맞는지 검토 필요")
    # 2.4~2.6 서비스별 IAM — 인터뷰
    for c, lab in (("2.4", "인스턴스"), ("2.5", "네트워크"), ("2.6", "기타")):
        rep.man(c, f"{lab} 서비스 액세스 제어(IAM)가 사용자 역할에 맞게 최소 부여됐는지 검토")


def _network(rep, ctx):
    cred, sub = ctx["cred"], ctx["sub"]

    def net():
        from azure.mgmt.network import NetworkManagementClient
        return NetworkManagementClient(cred, sub)

    # 3.1 공용 IP — 내부 전용 리소스에 공용 IP
    def c31():
        pips = list(net().public_ip_addresses.list_all())
        attached = [p.name for p in pips if p.ip_configuration]
        rep.man("3.1", [f"공용 IP {len(pips)}개(연결됨 {len(attached)}): {', '.join(attached[:30])}",
                        "내부 전용 리소스에 불필요한 공용 IP가 붙어있는지 검토"], attached)
    safe(rep, "3.1", c31)

    # 3.2 내부 접근통제(VPN/Bastion)
    def c32():
        from azure.mgmt.resource import ResourceManagementClient
        bastions = [b.name for b in net().bastion_hosts.list()]
        vpngw = [r.name for r in ResourceManagementClient(cred, sub).resources.list(
            filter="resourceType eq 'Microsoft.Network/virtualNetworkGateways'")]
        if bastions or vpngw:
            rep.good("3.2", f"Bastion={bastions or '없음'} / VNet GW={vpngw or '없음'} 존재 "
                            "(대상 서브넷 적용 여부는 추가 확인)")
        else:
            rep.man("3.2", "Bastion/VPN 게이트웨이가 확인되지 않음 → 내부 리소스 접근통제 수단 확인")
    safe(rep, "3.2", c32)

    # 3.3 NSG ANY
    def c33():
        bad = []
        for g in net().network_security_groups.list_all():
            for rule in list(g.security_rules or []):
                if rule.access != "Allow":
                    continue
                src = (rule.source_address_prefix or "").lower()
                dports = [rule.destination_port_range or ""] + list(rule.destination_port_ranges or [])
                any_port = any(p in ("*", "0-65535") for p in dports)
                if src in _ANY_SRC and any_port:
                    bad.append(f"{g.name}/{rule.name} ({rule.direction}) src={src} port=*")
        if bad:
            rep.vuln("3.3", ["NSG 전체 허용(ANY) 규칙:"] + bad, bad)
        else:
            rep.good("3.3", "NSG에 Source·Port 전체 허용(ANY) 규칙 없음")
    safe(rep, "3.3", c33)

    # 3.4 NSG 불필요 — 민감포트 인터넷 개방
    def c34():
        hits = []
        for g in net().network_security_groups.list_all():
            for rule in list(g.security_rules or []):
                if rule.access != "Allow" or rule.direction != "Inbound":
                    continue
                src = (rule.source_address_prefix or "").lower()
                if src not in _ANY_SRC:
                    continue
                dports = [rule.destination_port_range or ""] + list(rule.destination_port_ranges or [])
                for p in _SENSITIVE_PORTS:
                    if p in dports:
                        hits.append(f"{g.name}/{rule.name} port {p} from {src}")
        if hits:
            rep.vuln("3.4", ["민감 포트가 인터넷에 개방:"] + hits, hits)
        else:
            rep.man("3.4", "민감 포트 인터넷 개방은 없음. 그 외 불필요 규칙은 규칙 검토 필요")
    safe(rep, "3.4", c34)

    # 3.5 Azure Firewall ANY
    def c35():
        fws = list(net().azure_firewalls.list_all())
        if not fws:
            rep.na("3.5", "Azure Firewall 없음")
            return
        bad = []
        for fw in fws:
            for coll in list(fw.network_rule_collections or []):
                if getattr(coll.action, "type", "") != "Allow":
                    continue
                for r in list(coll.rules or []):
                    if "*" in (r.source_addresses or []) and "*" in (r.destination_ports or []):
                        bad.append(f"{fw.name}/{coll.name}/{r.name}")
        rep.vuln("3.5", ["방화벽 ANY 허용 규칙:"] + bad, bad) if bad \
            else rep.good("3.5", f"Azure Firewall {len(fws)}개에 ANY 허용 규칙 없음")
    safe(rep, "3.5", c35)

    # 3.6 방화벽 불필요 — 인터뷰
    rep.man("3.6", "Azure Firewall 정책 내 불필요/미사용 규칙 존재 여부 검토")

    # 3.7 NAT 게이트웨이 서브넷
    def c37():
        nats = list(net().nat_gateways.list_all())
        if not nats:
            rep.na("3.7", "NAT 게이트웨이 없음")
            return
        info = [f"{g.name} → 서브넷 {len(g.subnets or [])}개" for g in nats]
        rep.man("3.7", ["NAT GW 연결 서브넷 — 퍼블릭 접속 불필요한 서브넷 연결 검토:"] + info, info)
    safe(rep, "3.7", c37)

    # 3.8 스토리지 계정 보안
    def c38():
        from azure.mgmt.storage import StorageManagementClient
        cli = StorageManagementClient(cred, sub)
        bad = []
        accts = list(cli.storage_accounts.list())
        for a in accts:
            probs = []
            if not a.enable_https_traffic_only:
                probs.append("HTTPS 전용 아님")
            if (a.minimum_tls_version or "").replace("TLS", "").replace("_", ".") < "1.2":
                probs.append(f"TLS<{a.minimum_tls_version}")
            if a.allow_blob_public_access:
                probs.append("Blob 퍼블릭 허용")
            if probs:
                bad.append(f"{a.name}: {', '.join(probs)}")
        if not accts:
            rep.na("3.8", "스토리지 계정 없음")
        elif bad:
            rep.vuln("3.8", ["스토리지 계정 보안 미흡:"] + bad, bad)
        else:
            rep.good("3.8", f"스토리지 계정 {len(accts)}개 HTTPS 전용+TLS1.2+퍼블릭 차단")
    safe(rep, "3.8", c38)

    # 3.9 SAS 정책 — 인터뷰
    rep.man("3.9", "스토리지 공유 액세스 서명(SAS) 권한·허용 IP가 최소인지 확인 필요")

    # 3.10 / 3.11 AKS
    _aks(rep, ctx, ["3.10", "3.11"])


def _operation(rep, ctx):
    cred, sub = ctx["cred"], ctx["sub"]

    # 4.1 DB 암호화(TDE) — 인터뷰/부분
    def c41():
        try:
            from azure.mgmt.sql import SqlManagementClient
        except ImportError:
            rep.man("4.1", "azure-mgmt-sql 미설치 → SQL TDE 수동 확인")
            return
        cli = SqlManagementClient(cred, sub)
        servers = list(cli.servers.list())
        if not servers:
            rep.na("4.1", "Azure SQL 서버 없음")
            return
        rep.man("4.1", [f"Azure SQL 서버 {len(servers)}개 — TDE(투명한 데이터 암호화) 활성 여부 확인 필요"])
    safe(rep, "4.1", c41)

    # 4.2 스토리지 암호화 — 기본 활성. CMK 사용 여부
    def c42():
        from azure.mgmt.storage import StorageManagementClient
        accts = list(StorageManagementClient(cred, sub).storage_accounts.list())
        if not accts:
            rep.na("4.2", "스토리지 계정 없음")
            return
        no_cmk = [a.name for a in accts
                  if not (a.encryption and getattr(a.encryption, "key_source", "") ==
                          "Microsoft.Keyvault")]
        rep.man("4.2", [f"스토리지 {len(accts)}개 모두 저장 암호화(기본). 고객 관리형 키(CMK) 미사용: "
                        + (", ".join(no_cmk) if no_cmk else "없음")], no_cmk)
    safe(rep, "4.2", c42)

    # 4.3 디스크 암호화
    def c43():
        from azure.mgmt.compute import ComputeManagementClient
        disks = list(ComputeManagementClient(cred, sub).disks.list())
        if not disks:
            rep.na("4.3", "관리 디스크 없음")
            return
        weak = [d.name for d in disks
                if not d.encryption or d.encryption.type == "EncryptionAtRestWithPlatformKey"
                and not getattr(d, "encryption_settings_collection", None)]
        # 플랫폼 키는 기본 암호화이므로 '취약'으로 보진 않되, CMK/ADE 없으면 근거로만
        rep.man("4.3", [f"관리 디스크 {len(disks)}개 모두 저장 시 암호화(플랫폼 키 기본). "
                        f"CMK/ADE 미적용: {', '.join(weak[:30]) if weak else '없음'}"], weak)
    safe(rep, "4.3", c43)

    # 4.4 통신구간 암호화 — 인터뷰
    rep.man("4.4", "App Gateway/LB/Front Door 등 통신 구간 TLS 적용 여부 확인 필요")

    # 4.5 Key Vault 회전 정책
    def c45():
        try:
            from azure.mgmt.keyvault import KeyVaultManagementClient
        except ImportError:
            rep.man("4.5", "azure-mgmt-keyvault 미설치 → 키 회전 정책 수동 확인")
            return
        vaults = list(KeyVaultManagementClient(cred, sub).vaults.list())
        if not vaults:
            rep.na("4.5", "Key Vault 없음")
            return
        rep.man("4.5", [f"Key Vault {len(vaults)}개 — 키 회전 정책이 90일 이내인지 확인 필요 "
                        "(키 회전 정책은 데이터 평면 권한 필요)"])
    safe(rep, "4.5", c45)

    # 4.6 AD 감사 로그 — 인터뷰
    rep.man("4.6", "Entra ID 진단 설정(감사/로그인 로그를 Log Analytics/스토리지로 보관) 확인 필요")

    # 4.7~4.9 서비스 감사 로그 — 진단 설정 존재 여부
    def diag_check(code, label):
        from azure.mgmt.monitor import MonitorManagementClient
        from azure.mgmt.resource import ResourceManagementClient
        mon = MonitorManagementClient(cred, sub)
        res = ResourceManagementClient(cred, sub)
        total, no_diag = 0, []
        for r in res.resources.list():
            if not any(k in (r.type or "").lower() for k in
                       ("virtualmachines", "networksecuritygroups", "storageaccounts",
                        "loadbalancers", "vaults", "sql")):
                continue
            total += 1
            try:
                ds = list(mon.diagnostic_settings.list(r.id).value or [])
                if not ds:
                    no_diag.append(r.name)
            except Exception:
                pass
        if total == 0:
            rep.na(code, f"{label} 대상 리소스 없음")
        elif no_diag:
            rep.vuln(code, [f"진단 설정 없는 리소스 {len(no_diag)}/{total}: "
                            + ", ".join(no_diag[:30])], no_diag)
        else:
            rep.good(code, f"{label} 관련 리소스 {total}개 모두 진단 설정 존재")
    safe(rep, "4.7", lambda: diag_check("4.7", "인스턴스"))
    safe(rep, "4.8", lambda: diag_check("4.8", "네트워크"))
    safe(rep, "4.9", lambda: diag_check("4.9", "기타"))

    # 4.10 리소스 그룹 잠금
    def c410():
        from azure.mgmt.resource import ResourceManagementClient
        try:
            from azure.mgmt.resource import ManagementLockClient
        except ImportError:
            from azure.mgmt.resource.locks import ManagementLockClient
        lock = ManagementLockClient(cred, sub)
        rgs = [g.name for g in ResourceManagementClient(cred, sub).resource_groups.list()]
        locked = set()
        for lk in lock.management_locks.list_at_subscription_level():
            sc = (lk.id or "")
            for g in rgs:
                if f"/resourceGroups/{g}/".lower() in sc.lower() or sc.lower().endswith(
                        f"/resourcegroups/{g}".lower()):
                    locked.add(g)
        unlocked = [g for g in rgs if g not in locked]
        rep.man("4.10", [f"리소스 그룹 {len(rgs)}개 중 잠금 미설정 {len(unlocked)}개: "
                         + ", ".join(unlocked[:40]),
                         "상용/운영 리소스 그룹은 삭제 잠금(CanNotDelete) 권장"], unlocked)
    safe(rep, "4.10", c410)

    # 4.11 백업
    def c411():
        try:
            from azure.mgmt.recoveryservices import RecoveryServicesClient
        except ImportError:
            rep.man("4.11", "azure-mgmt-recoveryservices 미설치 → 백업(Recovery Services Vault) 수동 확인")
            return
        vaults = list(RecoveryServicesClient(cred, sub).vaults.list_by_subscription_id())
        if vaults:
            rep.man("4.11", [f"Recovery Services 자격 증명 모음 {len(vaults)}개 존재 — "
                             "백업 정책/주기 적정성은 인터뷰 확인"])
        else:
            rep.vuln("4.11", "Recovery Services Vault 등 백업 설정이 확인되지 않음")
    safe(rep, "4.11", c411)

    # 4.12 / 4.13 AKS
    _aks(rep, ctx, ["4.12", "4.13"])


# ---- AKS -----------------------------------------------------------------
def _aks(rep, ctx, codes):
    cred, sub = ctx["cred"], ctx["sub"]
    try:
        from azure.mgmt.containerservice import ContainerServiceClient
        clusters = list(ContainerServiceClient(cred, sub).managed_clusters.list())
    except Exception as e:
        for c in codes:
            if not rep.done(c):
                rep.man(c, f"AKS 조회 실패: {e}")
        return

    if not clusters:
        for c in codes:
            if not rep.done(c):
                rep.na(c, "AKS 클러스터 없음")
        return

    names = [c.name for c in clusters]
    for code in codes:
        if rep.done(code):
            continue
        if code == "3.11":  # API 서버 권한 있는 IP 범위
            bad = []
            for c in clusters:
                prof = getattr(c, "api_server_access_profile", None)
                private = getattr(prof, "enable_private_cluster", False) if prof else False
                ipr = getattr(prof, "authorized_ip_ranges", None) if prof else None
                if not private and not ipr:
                    bad.append(c.name)
            rep.vuln("3.11", "API 서버에 권한 IP 범위/프라이빗 미설정: " + ", ".join(bad), bad) \
                if bad else rep.good("3.11", "AKS API 서버 접근이 IP 범위 또는 프라이빗으로 제한됨")
        elif code == "4.13":  # 진단 로그
            from azure.mgmt.monitor import MonitorManagementClient
            mon = MonitorManagementClient(cred, sub)
            bad = []
            for c in clusters:
                try:
                    if not list(mon.diagnostic_settings.list(c.id).value or []):
                        bad.append(c.name)
                except Exception:
                    bad.append(c.name)
            rep.vuln("4.13", "진단 설정 없는 AKS: " + ", ".join(bad), bad) if bad \
                else rep.good("4.13", "AKS 클러스터 모두 진단 로그 설정")
        else:
            rep.man(code, [f"AKS 클러스터: {', '.join(names)}",
                           "이 항목은 kubectl(클러스터 접근)로 ServiceAccount/RBAC/PSP/이미지 무결성 확인 필요"],
                    names)
