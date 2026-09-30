#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""리눅스/윈도우/DBMS/웹서버 결과보고서 양식 생성 — 공식 결과보고서(xlsx)에서 만든다.

공식 보고서(결과보고서/주통기/*.xlsx, 저장소에는 올리지 않음)를 XML 수준에서 편집해
입력값(표지 문서정보·진단대상·판정·근거)과 증적 스크린샷만 지우고, 공식 파일의 결함을 고친다.
표지 로고·차트·도형·조건부서식·스타일은 원본 그대로 유지(openpyxl 로 저장하지 않음).

고치는 것(공식 파일 자체의 결함 포함)
 - 리눅스 2-1 외부 파일 링크(#VALUE!, 윈도우 영역명) → 이 파일 기준 수식, 2-2 F72 하드코딩 '양호' → 수식
 - 윈도우 3-1 G4 하드코딩 IP, 2-1 등급 분포가 53행(항목 판정)을 세던 오류 → 보안적용율 행
 - 대상이 양식 칸보다 적을 때 빈 칸이 0% 로 평균·분포에 섞이던 문제(빈 칸은 빈칸으로)
 - 점수 규칙 통일: 양호/(양호+취약) — N/A·인터뷰 필요는 제외(공식 윈도우·웹서버 방식)
 - 판정 칸에 남은 공식 보고서의 빨간 글씨 → 기본 글씨 + 조건부서식(취약 빨강/N/A 회색/인터뷰 주황)
 - 스크린샷 자리였던 수백 pt 행 높이 → 내용 높이, 인쇄 배율 10% → 읽을 수 있는 배율
 - 캐시된 옛 호스트·점수, 숨은 옛 근거 문장, 추가기능 작업창, 작성자 경로 제거

  python build_server_templates.py [linux windows dbms web]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import tpl_xml as X  # noqa: E402
import server_report  # noqa: E402

OFFICIAL = os.path.join(HERE, "결과보고서", "주통기")
OUT_DIR = os.environ.get("TPL_DIR") or HERE   # 양식 저장 폴더(기본: 이 폴더)
COVER, TARGET, GRAPH = "0. 표지", "1. 진단 대상", "2-1. 요약결과(그래프)"
PROJECT_TITLE = '"제로데이클리닉" 취약점 진단'
EVID_MAX_WIDTH = 70          # 스크린샷용으로 넓던 근거 열 → 인쇄 시 읽을 수 있는 폭
VERDICT_MIN_WIDTH = 9        # 판정 열 최소 폭(인터뷰 필요 2줄)

# 표 묶음: 2-x 요약 시트 + 3-x 상세 시트 + 진단대상 범위. slots = 대상 칸 수
TYPES = {
    "linux": {
        "src": "리눅스_서버_취약점진단_결과보고서v2.0.xlsx", "out": "보고서_양식_Linux.xlsx",
        "targets": [5, 6, 7, 8],
        "tables": [dict(summ="2-2. 요약 진단결과(Linux)", det="3-1. 진단 결과(Linux)", first=6, last=72,
                        slots=4, tgt="$B$5:$F$8", score="L", lookup="hlookup")],
        "graph": "multi", "graph_breaks": [70],
    },
    "windows": {
        "src": "윈도우_서버_취약점진단_결과보고서v2.1.xlsx", "out": "보고서_양식_Windows.xlsx",
        "targets": [5, 6],
        "tables": [dict(summ="2-2. 요약 진단결과(Window)", det="3-1. 진단 결과(window)", first=6, last=69,
                        slots=2, tgt="$B$5:$F$6", score="J", lookup="hlookup")],
        "graph": "multi", "graph_breaks": [70],
    },
    "dbms": {
        "src": "DBMS_취약점진단_결과보고서v2.1.xlsx", "out": "보고서_양식_DBMS.xlsx",
        "targets": [5],
        "tables": [dict(summ="2-2. 요약 진단결과(Oracle)", det="3-1. 진단 결과(Oracle)", first=6, last=31,
                        slots=1, tgt="$B$5:$F$5", score="I", lookup="index")],
        "graph": "single", "graph_breaks": [31, 64],
    },
    "web": {
        "src": "Webserver_취약점진단_결과보고서v1.7.xlsx", "out": "보고서_양식_Webserver.xlsx",
        "targets": [5, 7, 15, 16],
        "tables": [
            dict(summ="2-2. 요약 진단결과(IIS)", det="3-1. 진단 결과(IIS)", first=6, last=31,
                 slots=1, tgt="$B$5:$F$5", score="I", lookup="hlookup"),
            dict(summ="2-3. 요약 진단결과(Nginx)", det="3-2. 진단 결과(Nginx)", first=6, last=31,
                 slots=1, tgt="$B$7:$F$7", score="I", lookup="hlookup"),
            dict(summ="2-4. 요약 진단결과(Tomcat)", det="3-3. 진단 결과(Tomcat)", first=6, last=31,
                 slots=2, tgt="$B$15:$F$16", score="J", lookup="hlookup"),
        ],
        "graph": "web", "graph_breaks": [31, 64],
    },
}


def C(i):
    return X.col_letter(i)


def vcols(t):
    """상세 시트 판정 열(F,H,J,L..)"""
    return [C(6 + 2 * i) for i in range(t["slots"])]


def scols(t):
    """요약 시트 대상 열(F,G,H,I..)"""
    return [C(6 + i) for i in range(t["slots"])]


def rate_formulas(rng):
    """(취약 개수, 보안적용율) — 판정이 하나도 없는 칸(없는 대상)은 빈칸."""
    empty = f'COUNTIF({rng},"?*")=0'
    return (f'IF({empty},"",COUNTIF({rng},"취약"))',
            f'IF({empty},"",IFERROR(COUNTIF({rng},"양호")/(COUNTIF({rng},"양호")+COUNTIF({rng},"취약")),"N/A"))')


# ---------------- 입력값 비우기 ----------------
def blank(pkg, cfg):
    cov = pkg.sheet(COVER)
    for ref in ("L3", "L4", "L5", "L6", "B18"):
        X.clear_value(cov, ref)
    tw = pkg.sheet(TARGET)
    for r in cfg["targets"]:
        for col in "BCDEF":
            X.clear_value(tw, f"{col}{r}")
    for t in cfg["tables"]:
        ws = pkg.sheet(t["det"])
        last_col = X.col_idx(vcols(t)[-1]) + 1
        for r in range(t["first"], t["last"] + 1):
            for ci in range(6, max(last_col, 9) + 1):          # 판정·근거(+ 옆 빈칸의 잡문자)
                X.clear_value(ws, f"{C(ci)}{r}")
        X.remove_drawing(pkg, t["det"])


# ---------------- 표 수식(대상 없는 칸 안전 + 점수 규칙 통일) ----------------
def repair_detail(pkg, t):
    ws = pkg.sheet(t["det"])
    first, last = t["first"], t["last"]
    for c in vcols(t):
        e = C(X.col_idx(c) + 1)
        for r, k in ((3, 2), (4, 3), (5, 5)):                   # 대상명 / IP / 용도
            X.set_formula(ws, f"{e}{r}", f"IFERROR(VLOOKUP({c}$3,'1. 진단 대상'!{t['tgt']},{k},FALSE),\"\")")
        f1, f2 = rate_formulas(f"{c}${first}:{c}${last}")
        X.set_formula(ws, f"{c}{last + 1}", f1)
        X.set_formula(ws, f"{c}{last + 2}", f2)
    lab = X.cell_text(pkg, ws, f"C{last + 1}")
    if lab and lab.strip() != lab:                             # '\n취약항목 개수\n' → 글자가 안 보이던 문제
        X.set_str(ws, f"C{last + 1}", lab.strip(), style=X.get_cell(ws, f"C{last + 1}").get("s"))
    rows = X.rows_of(ws)
    for r in (last + 1, last + 2):
        if r in rows and float(rows[r].get("ht", "0")) < 20.25:
            rows[r].set("ht", "20.25")
            rows[r].set("customHeight", "1")


def repair_summary(pkg, t):
    ws = pkg.sheet(t["summ"])
    first, last, det = t["first"], t["last"], t["det"]
    sc = scols(t)
    a, b = sc[0], sc[-1]
    det_last_col = C(X.col_idx(vcols(t)[-1]) + 1)
    for c in sc:
        X.set_formula(ws, f"{c}4", f"IFERROR(VLOOKUP({c}$3,'1. 진단 대상'!{t['tgt']},2,FALSE),\"\")")
        X.set_formula(ws, f"{c}5", f"IFERROR(VLOOKUP({c}$3,'1. 진단 대상'!{t['tgt']},3,FALSE),\"\")")
    s_i = X.col_idx(t["score"])
    s_col, good, vul, na = (C(s_i + i) for i in range(4))     # 점수, 양호, 취약, N/A
    for r in range(first, last + 1):
        for c in sc:
            if t["lookup"] == "index":
                src = (f"INDEX('{det}'!$F${first}:$G${last},MATCH($C{r},'{det}'!$C${first}:$C${last},0),"
                       f"MATCH({c}$3,'{det}'!$F$3:$G$3,0))")
            else:
                src = f"HLOOKUP({c}$3,'{det}'!$F$3:${det_last_col}${last},ROW(A{r - 2}),FALSE)"
            X.set_formula(ws, f"{c}{r}", f'IFERROR(T({src}),"")')   # 빈 판정 → 빈칸(0 아님)
        X.set_formula(ws, f"{s_col}{r}", f'IF(${good}{r}+${vul}{r}=0,"N/A",${good}{r}/(${good}{r}+${vul}{r}))')
        X.set_formula(ws, f"{good}{r}", f'COUNTIF(${a}{r}:${b}{r},"양호")')
        X.set_formula(ws, f"{vul}{r}", f'COUNTIF(${a}{r}:${b}{r},"취약")')
        X.set_formula(ws, f"{na}{r}", f'COUNTIF(${a}{r}:${b}{r},"N/A")')
    for c in sc:
        f1, f2 = rate_formulas(f"{c}${first}:{c}${last}")
        X.set_formula(ws, f"{c}{last + 1}", f1)
        X.set_formula(ws, f"{c}{last + 2}", f2)


def style_tables(pkg, t):
    """판정 칸: 공식 보고서에 남은 빨간 글씨 제거 → 조건부서식이 색을 결정. 근거 칸: 세로 가운데·줄바꿈."""
    first, last = t["first"], t["last"]
    rows = range(first, last + 1)
    det = pkg.sheet(t["det"])
    plain = X.get_cell(det, f"E{first}").get("s", "0")          # 진단기준 칸(10pt 보통 글씨)
    X.restyle_range(pkg, det, vcols(t), rows, font_from=plain, horizontal="center", vertical="center",
                    wrapText="1")
    evid = [C(X.col_idx(c) + 1) for c in vcols(t)]
    X.restyle_range(pkg, det, evid, rows, horizontal="left", vertical="center", wrapText="1")
    widths = X.col_widths(det)
    for v, e in zip(vcols(t), evid):
        vw = widths.get(X.col_idx(v), widths["default"])
        ew = min(widths.get(X.col_idx(e), widths["default"]), EVID_MAX_WIDTH)
        if vw < VERDICT_MIN_WIDTH:                                  # '인터뷰 필요' 가 잘리지 않게
            ew -= VERDICT_MIN_WIDTH - vw
            X.set_col_width(det, v, VERDICT_MIN_WIDTH)
        X.set_col_width(det, e, round(ew, 2))
    X.add_verdict_cf(pkg, det, " ".join(f"{c}{first}:{c}{last}" for c in vcols(t)))
    summ = pkg.sheet(t["summ"])
    sc = scols(t)
    X.add_verdict_cf(pkg, summ, f"{sc[0]}{first}:{sc[-1]}{last}")
    # 요약 대상 열 글꼴을 첫 대상 열에 맞춤(공식 윈도우 G열은 'Noto Sans CJK SC' 라 다른 글꼴로 대체됨)
    X.restyle_range(pkg, summ, sc, rows, font_from=X.get_cell(summ, f"{sc[0]}{first}").get("s", "0"))
    # 취약항목 개수는 정수로(공식 웹 3-x 는 '9.0' 처럼 소수점)
    X.restyle_numfmt(pkg, det, [f"{c}{last + 1}" for c in vcols(t)], 1)
    X.restyle_numfmt(pkg, summ, [f"{c}{last + 1}" for c in sc], 1)
    if t["slots"] > 1:
        # 다중 대상 상세는 서버별 쪽에 B:D 만 반복 → 제목·결과행 라벨이 E 까지 병합돼 있으면 잘린다
        X.narrow_merge(det, "B2:E2", "B2:D2")
        for r in (last + 1, last + 2):
            X.narrow_merge(det, f"C{r}:E{r}", f"C{r}:D{r}")
            X.restyle_range(pkg, det, ["C"], [r], shrinkToFit="1", wrapText="0")


# ---------------- 2-1 그래프 ----------------
def graph_common(pkg):
    drawing = pkg.drawing_of(GRAPH)
    for ch in pkg.charts_of(drawing):
        root = pkg.part(ch)
        for ax in list(root.iter(f"{{{X.CNS}}}valAx")) + list(root.iter(f"{{{X.CNS}}}catAx")):
            for tt in ax.findall(f"{{{X.CNS}}}title"):              # 빈 축 제목 → '축 제목' 자리표시
                if not "".join(e.text or "" for e in tt.iter(f"{{{X.ANS}}}t")).strip():
                    ax.remove(tt)
        if list(root.iter(f"{{{X.CNS}}}pie3DChart")) or list(root.iter(f"{{{X.CNS}}}pieChart")):
            X.pie_hide_zero_labels(pkg, ch)
        if list(root.iter(f"{{{X.CNS}}}radarChart")):
            X.radar_scale_0_1(pkg, ch)
    X.radar_na_gaps(pkg, GRAPH)                 # 'N/A' 영역이 레이더 중심(0%)에 찍히지 않게
    X.remove_grade_legend_picture(pkg, drawing)
    g = pkg.sheet(GRAPH)
    for r in (18, 19, 20):
        X.set_formula(g, f"C{r}", f"IF($D$17=0,0,D{r}/$D$17)")


def graph_multi(pkg, cfg, t, area_rows, domain_col):
    """리눅스/윈도우 2-1: 외부 링크로 끊긴 수식 복원, 분포는 보안적용율 행 기준."""
    g = pkg.sheet(GRAPH)
    summ, t2 = t["summ"], t["last"] + 2
    sc = scols(t)
    rate = f"'{summ}'!${sc[0]}${t2}:${sc[-1]}${t2}"
    tg = f"'1. 진단 대상'!$B${cfg['targets'][0]}:$B${cfg['targets'][-1]}"
    for ref, fx in (("C5", f'IFERROR(AVERAGE({rate}),"")'), ("C6", f'IFERROR(AVERAGE({rate}),"")'),
                    ("D5", "D6"), ("D6", f"COUNT({tg})"), ("D17", f"COUNT({tg})"),
                    ("D18", f'COUNTIF({rate},">=0.85")'),
                    ("D19", f'COUNTIFS({rate},">=0.7",{rate},"<0.85")'),
                    ("D20", f'COUNTIF({rate},"<0.7")')):
        X.set_formula(g, ref, fx)
    tr = f"'1. 진단 대상'!{t['tgt']}"
    hdr = f"'{summ}'!${sc[0]}$3:${sc[-1]}${t2}"
    for r in range(36, 51):
        X.set_formula(g, f"W{r}", f'IFERROR(VLOOKUP($V{r},{tr},2,FALSE),"")')
        X.set_formula(g, f"X{r}", f'IFERROR(HLOOKUP($V{r},{hdr},{t2 - 2},FALSE),"")')
    for i, src in enumerate(area_rows):
        r = 72 + i
        X.set_formula(g, f"B{r}", f"SUBSTITUTE('{summ}'!B{src},CHAR(10),\"\")")   # '2. 파일 및 \n디렉토리'
        X.set_formula(g, f"C{r}", f"'{summ}'!{domain_col}{src}")
        X.set_formula(g, f"D{r}", "$C$6")
    X.restyle_range(pkg, g, ["B"], range(72, 72 + len(area_rows)), shrinkToFit="1", wrapText="0")  # '2. 파일 및 디렉토' 잘림
    rows = X.rows_of(g)
    for r in (4, 5, 6, 17, 18, 19, 20):                          # 9.6pt 라 글자가 겹치던 표 행
        if r in rows:
            rows[r].set("ht", "15")
            rows[r].set("customHeight", "1")


def graph_single(pkg, t):
    """DBMS 2-1: 평균 오류 방지, 분포 '양호' 칸을 직접 계산."""
    g = pkg.sheet(GRAPH)
    t2 = t["last"] + 2
    rate = f"'{t['summ']}'!F{t2}:F{t2}"
    X.set_formula(g, "C5", f'IFERROR(AVERAGE({rate}),"")')
    X.set_formula(g, "D19", f'COUNTIFS({rate},">=0.7",{rate},"<0.85")')


def graph_web(pkg):
    """웹서버 2-1: 수량이 고정 숫자를 세던 문제, 없는 대상의 #N/A·0, 점수 소수 표시."""
    g = pkg.sheet(GRAPH)
    for ref, rng in (("D6", "X37:X42"), ("D7", "X46:X48"), ("D8", "X52:X54")):
        X.set_formula(g, ref, f'COUNTIF({rng},"?*")')
    for r, summ, last_col in ((37, "2-2. 요약 진단결과(IIS)", "F"), (46, "2-3. 요약 진단결과(Nginx)", "F"),
                              (52, "2-4. 요약 진단결과(Tomcat)", "G"), (53, "2-4. 요약 진단결과(Tomcat)", "G")):
        X.set_formula(g, f"X{r}", f"IFERROR(T(HLOOKUP($W{r},'{summ}'!$F$3:${last_col}$31,2,0)),\"\")")
        X.set_formula(g, f"Y{r}", f"IFERROR(HLOOKUP($W{r},'{summ}'!$F$3:${last_col}$33,31,0),\"\")")
    for col in ("B", "U"):                                        # 영역명 '4. 패치 및 로그 관리' 잘림
        X.restyle_range(pkg, g, [col], range(67, 71), shrinkToFit="1", wrapText="0")
    pct = X.get_cell(g, "Y37").get("s")
    for r, src in ((37, 37), (38, 46), (39, 52), (40, 53)):
        X.set_formula(g, f"AE{r}", f'IF(X{src}="","",X{src})')
        X.set_formula(g, f"AF{r}", f'IF(Y{src}="",NA(),Y{src})', style=pct)   # 없는 대상은 막대 없이(#N/A=빈칸)
    # 인쇄: 차트 구역별(요약·분포 / 대상별 막대 / IIS·Nginx·Tomcat 레이더)
    ws = g
    X.set_print_area(pkg, GRAPH, "$A$1:$U$64,$A$65:$T$85,$U$65:$AE$85,$AF$65:$AS$85")
    pg = X.ensure_child(ws, "pageSetup")
    for k in ("fitToWidth", "fitToHeight"):
        if k in pg.attrib:
            del pg.attrib[k]
    pg.set("paperSize", "9")
    pg.set("orientation", "landscape")
    pg.set("scale", "85")
    X.set_row_breaks(ws, [31, 64])


# ---------------- 공통 ----------------
def fit_detail_rows(pkg, t):
    """상세 행 높이를 진단항목·진단기준 글자에 맞춘다(채울 때 근거 길이로 다시 맞춤)."""
    ws = pkg.sheet(t["det"])
    w = X.col_widths(ws)
    rows = X.rows_of(ws)
    for r in range(t["first"], t["last"] + 1):
        if r in rows:
            pairs = [(X.cell_text(pkg, ws, f"{c}{r}"), w.get(X.col_idx(c), w["default"])) for c in "DE"]
            rows[r].set("ht", f"{server_report.estimate_height(pairs, min_ht=31.2):.2f}")
            rows[r].set("customHeight", "1")


def page_footer(pkg):
    """표지를 뺀 모든 시트에 '쪽 / 전체쪽' 바닥글."""
    wb = pkg.part("xl/workbook.xml")
    for name in [s.get("name") for s in wb.find(X.q("sheets"))][1:]:
        hf = X.ensure_child(pkg.sheet(name), "headerFooter")
        of = hf.find(X.q("oddFooter"))
        if of is None:
            of = X.etree.SubElement(hf, X.q("oddFooter"))
        of.text = "&C&P / &N"


def build(kind):
    cfg = TYPES[kind]
    src = os.path.join(OFFICIAL, cfg["src"])
    if not os.path.exists(src):
        sys.exit(f"[!] 공식 보고서가 없습니다: {src}")
    pkg = X.Pkg(src)
    blank(pkg, cfg)
    X.set_str(pkg.sheet(COVER), "B11", PROJECT_TITLE, style=X.get_cell(pkg.sheet(COVER), "B11").get("s"))
    for t in cfg["tables"]:
        repair_detail(pkg, t)
        repair_summary(pkg, t)
        style_tables(pkg, t)
    graph_common(pkg)
    if cfg["graph"] == "multi":
        t = cfg["tables"][0]
        area_rows, dom = {"linux": ([6, 19, 39, 69, 70], "K"), "windows": ([6, 20, 43, 45, 49], "I")}[kind]
        graph_multi(pkg, cfg, t, area_rows, dom)
    elif cfg["graph"] == "single":
        graph_single(pkg, cfg["tables"][0])
    else:
        graph_web(pkg)
    X.strip_external_links(pkg)
    if kind == "dbms":   # 일부 세부 진단항목(D-07~09, D-19)만 Calibri 11 → 맑은 고딕 10
        for name, src in (("3-1. 진단 결과(Oracle)", "E6"), ("2-2. 요약 진단결과(Oracle)", "D7")):
            ws = pkg.sheet(name)
            X.restyle_range(pkg, ws, ["D"], range(6, 32), font_from=X.get_cell(ws, src).get("s"))
    if kind == "dbms":   # 공식 3-1 제목이 '요약결과'로 잘못 들어가 있음
        X.set_str(pkg.sheet("3-1. 진단 결과(Oracle)"), "B2", "Oracle 취약점 진단 상세결과(26항목)",
                  style=X.get_cell(pkg.sheet("3-1. 진단 결과(Oracle)"), "B2").get("s"))

    first_rows = {}
    for t in cfg["tables"]:
        fit_detail_rows(pkg, t)
        # 요약: 리눅스·윈도우는 서버 열이 많아 가로 방향, 짧은 표(DBMS·웹 26행)는 한 쪽에(영역명 잘림 방지)
        X.set_page_fit_width(pkg.sheet(t["summ"]), orientation="landscape",
                             one_page=(t["last"] - t["first"] + 1) <= 35)
        X.set_print_titles(pkg, t["summ"], "$2:$5")
        groups = [(c, C(X.col_idx(c) + 1)) for c in vcols(t)]
        X.detail_page_setup(pkg, t["det"], groups, t["last"] + 2, first_row=t["first"])
        first_rows[t["summ"]] = first_rows[t["det"]] = t["first"]
    if cfg["graph"] == "multi":
        X.graph_page_setup(pkg, GRAPH, cfg["graph_breaks"], extra_cells_to=(24, 50))   # V35:X50 대상별 점수표
    elif cfg["graph"] == "single":
        X.graph_page_setup(pkg, GRAPH, cfg["graph_breaks"], extra_cells_to=(25, 42))   # W35:Y42
    X.cover_one_page(pkg, COVER)
    X.set_page_fit_width(pkg.sheet(TARGET))                      # 진단대상 표가 2장으로 갈리던 문제
    X.set_print_area(pkg, TARGET, f"$A$1:$G${max(cfg['targets'])}")
    page_footer(pkg)
    X.prune_cell_styles(pkg)                                     # 안 쓰는 셀 스타일(윈도우 공식 파일 4만여 개)
    X.reset_all_views(pkg)
    X.open_on_first_sheet(pkg, first_rows)
    pkg.clean()
    pkg.drop_calc_chain()
    out = os.path.join(OUT_DIR, cfg["out"])
    pkg.save(out)
    print(f"양식 저장: {cfg['out']}  (원본: {cfg['src']})")


def main():
    for k in (sys.argv[1:] or list(TYPES)):
        build(k)


if __name__ == "__main__":
    main()
