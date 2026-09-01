#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""엑셀(보고서) 추출 모듈.

- export(app)            : 엑셀 버튼 진입점. 양식이 있으면 서식대로, 없으면 기본형식
- _fill_template_raw     : 보고서 양식(xlsx)을 zip 단위로 직접 편집(그래프 보존)
- _export_plain          : openpyxl 로 기본 표 형식 저장
그 외 _put_*, _clear_cols 등은 양식 셀을 직접 편집하는 헬퍼.
"""
import os
import io
import re
import zipfile
import datetime
from tkinter import filedialog, messagebox

try:
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment
except ImportError:
    openpyxl = None

from common import REPORT_STATUS, MANUAL_LABEL, SCRIPT_DIR

# 결과보고서 양식(같은 폴더). 있으면 이 서식 그대로 채워서 저장한다.
REPORT_TEMPLATE = os.path.join(SCRIPT_DIR, "보고서_양식_Linux.xlsx")

# 양식 내부 시트 XML 경로(파일명 기준 — openpyxl 을 거치지 않고 직접 편집해야
# 그래프/도형이 보존된다).
#   sheet1 = 0. 표지            sheet2 = 2-1. 요약결과(그래프)_깨짐
#   sheet3 = 1. 진단 대상       sheet4 = 2-1. 요약결과(그래프)
#   sheet5 = 2-2. 요약 진단결과  sheet6 = 3-1. 진단 결과(Linux)
XL_COVER = "xl/worksheets/sheet1.xml"
XL_TARGET = "xl/worksheets/sheet3.xml"
XL_GRAPH = "xl/worksheets/sheet4.xml"
XL_SUMMARY = "xl/worksheets/sheet5.xml"
XL_DETAIL = "xl/worksheets/sheet6.xml"
XL_WORKBOOK = "xl/workbook.xml"

# 보안 적용율(양호/진단항목) — 분모에서 N/A 와 "인터뷰 필요" 제외
_APPLY_RATE = (
    '(COUNTIF({c}$6:{c}$72,"양호"))/(COUNTA({c}$6:{c}$72)'
    '-COUNTIF({c}$6:{c}$72,"N/A")-COUNTIF({c}$6:{c}$72,"' + MANUAL_LABEL + '"))')


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
    """s 를 주면 셀 스타일 인덱스를 그 값으로 교체(배경색 등), 안 주면 원래 스타일 유지."""
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
    """행 안에서 값/수식이 든 셀만 골라 빈 셀로 만든다(스타일 유지)."""
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


# 양식 styles.xml 에 이미 정의된 조건부서식 글꼴색 (dxfId)
_DXF_RED = 4      # <font><b/><color rgb="FFFF0000"/>  → 취약
_DXF_BLUE = 7     # <font><b/><color rgb="FF0070C0"/>  → 인터뷰 필요


def _add_verdict_cf(sheet_xml, sqref):
    """판정 셀 범위에 '취약=빨강 / 인터뷰 필요=파랑' 글꼴색 조건부서식을 추가한다.

    양식의 기존 조건부서식은 sqref 가 863개로 쪼개져 일부 행에만 '취약' 규칙이
    있어 색이 안 나온다. 우선순위 1~2 로 범위 전체를 덮는 규칙을 하나 더 넣어
    보완한다(양호는 규칙 없이 기본 검정 유지). styles.xml 은 건드리지 않는다.
    """
    top = sqref.split(":")[0]           # 조건부서식 수식 기준 셀 (예: F6)
    block = (
        f'<conditionalFormatting sqref="{sqref}">'
        f'<cfRule type="containsText" dxfId="{_DXF_RED}" priority="1" operator="containsText" '
        f'text="취약"><formula>NOT(ISERROR(SEARCH("취약",{top})))</formula></cfRule>'
        f'<cfRule type="containsText" dxfId="{_DXF_BLUE}" priority="2" operator="containsText" '
        f'text="인터뷰"><formula>NOT(ISERROR(SEARCH("인터뷰",{top})))</formula></cfRule>'
        f'</conditionalFormatting>')
    return sheet_xml.replace("<pageMargins", block + "<pageMargins", 1)


# ---------------- 진입점 ----------------
def export(app):
    """엑셀 버튼 진입점. 양식이 있고 Linux 점검이면 서식대로, 아니면 기본형식."""
    if openpyxl is None:
        messagebox.showerror("의존성 오류", "openpyxl이 필요합니다.\npip install openpyxl")
        return
    if not app.results:
        messagebox.showwarning("데이터 없음", "먼저 점검을 실행하세요.")
        return
    default = f"kisa_{app.host_label or 'result'}.xlsx".replace(":", "_")
    path = filedialog.asksaveasfilename(defaultextension=".xlsx",
                                        initialfile=default,
                                        filetypes=[("Excel", "*.xlsx")])
    if not path:
        return
    # 보고서 양식(Linux 전용)이 있고 Linux 점검일 때만 서식대로 채워서 저장
    # (Windows 점검 결과는 Linux 양식과 안 맞으므로 기본 형식으로 저장)
    if os.path.exists(REPORT_TEMPLATE) and app.os_choice.get() == "linux":
        try:
            _fill_template_raw(app, path)
            app.log(f"✔ 엑셀 저장(보고서 양식): {path}")
            messagebox.showinfo("저장 완료", f"보고서 양식으로 저장했습니다:\n{path}")
            return
        except PermissionError:
            app.log(f"✖ 저장 실패(권한 없음): {path}")
            messagebox.showerror(
                "저장 실패",
                "파일에 쓸 수 없습니다. 같은 이름의 파일이 Excel 등에서 "
                f"열려 있으면 닫고 다시 저장하세요:\n{path}")
            return
        except Exception as e:
            app.log(f"⚠ 양식 채우기 실패({e}) → 기본 형식으로 저장합니다.")
    _export_plain(app, path)


def _fill_template_raw(app, path):
    """양식 xlsx 를 zip 단위로 직접 편집한다.

    openpyxl 로 열었다 저장하면 그래프(chart)·도형이 깨지므로, 시트 XML
    문자열만 손보고 charts/drawings/styles 등 나머지 파트는 원본 그대로
    다시 압축한다. 양식은 서버 15대용이므로 이번 점검(1대)에 안 쓰는 열은
    비워 #N/A·#DIV/0! 을 없앤다.
    """
    with zipfile.ZipFile(REPORT_TEMPLATE) as zin:
        order = zin.namelist()
        parts = {n: zin.read(n) for n in order}

    cover = parts[XL_COVER].decode("utf-8")
    target = parts[XL_TARGET].decode("utf-8")
    graph = parts[XL_GRAPH].decode("utf-8")
    summary = parts[XL_SUMMARY].decode("utf-8")
    detail = parts[XL_DETAIL].decode("utf-8")
    book = parts[XL_WORKBOOK].decode("utf-8")
    # styles.xml 은 건드리지 않는다 — 색은 조건부서식(글꼴색)으로 처리

    host = (app.host_label or app.conn_host or "").strip()
    ipaddr = (app.conn_host or "").strip()
    osver = (app.os_label or "").strip()

    # 표지: 작성일 자동 기입
    cover = _put_str(cover, "B18", datetime.date.today().strftime("%Y. %m. %d."))

    # 진단 대상: 호스트 1대
    target = _put_str(target, "B1", "  ※ 진단 대상 리스트 - 서버 1대 (Linux 1대)")
    target = _put_num(target, "B5", 1)
    target = _put_str(target, "C5", host)
    target = _put_str(target, "D5", ipaddr)
    target = _put_str(target, "E5", osver)

    # 3-1 상세 결과: F=판정(최종판정 기준), G=근거
    by_code = {r.get("code", ""): r for r in app.results}
    for n in range(1, 68):                       # U-01 → 6행, U-67 → 72행
        r = by_code.get(f"U-{n:02d}")
        if not r:
            continue
        row = 5 + n
        raw = r.get("final") or r.get("status", "")        # 검증자 최종판정 우선
        verdict = REPORT_STATUS.get(raw, raw)
        detail = _put_str(detail, f"F{row}", verdict)
        note = (r.get("note") or "").strip()
        evidence = " / ".join(r.get("evidence", []))
        if note:
            evidence = f"{evidence}  [검증자: {note}]" if evidence else f"[검증자: {note}]"
        detail = _put_str(detail, f"G{row}", evidence)
    for row in (3, 4, 5, 73, 74):               # 미사용 서버(H~AI) 정리
        detail = _clear_cols(detail, row, 8, 35)
    detail = _put_formula(detail, "F74", _APPLY_RATE.format(c="F"))
    detail = _add_verdict_cf(detail, "F6:F72")   # 취약=빨강 / 인터뷰=파랑 글꼴색

    # 2-2 요약: G~K열(서버2~6) 제거, "인터뷰 필요" 점수 제외
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
    summary = _put_formula(summary, "F74", _APPLY_RATE.format(c="F"))
    # 양식 버그: '3. 서비스 관리' 영역점수(V39)가 W69(패치)만 평균 → W39:W68 로 교정
    summary = _put_formula(
        summary, "V39",
        'IF(COUNTIF(W39:W68,"N/A")=COUNTA(W39:W68),"N/A",AVERAGE(W39:W68))')
    summary = _add_verdict_cf(summary, "F6:F72")

    # 2-1 그래프
    #   점수 범위 = '2-2. 요약 진단결과(Linux)'!$F$74:$T$74 (서버별 보안 적용율)
    #   안전 D18 = COUNTIF(점수,">=0.85")
    #   양호 D19 = COUNTIFS(점수,">=0.7", 점수,"<0.85")   ← 양식은 D17-(D18+D20) 뺄셈이라 교체
    #   취약 D20 = COUNTIF(점수,"<0.7")
    #   C18~C20  = D18~D20 / $D$17 (비율),  C5/C6 = AVERAGE(점수)
    SCORE = "'2-2. 요약 진단결과(Linux)'!$F$74:$T$74"
    graph = _put_formula(graph, "D18", f'COUNTIF({SCORE},">=0.85")')
    graph = _put_formula(graph, "D19", f'COUNTIFS({SCORE},">=0.7",{SCORE},"<0.85")')
    graph = _put_formula(graph, "D20", f'COUNTIF({SCORE},"<0.7")')
    graph = _put_formula(graph, "C5", f'AVERAGE({SCORE})')
    graph = _put_formula(graph, "C6", f'AVERAGE({SCORE})')
    for row in range(37, 51):
        graph = _clear_cols(graph, row, 22, 24)   # 미사용 서버 목록(V/W/X) 정리

    # workbook: 미완성 "_깨짐" 시트 숨김
    book = book.replace(
        '<sheet name="2-1. 요약결과(그래프)_깨짐" sheetId="2" state="visible" r:id="rId2" />',
        '<sheet name="2-1. 요약결과(그래프)_깨짐" sheetId="2" state="hidden" r:id="rId2" />')

    edited = {
        XL_COVER: cover, XL_TARGET: target, XL_GRAPH: graph,
        XL_SUMMARY: summary, XL_DETAIL: detail, XL_WORKBOOK: book,
    }
    import xml.dom.minidom as _minidom
    for name, xml in edited.items():
        _minidom.parseString(xml.encode("utf-8"))   # 형식 검증
        parts[name] = xml.encode("utf-8")

    # 메모리에서 zip 을 완성한 뒤 마지막에 한 번만 기록한다
    # (기록 실패 시에도 반쯤 쓰인 손상 파일이 남지 않도록).
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zout:
        for name in order:
            zout.writestr(name, parts[name])
    with open(path, "wb") as fh:
        fh.write(buf.getvalue())


def _export_plain(app, path):
    try:
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "취약점 빼기 팀 자동화 결과"
        headers = ["호스트", "코드", "중요도", "점검 항목", "자동판정", "최종판정", "근거", "비고"]
        ws.append(headers)
        for c in ws[1]:
            c.font = Font(bold=True, color="FFFFFF")
            c.fill = PatternFill("solid", fgColor="404040")
            c.alignment = Alignment(horizontal="center")
        font_color = {"취약": "FFFF0000", "인터뷰 필요": "FF0070C0"}  # 양호=검정
        for r in app.results:
            raw = r.get("final") or r.get("status", "")
            fin = REPORT_STATUS.get(raw, raw)      # 수동확인 → 인터뷰 필요
            ws.append([app.host_label, r.get("code", ""), r.get("importance", ""),
                       r.get("title", ""), r.get("status", ""), fin,
                       " / ".join(r.get("evidence", [])), r.get("note", "")])
            fc = font_color.get(fin)
            if fc:
                ws.cell(row=ws.max_row, column=6).font = Font(bold=True, color=fc)
        widths = [14, 7, 7, 30, 10, 10, 70, 24]
        for i, w in enumerate(widths, start=1):
            ws.column_dimensions[openpyxl.utils.get_column_letter(i)].width = w
        ws.freeze_panes = "A2"
        ws.auto_filter.ref = f"A1:H{ws.max_row}"
        wb.save(path)
        app.log(f"✔ 엑셀 저장: {path}")
        messagebox.showinfo("저장 완료", f"엑셀로 저장했습니다:\n{path}")
    except Exception as e:
        messagebox.showerror("저장 오류", str(e))
