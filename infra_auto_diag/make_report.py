#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""서버 진단 결과(JSON) → 보고서 양식 엑셀(xlsx) 생성 CLI.

흐름:
  1) 대상 서버에서 점검 스크립트를 JSON 으로 출력
       sudo bash kisa_unix_check.sh --json result.json
       powershell -File kisa_win_check.ps1 -Json result.json
  2) 그 JSON 으로 보고서 양식을 채운다
       python make_report.py linux   --result result.json
       python make_report.py windows --result result.json --ip 10.0.0.5

결과는 사진과 같은 다중시트 리포트(표지/진단대상/요약그래프/요약결과/상세).
양식 파일(보고서_양식_Linux.xlsx / _Windows.xlsx)이 같은 폴더에 있어야 한다(--template 로 지정 가능).
"""
import argparse
import glob
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
for _s in (getattr(sys, "stdout", None), getattr(sys, "stderr", None)):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

import server_report  # noqa: E402

TEMPLATE_SUFFIX = {"linux": "_Linux.xlsx", "windows": "_Windows.xlsx"}


def _find_template(os_kind, explicit):
    if explicit:
        return explicit if os.path.exists(explicit) else None
    suffix = TEMPLATE_SUFFIX[os_kind]
    for name in os.listdir(SCRIPT_DIR):
        if name.endswith(suffix):
            return os.path.join(SCRIPT_DIR, name)
    return None


# 서버(리눅스/윈도우)는 양식 파일에 채우고, 인프라(웹서버/DBMS)와 클라우드는 양식 없이 생성한다.
INFRA_KINDS = {"web", "webserver", "nginx", "iis", "tomcat", "dbms", "db", "oracle"}
CLOUD_KINDS = {"aws", "azure", "gcp", "naver"}


def main():
    ap = argparse.ArgumentParser(description="진단 JSON → 보고서 엑셀(xlsx) 생성")
    ap.add_argument("kind", choices=["linux", "windows", "web", "webserver", "nginx", "iis", "tomcat",
                                     "dbms", "db", "oracle", "aws", "azure", "gcp", "naver"],
                    help="대상: linux/windows(서버, 양식 필요) · web·nginx·iis·tomcat(웹서버) · "
                         "dbms/oracle(DB) · aws/azure/gcp/naver(클라우드)")
    ap.add_argument("--result", "-r", required=True, help="점검 스크립트가 낸 JSON 파일")
    ap.add_argument("--template", "-t", help="서버 보고서 양식 xlsx (linux/windows 만; 기본 자동 탐색)")
    ap.add_argument("--host", help="진단 대상 호스트명(기본: JSON host)")
    ap.add_argument("--ip", help="진단 대상 IP(기본: -)")
    ap.add_argument("--output", "-o", help="출력 xlsx (기본: report_<대상>_<host>.xlsx)")
    args = ap.parse_args()

    try:
        with open(args.result, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:  # noqa: BLE001
        sys.exit(f"[!] JSON 을 읽을 수 없습니다: {args.result} ({type(e).__name__}: {e})")

    results = data.get("results", [])
    if not results:
        sys.exit("[!] JSON 에 results 가 없습니다. 점검 스크립트를 --json 으로 먼저 실행하세요.")
    host = args.host or data.get("host", "") or "server"
    osver = data.get("os", "")
    ip = args.ip or "-"
    out = args.output or os.path.join(
        os.getcwd(),
        "report_{}_{}.xlsx".format(args.kind, "".join(c for c in host if c.isalnum() or c in "-_")[:40] or "server"))

    if args.kind in CLOUD_KINDS:
        # 클라우드 — 서버/웹과 동일한 5시트(표지/진단대상/요약그래프/요약결과/상세) xlsx 생성
        from cloud_check import report as cloud_report  # noqa: E402
        provider = args.kind if args.kind != "naver" else "naver"
        try:
            cloud_report.build_report(provider, host or provider.upper(), results, out)
        except Exception as e:  # noqa: BLE001
            sys.exit(f"[!] 보고서 생성 실패({type(e).__name__}): {e}")
    elif args.kind in INFRA_KINDS:
        # 웹서버/DBMS — 양식 파일 없이 openpyxl 로 5시트 보고서 생성(레이더 차트 포함)
        import infra_report  # noqa: E402
        target = {"web": "web", "webserver": "web", "db": "dbms", "oracle": "dbms"}.get(args.kind, args.kind)
        try:
            infra_report.build_report(target, host, osver, results, out)
        except Exception as e:  # noqa: BLE001
            sys.exit(f"[!] 보고서 생성 실패({type(e).__name__}): {e}")
    else:
        tpl = _find_template(args.kind, args.template)
        if not tpl:
            sys.exit(f"[!] 보고서 양식을 찾을 수 없습니다 ({TEMPLATE_SUFFIX[args.kind]}). "
                     f"--template 으로 경로를 지정하세요.")
        try:
            server_report.fill_report(args.kind, results, host, ip, osver, tpl, out)
        except Exception as e:  # noqa: BLE001
            sys.exit(f"[!] 보고서 생성 실패({type(e).__name__}): {e}")

    n_vuln = sum(1 for r in results if (r.get("final") or r.get("status")) == "취약")
    print(f"[+] 보고서 저장: {out}")
    print(f"    대상: {host} ({osver})  |  항목 {len(results)}개, 취약 {n_vuln}개")
    print("[*] 완료")


if __name__ == "__main__":
    main()
