#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""클라우드 결과보고서 양식 생성 — 공식 DBMS 양식 파일을 XML 수준에서 편집한다.

openpyxl 로 열었다 저장하지 않는다(표지 로고·그래프 제목 도형·3D 원형차트가 깨짐).
보고서_양식_DBMS.xlsx 의 필요한 XML 만 고치고 나머지(차트·그림·테마·스타일)는 원본 그대로 둔다.

 - 시트명 (Oracle) → (AWS) 등 CSP 이름, 모든 수식·차트 참조도 함께 변경
 - 2-2 요약 / 3-1 상세: DBMS 26항목을 CSP 항목 N개로 교체(영역 병합·영역 경계 굵은선 유지)
 - 점검결과/보안적용율 행, 그래프 참조(평균·분포·영역 레이더) 를 새 행/영역 수에 맞춤
 - 표지 부제·진단대상·그래프 라벨의 Oracle/DBMS 문구를 클라우드로 변경
 - 인쇄: 긴 표는 가로 1페이지 맞춤 + 제목행 반복

  python build_cloud_templates.py [aws azure gcp naver]
"""
import copy
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import tpl_xml as X  # noqa: E402
from tpl_xml import q  # noqa: E402
import server_report  # noqa: E402  (행 높이 계산 공용)

OUT_DIR = os.environ.get("TPL_DIR") or HERE   # 양식 읽기/쓰기 폴더(기본: 이 폴더)
SRC = os.path.join(OUT_DIR, "보고서_양식_DBMS.xlsx")
PROVIDERS = {  # key: (항목 모듈, 라벨, 출력 파일)
    "aws": ("aws_items", "AWS", "보고서_양식_AWS.xlsx"),
    "azure": ("azure_items", "Azure", "보고서_양식_Azure.xlsx"),
    "gcp": ("gcp_items", "GCP", "보고서_양식_GCP.xlsx"),
    "naver": ("ncp_items", "NCP", "보고서_양식_Naver.xlsx"),
}
OLD_SUM, OLD_DET = "2-2. 요약 진단결과(Oracle)", "3-1. 진단 결과(Oracle)"
GRAPH, COVER, TARGET = "2-1. 요약결과(그래프)", "0. 표지", "1. 진단 대상"
FIRST = 6                    # 항목 첫 행
OLD_LAST = 31                # DBMS 항목 마지막 행 (32 점검결과, 33 보안적용율)
HELPER_ROW = 67              # 2-1 영역별 평균 헬퍼표 첫 행(B/C)

# 원본 DBMS 양식에서 '중간 행' 스타일을 가져와 영역 경계만 굵은선으로 파생한다.
SUM_BASE_ROW = 7     # 2-2: A31 B163 C91 D87 E8 F33 G5 H159 I34 J120 K121 L30
DET_BASE_ROW = 17    # 3-1: A1 B163 C90 D87 E108 F11 G108
SUM_COLS = "ABCDEFGHIJKL"
DET_COLS = "ABCDEFG"


def load_items(mod):
    items = __import__("cloud_check." + mod, fromlist=["ITEMS"]).ITEMS
    codes = list(items)
    areas = []                       # [(영역명, [코드...])] — 연속 구간 단위
    for c in codes:
        a = items[c].get("area", "기타")
        if not areas or areas[-1][0] != a:
            areas.append((a, []))
        areas[-1][1].append(c)
    return items, codes, areas


def row_styles(ws, r, cols):
    row = X.rows_of(ws)[r]
    st = {X.split_ref(c.get("r"))[0]: c.get("s") for c in row.findall(q("c"))}
    return {col: st.get(col, "0") for col in cols}


def item_style(pkg, base, col, first, last, plain=("A",)):
    """영역 첫 행은 위 굵은선, 끝 행은 아래 굵은선(plain 열 = 테두리 없는 여백 열 제외)."""
    s = base[col]
    if col in plain or not (first or last):
        return s
    sides = {}
    if first:
        sides["top"] = "medium"
    if last:
        sides["bottom"] = "medium"
    return pkg.derive_xf(s, **sides)


def rebuild_table(pkg, ws, kind, items, codes, areas, det_name):
    """kind='summary'(2-2) | 'detail'(3-1): 6~31 항목행과 32~33 결과행을 새로 만든다."""
    n = len(codes)
    last = FIRST + n - 1
    t1, t2 = last + 1, last + 2
    cols = SUM_COLS if kind == "summary" else DET_COLS
    base = row_styles(ws, SUM_BASE_ROW if kind == "summary" else DET_BASE_ROW, cols)
    rows = X.rows_of(ws)
    proto = rows[SUM_BASE_ROW if kind == "summary" else DET_BASE_ROW]
    trail = [copy.deepcopy(rows[OLD_LAST + 1]), copy.deepcopy(rows[OLD_LAST + 2])]
    widths = X.col_widths(ws)
    delta = t2 - (OLD_LAST + 2)
    old_merges = X.merges(ws)
    sd = ws.find(q("sheetData"))
    for r in range(FIRST, OLD_LAST + 3):          # 기존 항목/결과 행 제거
        if r in rows:
            sd.remove(rows[r])
    X.renumber_tail(ws, OLD_LAST + 3, delta)      # 아래 빈 서식행 이동

    anchor = X.get_row(ws, FIRST - 1)
    merges = [m for m in old_merges if X.split_ref(m.split(":")[0])[1] < FIRST]
    for m in old_merges:                          # 표 아래 병합은 이동
        a, b = m.split(":")
        (ca, ra), (cb, rb) = X.split_ref(a), X.split_ref(b)
        if ra > OLD_LAST + 2:
            merges.append(f"{ca}{ra + delta}:{cb}{rb + delta}")
    r = FIRST
    for area, acodes in areas:
        s, e = r, r + len(acodes) - 1
        for i, code in enumerate(acodes):
            m = items[code]
            row = copy.deepcopy(proto)
            for c in list(row):
                row.remove(c)
            row.set("r", str(r))
            anchor.addnext(row)
            anchor = row
            first, lastrow = (i == 0), (i == len(acodes) - 1)
            plain = ("A", "G") if kind == "summary" else ("A",)   # 2-2 의 G 는 표 사이 빈 열
            st = {col: item_style(pkg, base, col, first, lastrow, plain) for col in cols}
            for col in cols:
                X.get_cell(ws, f"{col}{r}").set("s", str(st[col]))
            if kind == "detail":                                   # 판정 칸 줄바꿈(인터뷰 필요)
                fc = X.get_cell(ws, f"F{r}")
                fc.set("s", str(X.restyle(pkg, fc.get("s"), wrapText="1")))
            if first:
                X.set_str(ws, f"B{r}", area)
            X.set_str(ws, f"C{r}", code)
            X.set_str(ws, f"D{r}", m.get("title", ""))
            if kind == "summary":
                X.set_str(ws, f"E{r}", m.get("imp", ""))
                X.set_formula(ws, f"F{r}",
                              f"IFERROR(T(INDEX('{det_name}'!$F${FIRST}:$G${last},"
                              f"MATCH($C{r},'{det_name}'!$C${FIRST}:$C${last},0),"
                              f"MATCH(F$3,'{det_name}'!$F$3:$G$3,0))),\"\")")
                if first:
                    X.set_formula(ws, f"H{r}", f'IF(COUNTIF(I{s}:I{e},"N/A")=COUNTA(I{s}:I{e}),'
                                               f'"N/A",AVERAGE(I{s}:I{e}))')
                # 점수: 양호/(양호+취약) — N/A·인터뷰 필요는 제외(리눅스·윈도우·DBMS·웹서버와 같은 규칙)
                X.set_formula(ws, f"I{r}", f'IF($J{r}+$K{r}=0,"N/A",$J{r}/($J{r}+$K{r}))')
                X.set_formula(ws, f"J{r}", f'COUNTIF($F{r}:$F{r},"양호")')
                X.set_formula(ws, f"K{r}", f'COUNTIF($F{r}:$F{r},"취약")')
                X.set_formula(ws, f"L{r}", f'COUNTIF($F{r}:$F{r},"N/A")')
                row.set("ht", "31.65")
            else:
                X.set_str(ws, f"E{r}", m.get("crit", ""))
                ht = server_report.estimate_height(
                    [(m.get("title", ""), widths.get(4)), (m.get("crit", ""), widths.get(5))])
                row.set("ht", f"{ht:.2f}")
            row.set("customHeight", "1")
            r += 1
        if e > s:
            merges.append(f"B{s}:B{e}")
            if kind == "summary":
                merges.append(f"H{s}:H{e}")

    # 점검결과 / 보안적용율 (원본 32·33행 복제 후 이동)
    rng = f"F${FIRST}:F${last}"
    for i, tr in enumerate(trail):
        rr = t1 + i
        tr.set("r", str(rr))
        for c in tr.findall(q("c")):
            col, _ = X.split_ref(c.get("r"))
            c.set("r", f"{col}{rr}")
        anchor.addnext(tr)
        anchor = tr
    empty = f'COUNTIF({rng},"?*")=0'
    X.set_formula(ws, f"F{t1}", f'IF({empty},"",COUNTIF({rng},"취약"))')
    X.set_formula(ws, f"F{t2}", f'IF({empty},"",IFERROR(COUNTIF({rng},"양호")/'
                                f'(COUNTIF({rng},"양호")+COUNTIF({rng},"취약")),"N/A"))')
    merges += [f"B{t1}:B{t2}", f"C{t1}:E{t1}", f"C{t2}:E{t2}"]
    X.set_merges(ws, merges)

    # 조건부서식: 판정 열만 깔끔하게(원본 dxf 재사용). 인터뷰 필요는 배경 없이 기본 글자.
    itv = X.ensure_dxf(pkg, "interview")
    f_rng = f"F{FIRST}:F{last}"
    if kind == "summary":
        X.set_conditional_formats(ws, [
            (f_rng, [{"type": "cellIs", "formula": '"취약"', "dxfId": 50},
                     {"type": "cellIs", "formula": '"N/A"', "dxfId": 49},
                     {"type": "containsText", "text": "인터뷰", "dxfId": itv},
                     {"type": "containsText", "text": "확인", "dxfId": 44}]),
            (f"I{FIRST}:I{last}", [{"type": "cellIs", "formula": '"N/A"', "dxfId": 49}]),
            (f"F{t2}", [{"type": "cellIs", "formula": '"N/A"', "dxfId": 49}]),
        ])
    else:
        X.set_conditional_formats(ws, [
            (f_rng, [{"type": "containsText", "text": "취약", "dxfId": 34},
                     {"type": "cellIs", "formula": '"N/A"', "dxfId": 10},
                     {"type": "containsText", "text": "인터뷰", "dxfId": itv},
                     {"type": "containsText", "text": "확인", "dxfId": 33}]),
            (f"F{t2}", [{"type": "cellIs", "formula": '"N/A"', "dxfId": 10}]),
        ])
    w = X.col_widths(ws)
    if w.get(2, 0) < 16.5:
        X.set_col_width(ws, "D", round(w.get(4, 40) - (16.5 - w.get(2, 0)), 2))
        X.set_col_width(ws, "B", 16.5)
    X.set_dimension(ws)
    if kind == "summary":
        X.set_page_fit_width(ws, orientation="landscape")
    else:                                   # 가로 방향, 항목 열(B~E)·제목행 반복
        X.detail_page_setup(pkg, det_name, [("F", "G")], t2)
    return last, t1, t2


def fix_graph(pkg, label, sum_name, areas_rows, t2):
    """2-1 그래프: 평균/분포 참조를 새 보안적용율 행으로, 영역 헬퍼·레이더를 영역 수에 맞춤."""
    g = pkg.sheet(GRAPH)
    X.set_str(g, "B5", label)
    X.set_str(g, "W35", label)
    rate = f"'{sum_name}'!F{t2}:F{t2}"
    X.set_formula(g, "C5", f'IFERROR(AVERAGE({rate}),"")')
    X.set_formula(g, "D18", f'COUNTIF({rate},">=0.85")')
    X.set_formula(g, "D19", f'COUNTIFS({rate},">=0.7",{rate},"<0.85")')
    X.set_formula(g, "D20", f'COUNTIF({rate},"<0.7")')
    # 대상별 점수표: 계정 ID 가 잘리지 않게
    X.set_str(g, "X36", "계정 ID", style=X.get_cell(g, "X36").get("s"))
    X.set_col_width(g, "X", 20.66)
    X.restyle_range(pkg, g, ["X"], range(37, 43), shrinkToFit="1", wrapText="0")
    X.restyle_range(pkg, g, ["B"], range(HELPER_ROW, HELPER_ROW + 7), shrinkToFit="1", wrapText="0")
    # 영역별 평균 헬퍼(B67~B73 은 원본에 서식이 있는 7칸)
    for i in range(7):
        r = HELPER_ROW + i
        if i < len(areas_rows):
            X.set_formula(g, f"B{r}", f"'{sum_name}'!B{areas_rows[i]}")
            X.set_formula(g, f"C{r}", f"'{sum_name}'!H{areas_rows[i]}")
        else:
            X.set_str(g, f"B{r}", None)
            X.set_str(g, f"C{r}", None)
    last = HELPER_ROW + len(areas_rows) - 1
    rows = X.rows_of(g)
    for r in range(last + 1, HELPER_ROW + 7):          # 영역이 7개보다 적으면 남는 빈 노란 행 숨김
        if r in rows:
            rows[r].set("hidden", "1")
    for r in range(HELPER_ROW, HELPER_ROW + 7):        # 레이더용 보조 열(점수 없는 영역 = #N/A → 빈칸)
        if r <= last:
            X.set_formula(g, f"BA{r}", f"IF(ISNUMBER(C{r}),C{r},NA())", style=X.get_cell(g, f"C{r}").get("s"))
        else:
            X.set_str(g, f"BA{r}", None)
    # X 열을 넓히고 행을 숨겼으니 인쇄 영역·배율을 다시 계산
    X.graph_page_setup(pkg, GRAPH, [31, 64], extra_cells_to=(25, 42))
    # 레이더(영역 평균) 범위 + 모든 차트 캐시 제거(열 때 셀 값으로 다시 그림)
    drawing = pkg.drawing_of(GRAPH)
    for ch in pkg.charts_of(drawing):
        root = pkg.part(ch)
        for f in root.iter(f"{{{X.CNS}}}f"):
            f.text = (f.text.replace("$B$67:$B$70", f"$B${HELPER_ROW}:$B${last}")
                            .replace("$C$67:$C$70", f"$BA${HELPER_ROW}:$BA${last}")
                            .replace("$BA$67:$BA$70", f"$BA${HELPER_ROW}:$BA${last}"))
        for tag in ("strCache", "numCache"):
            for e in list(root.iter(f"{{{X.CNS}}}{tag}")):
                e.getparent().remove(e)
    # 도형 글자(그래프 제목 상자·화살표)
    repl = {"DBMS 진단결과": "클라우드 진단결과", "Oracle 항목별 진단 결과": f"{label} 항목별 진단 결과",
            "Oracle": label}
    for t in pkg.part(drawing).iter(f"{{{X.ANS}}}t"):
        if t.text in repl:
            t.text = repl[t.text]


def fix_views(pkg, sum_name, det_name):
    """열면 표지부터, 2-2/3-1 스크롤 처음으로, 긴 표 인쇄 시 제목행(2~5행) 반복."""
    X.open_on_first_sheet(pkg, {sum_name: FIRST, det_name: FIRST})
    X.set_print_titles(pkg, sum_name, "$2:$5")


def build(provider):
    mod, label, out = PROVIDERS[provider]
    items, codes, areas = load_items(mod)
    n = len(codes)
    sum_name, det_name = f"2-2. 요약 진단결과({label})", f"3-1. 진단 결과({label})"

    pkg = X.Pkg(SRC)
    pkg.rename_sheet(OLD_SUM, sum_name)
    pkg.rename_sheet(OLD_DET, det_name)

    last, t1, t2 = rebuild_table(pkg, pkg.sheet(det_name), "detail", items, codes, areas, det_name)
    rebuild_table(pkg, pkg.sheet(sum_name), "summary", items, codes, areas, det_name)
    X.set_str(pkg.sheet(sum_name), "B2", f"{label} 취약점 진단 요약결과({n}항목)")
    X.set_str(pkg.sheet(det_name), "B2", f"{label} 취약점 진단 상세결과({n}항목)")

    area_rows, r = [], FIRST
    for _a, acodes in areas:
        area_rows.append(r)
        r += len(acodes)
    fix_graph(pkg, label, sum_name, area_rows, t2)

    # 표지 부제 / 진단 대상 라벨
    X.set_str(pkg.sheet(COVER), "B13", "클라우드 진단 상세결과")
    tw = pkg.sheet(TARGET)
    keep = lambda ref: X.get_cell(tw, ref).get("s")   # noqa: E731  원래 서식 유지
    X.set_str(tw, "B1", f"  ※ 진단 대상 리스트 - 클라우드 계정 1개 ({label} 1개)", style=keep("B1"))
    X.set_str(tw, "B4", label, style=keep("B4"))
    for ref, text in (("C3", "계정 ID"), ("D3", "리전"), ("E3", "구분")):   # 서버용 Hostname/IP/버전 → 클라우드
        X.set_str(tw, ref, text, style=keep(ref))
    for col, w in (("C", 26), ("D", 16), ("E", 18)):
        X.set_col_width(tw, col, w)
    # 2-2 머리글 계정 ID/리전: 칸을 넓히고(옆 빈 간격 열 G 에서 가져옴) 그래도 길면 축소 맞춤
    sm = pkg.sheet(sum_name)
    X.set_col_width(sm, "F", 22)
    X.set_col_width(sm, "G", 5.33)
    X.restyle_range(pkg, sm, ["F"], (4, 5), shrinkToFit="1", wrapText="0")
    # 3-1 판정 칸: '인터뷰 필요' 가 잘리지 않게 폭 확보(근거 열에서 가져옴)
    dt = pkg.sheet(det_name)
    w = X.col_widths(dt)
    if w.get(6, 0) < 12.5:
        X.set_col_width(dt, "G", round(w.get(7, 70) - (12.5 - w.get(6, 0)), 2))
        X.set_col_width(dt, "F", 12.5)
    # 항목코드 1.1/1.10 은 숫자처럼 보이는 텍스트(숫자로 바꾸면 1.10=1.1 충돌) → 녹색 오류 표시 끄기
    for ws in (sm, dt):
        ie = X.ensure_child(ws, "ignoredErrors")
        e = X.etree.SubElement(ie, q("ignoredError"))
        e.set("sqref", f"C{FIRST}:C{last}")
        e.set("numberStoredAsText", "1")

    fix_views(pkg, sum_name, det_name)
    pkg.clean()
    pkg.drop_calc_chain()
    pkg.save(os.path.join(OUT_DIR, out))
    print(f"양식 저장: {out}  ({n}항목, 영역 {len(areas)})")


def main():
    for p in (sys.argv[1:] or list(PROVIDERS)):
        build(p)


if __name__ == "__main__":
    main()
