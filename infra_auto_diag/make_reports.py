#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""폴더 안의 진단 결과(CSV/JSON)를 한 번에 결과보고서(xlsx)로 변환한다.

CSV/JSON 을 한 폴더에 모아 놓고 실행하면, 파일명으로 종류를 알아서 구분해
종류별로 보고서를 만들어 출력 폴더(기본: 결과보고서_출력)에 저장한다.

파일명 규칙(스크립트가 저장하는 이름 그대로면 자동 인식):
  cloud_AWS_*.csv / cloud_AZURE_* / cloud_GCP_* / cloud_NAVER_*   → 클라우드(계정마다 1개)
  server_linux_<host>_*.csv                                       → 리눅스(최대 4대 한 보고서)
  server_windows_<host>_*.csv                                     → 윈도우(최대 2대 한 보고서)
  web_iis_/web_nginx_/web_tomcat_<host>_*.csv                     → 웹서버(IIS/Nginx/Tomcat 합쳐 1개)
  db_oracle_<host>_*.csv                                          → DBMS

사용:
  python make_reports.py                        # 현재 폴더 → ./결과보고서_출력/
  python make_reports.py <입력폴더> -o <출력폴더>
  python make_reports.py --kind linux a.csv b.csv   # 종류를 직접 지정(파일명이 규칙과 다를 때)
"""
import argparse
import glob
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
for _s in (getattr(sys, "stdout", None), getattr(sys, "stderr", None)):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

import make_report as MR       # noqa: E402  (_load_scan, _find_template, TEMPLATE_SUFFIX)
import server_report           # noqa: E402

# 파일명 앞부분 → (fill_kind, 양식 key, 그룹키). 그룹키가 같은 파일은 한 보고서로 합친다.
CLOUD = {"aws": "aws", "azure": "azure", "gcp": "gcp", "naver": "naver", "ncp": "naver"}
CAP = {"linux": 4, "windows": 2, "web": 4, "dbms": 1}


def classify(path):
    """파일명·내용으로 (fill_kind, tpl_key, 그룹키, sw힌트, host) 판별. 못하면 None."""
    name = os.path.basename(path).lower()
    stem = os.path.splitext(os.path.basename(path))[0]
    host = _host_from(stem)
    m = re.match(r"cloud_([a-z]+)", name)
    if m and m.group(1) in CLOUD:
        csp = CLOUD[m.group(1)]
        return "cloud", csp, path, None, host      # 클라우드는 파일마다 따로(그룹키=경로)
    if name.startswith("server_linux"):
        return "linux", "linux", "linux", None, host
    if name.startswith("server_windows"):
        return "windows", "windows", "windows", None, host
    m = re.match(r"web_(iis|nginx|tomcat)", name)
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
        return "cloud", CLOUD[prov], path, None, host
    return None


def _host_from(stem):
    """server_linux_<host>_20260930_0224 → <host> (뒤의 날짜/시각 토큰 제거)."""
    s = re.sub(r"^(server_linux|server_windows|web_[a-z]+|db_oracle|cloud_[a-z]+)_", "", stem, flags=re.I)
    s = re.sub(r"_?\d{6,8}(_\d{3,6})?$", "", s)      # _YYYYMMDD(_HHMM)
    return s or ""


def _one_report(fill_kind, tpl_key, files, out_dir, meta, seq=None):
    """files(같은 그룹) → 보고서 1개(또는 대상 초과 시 여러 개)."""
    servers = []
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
        servers.append(sv)
    if not servers:
        return []
    tpl = MR._find_template(tpl_key, None)
    if not tpl:
        print(f"  [!] 양식 없음({MR.TEMPLATE_SUFFIX[tpl_key]}) — {fill_kind} 건너뜀")
        return []
    cap = CAP.get(fill_kind, 99) if fill_kind != "web" else 99
    chunks = [servers[i:i + cap] for i in range(0, len(servers), cap)]
    outs = []
    if fill_kind == "cloud":
        label = re.sub(r"^cloud[_-]?", "", str(seq or servers[0]["host"]), flags=re.I)
    else:
        label = fill_kind
    label = "".join(c for c in label if c.isalnum() or c in "-_")[:40] or fill_kind
    for n, chunk in enumerate(chunks, 1):
        suffix = "" if len(chunks) == 1 else f"_{n}"
        prefix = "보고서_클라우드" if fill_kind == "cloud" else f"보고서_{fill_kind}"
        out = os.path.join(out_dir, f"{prefix}_{label}{suffix}.xlsx")
        try:
            server_report.fill_report(fill_kind, chunk, tpl, out, meta=meta)
        except Exception as e:  # noqa: BLE001
            print(f"  [!] 생성 실패({fill_kind}/{label}): {type(e).__name__}: {e}")
            continue
        outs.append(out)
        print(f"  [+] {os.path.basename(out)}  ({len(chunk)}대/개)")
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
            gk = f if fk == "cloud" else fk
            info = (fk, tk, gk, sw, _host_from(os.path.splitext(os.path.basename(f))[0]))
        else:
            info = classify(f)
        if not info:
            unknown.append(f)
            continue
        fk, tk, gk, sw, host = info
        groups.setdefault((fk, tk, gk), []).append((f, sw, host))

    print(f"[*] 입력 {len(files)}개 → 출력 폴더: {args.output}")
    made = []
    for (fk, tk, gk), items in sorted(groups.items()):
        seq = os.path.splitext(os.path.basename(gk))[0] if fk == "cloud" else None
        made += _one_report(fk, tk, items, args.output, meta, seq)
    for u in unknown:
        print(f"  [?] 종류 모름(건너뜀): {os.path.basename(u)}  — --kind 로 지정하세요")
    print(f"[*] 완료: 보고서 {len(made)}개 생성")


if __name__ == "__main__":
    main()
