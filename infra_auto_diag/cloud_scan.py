#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""클라우드 취약점 진단 — GUI 없이 실행하는 단독 스크립트(CLI).

★ 클라우드 쉘에서 키 없이 그대로:
    (AWS CloudShell)      python cloud_scan.py aws
    (GCP Cloud Shell)     python cloud_scan.py gcp
    (Azure Cloud Shell)   python cloud_scan.py azure --subscription-id <ID>
  → 쉘에 이미 로그인된 자격(ambient: CloudShell/역할/az login/ADC)을 자동 사용한다.
    GCP 프로젝트는 Cloud Shell 환경변수에서 자동 인식(없으면 --project).

키를 직접 줄 수도 있다(쉘 밖·CI 등):
    python cloud_scan.py aws   --access-key AKIA... --secret-key ... --region ap-northeast-2
    python cloud_scan.py azure --tenant-id .. --client-id .. --client-secret .. --subscription-id ..
    python cloud_scan.py gcp   --sa-key sa.json --project my-proj
    python cloud_scan.py naver --access-key .. --secret-key .. --region KR   (또는 환경변수 NCP_ACCESS_KEY/NCP_SECRET_KEY)

네이버(NCP)는 쉘 기본자격이 없어 키가 필요하며, 안 주면 실행 중 물어본다.
진단이 끝나면 콘솔에 요약을 찍고, 해당 CSP 보고서 양식(.xlsx)에 채워 저장한다.

의존성: 해당 CSP SDK (aws=boto3, azure=azure-identity/mgmt, gcp=google-api-python-client,
naver=표준 라이브러리) + openpyxl. tkinter/GUI 불필요.
클라우드 쉘에는 boto3/gcloud SDK 가 대개 미리 깔려 있어 바로 실행된다.
"""
import argparse
import datetime
import getpass
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import cloud_check  # noqa: E402  (같은 폴더의 패키지)

MANUAL_LABEL = "인터뷰 필요"
REPORT_STATUS = {
    "양호": "양호", "취약": "취약", "N/A": "N/A",
    "수동확인": MANUAL_LABEL, MANUAL_LABEL: MANUAL_LABEL,
}

# CSP(run 이 돌려주는 os 라벨) → (양식파일, 시트명)
TEMPLATES = {
    "AWS":   ("보고서_양식_AWS.xlsx",   "진단 결과(AWS)"),
    "AZURE": ("보고서_양식_Azure.xlsx", "진단 결과(Azure)"),
    "GCP":   ("보고서_양식_GCP.xlsx",   "진단 결과(GCP)"),
    "NAVER": ("보고서_양식_Naver.xlsx", "진단 결과(Naver)"),
}
FIRST_ROW, CODE_COL, RESULT_COL, DETAIL_COL, RES_COL = 4, 2, 7, 8, 9


# ------------------------------------------------------------------ 자격증명
def _ask(label, secret=False, default=""):
    # 비대화형(파이프/CI)에서는 입력을 기다리지 않고 기본값 사용 → 행 방지
    if not sys.stdin or not sys.stdin.isatty():
        return default
    prompt = f"{label}{f' [{default}]' if default else ''}: "
    try:
        val = getpass.getpass(prompt) if secret else input(prompt)
    except (EOFError, KeyboardInterrupt):
        val = ""
    return (val or default).strip()


def _env(*names):
    for n in names:
        v = os.environ.get(n)
        if v:
            return v
    return ""


def collect_creds(provider, args):
    """자격증명을 모은다. AWS/Azure/GCP 는 클라우드 쉘/로그인 자격(ambient)을 그대로 쓰도록
    인자·환경변수만 참고하고 프롬프트하지 않는다. NCP 만 없으면 물어본다."""
    p = provider.lower()
    if p == "aws":
        # 키를 안 주면 boto3 기본 체인(CloudShell/EC2 역할/env/~/.aws)을 사용
        ak = args.access_key or _env("AWS_ACCESS_KEY_ID")
        sk = args.secret_key or _env("AWS_SECRET_ACCESS_KEY")
        creds = {
            "access_key": ak, "secret_key": sk,
            "session_token": args.session_token or _env("AWS_SESSION_TOKEN"),
            "profile": args.profile or "",
            "region": args.region or _env("AWS_REGION", "AWS_DEFAULT_REGION") or "ap-northeast-2",
        }
        creds["mode"] = "key" if ak else ("profile" if creds["profile"] else "env")
        return creds
    if p == "azure":
        # 비우면 DefaultAzureCredential(az login / Cloud Shell / 관리 ID) 사용
        return {
            "tenant_id": args.tenant_id or _env("AZURE_TENANT_ID"),
            "client_id": args.client_id or _env("AZURE_CLIENT_ID"),
            "client_secret": args.client_secret or _env("AZURE_CLIENT_SECRET"),
            "subscription_id": args.subscription_id or _env("AZURE_SUBSCRIPTION_ID"),
        }
    if p == "gcp":
        # 비우면 ADC. Cloud Shell 은 프로젝트가 환경변수로 들어있음
        return {
            "sa_key_path": args.sa_key or _env("GOOGLE_APPLICATION_CREDENTIALS"),
            "project_id": args.project or _env("GOOGLE_CLOUD_PROJECT", "DEVSHELL_PROJECT_ID",
                                               "GCLOUD_PROJECT", "GCP_PROJECT"),
        }
    if p == "naver":
        # NCP 는 ambient 자격이 없어 키가 필요 → 인자/환경변수, 없으면 물어본다
        ak = args.access_key or _env("NCP_ACCESS_KEY", "NCP_ACCESS_KEY_ID")
        sk = args.secret_key or _env("NCP_SECRET_KEY", "NCP_SECRET_ACCESS_KEY")
        if not ak:
            ak = _ask("NCP Access Key ID")
        if not sk:
            sk = _ask("NCP Secret Key", secret=True)
        return {"access_key": ak, "secret_key": sk,
                "region": args.region or _env("NCP_REGION") or "KR"}
    raise SystemExit(f"알 수 없는 provider: {provider}")


# ------------------------------------------------------------------ 엑셀 저장
def save_excel(os_label, results, host_label, out_path=None):
    try:
        import openpyxl
        from openpyxl.styles import Font
    except ImportError:
        print("  ! openpyxl 이 없어 엑셀 저장을 건너뜁니다 (pip install openpyxl)")
        return None
    key = (os_label or "").upper()
    tpl = TEMPLATES.get(key)
    if not tpl:
        print(f"  ! {os_label} 양식이 없어 엑셀 저장을 건너뜁니다")
        return None
    tpl_path = os.path.join(SCRIPT_DIR, tpl[0])
    if not os.path.exists(tpl_path):
        print(f"  ! 양식 파일 없음: {tpl_path}")
        return None

    if not out_path:
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M")
        safe_host = "".join(c for c in (host_label or "result") if c.isalnum() or c in "-_")[:40]
        out_path = os.path.join(os.getcwd(), f"클라우드_{key}_{safe_host}_{stamp}.xlsx")

    wb = openpyxl.load_workbook(tpl_path)
    ws = wb[tpl[1]]
    row_of = {}
    for row in range(FIRST_ROW, ws.max_row + 1):
        code = ws.cell(row=row, column=CODE_COL).value
        if code is not None:
            row_of[str(code).strip()] = row

    red = Font(color="FFFF0000", bold=True)
    blue = Font(color="FF0070C0", bold=True)
    black = Font(color="FF000000")
    for r in results:
        row = row_of.get(str(r.get("code", "")))
        if not row:
            continue
        verdict = REPORT_STATUS.get(r.get("status", ""), r.get("status", ""))
        cell = ws.cell(row=row, column=RESULT_COL, value=verdict)
        cell.font = red if verdict == "취약" else blue if verdict == MANUAL_LABEL else black
        ws.cell(row=row, column=DETAIL_COL, value=" / ".join(r.get("evidence", []))[:32000])
        ws.cell(row=row, column=RES_COL, value=" / ".join(r.get("resources", []))[:32000])
    wb.save(out_path)
    return out_path


# ------------------------------------------------------------------ 메인
def main():
    ap = argparse.ArgumentParser(description="클라우드 취약점 진단(GUI 없이 실행 → 엑셀 저장)")
    ap.add_argument("provider", choices=["aws", "azure", "gcp", "naver"], help="점검 대상 CSP")
    ap.add_argument("-o", "--output", help="엑셀 저장 경로 (기본: 현재 폴더에 자동 이름)")
    ap.add_argument("--no-excel", action="store_true", help="엑셀 저장 없이 콘솔 출력만")
    # 공통/개별 자격증명
    ap.add_argument("--access-key"); ap.add_argument("--secret-key")
    ap.add_argument("--session-token"); ap.add_argument("--profile")
    ap.add_argument("--region")
    ap.add_argument("--tenant-id"); ap.add_argument("--client-id")
    ap.add_argument("--client-secret"); ap.add_argument("--subscription-id")
    ap.add_argument("--sa-key"); ap.add_argument("--project")
    args = ap.parse_args()

    provider = args.provider.lower()
    if not cloud_check.available(provider):
        pkg = cloud_check.missing_package(provider)
        sys.exit(f"[!] {cloud_check.label(provider)} 진단 SDK 미설치 → pip install {pkg}")

    creds = collect_creds(provider, args)
    print(f"\n[*] {cloud_check.label(provider)} 진단 시작 …")
    try:
        report = cloud_check.run(provider, creds)
    except RuntimeError as e:
        sys.exit(f"[!] 진단 중단: {e}")
    except Exception as e:  # noqa: BLE001
        sys.exit(f"[!] 예기치 못한 오류({type(e).__name__}): {e}")

    results = report.get("results", [])
    host = report.get("host", "")
    os_label = report.get("os", provider.upper())

    # 콘솔 요약
    counts = {}
    print(f"\n===== 진단 결과: {host} ({os_label}) — {len(results)}항목 =====")
    for r in results:
        st = REPORT_STATUS.get(r.get("status", ""), r.get("status", ""))
        counts[st] = counts.get(st, 0) + 1
        mark = {"취약": "✗", "양호": "✓", "N/A": "-", MANUAL_LABEL: "?"}.get(st, " ")
        print(f"  {mark} [{r.get('code',''):<6}] {st:<8} {r.get('title','')}")
    print("  " + " | ".join(f"{k} {v}" for k, v in sorted(counts.items())))

    # 엑셀 저장
    if not args.no_excel:
        path = save_excel(os_label, results, host, args.output)
        if path:
            print(f"\n[+] 엑셀 저장: {path}")
    print("[*] 완료")


if __name__ == "__main__":
    main()
