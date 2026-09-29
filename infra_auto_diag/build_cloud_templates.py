#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""클라우드 결과보고서 양식 생성 — 사람이 만든 DBMS 양식을 '복붙 편집'해서 만든다.

새로 그리지 않는다. 보고서_양식_DBMS.xlsx(단일 대상, 폰트/차트/조건부서식 완성)를 열어
 - 시트명 (Oracle) → 제거, 모든 수식의 (Oracle) 참조도 함께 정리
 - 3-1/2-2 항목을 CSP 항목(코드/세부/진단기준/중요도/영역)으로 교체, 항목 수만큼 행 확장
 - 점검결과/보안적용율 행, 영역 병합, 조건부서식, 그래프 참조를 새 행수/영역수에 맞게 갱신
만 한다. openpyxl 왕복이 DBMS 의 맑은고딕/차트(3D막대·원형·레이더)/서식을 보존.

  python build_cloud_templates.py [aws azure gcp naver]
"""
import sys
from copy import copy
import openpyxl
from openpyxl.utils import get_column_letter as GL
from openpyxl.styles import Font
from openpyxl.formatting.rule import CellIsRule, FormulaRule

SRC = "보고서_양식_DBMS.xlsx"
DET = "3-1. 진단 결과"        # (Oracle 제거 후 이름)
SUM = "2-2. 요약 진단결과"
GRAPH = "2-1. 요약결과(그래프)"
FIRST = 6
PROVIDERS = {
    "aws": ("aws_items", "AWS", "보고서_양식_AWS.xlsx"),
    "azure": ("azure_items", "Azure", "보고서_양식_Azure.xlsx"),
    "gcp": ("gcp_items", "GCP", "보고서_양식_GCP.xlsx"),
    "naver": ("ncp_items", "Naver", "보고서_양식_Naver.xlsx"),
}


def _ck(c):
    import re
    m = re.match(r"(\d+)\.(\d+)$", str(c))
    if m:
        return (0, int(m.group(1)), int(m.group(2)))
    m = re.match(r"([A-Za-z]+)-?(\d+)$", str(c))
    return (1, m.group(1), int(m.group(2))) if m else (2, str(c), 0)


def _copy_row_style(ws, src_r, dst_r, cols):
    ws.row_dimensions[dst_r].height = ws.row_dimensions[src_r].height
    for c in cols:
        s = ws.cell(src_r, c); d = ws.cell(dst_r, c)
        d.font = copy(s.font); d.fill = copy(s.fill); d.border = copy(s.border)
        d.alignment = copy(s.alignment); d.number_format = s.number_format


def _unmerge_all(ws):
    for m in list(ws.merged_cells.ranges):
        ws.unmerge_cells(str(m))


def build(provider):
    mod, label, out = PROVIDERS[provider]
    items = __import__("cloud_check." + mod, fromlist=["ITEMS"]).ITEMS
    codes = sorted(items, key=_ck)
    n = len(codes)
    last = FIRST + n - 1
    # 영역별 연속행
    areas, arng = [], {}
    r = FIRST
    for c in codes:
        a = items[c].get("area", "기타")
        if a not in arng:
            areas.append(a); arng[a] = [r, r]
        arng[a][1] = r
        r += 1
    D = len(areas)

    wb = openpyxl.load_workbook(SRC)

    # 1) 시트명 (Oracle) 제거 + 모든 수식의 (Oracle) 참조 정리
    for ws in wb.worksheets:
        if "(Oracle)" in ws.title:
            ws.title = ws.title.replace("(Oracle)", "")
    for ws in wb.worksheets:
        for row in ws.iter_rows():
            for cell in row:
                if isinstance(cell.value, str) and cell.value.startswith("=") and "(Oracle)" in cell.value:
                    cell.value = cell.value.replace("(Oracle)", "")

    det = wb[DET]; sm = wb[SUM]; g = wb[GRAPH]
    OLD_LAST = 31          # DBMS 항목 마지막행
    OLD_T1, OLD_T2 = 32, 33  # 점검결과, 보안적용율

    # 2) 3-1 상세 재구성
    _rebuild_sheet(det, codes, items, arng, areas, n, last, kind="detail")
    # 3) 2-2 요약 재구성
    _rebuild_sheet(sm, codes, items, arng, areas, n, last, kind="summary")

    # 4) 표지/진단대상 라벨
    cov = wb["0. 표지"]
    for row in cov.iter_rows():
        for cell in row:
            if isinstance(cell.value, str) and "진단 상세결과" in cell.value:
                cell.value = f"클라우드({label}) 진단 상세결과"
    tg = wb["1. 진단 대상"]
    for row in tg.iter_rows():
        for cell in row:
            if cell.value == "Oracle":
                cell.value = label
            elif isinstance(cell.value, str) and "진단 대상 리스트" in cell.value:
                cell.value = f"  ※ 진단 대상 리스트 - 클라우드({label}) 1대"

    # 5) 그래프 참조 갱신(보안적용율 행 이동, 도메인 헬퍼/레이더)
    t2 = last + 2   # 보안적용율 새 행
    def _fix(cell_ref, formula):
        g[cell_ref] = formula
    _fix("C5", f"=AVERAGE('{SUM}'!F{t2}:F{t2})")
    _fix("D18", f'=COUNTIF(\'{SUM}\'!F{t2}:F{t2},">=0.85")')
    _fix("D20", f'=COUNTIF(\'{SUM}\'!F{t2}:F{t2},"<0.7")')
    # 도메인 헬퍼(B67.., C67..) — 도메인 시작행의 B/H 참조. 도메인 수만큼.
    for i, a in enumerate(areas):
        s = arng[a][0]
        g.cell(67 + i, 2, f"='{SUM}'!B{s}")
        g.cell(67 + i, 3, f"='{SUM}'!H{s}")
    for i in range(D, 6):   # 남는 헬퍼행 비움(기존 4개 초과분/미만분)
        g.cell(67 + i, 2, None); g.cell(67 + i, 3, None)
    # 레이더 차트 카테고리/값 범위를 도메인 수에 맞게
    for ch in g._charts:
        if type(ch).__name__ == "RadarChart":
            for ser in ch.series:
                if ser.val and ser.val.numRef:
                    ser.val.numRef.f = f"'{GRAPH}'!$C$67:$C${66 + D}"
                if ser.cat and ser.cat.strRef:
                    ser.cat.strRef.f = f"'{GRAPH}'!$B$67:$B${66 + D}"

    wb.save(out)
    print(f"양식 저장: {out}  ({n}항목, 영역 {D}, DBMS 양식 기반)")


def _rebuild_sheet(ws, codes, items, arng, areas, n, last, kind):
    OLD_LAST, OLD_T1, OLD_T2 = 31, 32, 33
    cols = list(range(2, 13))   # B~L
    _unmerge_all(ws)
    # 옛 값/수식(항목 판정·집계·트레일링) 비우기 → 새로 채움(수식셀 잔존 방지)
    for r in range(FIRST, OLD_T2 + 1):
        for c in range(6, 13):   # F~L
            ws.cell(r, c).value = None
    # 새 항목 행이 기존(6~31)보다 많으면 스타일 복사로 확장
    for rr in range(OLD_LAST + 1, last + 1):
        _copy_row_style(ws, OLD_LAST, rr, cols)
    # 항목 내용 채우기
    for i, c in enumerate(codes):
        r = FIRST + i
        m = items[c]
        ws.cell(r, 3, c)
        ws.cell(r, 4, m.get("title", ""))
        ws.cell(r, 5, m.get("crit", ""))            # 진단기준
        ws.cell(r, 6, None)                          # F: 판정(상세는 빈칸/요약은 아래서 수식)
        if kind == "detail":
            ws.cell(r, 7, None)                      # G: 근거
        else:  # summary
            ws.cell(r, 5, m.get("imp", ""))          # 요약 E열 = 중요도
            ws.cell(r, 6, (f"=INDEX('{DET}'!$F$6:$G${last},"
                           f"MATCH($C{r},'{DET}'!$C$6:$C${last},0),"
                           f"MATCH(F$3,'{DET}'!$F$3:$G$3,0))"))
            ws.cell(r, 9, f'=IF(COUNTIF($F{r}:$F{r},"N/A")=COUNTA($F{r}:$F{r}),"N/A",$J{r}/(COUNTA($F{r}:$F{r})-$L{r}))')
            ws.cell(r, 10, f'=COUNTIF($F{r}:$F{r},"양호")')
            ws.cell(r, 11, f'=COUNTIF($F{r}:$F{r},"취약")')
            ws.cell(r, 12, f'=COUNTIF($F{r}:$F{r},"N/A")')
    # 항목이 기존보다 적으면 남은 행(끝~31) 비우기
    for r in range(last + 1, OLD_LAST + 1):
        for c in cols:
            ws.cell(r, c).value = None
    # 영역 병합(B열) + (요약) H열 영역별점수
    for a in areas:
        s, e = arng[a]
        ws.cell(s, 2, a)
        if e > s:
            ws.merge_cells(start_row=s, start_column=2, end_row=e, end_column=2)
        if kind == "summary":
            ws.cell(s, 8, f'=IF(COUNTIF(I{s}:I{e},"N/A")=COUNTA(I{s}:I{e}),"N/A",AVERAGE(I{s}:I{e}))')
            if e > s:
                ws.merge_cells(start_row=s, start_column=8, end_row=e, end_column=8)
    # 점검결과/보안적용율 행 이동(스타일 복사 후 수식)
    t1, t2 = last + 1, last + 2
    for src, dst in ((OLD_T1, t1), (OLD_T2, t2)):
        if src != dst:
            _copy_row_style(ws, src, dst, cols)
            for c in cols:                            # 원래 위치 값 비움(이동)
                if FIRST <= src <= last:
                    continue
    # 이동 대상 라벨/수식
    ws.cell(t1, 2, "점검결과"); ws.merge_cells(start_row=t1, start_column=2, end_row=t2, end_column=2)
    ws.cell(t1, 3, "취약항목 개수"); ws.merge_cells(start_row=t1, start_column=3, end_row=t1, end_column=5)
    ws.cell(t1, 6, f'=COUNTIF(F$6:F${last},"취약")')
    ws.cell(t2, 3, "보안 적용율 (양호항목 / 진단항목) %"); ws.merge_cells(start_row=t2, start_column=3, end_row=t2, end_column=5)
    ws.cell(t2, 6, f'=(COUNTIF(F$6:F${last},"양호"))/(COUNTA(F$6:F${last})-COUNTIF(F$6:F${last},"N/A")-COUNTIF(F$6:F${last},"인터뷰 필요"))')
    ws.cell(t2, 6).number_format = "0.0%"
    # 헤더(B2:F2) 제목 갱신
    for row in ws.iter_rows(min_row=2, max_row=2):
        for cell in row:
            if isinstance(cell.value, str) and "취약점 진단" in cell.value:
                cell.value = f"취약점 진단 {'상세결과' if kind=='detail' else '요약결과'}({n}항목)"
    # 조건부서식 재설정(취약=빨강/N/A=회색/인터뷰=파랑)
    try:
        ws.conditional_formatting = ws.conditional_formatting.__class__()
    except Exception:
        pass
    fc = f"F{FIRST}:F{last}"
    ws.conditional_formatting.add(fc, CellIsRule(operator="equal", formula=['"취약"'], font=Font(color="FFFF0000", bold=True)))
    ws.conditional_formatting.add(fc, CellIsRule(operator="equal", formula=['"N/A"'], font=Font(color="FF808080")))
    ws.conditional_formatting.add(fc, FormulaRule(formula=[f'ISNUMBER(SEARCH("인터뷰",F{FIRST}))'], font=Font(color="FF0070C0", bold=True)))


def main():
    for p in (sys.argv[1:] or list(PROVIDERS)):
        build(p)


if __name__ == "__main__":
    main()
