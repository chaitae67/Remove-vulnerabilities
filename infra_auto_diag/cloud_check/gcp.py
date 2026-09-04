#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GCP 클라우드 취약점 진단 (SK Shieldus 2024 클라우드 보안가이드 52항목).

READ-ONLY — list/get 만 호출. 리소스를 변경하지 않는다.
필요 권한: `roles/iam.securityReviewer` + `roles/viewer` (서비스계정).
Cloud ID / Google 계정 항목은 Admin SDK(도메인 관리자) 권한이 별도로 필요 → 수동확인.

pip: google-api-python-client google-auth
"""
import datetime

from .base import Reporter, safe, GOOD, VULN, NA, MAN
from .gcp_items import ITEMS

_SENSITIVE_PORTS = {"22", "3389", "3306", "5432", "6379", "27017", "1433", "9200", "445", "23", "11211"}


def _credentials(creds):
    scopes = ["https://www.googleapis.com/auth/cloud-platform.read-only",
              "https://www.googleapis.com/auth/cloud-platform"]
    path = creds.get("sa_key_path")
    if path:
        from google.oauth2 import service_account
        return service_account.Credentials.from_service_account_file(path, scopes=scopes)
    import google.auth
    c, _ = google.auth.default(scopes=scopes)
    return c


def _svc(cred, name, version):
    from googleapiclient.discovery import build
    return build(name, version, credentials=cred, cache_discovery=False)


def _api_err(e):
    """googleapiclient HttpError 를 분류: 'disabled' / 'denied' / 'notfound' / 'other'."""
    s = f"{type(e).__name__} {e}"
    if "SERVICE_DISABLED" in s or "has not been used in project" in s or "it is disabled" in s:
        return "disabled"
    if "PERMISSION_DENIED" in s or "does not have permission" in s or "403" in s and "disabled" not in s:
        return "denied"
    if "404" in s or "NOT_FOUND" in s:
        return "notfound"
    return "other"


def _resolve(rep, codes, e, service_label):
    """조회 실패 시 코드들을 상황에 맞게 채운다."""
    kind = _api_err(e)
    for c in codes:
        if rep.done(c):
            continue
        if kind == "disabled":
            rep.na(c, f"{service_label} API 가 프로젝트에 비활성 → 미사용으로 간주")
        elif kind == "denied":
            rep.man(c, f"{service_label} 조회 권한 부족 (roles/viewer 필요) → 수동 확인")
        elif kind == "notfound":
            rep.na(c, f"{service_label} 리소스 없음")
        else:
            rep.man(c, f"{service_label} 조회 실패: {e}")


def _page(coll, key, **kw):
    """discovery list 컬렉션을 nextPageToken 따라 모두 모은다.

    coll : 예) compute.firewalls()   (list / list_next 를 가진 객체)
    """
    out, req = [], coll.list(**kw)
    while req is not None:
        resp = req.execute()
        out += resp.get(key, [])
        req = coll.list_next(previous_request=req, previous_response=resp)
    return out


def run(creds):
    try:
        cred = _credentials(creds)
    except Exception as e:
        raise RuntimeError(
            "GCP 자격증명을 불러올 수 없습니다. 서비스계정 JSON 키 경로를 지정하거나 "
            f"gcloud ADC 를 설정하세요.\n({type(e).__name__}: {e})")

    project = creds.get("project_id") or getattr(cred, "project_id", "") or ""
    if not project:
        raise RuntimeError("GCP Project ID 를 지정하세요.")

    # 자격/프로젝트 유효성
    try:
        crm = _svc(cred, "cloudresourcemanager", "v1")
        proj = crm.projects().get(projectId=project).execute()
        pname = proj.get("name", project)
    except Exception as e:
        raise RuntimeError(
            "GCP 자격증명이 유효하지 않거나 프로젝트에 접근할 수 없습니다. "
            f"서비스계정 키 / Project ID 확인.\n({type(e).__name__}: {e})")

    rep = Reporter(ITEMS)
    ctx = {"cred": cred, "project": project, "crm": crm}

    _account(rep, ctx)
    _permission(rep, ctx)
    _network(rep, ctx)
    _operation(rep, ctx)

    rep.fill_missing(MAN, "이번 버전 자동 점검 미지원 → GCP 콘솔에서 수동 확인")
    return {"host": f"GCP 프로젝트 {pname} ({project})", "os": "GCP",
            "family": "cloud", "results": rep.results()}


def _iam_policy(ctx):
    return ctx["crm"].projects().getIamPolicy(
        resource=ctx["project"], body={"options": {"requestedPolicyVersion": 3}}).execute()


# ========================= 1. 계정 관리 =========================
def _account(rep, ctx):
    cred, project = ctx["cred"], ctx["project"]

    # 1.1 사용자 계정 관리 — 프로젝트 IAM 정책으로 광범위 권한 사용자 수 확인
    def c11():
        pol = _iam_policy(ctx)
        owners, all_users, ext = [], set(), []
        for b in pol.get("bindings", []):
            for m in b.get("members", []):
                if m.startswith("user:"):
                    u = m.split(":", 1)[1]
                    all_users.add(u)
                    if b["role"] in ("roles/owner", "roles/editor") or b["role"].endswith("Admin"):
                        owners.append(f"{u} ({b['role'].split('/')[-1]})")
                if m.startswith("group:") or m == "allUsers" or m == "allAuthenticatedUsers":
                    ext.append(m)
        ev = [f"IAM 사용자 {len(all_users)}명, 광범위 권한(owner/editor/*Admin) 보유: "
              + (", ".join(sorted(set(owners))) if owners else "없음"),
              "불필요 계정(협력사/테스트/퇴직자) 존재 여부는 담당자 인터뷰로 확인"]
        if ext:
            ev.append(f"⚠ 광범위 대상 바인딩: {', '.join(sorted(set(ext)))}")
        if len(set(owners)) >= 2 or ext:
            rep.vuln("1.1", ev, sorted(set(owners)))
        else:
            rep.man("1.1", ev, sorted(set(owners)))
    safe(rep, "1.1", c11)

    # 1.2~1.4, 1.9 : Cloud ID / Google Workspace 조직 설정 → 프로젝트 서비스계정으로는 조회 불가
    _WS = ("이 항목은 Google Workspace/Cloud ID 조직 관리 설정이라 프로젝트 권한(서비스계정)으로는 "
           "조회할 수 없습니다. admin.google.com(관리 콘솔)에서 직접 확인 → 인터뷰")
    rep.man("1.2", "Cloud ID 계정 정책(조직 단위/역할 위임). " + _WS)
    rep.man("1.3", "Cloud ID 패스워드 정책(길이/복잡성/만료/재사용). " + _WS)
    rep.man("1.9", "2단계 인증(MFA) 강제 정책. " + _WS)

    # 1.4 Identity Platform — 서비스 구성 존재 여부는 확인 가능
    def c14():
        try:
            it = _svc(cred, "identitytoolkit", "v2")
            cfg = it.projects().getConfig(name=f"projects/{project}/config").execute()
        except Exception as e:
            if _api_err(e) in ("disabled", "notfound"):
                rep.na("1.4", "Identity Platform(Identity Toolkit) 미사용")
                return
            rep.man("1.4", f"Identity Platform 조회 실패: {e}")
            return
        signin = cfg.get("signIn", {})
        rep.man("1.4", [f"Identity Platform 사용 중 (이메일 로그인={signin.get('email', {}).get('enabled')}, "
                        f"익명={signin.get('anonymous', {}).get('enabled')}) — 사용자 계정/공급자 적정성 검토"])
    safe(rep, "1.4", c14)

    # 1.5 API 활성화 및 사용 주기 (SA 키 오래된 것)
    def c15():
        su = _svc(cred, "serviceusage", "v1")
        enabled = _page(su.services(), "services", parent=f"projects/{project}", filter="state:ENABLED")
        iam = _svc(cred, "iam", "v1")
        sas = iam.projects().serviceAccounts().list(
            name=f"projects/{project}").execute().get("accounts", [])
        old, total_keys = [], 0
        now = datetime.datetime.now(datetime.timezone.utc)
        for sa in sas:
            keys = iam.projects().serviceAccounts().keys().list(
                name=sa["name"], keyTypes="USER_MANAGED").execute().get("keys", [])
            total_keys += len(keys)
            for k in keys:
                vb = k.get("validAfterTime", "")
                try:
                    age = (now - datetime.datetime.fromisoformat(vb.replace("Z", "+00:00"))).days
                    if age > 90:
                        old.append(f"{sa['email']} 키 {age}일")
                except Exception:
                    pass
        ev = [f"활성 API {len(enabled)}개, 사용자 관리 서비스계정 {len(sas)}개, 사용자 관리 키 {total_keys}개"]
        if old:
            rep.vuln("1.5", ev + ["90일 초과 서비스계정 키:"] + old, old)
        elif total_keys == 0:
            rep.na("1.5", ev + ["다운로드된 사용자 관리 서비스계정 키가 없음(권장 상태)"])
        else:
            rep.good("1.5", ev + ["90일 초과 서비스계정 키 없음"])
    safe(rep, "1.5", c15)

    # 1.6 SSH 키 사용 관리 (OS Login / block-project-ssh-keys)
    def c16():
        comp = _svc(cred, "compute", "v1")
        meta = {m["key"]: m["value"] for m in
                comp.projects().get(project=project).execute().get(
                    "commonInstanceMetadata", {}).get("items", [])}
        oslogin = meta.get("enable-oslogin", "").lower() == "true"
        block = meta.get("block-project-ssh-keys", "").lower() == "true"
        if oslogin:
            rep.good("1.6", "프로젝트 메타데이터 enable-oslogin=TRUE (IAM 기반 SSH 키 관리)")
        elif block:
            rep.man("1.6", "OS Login 미사용이나 block-project-ssh-keys=TRUE. 인스턴스별 키 관리 주체 확인")
        else:
            rep.vuln("1.6", "OS Login 미사용 + 프로젝트 SSH 키 차단 안 됨 → 키 관리 주체 불명확")
    safe(rep, "1.6", c16)

    # 1.7 메타데이터 관리 (프로젝트 OS Login / 직렬포트 / 프로젝트 SSH 키 차단)
    def c17():
        comp = _svc(cred, "compute", "v1")
        pmeta = {m["key"]: m["value"] for m in
                 comp.projects().get(project=project).execute().get(
                     "commonInstanceMetadata", {}).get("items", [])}
        bad = []
        if pmeta.get("enable-oslogin", "").lower() != "true":
            bad.append("프로젝트 enable-oslogin 미설정")
        agg = comp.instances().aggregatedList(project=project).execute().get("items", {})
        insts = [i for z in agg.values() for i in z.get("instances", [])]
        for i in insts:
            m = {x["key"]: x["value"] for x in i.get("metadata", {}).get("items", [])}
            if m.get("serial-port-enable", "").lower() in ("true", "1"):
                bad.append(f"{i['name']} 직렬 포트 활성")
            if m.get("enable-oslogin", pmeta.get("enable-oslogin", "")).lower() != "true":
                bad.append(f"{i['name']} OS Login 미적용")
        if bad:
            rep.vuln("1.7", ["메타데이터 보안 미흡:"] + sorted(set(bad)), sorted(set(bad)))
        elif not insts:
            rep.good("1.7", "프로젝트 enable-oslogin=TRUE, 인스턴스 없음")
        else:
            rep.good("1.7", f"프로젝트 OS Login 활성 + 인스턴스 {len(insts)}개 직렬포트 비활성/OS Login 적용")
    safe(rep, "1.7", c17)

    # 1.8 SQL 계정 관리
    def c18():
        sql = _svc(cred, "sqladmin", "v1")
        inst = sql.instances().list(project=project).execute().get("items", [])
        if not inst:
            rep.na("1.8", "Cloud SQL 인스턴스 없음")
            return
        rep.man("1.8", [f"Cloud SQL {len(inst)}개 — root/기본 계정 사용 여부, 계정별 접근제어 인터뷰 확인"],
                [i["name"] for i in inst])
    safe(rep, "1.8", c18)

    # 1.10~1.12 GKE
    _gke(rep, ctx, ["1.10", "1.11", "1.12"])


# ========================= 2. 권한 관리 =========================
def _permission(rep, ctx):
    def c2x(code, label):
        pol = _iam_policy(ctx)
        broad = []
        for b in pol.get("bindings", []):
            role = b["role"]
            if role in ("roles/owner", "roles/editor") or role.endswith("Admin"):
                users = [m for m in b.get("members", []) if m.startswith("user:")]
                if users:
                    broad.append(f"{role}: {', '.join(u.split(':')[1] for u in users)}")
        if broad:
            rep.vuln(code, [f"{label} — 사용자에게 광범위 역할(owner/editor/*Admin) 직접 부여:"] + broad, broad)
        else:
            rep.good(code, f"{label} — 사용자 직접 광범위 역할 부여 없음")
    safe(rep, "2.1", lambda: c2x("2.1", "인스턴스 서비스 정책"))
    # 2.2 / 2.3 은 같은 IAM 정책이라 첫 결과 재사용 없이 인터뷰로
    safe(rep, "2.2", lambda: rep.man("2.2", "네트워크 서비스 IAM 권한이 역할에 맞게 최소 부여됐는지 검토"))
    safe(rep, "2.3", lambda: rep.man("2.3", "기타 서비스 IAM 권한이 역할에 맞게 최소 부여됐는지 검토"))


# ==================== 3. 가상 리소스 관리 ====================
def _network(rep, ctx):
    cred, project = ctx["cred"], ctx["project"]
    comp = _svc(cred, "compute", "v1")

    def _instances():
        agg = comp.instances().aggregatedList(project=project).execute().get("items", {})
        return [i for z in agg.values() for i in z.get("instances", [])]

    # 3.1 ID 및 API 액세스 — 인스턴스 서비스계정 스코프
    def c31():
        bad = []
        insts = _instances()
        for i in insts:
            for sa in i.get("serviceAccounts", []):
                if "https://www.googleapis.com/auth/cloud-platform" in sa.get("scopes", []):
                    bad.append(f"{i['name']} ({sa.get('email')}: cloud-platform 전체)")
        if not insts:
            rep.na("3.1", "Compute 인스턴스 없음")
        elif bad:
            rep.vuln("3.1", ["인스턴스에 전체 API 액세스(cloud-platform) 스코프:"] + bad, bad)
        else:
            rep.good("3.1", "인스턴스 서비스계정 스코프가 최소화됨 (cloud-platform 전체 없음)")
    safe(rep, "3.1", c31)

    # 3.2 VM 인스턴스 보안 — Shielded VM / IP forwarding
    def c32():
        bad = []
        insts = _instances()
        for i in insts:
            if i.get("canIpForward"):
                bad.append(f"{i['name']} (IP 포워딩 허용)")
            sc = i.get("shieldedInstanceConfig", {})
            if not sc.get("enableSecureBoot"):
                bad.append(f"{i['name']} (Secure Boot 미설정)")
        if not insts:
            rep.na("3.2", "Compute 인스턴스 없음")
        elif bad:
            rep.man("3.2", ["점검 필요:"] + bad, bad)
        else:
            rep.good("3.2", f"인스턴스 {len(insts)}개 Secure Boot 활성 + IP 포워딩 비활성")
    safe(rep, "3.2", c32)

    # 3.3 애플리케이션 방화벽 — Cloud Armor
    def c33():
        try:
            pols = comp.securityPolicies().list(project=project).execute().get("items", [])
        except Exception:
            pols = []
        # 외부 HTTP(S) LB 가 있는데 Cloud Armor 가 없으면 취약, LB 자체가 없으면 N/A
        try:
            proxies = comp.targetHttpsProxies().list(project=project).execute().get("items", [])
            proxies += comp.targetHttpProxies().list(project=project).execute().get("items", [])
        except Exception:
            proxies = []
        if pols:
            rep.good("3.3", f"Cloud Armor 보안 정책 {len(pols)}개 적용")
        elif proxies:
            rep.vuln("3.3", f"외부 로드밸런서({len(proxies)}개)가 있으나 Cloud Armor(WAF) 정책이 없음")
        else:
            rep.na("3.3", "외부 로드밸런서 없음 → 애플리케이션 방화벽 대상 아님")
    safe(rep, "3.3", c33)

    # 3.4 방화벽 ANY
    def c34():
        fws = _page(comp.firewalls(), "items", project=project)
        bad = []
        for f in fws:
            if f.get("disabled"):
                continue
            if "0.0.0.0/0" not in f.get("sourceRanges", []):
                continue
            for a in f.get("allowed", []):
                ports = a.get("ports", [])
                if not ports or any(p in ("0-65535",) for p in ports) or a.get("IPProtocol") == "all":
                    bad.append(f"{f['name']} ({a.get('IPProtocol')}:{ports or 'all'})")
        if bad:
            rep.vuln("3.4", ["방화벽 전체 허용(0.0.0.0/0 + 전체 포트/프로토콜):"] + bad, bad)
        else:
            rep.good("3.4", "방화벽에 0.0.0.0/0 전체 포트 허용 규칙 없음")
    safe(rep, "3.4", c34)

    # 3.5 방화벽 불필요 — 민감포트 인터넷 개방
    def c35():
        fws = _page(comp.firewalls(), "items", project=project)
        hits = []
        for f in fws:
            if f.get("disabled") or "0.0.0.0/0" not in f.get("sourceRanges", []):
                continue
            for a in f.get("allowed", []):
                for p in a.get("ports", []):
                    lo = p.split("-")[0]
                    if lo in _SENSITIVE_PORTS:
                        hits.append(f"{f['name']} {a.get('IPProtocol')}/{p}")
        if hits:
            rep.vuln("3.5", ["민감 포트가 인터넷(0.0.0.0/0)에 개방:"] + hits, hits)
        else:
            rep.man("3.5", "민감 포트 인터넷 개방 없음. 그 외 불필요 규칙은 규칙 검토 필요")
    safe(rep, "3.5", c35)

    # 3.6 서브넷 관리 — 인터뷰
    def c36():
        agg = comp.subnetworks().aggregatedList(project=project).execute().get("items", {})
        allsubs = [s for z in agg.values() for s in z.get("subnetworks", [])]
        rep.man("3.6", [f"서브넷 {len(allsubs)}개 — 대역/용도 분리 및 불필요 서브넷 검토"],
                [s["name"] for s in allsubs])
    safe(rep, "3.6", c36)

    # 3.7 비공개 구글 액세스
    def c37():
        agg = comp.subnetworks().aggregatedList(project=project).execute().get("items", {})
        allsubs = [s for z in agg.values() for s in z.get("subnetworks", [])]
        off = [s["name"] for s in allsubs if not s.get("privateIpGoogleAccess")]
        if not allsubs:
            rep.na("3.7", "서브넷 없음")
        elif off:
            rep.vuln("3.7", "비공개 Google 액세스 미설정 서브넷: " + ", ".join(off), off)
        else:
            rep.good("3.7", "모든 서브넷에 비공개 Google 액세스 설정")
    safe(rep, "3.7", c37)

    # 3.8 공유 VPC — 인터뷰
    def c38():
        try:
            xpn = comp.projects().getXpnHost(project=project).execute()
            host = xpn.get("name")
        except Exception:
            host = None
        rep.man("3.8", f"공유 VPC 호스트: {host or '없음/해당없음'} — 연결 서비스 프로젝트 범위 검토")
    safe(rep, "3.8", c38)

    # 3.9 VPN 연결 — 인터뷰
    def c39():
        agg = comp.vpnTunnels().aggregatedList(project=project).execute().get("items", {})
        tuns = [t for z in agg.values() for t in z.get("vpnTunnels", [])]
        if not tuns:
            rep.na("3.9", "VPN 터널 없음")
        else:
            rep.man("3.9", [f"VPN 터널 {len(tuns)}개 — 대상/공유키/IKE 버전 적정성 검토"],
                    [t["name"] for t in tuns])
    safe(rep, "3.9", c39)

    # 3.10 / 3.12 Storage 버킷 ACL / 퍼블릭
    def storage_check():
        st = _svc(cred, "storage", "v1")
        buckets = st.buckets().list(project=project).execute().get("items", [])
        if not buckets:
            rep.na("3.10", "Storage 버킷 없음")
            rep.na("3.11", "Storage 버킷 없음")
            rep.na("3.12", "Storage 버킷 없음")
            return
        public, no_ubla, no_pap = [], [], []
        for b in buckets:
            name = b["name"]
            try:
                pol = st.buckets().getIamPolicy(bucket=name).execute()
                for bd in pol.get("bindings", []):
                    if set(bd.get("members", [])) & {"allUsers", "allAuthenticatedUsers"}:
                        public.append(f"{name} ({bd['role']})")
            except Exception:
                pass
            iamcfg = b.get("iamConfiguration", {})
            if not iamcfg.get("uniformBucketLevelAccess", {}).get("enabled"):
                no_ubla.append(name)
            # inherited(기본) 은 조직 정책에 위임된 상태 → 명시적으로 꺼진 경우만 취약
            if iamcfg.get("publicAccessPrevention") not in ("enforced", "inherited"):
                no_pap.append(name)
        rep.vuln("3.12", "퍼블릭(allUsers/allAuthenticatedUsers) 버킷: " + ", ".join(public), public) \
            if public else rep.good("3.12", f"버킷 {len(buckets)}개 모두 퍼블릭 접근 없음")
        rep.vuln("3.10", "균일 버킷 수준 액세스 미설정(세분화 ACL): " + ", ".join(no_ubla), no_ubla) \
            if no_ubla else rep.good("3.10", "모든 버킷 균일 버킷 수준 액세스(UBLA) 설정")
        rep.vuln("3.11", "공개 액세스 방지가 명시적으로 해제됨: " + ", ".join(no_pap), no_pap) \
            if no_pap else rep.good("3.11",
                                    f"버킷 {len(buckets)}개 공개 액세스 방지 enforced/inherited")
    safe(rep, "3.10", storage_check)

    # 3.13 GKE Pod 보안
    _gke(rep, ctx, ["3.13"])


# ========================= 4. 운영 관리 =========================
def _operation(rep, ctx):
    cred, project = ctx["cred"], ctx["project"]

    # 4.1 디스크 암호화 (기본 암호화 + CMEK)
    def c41():
        comp = _svc(cred, "compute", "v1")
        agg = comp.disks().aggregatedList(project=project).execute().get("items", {})
        disks = [d for z in agg.values() for d in z.get("disks", [])]
        if not disks:
            rep.na("4.1", "Compute 디스크 없음")
            return
        cmek = [d["name"] for d in disks if d.get("diskEncryptionKey", {}).get("kmsKeyName")]
        rep.man("4.1", [f"디스크 {len(disks)}개 모두 저장 시 암호화(기본). "
                        f"CMEK 사용: {len(cmek)}개"], cmek)
    safe(rep, "4.1", c41)

    # 4.2 이미지 암호화
    def c42():
        comp = _svc(cred, "compute", "v1")
        imgs = comp.images().list(project=project).execute().get("items", [])
        if not imgs:
            rep.na("4.2", "커스텀 이미지 없음")
        else:
            cmek = [i["name"] for i in imgs if i.get("imageEncryptionKey", {}).get("kmsKeyName")]
            rep.man("4.2", [f"커스텀 이미지 {len(imgs)}개(기본 암호화). CMEK: {len(cmek)}개"], cmek)
    safe(rep, "4.2", c42)

    # 4.3 SQL 암호화 / 4.6 SQL SSL
    def sql_check():
        sql = _svc(cred, "sqladmin", "v1")
        inst = sql.instances().list(project=project).execute().get("items", [])
        if not inst:
            rep.na("4.3", "Cloud SQL 없음")
            rep.na("4.6", "Cloud SQL 없음")
            return
        no_cmek = [i["name"] for i in inst if not i.get("diskEncryptionConfiguration")]
        rep.man("4.3", [f"Cloud SQL {len(inst)}개(기본 암호화). CMEK 미사용: "
                        + (", ".join(no_cmek) if no_cmek else "없음")], no_cmek)
        no_ssl = []
        for i in inst:
            ipc = i.get("settings", {}).get("ipConfiguration", {})
            mode = ipc.get("sslMode", "")
            if not ipc.get("requireSsl") and mode not in ("ENCRYPTED_ONLY", "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"):
                no_ssl.append(i["name"])
        rep.vuln("4.6", "SSL/TLS 강제 안 된 Cloud SQL: " + ", ".join(no_ssl), no_ssl) \
            if no_ssl else rep.good("4.6", f"Cloud SQL {len(inst)}개 모두 SSL 연결 강제")
    safe(rep, "4.3", sql_check)

    # 4.4 Storage 암호화 (default kms) / 4.5 데이터 보안
    def c44():
        st = _svc(cred, "storage", "v1")
        buckets = st.buckets().list(project=project).execute().get("items", [])
        if not buckets:
            rep.na("4.4", "Storage 버킷 없음")
            rep.na("4.5", "Storage 버킷 없음")
            return
        cmek = [b["name"] for b in buckets if b.get("encryption", {}).get("defaultKmsKeyName")]
        rep.man("4.4", [f"버킷 {len(buckets)}개 모두 저장 암호화(기본). 기본 CMEK: {len(cmek)}개"], cmek)
        no_ver = [b["name"] for b in buckets if not b.get("versioning", {}).get("enabled")]
        rep.man("4.5", [f"버전 관리 미설정 버킷: {', '.join(no_ver) if no_ver else '없음'} "
                        "(보존/버전/객체 잠금 정책 검토)"], no_ver)
    safe(rep, "4.4", c44)

    # 4.7 LB SSL 정책
    def c47():
        comp = _svc(cred, "compute", "v1")
        sslpols = {p["name"]: p for p in comp.sslPolicies().list(project=project).execute().get("items", [])}
        proxies = comp.targetHttpsProxies().list(project=project).execute().get("items", [])
        weak = []
        for p in proxies:
            pol = p.get("sslPolicy", "").split("/")[-1]
            if not pol:
                weak.append(f"{p['name']} (기본 정책=호환)")
            else:
                sp = sslpols.get(pol, {})
                if sp.get("minTlsVersion", "TLS_1_0") in ("TLS_1_0", "TLS_1_1") or \
                        sp.get("profile") == "COMPATIBLE":
                    weak.append(f"{p['name']} ({sp.get('profile')}, {sp.get('minTlsVersion')})")
        if not proxies:
            rep.na("4.7", "HTTPS 로드밸런서 없음")
        elif weak:
            rep.vuln("4.7", ["약한 SSL 정책:"] + weak, weak)
        else:
            rep.good("4.7", f"HTTPS 프록시 {len(proxies)}개 모두 강화된 SSL 정책(TLS1.2+)")
    safe(rep, "4.7", c47)

    # 4.8 App Engine SSL
    def c48():
        try:
            ae = _svc(cred, "appengine", "v1")
            app = ae.apps().get(appsId=project).execute()
        except Exception:
            rep.na("4.8", "App Engine 앱 없음")
            return
        rep.man("4.8", "App Engine — 커스텀 도메인 SSL 인증서 및 HTTPS 강제(secure: always) 확인 필요")
    safe(rep, "4.8", c48)

    # 4.9 통신구간 암호화 — 인터뷰
    rep.man("4.9", "LB/프록시/인터커넥트 등 통신 구간 TLS 적용 여부 확인 필요")

    # 4.10 / 4.11 감사 로그
    def audit_check():
        pol = _iam_policy(ctx)
        acfg = pol.get("auditConfigs", [])
        allsvc = next((a for a in acfg if a.get("service") == "allServices"), None)
        types = {c["logType"] for c in allsvc.get("auditLogConfigs", [])} if allsvc else set()
        need = {"ADMIN_READ", "DATA_READ", "DATA_WRITE"}
        if need.issubset(types):
            rep.good("4.10", "allServices 에 ADMIN_READ/DATA_READ/DATA_WRITE 감사 로그 설정")
        else:
            rep.vuln("4.10", f"데이터 액세스 감사 로그 미흡 (allServices 설정={sorted(types) or '없음'})")
        exempt = []
        for a in acfg:
            for c in a.get("auditLogConfigs", []):
                exempt += c.get("exemptedMembers", [])
        if exempt:
            rep.vuln("4.11", "감사 로그 면제 대상 존재: " + ", ".join(sorted(set(exempt))), sorted(set(exempt)))
        else:
            rep.good("4.11", "감사 로그 면제(exemptedMembers) 사용자 없음")
    safe(rep, "4.10", audit_check)

    # 4.12 VPC flow logs
    def c412():
        comp = _svc(cred, "compute", "v1")
        agg = comp.subnetworks().aggregatedList(project=project).execute().get("items", {})
        subs = [s for z in agg.values() for s in z.get("subnetworks", [])
                if s.get("purpose", "PRIVATE") == "PRIVATE"]
        off = [s["name"] for s in subs if not s.get("enableFlowLogs")]
        if not subs:
            rep.na("4.12", "일반 서브넷 없음")
        elif off:
            rep.vuln("4.12", "흐름 로그 미설정 서브넷: " + ", ".join(off), off)
        else:
            rep.good("4.12", "모든 서브넷에 VPC 흐름 로그 설정")
    safe(rep, "4.12", c412)

    # 4.13 방화벽 로그
    def c413():
        comp = _svc(cred, "compute", "v1")
        fws = _page(comp.firewalls(), "items", project=project)
        off = [f["name"] for f in fws if not f.get("disabled")
               and not f.get("logConfig", {}).get("enable")]
        if not fws:
            rep.na("4.13", "방화벽 규칙 없음")
        elif off:
            rep.vuln("4.13", f"로깅 비활성 방화벽 규칙 {len(off)}개: " + ", ".join(off[:30]), off)
        else:
            rep.good("4.13", "활성 방화벽 규칙 모두 로깅 설정")
    safe(rep, "4.13", c413)

    # 4.14 로그 보관 설정
    def c414():
        lg = _svc(cred, "logging", "v2")
        buckets = lg.projects().locations().buckets().list(
            parent=f"projects/{project}/locations/-").execute().get("buckets", [])
        short = [b["name"].split("/")[-1] for b in buckets
                 if 0 < b.get("retentionDays", 0) < 365]
        if short:
            rep.vuln("4.14", "보관기간 1년 미만 로그 버킷: " + ", ".join(short), short)
        else:
            rep.good("4.14", "로그 버킷 보관기간이 1년 이상")
    safe(rep, "4.14", c414)

    # 4.15~4.17 이상징후 알림 — 인터뷰 / monitoring
    def c417():
        try:
            mon = _svc(cred, "monitoring", "v3")
            pols = mon.projects().alertPolicies().list(name=f"projects/{project}").execute().get("alertPolicies", [])
        except Exception:
            pols = []
        rep.man("4.17", [f"모니터링 알림 정책 {len(pols)}개 — 가상 리소스 이상징후 알림 구성 검토"])
    rep.man("4.15", "Google 계정 사용자 이상징후 알림은 Admin Console(조직) 권한 필요 → 수동 확인")
    rep.man("4.16", "Cloud ID 계정 이상징후 알림은 Admin Console 권한 필요 → 수동 확인")
    safe(rep, "4.17", c417)

    # 4.18 백업
    def c418():
        sql = _svc(cred, "sqladmin", "v1")
        inst = sql.instances().list(project=project).execute().get("items", [])
        no_bk = [i["name"] for i in inst
                 if not i.get("settings", {}).get("backupConfiguration", {}).get("enabled")]
        ev = [f"Cloud SQL {len(inst)}개 중 자동 백업 미설정 {len(no_bk)}개"]
        if inst and no_bk:
            rep.vuln("4.18", ev + [", ".join(no_bk)], no_bk)
        elif inst:
            rep.man("4.18", ev + ["디스크 스냅샷 스케줄 등 전체 백업 정책은 인터뷰 확인"])
        else:
            rep.man("4.18", "Cloud SQL 없음 — 스냅샷 스케줄/백업 정책 존재 여부 인터뷰 확인")
    safe(rep, "4.18", c418)

    # 4.19~4.24 GKE
    _gke(rep, ctx, ["4.19", "4.20", "4.21", "4.22", "4.23", "4.24"])


# ---- GKE ----------------------------------------------------------------
def _gke(rep, ctx, codes):
    cred, project = ctx["cred"], ctx["project"]
    try:
        gke = _svc(cred, "container", "v1")
        clusters = gke.projects().locations().clusters().list(
            parent=f"projects/{project}/locations/-").execute().get("clusters", [])
    except Exception as e:
        _resolve(rep, codes, e, "Kubernetes Engine(GKE)")
        return
    if not clusters:
        for c in codes:
            if not rep.done(c):
                rep.na(c, "GKE 클러스터 없음")
        return

    names = [c["name"] for c in clusters]

    def any_bad(pred):
        return [c["name"] for c in clusters if pred(c)]

    checks = {
        "4.19": ("보안 GKE 노드(Shielded Nodes)",
                 lambda c: not c.get("shieldedNodes", {}).get("enabled")),
        "4.20": ("애플리케이션 레이어 비밀 암호화",
                 lambda c: c.get("databaseEncryption", {}).get("state") != "ENCRYPTED"),
        "4.21": ("워크로드 아이덴티티",
                 lambda c: not c.get("workloadIdentityConfig", {}).get("workloadPool")),
        "4.22": ("워크로드 취약점 스캔",
                 lambda c: (c.get("securityPostureConfig", {}).get("vulnerabilityMode")
                            in (None, "VULNERABILITY_DISABLED"))),
        "4.23": ("클러스터 로깅",
                 lambda c: not c.get("loggingConfig", {}).get("componentConfig", {}).get("enableComponents")),
        "4.24": ("클러스터 모니터링",
                 lambda c: not c.get("monitoringConfig", {}).get("componentConfig", {}).get("enableComponents")),
    }
    for code in codes:
        if rep.done(code):
            continue
        if code in checks:
            label, pred = checks[code]
            bad = any_bad(pred)
            rep.vuln(code, f"{label} 미설정 클러스터: {', '.join(bad)}", bad) if bad \
                else rep.good(code, f"GKE 클러스터 {len(clusters)}개 모두 {label} 설정")
        else:
            rep.man(code, [f"GKE 클러스터: {', '.join(names)}",
                           "이 항목은 kubectl 로 RBAC/ServiceAccount/Pod 보안 확인 필요"], names)
