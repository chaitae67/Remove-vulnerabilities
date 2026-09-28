#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""서버(Linux/Windows) 진단 결과 → 보고서 양식(xlsx) 채우기.

보고서_양식_{Linux,Windows}.xlsx 의 시트(0.표지 / 1.진단대상 / 2-1.그래프 /
2-2.요약 / 3-1.상세)를 채운다. 차트가 깨지지 않게 xlsx 를 zip 단위로 열어
시트 XML 문자열만 직접 편집하고 charts/drawings/styles 등은 원본 그대로 다시 압축한다.

이 파일은 GUI/tkinter 에 의존하지 않는다. make_report.py(CLI)가 사용한다.
"""
import datetime
import io
import re
import zipfile
import xml.dom.minidom as _minidom

MANUAL_LABEL = "인터뷰 필요"
REPORT_STATUS = {
    "양호": "양호", "취약": "취약", "N/A": "양호",   # N/A 는 보고서에서 양호 처리(대상 없음)
    "수동확인": MANUAL_LABEL, MANUAL_LABEL: MANUAL_LABEL,
}

# 계열별 양식 스펙 (시트 XML 직접 편집 → 그래프 보존). template 은 호출 시 경로로 주입.
REPORT_SPECS = {
    "linux": {
        "cover": "xl/worksheets/sheet1.xml", "target": "xl/worksheets/sheet3.xml",
        "graph": "xl/worksheets/sheet4.xml", "summary": "xl/worksheets/sheet5.xml",
        "detail": "xl/worksheets/sheet6.xml",
        "broken_from": '<sheet name="2-1. 요약결과(그래프)_깨짐" sheetId="2" state="visible" r:id="rId2" />',
        "broken_to":   '<sheet name="2-1. 요약결과(그래프)_깨짐" sheetId="2" state="hidden" r:id="rId2" />',
        "label": "Linux", "prefix": "U", "count": 67, "first_row": 6, "last_row": 72,
        "detail_cols_from": 8, "detail_cols_to": 35,
        "score_range": "'2-2. 요약 진단결과(Linux)'!$F$74:$T$74",
        "summary_rewrite": "linux",
        "dxf_red": 4, "dxf_blue": 7,
    },
    "windows": {
        "cover": "xl/worksheets/sheet2.xml", "target": "xl/worksheets/sheet3.xml",
        "graph": "xl/worksheets/sheet4.xml", "summary": "xl/worksheets/sheet5.xml",
        "detail": "xl/worksheets/sheet6.xml",
        "broken_from": '<sheet name="2-1. 요약결과(그래프)_깨짐" sheetId="3" r:id="rId1"/>',
        "broken_to":   '<sheet name="2-1. 요약결과(그래프)_깨짐" sheetId="3" state="hidden" r:id="rId1"/>',
        "label": "Windows", "prefix": "W", "count": 64, "first_row": 6, "last_row": 69,
        "detail_cols_from": 8, "detail_cols_to": 13,
        "score_range": "'2-2. 요약 진단결과(Window)'!$F$71:$G$71",
        "summary_rewrite": "windows",
        "dxf_red": 22, "dxf_blue": 21,
    },
}


# ---------------- 양식 xlsx 직접 편집 헬퍼 ----------------
def _xesc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _col_letter(n):
    s = ""
    while n > 0:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def _cell_match(xml, ref):
    return re.search(r'<c r="' + re.escape(ref) + r'"([^>]*?)(?:/>|>.*?</c>)', xml, re.S)


def _cell_style(attrs):
    m = re.search(r'\bs="\d+"', attrs)
    return " " + m.group(0) if m else ""


def _cell_replace(xml, ref, builder, required=True):
    m = _cell_match(xml, ref)
    if not m:
        if required:
            raise KeyError("cell %s not found" % ref)
        return xml
    return xml[:m.start()] + builder(_cell_style(m.group(1))) + xml[m.end():]


def _put_str(xml, ref, text, required=True, s=None):
    def build(old):
        st = f' s="{s}"' if s is not None else old
        return (f'<c r="{ref}"{st} t="inlineStr"><is><t xml:space="preserve">'
                f'{_xesc(text)}</t></is></c>')
    return _cell_replace(xml, ref, build, required)


def _put_num(xml, ref, num, required=True):
    return _cell_replace(xml, ref, lambda s: f'<c r="{ref}"{s}><v>{num}</v></c>', required)


def _put_formula(xml, ref, formula, required=True):
    esc = _xesc(formula)
    return _cell_replace(
        xml, ref, lambda s: f'<c r="{ref}"{s}><f>{esc}</f><v/></c>', required)


def _clear_cols(xml, row, col_from, col_to):
    for c in range(col_from, col_to + 1):
        ref = f"{_col_letter(c)}{row}"
        m = _cell_match(xml, ref)
        if not m:
            continue
        frag = m.group(0)
        if "<f>" in frag or "<v>" in frag or "<is>" in frag:
            xml = (xml[:m.start()]
                   + f'<c r="{ref}"{_cell_style(m.group(1))}/>'
                   + xml[m.end():])
    return xml


def _add_verdict_cf(sheet_xml, sqref, dxf_red, dxf_blue):
    top = sqref.split(":")[0]
    block = (
        f'<conditionalFormatting sqref="{sqref}">'
        f'<cfRule type="containsText" dxfId="{dxf_red}" priority="1" operator="containsText" '
        f'text="취약"><formula>NOT(ISERROR(SEARCH("취약",{top})))</formula></cfRule>'
        f'<cfRule type="containsText" dxfId="{dxf_blue}" priority="2" operator="containsText" '
        f'text="인터뷰"><formula>NOT(ISERROR(SEARCH("인터뷰",{top})))</formula></cfRule>'
        f'</conditionalFormatting>')
    return sheet_xml.replace("<pageMargins", block + "<pageMargins", 1)


def _apply_rate(col, last):
    r = f"{col}$6:{col}${last}"
    return (f'(COUNTIF({r},"양호"))/(COUNTA({r})'
            f'-COUNTIF({r},"N/A")-COUNTIF({r},"{MANUAL_LABEL}"))')


# ---------------- 진입점 ----------------
def fill_report(os_kind, results, host, ip, osver, template_path, out_path):
    """서버 1대 진단 결과를 계열 양식에 채워 out_path 로 저장한다.

    os_kind : 'linux' | 'windows'
    results : [{code,status,evidence,importance,title,(final,note)}...]
    host/ip/osver : 진단 대상 표기값
    """
    spec = REPORT_SPECS[os_kind]
    first, last = spec["first_row"], spec["last_row"]
    pre = spec["prefix"]
    cf_range = f"F{first}:F{last}"

    with zipfile.ZipFile(template_path) as zin:
        order = zin.namelist()
        parts = {n: zin.read(n) for n in order}

    cover = parts[spec["cover"]].decode("utf-8")
    target = parts[spec["target"]].decode("utf-8")
    graph = parts[spec["graph"]].decode("utf-8")
    summary = parts[spec["summary"]].decode("utf-8")
    detail = parts[spec["detail"]].decode("utf-8")
    book = parts["xl/workbook.xml"].decode("utf-8")

    host = (host or "").strip()
    ip = (ip or "-").strip()
    osver = (osver or "").strip()

    # 표지: 작성일 자동
    cover = _put_str(cover, "B18", datetime.date.today().strftime("%Y. %m. %d."), required=False)

    # 진단 대상: 1대
    target = _put_str(target, "B1", f"  ※ 진단 대상 리스트 - 서버 1대 ({spec['label']} 1대)")
    target = _put_num(target, "B5", 1)
    target = _put_str(target, "C5", host)
    target = _put_str(target, "D5", ip)
    target = _put_str(target, "E5", osver)
    target = _put_str(target, "F5", "-", required=False)
    for row in range(6, 20):
        target = _clear_cols(target, row, 2, 7)

    # 3-1 상세: F=판정, G=근거
    by_code = {r.get("code", ""): r for r in results}
    for n in range(1, spec["count"] + 1):
        r = by_code.get(f"{pre}-{n:02d}")
        if not r:
            continue
        row = first - 1 + n
        raw = r.get("final") or r.get("status", "")
        verdict = REPORT_STATUS.get(raw, raw)
        detail = _put_str(detail, f"F{row}", verdict)
        note = (r.get("note") or "").strip()
        evidence = " / ".join(r.get("evidence", []))
        if note:
            evidence = f"{evidence}  [검증자: {note}]" if evidence else f"[검증자: {note}]"
        detail = _put_str(detail, f"G{row}", evidence)
    dc_from, dc_to = spec["detail_cols_from"], spec["detail_cols_to"]
    for row in (3, 4, 5, last + 1, last + 2):
        detail = _clear_cols(detail, row, dc_from, dc_to)
    detail = _put_formula(detail, f"F{last + 2}", _apply_rate("F", last))
    detail = _add_verdict_cf(detail, cf_range, spec["dxf_red"], spec["dxf_blue"])

    # 2-2 요약
    if spec["summary_rewrite"] == "linux":
        summary = _put_formula(
            summary, "F72",
            "HLOOKUP(F$3,'3-1. 진단 결과(Linux)'!$F$3:$Q$72,ROW(A70),FALSE)")
        for row in range(3, 75):
            summary = _clear_cols(summary, row, 7, 11)
        for row in range(6, 73):
            rng = f"$F{row}:$T{row}"
            summary = _put_formula(
                summary, f"Z{row}",
                f'COUNTIF({rng},"N/A")+COUNTIF({rng},"{MANUAL_LABEL}")')
            summary = _put_formula(
                summary, f"W{row}",
                f'IF(COUNTIF({rng},"N/A")+COUNTIF({rng},"{MANUAL_LABEL}")'
                f'=COUNTA({rng}),"N/A",$X{row}/(COUNTA({rng})-$Z{row}))')
        summary = _put_formula(
            summary, "V39",
            'IF(COUNTIF(W39:W68,"N/A")=COUNTA(W39:W68),"N/A",AVERAGE(W39:W68))')
    else:  # windows
        for row in range(3, last + 3):
            summary = _clear_cols(summary, row, 7, 7)
    summary = _put_formula(summary, f"F{last + 2}", _apply_rate("F", last))
    summary = _add_verdict_cf(summary, cf_range, spec["dxf_red"], spec["dxf_blue"])

    # 2-1 그래프
    SCORE = spec["score_range"]
    graph = _put_formula(graph, "D18", f'COUNTIF({SCORE},">=0.85")', required=False)
    graph = _put_formula(graph, "D19", f'COUNTIFS({SCORE},">=0.7",{SCORE},"<0.85")', required=False)
    graph = _put_formula(graph, "D20", f'COUNTIF({SCORE},"<0.7")', required=False)
    graph = _put_formula(graph, "C5", f'AVERAGE({SCORE})', required=False)
    graph = _put_formula(graph, "C6", f'AVERAGE({SCORE})', required=False)
    for row in range(37, 51):
        graph = _clear_cols(graph, row, 22, 24)

    book = book.replace(spec["broken_from"], spec["broken_to"])
    if "<calcPr" not in book:
        book = book.replace("</workbook>", '<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>')
    elif "fullCalcOnLoad" not in book:
        book = re.sub(r"<calcPr ", '<calcPr fullCalcOnLoad="1" ', book, count=1)

    edited = {
        spec["cover"]: cover, spec["target"]: target, spec["graph"]: graph,
        spec["summary"]: summary, spec["detail"]: detail, "xl/workbook.xml": book,
    }
    for name, xml in edited.items():
        _minidom.parseString(xml.encode("utf-8"))   # 형식 검증
        parts[name] = xml.encode("utf-8")

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zout:
        for name in order:
            zout.writestr(name, parts[name])
    with open(out_path, "wb") as fh:
        fh.write(buf.getvalue())
    return out_path
