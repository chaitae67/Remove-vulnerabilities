#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Naver Cloud Platform(NCP) 취약점 진단 — 네이버 클라우드 보고서 양식 v1.2(31항목).

읽기 전용. NCP Open API(VPC 환경)를 HMAC-SHA256 서명으로 호출한다.
자동 판정이 가능한 항목(ACG ANY, 멀티존 등)만 판정하고,
정책/운영/인터뷰성 항목은 '수동확인'(보고서엔 "인터뷰 필요")으로 둔다.

필요 권한: 서브 계정에 NCP의 뷰어/보안검토 성격 권한(Server/VPC 조회).
표준 라이브러리만 사용(urllib) — 별도 SDK 불필요.
"""
import base64
import hashlib
import hmac
import json
import time
import urllib.request
import urllib.error
import urllib.parse

from .base import Reporter, safe, GOOD, VULN, NA, MAN
from .ncp_items import ITEMS

API_HOST = "https://ncloud.apigw.ntruss.com"
ANY_CIDR = {"0.0.0.0/0", "::/0"}


# ------------------------------------------------------------------ 서명/호출
def _sign(secret, method, uri, ts, access):
    msg = f"{method} {uri}\n{ts}\n{access}"
    dig = hmac.new(secret.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).digest()
    return base64.b64encode(dig).decode("utf-8")


def _api(creds, path, params=None, method="GET"):
    """NCP Open API 호출. 반환은 파싱된 dict. 인증/HTTP 오류는 예외로 던진다."""
    access = creds["access_key"]
    secret = creds["secret_key"]
    q = dict(params or {})
    q.setdefault("responseFormatType", "json")
    q.setdefault("regionCode", creds.get("region") or "KR")
    query = urllib.parse.urlencode(sorted(q.items()))
    uri = f"{path}?{query}"
    ts = str(int(time.time() * 1000))
    headers = {
        "x-ncp-apigw-timestamp": ts,
        "x-ncp-iam-access-key": access,
        "x-ncp-apigw-signature-v2": _sign(secret, method, uri, ts, access),
        "x-ncp-apigw-api-key-v2": creds.get("api_gw_key", ""),
        "Accept": "application/json",
    }
    req = urllib.request.Request(API_HOST + uri, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        # 인증 실패는 상위에서 RuntimeError 로 승격시키도록 표식을 남긴다
        if e.code in (401, 403) or "Authentication Failed" in detail or "InvalidAuthorization" in detail:
            raise PermissionError(f"NCP 인증/권한 오류(HTTP {e.code}): {detail}")
        raise RuntimeError(f"NCP API 오류(HTTP {e.code}) {path}: {detail}")
    data = json.loads(body) if body.strip() else {}
    return data


def _first_list(data):
    """NCP 응답 dict에서 *List 배열을 찾아 반환(응답 래퍼 이름이 API마다 다름)."""
    for k, v in (data or {}).items():
        if k.endswith("List") and isinstance(v, list):
            return v
    return []


# ------------------------------------------------------------------ 진입점
def run(creds):
    creds = dict(creds or {})
    if not creds.get("access_key") or not creds.get("secret_key"):
        raise RuntimeError("NCP Access Key / Secret Key 를 입력하세요.")
    creds.setdefault("region", "KR")

    # 자격 유효성: 서버 목록 조회로 확인(권한 부족이면 명확히 안내)
    try:
        _api(creds, "/vserver/v2/getServerInstanceList")
    except PermissionError as e:
        raise RuntimeError(
            "NCP 자격증명이 유효하지 않거나 Server 조회 권한이 없습니다. "
            f"Access Key/Secret Key 및 서브계정 권한을 확인하세요.\n({e})")
    except RuntimeError:
        # 인증은 됐으나 특정 API 오류 — 진단은 계속(항목별 safe 처리)
        pass

    rep = Reporter(ITEMS)
    _server_security(rep, creds)      # SV-*, MU-01
    _network_security(rep, creds)     # VP-*
    _storage_db(rep, creds)           # ST-*, DB-*

    # 나머지(정책/계정/감사/인터뷰성)는 자동 판정 대상이 아니므로 인터뷰 필요로 채운다
    rep.fill_missing(MAN, "정책/운영/인터뷰 확인 항목 → NCP 콘솔·담당자 확인 필요")
    # 액세스 키 일부를 보고서에 남기지 않는다(계정 ID 는 cloud_scan --account 로 지정)
    return {"host": f"NCP 계정 (리전: {creds['region']})", "os": "Naver",
            "account": creds.get("account") or "-", "region": creds["region"], "kind": "NCP 계정",
            "family": "cloud", "results": rep.results()}


# ------------------------------------------------------------------ 3. 서버 / 7. 연속성
def _server_security(rep, creds):
    servers = []

    def load():
        nonlocal servers
        data = _api(creds, "/vserver/v2/getServerInstanceList")
        servers = _first_list(data)

    # 서버 목록 자체 실패 시 safe 가 관련 항목을 수동확인으로 처리
    safe(rep, "SV-05", load)

    # SV-01 / SV-02  ACG(Access Control Group) 규칙 — 인바운드 ANY 검사
    def c_acg():
        acgs = _first_list(_api(creds, "/vserver/v2/getAccessControlGroupList"))
        if not acgs:
            rep.na("SV-01", "ACG 없음(서버/네트워크 미사용)")
            rep.na("SV-02", "ACG 없음")
            return
        any_in = []
        for g in acgs:
            gno = g.get("accessControlGroupNo")
            gname = g.get("accessControlGroupName", str(gno))
            rules = _first_list(_api(creds, "/vserver/v2/getAccessControlGroupRuleList",
                                     {"accessControlGroupNo": gno}))
            for r in rules:
                if (r.get("accessControlGroupRuleType", {}) or {}).get("code") == "OTBND":
                    continue  # 인바운드만
                ipb = r.get("ipBlock") or r.get("accessSourceCidr") or ""
                port = r.get("portRange") or ""
                if ipb in ANY_CIDR and (port in ("", "1-65535", "1-65535/tcp") or port.strip() == ""):
                    any_in.append(f"{gname}: {ipb} {port or 'ALL'}")
        if any_in:
            rep.vuln("SV-01", ["ACG 인바운드에 ANY(0.0.0.0/0 + 전체 포트) 허용:"] + any_in, any_in)
        else:
            rep.good("SV-01", f"ACG {len(acgs)}개 인바운드에 ANY 전체 허용 규칙 없음")
        rep.man("SV-02", "서버간 통신 범위(승인 정책 대비)는 ACG 규칙을 콘솔에서 검토 필요")
    safe(rep, "SV-01", c_acg)

    # SV-04 공인 IP 사용 제한 — 공인 IP 보유 서버 목록 제시(프라이빗 여부는 검토 필요)
    def c_pubip():
        pub = []
        for s in servers:
            ip = s.get("publicIp") or ""
            if ip:
                pub.append(f"{s.get('serverName', s.get('serverInstanceNo',''))}({ip})")
        if not servers:
            rep.na("SV-04", "서버 인스턴스 없음")
        elif pub:
            rep.man("SV-04", ["공인 IP 할당 서버(프라이빗 존 여부 검토 필요):"] + pub, pub)
        else:
            rep.good("SV-04", "공인 IP가 할당된 서버 없음")
    safe(rep, "SV-04", c_pubip)

    # SV-05 불필요한 서버 — 정지 상태 서버 존재 여부(반납 검토)
    def c_unused():
        if not servers:
            rep.na("SV-05", "서버 인스턴스 없음")
            return
        stopped = [s.get("serverName", "") for s in servers
                   if (s.get("serverInstanceStatus", {}) or {}).get("code") in ("NSTOP", "STOP")]
        if stopped:
            rep.man("SV-05", ["정지 상태 서버(반납 필요 여부 검토):"] + stopped, stopped)
        else:
            rep.man("SV-05", f"서버 {len(servers)}개 사용 목적 검토 필요(운영 인터뷰)")
    safe(rep, "SV-05", c_unused)

    # MU-01 멀티존 구성 — 실행 중 서버 존 분포
    def c_zone():
        if not servers:
            rep.na("MU-01", "서버 인스턴스 없음")
            return
        zones = set()
        for s in servers:
            z = (s.get("zoneCode") or (s.get("zone", {}) or {}).get("zoneCode") or "")
            if z:
                zones.add(z)
        if len(zones) >= 2:
            rep.good("MU-01", f"서버가 {len(zones)}개 존에 분산: {', '.join(sorted(zones))}")
        else:
            rep.vuln("MU-01", f"서버가 단일 존에만 구성됨: {', '.join(sorted(zones)) or '미상'}")
    safe(rep, "MU-01", c_zone)


# ------------------------------------------------------------------ 2. 네트워크
def _network_security(rep, creds):
    # VP-01 VPC Naming — VPC 목록 제시(식별 가능 여부는 검토)
    def c_vpc():
        vpcs = _first_list(_api(creds, "/vpc/v2/getVpcList"))
        if not vpcs:
            rep.na("VP-01", "VPC 없음")
            return
        names = [v.get("vpcName", v.get("vpcNo", "")) for v in vpcs]
        rep.man("VP-01", ["VPC 목록(이름으로 서비스 식별 가능한지 검토):"] + names, names)
    safe(rep, "VP-01", c_vpc)

    # VP-03 NACL — 광범위 허용 규칙 검사
    def c_nacl():
        acls = _first_list(_api(creds, "/vpc/v2/getNetworkAclList"))
        if not acls:
            rep.na("VP-03", "Network ACL 없음")
            return
        wide = []
        for a in acls:
            ano = a.get("networkAclNo")
            aname = a.get("networkAclName", str(ano))
            rules = _first_list(_api(creds, "/vpc/v2/getNetworkAclRuleList",
                                     {"networkAclNo": ano}))
            for r in rules:
                if (r.get("ruleAction", {}) or {}).get("code") != "ALLOW":
                    continue
                if (r.get("networkAclRuleType", {}) or {}).get("code") == "OTBND":
                    continue
                ipb = r.get("ipBlock") or ""
                port = r.get("portRange") or ""
                if ipb in ANY_CIDR and (port.strip() in ("", "1-65535")):
                    wide.append(f"{aname}: {ipb} {port or 'ALL'}")
        if wide:
            rep.vuln("VP-03", ["NACL 인바운드에 광범위(0.0.0.0/0 전체 포트) 허용:"] + wide, wide)
        else:
            rep.good("VP-03", f"NACL {len(acls)}개에 광범위 전체 허용 규칙 없음")
    safe(rep, "VP-03", c_nacl)


# ------------------------------------------------------------------ 4. 스토리지 / 5. DB
def _storage_db(rep, creds):
    # Object Storage / NAS / Cloud DB 는 별도 서명(S3 호환)·엔드포인트가 필요해
    # 이번 버전은 콘솔 확인으로 안내(오탐 방지). fill_missing 이 처리.
    return
