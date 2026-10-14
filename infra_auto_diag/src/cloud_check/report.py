#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""클라우드 진단 결과 → 다중시트 보고서(xlsx) 생성.

서버 보고서(표지/진단대상/요약그래프/요약결과/상세)와 같은 구성을,
양식 파일 없이 openpyxl 로 처음부터 만든다(레이더 차트 포함).
항목 메타(area/title/중요도/진단기준)는 provider별 *_items.ITEMS 를 그대로 쓰므로
AWS/Azure/GCP=SK Shieldus, Naver=네이버 클라우드 기준이 자동 반영된다.
"""
import datetime

MANUAL_LABEL = "인터뷰 필요"
REPORT_STATUS = {
    "양호": "양호", "취약": "취약", "N/A": "양호",
    "수동확인": MANUAL_LABEL, MANUAL_LABEL: MANUAL_LABEL,
}
GUIDE = {
    "aws": "SK Shieldus 2024 클라우드 보안가이드 (AWS)",
    "azure": "SK Shieldus 2024 클라우드 보안가이드 (Azure)",
    "gcp": "SK Shieldus 2024 클라우드 보안가이드 (GCP)",
    "naver": "네이버 클라우드 플랫폼 보안 가이드 (취약점 진단 기준)",
}


def _load_items(provider):
    mod = {"aws": "aws_items", "azure": "azure_items",
           "gcp": "gcp_items", "naver": "ncp_items"}.get(provider)
    if not mod:
        return {}
    import importlib
    try:
        return importlib.import_module("." + mod, __package__).ITEMS
    except Exception:
        return {}


def _code_key(c):
    # "1.10" / "AC-01" 정렬용
    import re
    m = re.match(r"(\d+)\.(\d+)$", str(c))
    if m:
        return (0, int(m.group(1)), int(m.group(2)), "")
    m = re.match(r"([A-Za-z]+)-?(\d+)$", str(c))
    if m:
        return (1, m.group(1), int(m.group(2)), "")
    return (2, str(c), 0, "")


def build_report(provider, host, results, out_path):
    """provider('aws'..'naver'), host(식별자), results(run()의 results), out_path 로 저장.

    서버 보고서와 동일한 5시트+3차트 양식(infra_report)으로 생성한다.
    infra_report 를 불러올 수 없는 환경에서만 아래 기존(단일 레이더) 생성으로 폴백한다.
    """
    try:
        import infra_report
        return infra_report.build_report(provider, host, "", results, out_path)
    except Exception:
        return _build_report_legacy(provider, host, results, out_path)


def _build_report_legacy(provider, host, results, out_path):
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.chart import RadarChart, Reference
    from openpyxl.utils import get_column_letter

    provider = (provider or "").lower()
    items = _load_items(provider)
    label = {"aws": "AWS", "azure": "Azure", "gcp": "GCP", "naver": "Naver"}.get(provider, provider.upper())
    today = datetime.date.today().strftime("%Y년 %m월 %d일")

    # ---- 스타일 ----
    thin = Side(style="thin", color="FFBBBBBB")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    hdr_fill = PatternFill("solid", fgColor="FFDDEBF7")
    area_fill = PatternFill("solid", fgColor="FFF2F2F2")
    bold = Font(bold=True)
    center = Alignment(horizontal="center", vertical="center", wrap_text=True)
    left = Alignment(horizontal="left", vertical="center", wrap_text=True)
    red = Font(color="FFFF0000", bold=True)
    blue = Font(color="FF0070C0", bold=True)

    def verdict_of(r):
        return REPORT_STATUS.get(r.get("status", ""), r.get("status", ""))

    # 정렬된 결과
    results = sorted(results, key=lambda r: _code_key(r.get("code", "")))
    # 영역(area)별 그룹 — items 메타에서, 없으면 코드 접두로 추정
    def area_of(code):
        meta = items.get(code, {})
        return meta.get("area", "기타")
    areas = []
    for r in results:
        a = area_of(r.get("code", ""))
        if a not in areas:
            areas.append(a)

    wb = openpyxl.Workbook()

    # ================= 0. 표지 =================
    ws = wb.active
    ws.title = "0. 표지"
    ws.sheet_view.showGridLines = False
    info = [("문서번호", "XXXXX-VA-2026XXX"), ("작성자", "취약점진단팀"),
            ("보안등급", "Confidential"), ("Ver", "ver 1.0")]
    for i, (k, v) in enumerate(info):
        r = 3 + i
        c1 = ws.cell(r, 6, k); c1.fill = area_fill; c1.font = bold; c1.alignment = center; c1.border = border
        c2 = ws.cell(r, 7, v); c2.alignment = center; c2.border = border
    ws.cell(11, 3, f'"{host}" 취약점 진단').font = Font(bold=True, size=16)
    ws.cell(13, 3, f"클라우드({label}) 진단 상세결과").font = Font(bold=True, size=22)
    ws.cell(18, 3, today).font = Font(bold=True, size=12)
    ws.cell(21, 3, GUIDE.get(provider, "")).font = Font(size=10, color="FF666666")
    ws.column_dimensions["F"].width = 12
    ws.column_dimensions["G"].width = 22

    # ================= 1. 진단 대상 =================
    ws = wb.create_sheet("1. 진단 대상")
    ws.cell(1, 2, f"※ 진단 대상 - 클라우드({label})").font = Font(bold=True, size=13)
    heads = ["구분", "계정 / 리소스", "비고"]
    for j, h in enumerate(heads):
        c = ws.cell(3, 2 + j, h); c.font = bold; c.fill = hdr_fill; c.alignment = center; c.border = border
    row = [label, host, GUIDE.get(provider, "")]
    for j, v in enumerate(row):
        c = ws.cell(4, 2 + j, v); c.alignment = left; c.border = border
    for col, w in (("B", 14), ("C", 46), ("D", 40)):
        ws.column_dimensions[col].width = w

    # ================= 2-2. 요약 진단결과 =================
    ws_sum = wb.create_sheet("2-2. 요약 진단결과")
    heads = ["진단항목", "항목코드", "세부 진단항목", "중요도", "진단결과"]
    for j, h in enumerate(heads):
        c = ws_sum.cell(3, 1 + j, h); c.font = bold; c.fill = hdr_fill; c.alignment = center; c.border = border
    r = 4
    for a in areas:
        first = r
        for res in [x for x in results if area_of(x.get("code", "")) == a]:
            meta = items.get(res.get("code", ""), {})
            v = verdict_of(res)
            ws_sum.cell(r, 1, a if r == first else None)
            ws_sum.cell(r, 2, res.get("code", ""))
            ws_sum.cell(r, 3, res.get("title", meta.get("title", "")))
            ws_sum.cell(r, 4, res.get("importance", meta.get("imp", "")))
            vc = ws_sum.cell(r, 5, v)
            if v == "취약":
                vc.font = red
            elif v == MANUAL_LABEL:
                vc.font = blue
            for col in range(1, 6):
                cc = ws_sum.cell(r, col); cc.border = border
                cc.alignment = center if col in (2, 4, 5) else left
            r += 1
    last_data = r - 1
    for col, w in zip("ABCDE", (16, 10, 30, 8, 12)):
        ws_sum.column_dimensions[col].width = w

    # 영역별 점수표(오른쪽) — 레이더 차트 소스
    ws_sum.cell(3, 8, "진단 영역").font = bold
    ws_sum.cell(3, 9, "양호율").font = bold
    for c in (ws_sum.cell(3, 8), ws_sum.cell(3, 9)):
        c.fill = hdr_fill; c.alignment = center; c.border = border
    score_first = 4
    ar = score_first
    for a in areas:
        good = vuln = 0
        for res in [x for x in results if area_of(x.get("code", "")) == a]:
            v = verdict_of(res)
            if v == "양호":
                good += 1
            elif v == "취약":
                vuln += 1
        rate = (good / (good + vuln)) if (good + vuln) else 0
        ws_sum.cell(ar, 8, a).border = border
        sc = ws_sum.cell(ar, 9, round(rate, 3)); sc.number_format = "0.0%"; sc.border = border; sc.alignment = center
        ar += 1
    score_last = ar - 1
    ws_sum.column_dimensions["H"].width = 22
    ws_sum.column_dimensions["I"].width = 10

    # ================= 2-1. 요약결과(그래프) =================
    ws_g = wb.create_sheet("2-1. 요약결과(그래프)")
    ws_g.cell(1, 1, f"클라우드({label}) 진단 요약 — 영역별 양호율").font = Font(bold=True, size=13)
    chart = RadarChart()
    chart.type = "filled"
    chart.title = "영역별 양호율"
    chart.style = 26
    data = Reference(ws_sum, min_col=9, min_row=3, max_row=score_last)   # 헤더 포함
    cats = Reference(ws_sum, min_col=8, min_row=score_first, max_row=score_last)
    chart.add_data(data, titles_from_data=True)
    chart.set_categories(cats)
    chart.height = 11
    chart.width = 18
    ws_g.add_chart(chart, "B3")

    # ================= 3-1. 진단 결과(상세) =================
    ws_d = wb.create_sheet(f"3-1. 진단 결과({label})")
    heads = ["진단항목", "항목코드", "세부 진단항목", "진단기준", "진단결과", "상세 내용 / 근거", "관련 리소스"]
    for j, h in enumerate(heads):
        c = ws_d.cell(3, 1 + j, h); c.font = bold; c.fill = hdr_fill; c.alignment = center; c.border = border
    r = 4
    for a in areas:
        first = r
        for res in [x for x in results if area_of(x.get("code", "")) == a]:
            meta = items.get(res.get("code", ""), {})
            v = verdict_of(res)
            ws_d.cell(r, 1, a if r == first else None)
            ws_d.cell(r, 2, res.get("code", ""))
            ws_d.cell(r, 3, res.get("title", meta.get("title", "")))
            ws_d.cell(r, 4, meta.get("crit", ""))
            vc = ws_d.cell(r, 5, v)
            if v == "취약":
                vc.font = red
            elif v == MANUAL_LABEL:
                vc.font = blue
            ws_d.cell(r, 6, " / ".join(res.get("evidence", []))[:32000])
            ws_d.cell(r, 7, " / ".join(res.get("resources", []))[:32000])
            for col in range(1, 8):
                cc = ws_d.cell(r, col); cc.border = border
                cc.alignment = center if col in (2, 5) else left
            r += 1
    for col, w in zip("ABCDEFG", (16, 10, 26, 46, 12, 50, 26)):
        ws_d.column_dimensions[col].width = w
    ws_d.freeze_panes = "A4"

    wb.save(out_path)
    return out_path
