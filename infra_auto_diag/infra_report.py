#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""인프라(웹/DB 등) 진단 결과(JSON) → 다중시트 보고서(xlsx) 생성.

서버 보고서와 동일한 구성(표지/진단대상/요약그래프/요약결과/상세)을 양식 파일 없이
openpyxl 로 처음부터 만든다(레이더 차트 포함). 클라우드 보고서(cloud_check/report.py)와
같은 방식이며, 항목 메타(제목/중요도/근거)는 스캔 스크립트 JSON 을 그대로 쓴다.

대상(target) 키: nginx / iis / oracle (그 외는 area='기타' 로 묶임)
"""
import datetime

MANUAL_LABEL = "인터뷰 필요"
REPORT_STATUS = {
    "양호": "양호", "취약": "취약", "N/A": "양호",
    "수동확인": MANUAL_LABEL, MANUAL_LABEL: MANUAL_LABEL,
}
TARGET_LABEL = {
    "web": "웹서버", "nginx": "웹서버(Nginx)", "iis": "웹서버(IIS)", "tomcat": "웹서버(Tomcat)",
    "dbms": "DBMS(Oracle)", "oracle": "DBMS(Oracle)",
}
GUIDE = {
    "web": "KISA 주통기 상세가이드(WEB) / SK Shieldus 웹 보안가이드",
    "nginx": "KISA 주통기 상세가이드(WEB) / SK Shieldus 웹 보안가이드",
    "iis": "KISA 주통기 상세가이드(WEB) / SK Shieldus 웹 보안가이드",
    "tomcat": "KISA 주통기 상세가이드(WEB) / SK Shieldus 웹 보안가이드",
    "dbms": "KISA 주통기 상세가이드(DBMS) / SK Shieldus DB 보안가이드",
    "oracle": "KISA 주통기 상세가이드(DBMS) / SK Shieldus DB 보안가이드",
}
# 항목코드 → 진단 영역(공식 결과보고서 도메인). 코드 접두(WEB-/D-)로 자동 선택.
_WEB_AREA = {}
for _c in range(1, 27):
    _k = "WEB-%02d" % _c
    if _c <= 3:    _WEB_AREA[_k] = "1. 계정 관리"
    elif _c <= 18: _WEB_AREA[_k] = "2. 서비스 관리"
    elif _c <= 23: _WEB_AREA[_k] = "3. 보안 설정"
    else:          _WEB_AREA[_k] = "4. 패치 및 로그 관리"
_DB_AREA = {}
for _c in range(1, 27):
    _k = "D-%02d" % _c
    if _c <= 9:    _DB_AREA[_k] = "1. 계정 관리"
    elif _c <= 16: _DB_AREA[_k] = "2. 접근 관리"
    elif _c <= 24: _DB_AREA[_k] = "3. 옵션 관리"
    else:          _DB_AREA[_k] = "4. 패치 관리"


def _area_map_for(target, results):
    t = (target or "").lower()
    if t in ("dbms", "oracle"):
        return _DB_AREA
    if t in ("web", "nginx", "iis", "tomcat"):
        return _WEB_AREA
    # 코드 접두로 추정
    for r in results:
        if str(r.get("code", "")).startswith("D-"):
            return _DB_AREA
    return _WEB_AREA


def _code_key(c):
    import re
    m = re.match(r"([A-Za-z]+)-?(\d+)$", str(c))
    if m:
        return (m.group(1), int(m.group(2)))
    return (str(c), 0)


def build_report(target, host, osver, results, out_path):
    """target('nginx'/'iis'/'oracle'), host, osver, results(JSON results), out_path."""
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.chart import RadarChart, Reference

    target = (target or "").lower()
    label = TARGET_LABEL.get(target, target.upper())
    amap = _area_map_for(target, results)
    today = datetime.date.today().strftime("%Y년 %m월 %d일")

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

    def area_of(code):
        return amap.get(code, "기타")

    results = sorted(results, key=lambda r: _code_key(r.get("code", "")))
    areas = []
    for r in results:
        a = area_of(r.get("code", ""))
        if a not in areas:
            areas.append(a)

    wb = openpyxl.Workbook()

    # 0. 표지
    ws = wb.active
    ws.title = "0. 표지"
    ws.sheet_view.showGridLines = False
    info = [("문서번호", "XXXXX-VA-2026XXX"), ("작성자", "취약점진단팀"),
            ("보안등급", "Confidential"), ("Ver", "ver 1.0")]
    for i, (k, v) in enumerate(info):
        rr = 3 + i
        c1 = ws.cell(rr, 6, k); c1.fill = area_fill; c1.font = bold; c1.alignment = center; c1.border = border
        c2 = ws.cell(rr, 7, v); c2.alignment = center; c2.border = border
    ws.cell(11, 3, f'"{host}" 취약점 진단').font = Font(bold=True, size=16)
    ws.cell(13, 3, f"{label} 진단 상세결과").font = Font(bold=True, size=22)
    ws.cell(18, 3, today).font = Font(bold=True, size=12)
    ws.cell(21, 3, GUIDE.get(target, "")).font = Font(size=10, color="FF666666")
    ws.column_dimensions["F"].width = 12
    ws.column_dimensions["G"].width = 22

    # 1. 진단 대상
    ws = wb.create_sheet("1. 진단 대상")
    ws.cell(1, 2, f"※ 진단 대상 - {label}").font = Font(bold=True, size=13)
    heads = ["구분", "대상 / 버전", "비고"]
    for j, h in enumerate(heads):
        c = ws.cell(3, 2 + j, h); c.font = bold; c.fill = hdr_fill; c.alignment = center; c.border = border
    row = [label, f"{host}  ({osver})" if osver else host, GUIDE.get(target, "")]
    for j, v in enumerate(row):
        c = ws.cell(4, 2 + j, v); c.alignment = left; c.border = border
    for col, w in (("B", 14), ("C", 46), ("D", 42)):
        ws.column_dimensions[col].width = w

    # 2-2. 요약 진단결과
    ws_sum = wb.create_sheet("2-2. 요약 진단결과")
    heads = ["진단영역", "항목코드", "세부 진단항목", "중요도", "진단결과"]
    for j, h in enumerate(heads):
        c = ws_sum.cell(3, 1 + j, h); c.font = bold; c.fill = hdr_fill; c.alignment = center; c.border = border
    r = 4
    for a in areas:
        first = r
        for res in [x for x in results if area_of(x.get("code", "")) == a]:
            v = verdict_of(res)
            ws_sum.cell(r, 1, a if r == first else None)
            ws_sum.cell(r, 2, res.get("code", ""))
            ws_sum.cell(r, 3, res.get("title", ""))
            ws_sum.cell(r, 4, res.get("importance", ""))
            vc = ws_sum.cell(r, 5, v)
            if v == "취약":
                vc.font = red
            elif v == MANUAL_LABEL:
                vc.font = blue
            for col in range(1, 6):
                cc = ws_sum.cell(r, col); cc.border = border
                cc.alignment = center if col in (2, 4, 5) else left
            r += 1
    for col, w in zip("ABCDE", (18, 10, 34, 8, 12)):
        ws_sum.column_dimensions[col].width = w

    # 영역별 양호율(오른쪽) — 레이더 소스
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
        rate = (good / (good + vuln)) if (good + vuln) else 1.0
        ws_sum.cell(ar, 8, a).border = border
        sc = ws_sum.cell(ar, 9, round(rate, 3)); sc.number_format = "0.0%"; sc.border = border; sc.alignment = center
        ar += 1
    score_last = ar - 1
    ws_sum.column_dimensions["H"].width = 22
    ws_sum.column_dimensions["I"].width = 10

    # 2-1. 요약결과(그래프)
    ws_g = wb.create_sheet("2-1. 요약결과(그래프)")
    ws_g.cell(1, 1, f"{label} 진단 요약 — 영역별 양호율").font = Font(bold=True, size=13)
    chart = RadarChart()
    chart.type = "filled"
    chart.title = "영역별 양호율"
    chart.style = 26
    data = Reference(ws_sum, min_col=9, min_row=3, max_row=score_last)
    cats = Reference(ws_sum, min_col=8, min_row=score_first, max_row=score_last)
    chart.add_data(data, titles_from_data=True)
    chart.set_categories(cats)
    chart.height = 11
    chart.width = 18
    ws_g.add_chart(chart, "B3")

    # 3-1. 진단 결과(상세)
    ws_d = wb.create_sheet(f"3-1. 진단 결과")
    heads = ["진단영역", "항목코드", "세부 진단항목", "중요도", "진단결과", "상세 내용 / 근거"]
    for j, h in enumerate(heads):
        c = ws_d.cell(3, 1 + j, h); c.font = bold; c.fill = hdr_fill; c.alignment = center; c.border = border
    r = 4
    for a in areas:
        first = r
        for res in [x for x in results if area_of(x.get("code", "")) == a]:
            v = verdict_of(res)
            ws_d.cell(r, 1, a if r == first else None)
            ws_d.cell(r, 2, res.get("code", ""))
            ws_d.cell(r, 3, res.get("title", ""))
            ws_d.cell(r, 4, res.get("importance", ""))
            vc = ws_d.cell(r, 5, v)
            if v == "취약":
                vc.font = red
            elif v == MANUAL_LABEL:
                vc.font = blue
            ws_d.cell(r, 6, " / ".join(res.get("evidence", []))[:32000])
            for col in range(1, 7):
                cc = ws_d.cell(r, col); cc.border = border
                cc.alignment = center if col in (2, 4, 5) else left
            r += 1
    for col, w in zip("ABCDEF", (18, 10, 30, 8, 12, 66)):
        ws_d.column_dimensions[col].width = w
    ws_d.freeze_panes = "A4"

    wb.save(out_path)
    return out_path
