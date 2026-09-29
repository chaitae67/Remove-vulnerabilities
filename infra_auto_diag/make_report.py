#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""진단 결과(JSON) → 공식 결과보고서 양식 엑셀(xlsx) 생성 CLI.

흐름:
  1) 대상에서 점검 스크립트를 JSON 으로 출력
       sudo bash kisa_unix_check.sh --json result.json
       powershell -File kisa_win_check.ps1 -Json result.json
  2) 그 JSON 으로 보고서 양식을 채운다
       python make_report.py linux   --result a.json b.json --ip 10.0.0.5 10.0.0.6
       python make_report.py windows --result result.json --project 제로데이클리닉 --date 2026-09-29

양식 파일(보고서_양식_Linux.xlsx 등)이 같은 폴더에 있어야 한다(--template 로 지정 가능).
양식 칸보다 서버가 많으면(리눅스 4대·윈도우 2대 초과) 보고서를 여러 파일로 나눠 저장한다.
"""
import argparse
import json
import os
import sys
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
for _s in (getattr(sys, "stdout", None), getattr(sys, "stderr", None)):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

try:
    import server_report  # noqa: E402
except ImportError as _e:  # lxml 미설치
    sys.exit(f"[!] {_e}\n    pip install lxml  (보고서 양식 채우기에 필요)")

TEMPLATE_SUFFIX = {"linux": "_Linux.xlsx", "windows": "_Windows.xlsx",
                   "dbms": "_DBMS.xlsx", "web": "_Webserver.xlsx",
                   "aws": "_AWS.xlsx", "azure": "_Azure.xlsx", "gcp": "_GCP.xlsx", "naver": "_Naver.xlsx"}


def _find_template(key, explicit):
    """양식 파일 찾기. 엑셀이 열어둔 잠금파일(~$...)·깨진 파일은 건너뛴다."""
    if explicit:
        return explicit if os.path.exists(explicit) else None
    suffix = TEMPLATE_SUFFIX[key]
    names = sorted(n for n in os.listdir(SCRIPT_DIR) if n.endswith(suffix) and not n.startswith("~$"))
    names.sort(key=lambda n: n != "보고서_양식" + suffix)          # 정확한 이름 우선
    for name in names:
        path = os.path.join(SCRIPT_DIR, name)
        if zipfile.is_zipfile(path):
            return path
    return None


CLOUD_KINDS = {"aws", "azure", "gcp", "naver"}
WEB_SW = {"nginx", "iis", "tomcat"}


def main():
    ap = argparse.ArgumentParser(description="진단 JSON → 보고서 엑셀(xlsx) 생성")
    ap.add_argument("kind", choices=["linux", "windows", "web", "webserver", "nginx", "iis", "tomcat",
                                     "dbms", "db", "oracle", "aws", "azure", "gcp", "naver"],
                    help="대상: linux/windows(서버) · web·nginx·iis·tomcat(웹서버) · "
                         "dbms/oracle(DB) · aws/azure/gcp/naver(클라우드)")
    ap.add_argument("--result", "-r", required=True, nargs="+",
                    help="점검 JSON 파일(들). 여러 대를 나열하면 한 보고서에 열로 합침")
    ap.add_argument("--template", "-t", help="보고서 양식 xlsx (기본: 같은 폴더에서 자동 탐색)")
    ap.add_argument("--host", help="진단 대상 호스트명(기본: JSON host) — 단일 대상에만 적용")
    ap.add_argument("--ip", nargs="*", default=[], help="진단 대상 IP(들). --result 순서와 매칭(기본: JSON ip)")
    ap.add_argument("--role", nargs="*", default=[], help="용도(들). --result 순서와 매칭(선택)")
    ap.add_argument("--output", "-o", help="출력 xlsx (기본: report_<대상>_<host>.xlsx)")
    ap.add_argument("--project", help='표지 제목의 사업명(예: 제로데이클리닉 → "제로데이클리닉" 취약점 진단)')
    ap.add_argument("--docno", help="표지 문서번호")
    ap.add_argument("--author", help="표지 작성자(기본: 취약점진단팀)")
    ap.add_argument("--grade", help="표지 보안등급(기본: Confidential)")
    ap.add_argument("--version", help="표지 버전(기본: ver 1.0)")
    ap.add_argument("--date", help="표지 날짜 YYYY-MM-DD(기본: 오늘)")
    ap.add_argument("--fix-template", action="store_true", help=argparse.SUPPRESS)   # 예전 옵션(이제 불필요)
    args = ap.parse_args()

    loaded = []
    for i, path in enumerate(args.result):
        try:
            with open(path, encoding="utf-8-sig") as f:      # PowerShell 이 붙이는 BOM 허용
                d = json.load(f)
        except Exception as e:  # noqa: BLE001
            sys.exit(f"[!] JSON 을 읽을 수 없습니다: {path} ({type(e).__name__}: {e})")
        if not d.get("results"):
            sys.exit(f"[!] {path} 에 results 가 없습니다. 점검 스크립트를 --json 으로 먼저 실행하세요.")
        sv = {
            "host": (args.host if (len(args.result) == 1 and args.host) else None) or d.get("host", "")
                    or f"server{i+1}",
            "ip": args.ip[i] if i < len(args.ip) else (d.get("ip") or "-"),
            "osver": d.get("os", ""),
            "target": d.get("target", ""),   # 웹 소프트웨어 판별용(웹서버(nginx) 등)
            "role": args.role[i] if i < len(args.role) else "",
            "results": d["results"],
        }
        if args.kind in WEB_SW:
            sv["sw"] = args.kind
        for k in ("account", "region", "kind"):              # 클라우드 진단대상(계정 ID/리전/구분)
            if d.get(k):
                sv[k] = d[k]
        loaded.append(sv)

    if args.kind in CLOUD_KINDS:
        fill_kind, tpl_key = "cloud", args.kind           # cloud 스펙 + CSP별 양식(_AWS.xlsx 등)
    else:
        fill_kind = {"db": "dbms", "oracle": "dbms",
                     "webserver": "web", "nginx": "web", "iis": "web", "tomcat": "web"}.get(args.kind, args.kind)
        tpl_key = fill_kind
    tpl = _find_template(tpl_key, args.template)
    if not tpl:
        sys.exit(f"[!] 보고서 양식을 찾을 수 없습니다 ({TEMPLATE_SUFFIX[tpl_key]}). "
                 f"--template 으로 경로를 지정하세요.")
    meta = {k: getattr(args, k) for k in ("project", "docno", "author", "grade", "version", "date")
            if getattr(args, k)}

    host = loaded[0]["host"] or "server"
    base = args.output or os.path.join(
        os.getcwd(), "report_{}_{}.xlsx".format(args.kind, "".join(c for c in host if c.isalnum() or c in "-_")[:40]
                                                or "server"))
    cap = server_report.SPECS[fill_kind].get("servers", 99) if fill_kind != "web" else 99
    chunks = [loaded[i:i + cap] for i in range(0, len(loaded), cap)]
    outs = []
    for n, chunk in enumerate(chunks, 1):
        out = base if len(chunks) == 1 else f"{base[:-5] if base.endswith('.xlsx') else base}_{n}.xlsx"
        try:
            server_report.fill_report(fill_kind, chunk, tpl, out, meta=meta)
        except Exception as e:  # noqa: BLE001
            sys.exit(f"[!] 보고서 생성 실패({type(e).__name__}): {e}")
        outs.append((out, chunk))

    for out, chunk in outs:
        print(f"[+] 보고서 저장: {out}")
        for s in chunk:
            res = s["results"]
            st = [server_report.normalize_status(r.get("final") or r.get("status")) for r in res]
            print(f"    - {s['host']} ({s['osver']})  항목 {len(res)}개 | 양호 {st.count('양호')} · "
                  f"취약 {st.count('취약')} · N/A {st.count('N/A')} · 인터뷰 필요 {st.count('인터뷰 필요')}")
    print("[*] 완료")


if __name__ == "__main__":
    main()
