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
        "servers": 4, "summary_slots": 6,
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
        "servers": 2, "summary_slots": 2,
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
def fill_report(os_kind, servers, template_path, out_path):
    """서버 여러 대 진단 결과를 계열 양식(다중서버)에 채워 out_path 로 저장한다.

    os_kind : 'linux' | 'windows'
    servers : [{host, ip, osver, role, results:[{code,status,evidence,...}]}...]  (서버 1대당 1개)
              — 하위호환: 단일 dict 또는 results 리스트도 허용.

    템플릿은 3-1 상세의 서버별 판정/근거 컬럼만 채우면 2-2 요약·점수·차트가
    수식(HLOOKUP/VLOOKUP/COUNTIF)으로 자동 계산된다. 따라서 데이터 셀만 채운다.
    """
    spec = REPORT_SPECS[os_kind]
    first, last = spec["first_row"], spec["last_row"]
    pre = spec["prefix"]
    cap = spec["servers"]

    if isinstance(servers, dict):
        servers = [servers]
    elif servers and isinstance(servers[0], dict) and "results" not in servers[0] and "code" in servers[0]:
        servers = [{"results": servers}]
    servers = [s for s in servers if s.get("results")]
    n = min(len(servers), cap)

    with zipfile.ZipFile(template_path) as zin:
        order = zin.namelist()
        parts = {nm: zin.read(nm) for nm in order}

    cover = parts[spec["cover"]].decode("utf-8")
    target = parts[spec["target"]].decode("utf-8")
    summary = parts[spec["summary"]].decode("utf-8")
    detail = parts[spec["detail"]].decode("utf-8")
    book = parts["xl/workbook.xml"].decode("utf-8")

    # 표지: 작성일 자동
    cover = _put_str(cover, "B18", datetime.date.today().strftime("%Y. %m. %d."), required=False)

    # 1. 진단 대상: N대
    target = _put_str(target, "B1", f"  ※ 진단 대상 리스트 - 서버 {n}대 ({spec['label']} {n}대)")
    for i in range(n):
        sv = servers[i]
        row = 5 + i
        target = _put_num(target, f"B{row}", i + 1)
        target = _put_str(target, f"C{row}", (sv.get("host") or "").strip())
        target = _put_str(target, f"D{row}", (sv.get("ip") or "-").strip())
        target = _put_str(target, f"E{row}", (sv.get("osver") or "").strip())
        target = _put_str(target, f"F{row}", (sv.get("role") or "-").strip(), required=False)
    for row in range(5 + n, 20):
        target = _clear_cols(target, row, 2, 6)

    # 3-1 상세: 서버 i → 판정 컬럼(F,H,J,L=6+2i), 근거 컬럼(G,I,K,M=7+2i)
    for i in range(n):
        sv = servers[i]
        cv, ce = 6 + 2 * i, 7 + 2 * i
        vL, eL = _col_letter(cv), _col_letter(ce)
        detail = _put_num(detail, f"{vL}3", i + 1, required=False)
        detail = _put_str(detail, f"{eL}3", (sv.get("host") or "").strip(), required=False)
        detail = _put_str(detail, f"{eL}4", (sv.get("ip") or "-").strip(), required=False)
        detail = _put_str(detail, f"{eL}5", (sv.get("role") or "").strip(), required=False)
        by_code = {r.get("code", ""): r for r in sv.get("results", [])}
        for k in range(1, spec["count"] + 1):
            r = by_code.get(f"{pre}-{k:02d}")
            if not r:
                continue
            row = first - 1 + k
            raw = r.get("final") or r.get("status", "")
            verdict = REPORT_STATUS.get(raw, raw)
            detail = _put_str(detail, f"{vL}{row}", verdict, required=False)
            note = (r.get("note") or "").strip()
            evidence = " / ".join(r.get("evidence", []))
            if note:
                evidence = f"{evidence}  [검증자: {note}]" if evidence else f"[검증자: {note}]"
            detail = _put_str(detail, f"{eL}{row}", evidence, required=False)
    for i in range(n, cap):     # 미사용 서버 컬럼 비우기(2-2 HLOOKUP #N/A 방지)
        cv, ce = 6 + 2 * i, 7 + 2 * i
        for row in [3, 4, 5] + list(range(first, last + 1)):
            detail = _clear_cols(detail, row, cv, ce)

    # 2-2 요약: 서버 번호 칸만 사용 대수로 맞추고 나머지 수식은 그대로 자동계산
    for i in range(spec["summary_slots"]):
        col = 6 + i
        if i < n:
            summary = _put_num(summary, f"{_col_letter(col)}3", i + 1, required=False)
        else:
            for row in [3, 4, 5] + list(range(first, last + 1)):
                summary = _clear_cols(summary, row, col, col)

    book = book.replace(spec["broken_from"], spec["broken_to"])
    if "<calcPr" not in book:
        book = book.replace("</workbook>", '<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>')
    elif "fullCalcOnLoad" not in book:
        book = re.sub(r"<calcPr ", '<calcPr fullCalcOnLoad="1" ', book, count=1)

    edited = {
        spec["cover"]: cover, spec["target"]: target,
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
