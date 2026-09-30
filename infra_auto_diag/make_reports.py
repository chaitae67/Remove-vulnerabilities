#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""폴더 안의 진단 결과(CSV/JSON)를 한 번에 결과보고서(xlsx)로 변환한다.

CSV/JSON 을 한 폴더에 모아 놓고 실행하면, 파일명으로 종류를 알아서 구분해
종류별로 보고서를 만들어 출력 폴더(기본: 결과보고서_출력)에 저장한다.

파일명 규칙(스크립트가 저장하는 이름 그대로면 자동 인식):
  cloud_AWS_*.csv / cloud_AZURE_* / cloud_GCP_* / cloud_NAVER_*   → 클라우드(계정마다 1개)
  server_linux_<host>_*.csv                                       → 리눅스(최대 4대 한 보고서)
  server_windows_<host>_*.csv                                     → 윈도우(최대 2대 한 보고서)
  web_iis_/web_nginx_/web_tomcat_<host>_*.csv                     → 웹서버(IIS/Nginx/Tomcat 합쳐 1개)
  web_linux_<nginx|tomcat>_ / web_windows_<iis|tomcat>_<host>_*.csv  → 〃 (통합 점검 kisa_all_check.ps1 출력)
  db_oracle_<host>_*.csv                                          → DBMS

출력 파일명(공식 양식 형식은 그대로, 종류별 고정 이름 + 생성 시각 YYMMDDHHMM):
  (자동화진단)리눅스_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx      (리눅스 최대 4대 누적)
  (자동화진단)윈도우_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx      (윈도우 최대 2대 누적)
  (자동화진단)Webserver_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx    (웹 여러 대 누적)
  (자동화진단)DBMS_서버_취약점진단_결과보고서_<YYMMDDHHMM>.xlsx        (DB 마다 1개)
  (자동화진단)클라우드_서버_취약점진단_결과보고서_<CSP>_<계정>_<YYMMDDHHMM>.xlsx  (계정마다 1개)
  · 같은 호스트(클라우드는 계정)를 다시 스캔하면 최신 스캔으로 교체(누적).
  · 내용이 바뀌면 그 시각의 새 파일이 생기고 옛 파일은 그대로 남는다(이력 보존). 내용이 같으면 새로 안 만든다.
    최신본 기록은 출력 폴더의 .report_version.json 에 종류별로 남는다(터미널엔 이번 최신 파일만 표시).

사용:
  python make_reports.py                        # 현재 폴더(하위 폴더 포함) → ./결과보고서_출력/
  python make_reports.py <입력폴더> -o <출력폴더>
  python make_reports.py --kind linux a.csv b.csv   # 종류를 직접 지정(파일명이 규칙과 다를 때)

이 스크립트는 make_report.py·server_report.py·양식(보고서_양식_*.xlsx)이 필요하다. 따라서:
  · infra_auto_diag 안이나 그 상위/근처(같은 저장소 안 어디든)에 두면 알아서 찾는다.
  · 완전히 무관한 폴더에 둘 거면 INFRA_DIR 환경변수로 infra_auto_diag 경로를 지정한다.
    (Windows)  set INFRA_DIR=C:\...\infra_auto_diag & python make_reports.py 입력csv
    (bash)     INFRA_DIR=/path/infra_auto_diag python make_reports.py 입력csv
입력 폴더는 하위 폴더까지 재귀로 훑는다.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
for _s in (getattr(sys, "stdout", None), getattr(sys, "stderr", None)):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def _find_tools():
    """make_report.py·server_report.py·양식 파일이 있는 폴더(보통 infra_auto_diag)를 찾는다.
    이 스크립트를 아무 폴더에 둬도 동작하도록: 옆 폴더 → 상위 폴더들 → 환경변수(INFRA_DIR) 순으로 탐색."""
    seen = []
    here = SCRIPT_DIR
    cands = [here, os.path.join(here, "infra_auto_diag")]
    d = here
    for _ in range(6):                       # 상위 폴더로 올라가며 infra_auto_diag 찾기
        cands += [d, os.path.join(d, "infra_auto_diag")]
        d = os.path.dirname(d)
    env = os.environ.get("INFRA_DIR")
    if env:
        cands.insert(0, env)
    for c in cands:
        c = os.path.abspath(c)
        if c in seen:
            continue
        seen.append(c)
        if os.path.exists(os.path.join(c, "make_report.py")) and \
           os.path.exists(os.path.join(c, "server_report.py")):
            return c
    return None


_TOOLS = _find_tools()
if not _TOOLS:
    sys.exit("[!] make_report.py·server_report.py 를 찾지 못했습니다. 이 스크립트를 infra_auto_diag 안이나 그 근처에 두거나, "
             "INFRA_DIR 환경변수로 그 폴더를 지정하세요.")
sys.path.insert(0, _TOOLS)

import make_report as MR       # noqa: E402  (_load_scan, _find_template, TEMPLATE_SUFFIX)
import server_report           # noqa: E402

# 파일명 앞부분 → (fill_kind, 양식 key, 그룹키). 그룹키가 같은 파일은 한 보고서로 합친다.
CLOUD = {"aws": "aws", "azure": "azure", "gcp": "gcp", "naver": "naver", "ncp": "naver"}
CAP = {"linux": 4, "windows": 2, "web": 4, "dbms": 1}

# 종류별 결과보고서 파일명(뒤에 _v<버전> 이 붙는다). 원래 공식 양식 형식은 그대로 유지.
REPORT_NAME = {
    "linux":   "(자동화진단)리눅스_서버_취약점진단_결과보고서",
    "windows": "(자동화진단)윈도우_서버_취약점진단_결과보고서",
    "web":     "(자동화진단)Webserver_서버_취약점진단_결과보고서",
    "dbms":    "(자동화진단)DBMS_서버_취약점진단_결과보고서",
    "cloud":   "(자동화진단)클라우드_서버_취약점진단_결과보고서",
}
MANIFEST = ".report_version.json"       # 출력 폴더에 저장: 종류별 최신 버전·내용 서명 기록(ASCII 이름)


def _safe(s):
    return "".join(c for c in str(s) if c.isalnum() or c in "-_.")[:40]


def _cap(fill_kind):
    """양식이 담을 수 있는 대상 수(초과하면 여러 파일로 나눔). 웹은 여러 대를 한 보고서에."""
    if fill_kind == "web":
        return 99
    try:
        return server_report.SPECS[fill_kind].get("servers", 99) or 99
    except Exception:
        return CAP.get(fill_kind, 99)


def _ts_key(path):
    """스캔 시각(파일명의 YYYYMMDD_HHMM, 없으면 수정시각)을 12자리 문자열로 → 최신 판별용."""
    m = re.search(r"(\d{8})_?(\d{4,6})?", os.path.basename(path))
    if m:
        return (m.group(1) + (m.group(2) or "0000"))[:12].ljust(12, "0")
    try:
        return time.strftime("%Y%m%d%H%M", time.localtime(os.path.getmtime(path)))
    except OSError:
        return "0" * 12


def _norm_host(h):
    """호스트명 정규화 — 도메인 접미사(FQDN)·대소문자 차이를 무시해 같은 서버로 묶는다.
    예) ip-10-0-2-203 == ip-10-0-2-203.ap-northeast-2.compute.internal,
        EC2AMAZ-A863V5R == EC2AMAZ-A863V5R.WORKGROUP."""
    return str(h or "-").strip().split(".")[0].lower()


def _identity(fill_kind, sv):
    """같은 대상인지 판별하는 키. 겹치면 최신 스캔으로 교체한다(호스트명은 정규화 후 비교)."""
    if fill_kind == "cloud":
        return _norm_host(sv.get("account") or sv.get("host"))
    if fill_kind == "web":
        return f"{_norm_host(sv.get('host'))}|{str(sv.get('sw', '')).lower()}"
    return _norm_host(sv.get("host"))


def _sig(servers):
    """보고서에 들어가는 내용(대상·항목 결과)의 서명. 내용이 바뀌면 달라진다 → 버전 증가 판단."""
    norm = []
    for sv in sorted(servers, key=lambda s: (str(s.get("host", "")), str(s.get("sw", "")),
                                             str(s.get("account", "")))):
        items = sorted(({"c": r.get("code"),
                         "s": r.get("final") or r.get("status"),
                         "e": r.get("evidence")} for r in sv.get("results", [])),
                       key=lambda x: str(x["c"]))
        norm.append({"h": sv.get("host"), "ip": sv.get("ip"), "os": sv.get("osver"),
                     "acc": sv.get("account"), "reg": sv.get("region"), "sw": sv.get("sw"),
                     "items": items})
    blob = json.dumps(norm, ensure_ascii=False, sort_keys=True)
    return hashlib.sha1(blob.encode("utf-8")).hexdigest()[:10]


def _load_manifest(out_dir):
    try:
        with open(os.path.join(out_dir, MANIFEST), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _save_manifest(out_dir, manifest):
    try:
        with open(os.path.join(out_dir, MANIFEST), "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def classify(path):
    """파일명·내용으로 (fill_kind, tpl_key, 그룹키, sw힌트, host) 판별. 못하면 None."""
    name = os.path.basename(path).lower()
    stem = os.path.splitext(os.path.basename(path))[0]
    host = _host_from(stem)
    m = re.match(r"cloud_([a-z]+)", name)
    if m and m.group(1) in CLOUD:
        csp = CLOUD[m.group(1)]
        return "cloud", csp, csp, None, host       # 같은 CSP 는 한 그룹(계정별로 파일 분리·교체)
    if name.startswith("server_linux"):
        return "linux", "linux", "linux", None, host
    if name.startswith("server_windows"):
        return "windows", "windows", "windows", None, host
    m = re.match(r"web_(?:(?:linux|windows)_)?(iis|nginx|tomcat)", name)   # web_nginx_ / web_linux_nginx_
    if m:
        return "web", "web", "web", m.group(1), host
    if name.startswith(("db_oracle", "dbms", "oracle")):
        return "dbms", "dbms", "dbms", None, host
    # 파일명으로 모르면 내용의 provider(클라우드 CSV/JSON) 로 시도
    try:
        d = MR._load_scan(path)
    except Exception:
        return None
    prov = str(d.get("provider") or "").lower()
    if prov in CLOUD:
        return "cloud", CLOUD[prov], CLOUD[prov], None, host
    return None


def _host_from(stem):
    """server_linux_<host>_20260930_0224 → <host> (뒤의 날짜/시각 토큰 제거)."""
    s = re.sub(r"^(server_linux|server_windows|web_(?:(?:linux|windows)_)?[a-z]+|db_oracle|cloud_[a-z]+)_", "",
               stem, flags=re.I)
    s = re.sub(r"_?\d{6,8}(_\d{3,6})?$", "", s)      # _YYYYMMDD(_HHMM)
    return s or ""


def _one_report(fill_kind, tpl_key, files, out_dir, meta, manifest):
    """files(같은 그룹) → 결과보고서. 같은 호스트는 최신 스캔으로 교체(누적), 내용 바뀌면 _v 버전 증가.

    · 리눅스 4대·윈도우 2대·웹 여러 대를 한 보고서에 누적(양식 수용량 초과 시 파일 분리).
    · 클라우드·DBMS 양식은 대상 1개짜리 → 계정/DB 마다 파일이 나뉜다.
    """
    # 1) 파일 로드(+ 스캔 시각)
    loaded = []
    for path, sw, host in files:
        try:
            d = MR._load_scan(path)
        except Exception as e:  # noqa: BLE001
            print(f"  [!] 건너뜀 {os.path.basename(path)}: {e}")
            continue
        if not d.get("results"):
            print(f"  [!] 건너뜀 {os.path.basename(path)}: 결과 없음")
            continue
        sv = {"host": d.get("host") or host or "server", "ip": d.get("ip") or "-",
              "osver": d.get("os", ""), "target": d.get("target", ""), "role": "",
              "results": d["results"]}
        if sw:
            sv["sw"] = sw
        for k in ("account", "region", "kind"):
            if d.get(k):
                sv[k] = d[k]
        loaded.append((sv, _ts_key(path)))
    if not loaded:
        return []

    # 2) 같은 대상(호스트/계정) 중복 → 최신 스캔만 남김(교체)
    best = {}
    for sv, ts in loaded:
        idk = _identity(fill_kind, sv)
        if idk in best and ts < best[idk][1]:
            continue
        if idk in best:
            print(f"  [=] {sv.get('host') or sv.get('account')} 중복 → 최신 스캔으로 교체")
        best[idk] = (sv, ts)
    servers = [v[0] for v in sorted(best.values(),
                                    key=lambda x: (str(x[0].get("host", "")),
                                                   str(x[0].get("sw", "")),
                                                   str(x[0].get("account", ""))))]

    tpl = MR._find_template(tpl_key, None)
    if not tpl:
        print(f"  [!] 양식 없음({MR.TEMPLATE_SUFFIX[tpl_key]}) — {fill_kind} 건너뜀")
        return []
    cap = _cap(fill_kind)

    # 3) 클라우드는 계정마다 별도 보고서(양식이 대상 1개), 그 외는 종류별 한 보고서에 누적
    if fill_kind == "cloud":
        units = [(f"{tpl_key.upper()}_{_safe(sv.get('account') or sv.get('host') or tpl_key)}",
                  f"cloud:{tpl_key}:{_identity('cloud', sv)}", [sv]) for sv in servers]
    else:
        chunks = [servers[i:i + cap] for i in range(0, len(servers), cap)]
        units = []
        for n, chunk in enumerate(chunks, 1):
            part = "" if len(chunks) == 1 else f"_({n})"
            units.append((part, fill_kind, chunk))

    base = REPORT_NAME.get(fill_kind, f"보고서_{fill_kind}")
    now = time.strftime("%y%m%d%H%M")                    # 생성 시각 YYMMDDHHMM
    outs = []
    for tail, mkey, chunk in units:
        sig = _sig(chunk)
        part = "" if fill_kind == "cloud" else tail       # 초과분 파트 접미사 _(2) 등
        mkey_full = f"{mkey}|{part}"
        name = f"{base}_{tail}" if (fill_kind == "cloud") else base
        ent = manifest.get(mkey_full) or {}
        # 내용이 이전과 같고 그 파일이 아직 있으면 새로 안 만들고 기존 최신본 유지
        if ent.get("sig") == sig and ent.get("file") and \
           os.path.exists(os.path.join(out_dir, ent["file"])):
            outs.append(os.path.join(out_dir, ent["file"]))
            print(f"  [=] {ent['file']}  ({len(chunk)}대/개, 변경 없음 → 기존 유지)")
            continue
        out = os.path.join(out_dir, f"{name}_{now}{part}.xlsx")
        if os.path.exists(out):                            # 같은 분에 이미 있으면 겹침 방지
            out = os.path.join(out_dir, f"{name}_{now}{part}_2.xlsx")
        try:
            server_report.fill_report(fill_kind, chunk, tpl, out, meta=meta)
        except Exception as e:  # noqa: BLE001
            print(f"  [!] 생성 실패({fill_kind}/{mkey}): {type(e).__name__}: {e}")
            continue
        manifest[mkey_full] = {"sig": sig, "file": os.path.basename(out)}
        outs.append(out)
        print(f"  [+] {os.path.basename(out)}  ({len(chunk)}대/개, 새로 생성)")
    return outs


def main():
    ap = argparse.ArgumentParser(description="폴더 안 진단 결과(CSV/JSON) → 결과보고서 일괄 변환")
    ap.add_argument("inputs", nargs="*", default=["."],
                    help="입력 폴더 또는 파일들(기본: 현재 폴더)")
    ap.add_argument("-o", "--output", default="결과보고서_출력", help="출력 폴더(기본: 결과보고서_출력)")
    ap.add_argument("--kind", choices=["linux", "windows", "web", "dbms", "aws", "azure", "gcp", "naver"],
                    help="종류를 직접 지정(파일명이 규칙과 다를 때 — 입력을 파일들로 줄 것)")
    ap.add_argument("--project", help="표지 사업명")
    ap.add_argument("--date", help="표지 날짜 YYYY-MM-DD")
    args = ap.parse_args()

    # 입력 파일 수집(폴더면 그 안의 csv/json)
    files = []
    for p in args.inputs:
        if os.path.isdir(p):
            for pat in ("*.csv", "*.json"):
                files += glob.glob(os.path.join(p, pat))
                files += glob.glob(os.path.join(p, "**", pat), recursive=True)   # 하위 폴더까지
        elif os.path.isfile(p):
            files.append(p)
    files = sorted(set(os.path.abspath(f) for f in files
                       if not os.path.basename(f).startswith("~$")))
    if not files:
        sys.exit("[!] 변환할 CSV/JSON 이 없습니다.")

    os.makedirs(args.output, exist_ok=True)
    meta = {k: getattr(args, k) for k in ("project", "date") if getattr(args, k)}

    # 종류·그룹별로 묶기
    groups = {}   # (fill_kind, tpl_key, 그룹키) → [(path, sw, host)]
    unknown = []
    for f in files:
        if args.kind:
            fk = {"aws": "cloud", "azure": "cloud", "gcp": "cloud", "naver": "cloud"}.get(args.kind, args.kind)
            tk = args.kind if args.kind in CLOUD or args.kind in ("aws", "azure", "gcp", "naver") else fk
            sw = args.kind if args.kind in ("iis", "nginx", "tomcat") else None
            gk = tk if fk == "cloud" else fk
            info = (fk, tk, gk, sw, _host_from(os.path.splitext(os.path.basename(f))[0]))
        else:
            info = classify(f)
        if not info:
            unknown.append(f)
            continue
        fk, tk, gk, sw, host = info
        groups.setdefault((fk, tk, gk), []).append((f, sw, host))

    print(f"[*] 입력 {len(files)}개 → 출력 폴더: {args.output}")
    manifest = _load_manifest(args.output)          # 종류별 최신 버전·내용 서명(재실행 시 이어감)
    made = []
    for (fk, tk, gk), items in sorted(groups.items()):
        made += _one_report(fk, tk, items, args.output, meta, manifest)
    _save_manifest(args.output, manifest)
    for u in unknown:
        print(f"  [?] 종류 모름(건너뜀): {os.path.basename(u)}  — --kind 로 지정하세요")
    print(f"[*] 완료: 보고서 {len(made)}개 생성")


if __name__ == "__main__":
    main()
