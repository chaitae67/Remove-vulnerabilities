#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""서버(Linux/Windows) 진단 결과 → 공식 결과보고서 양식(다중서버) 채우기.

양식 100% 보존: xlsx 를 zip 으로 열어 '입력 셀의 값'만 XML 에서 직접 교체한다.
차트/색상/서식/병합/수식은 원본 그대로 복사 → 엑셀에서 열면 2-2 요약·2-1 그래프가 자동 재계산.
채우는 곳: 0.표지(L3~L6,B18) / 1.진단대상(B5:F..) / 3-1.상세(서버별 판정 F/H/J/L + 근거 G/I/K/M).

의존성: lxml.  make_report.py(CLI)가 servers 리스트를 넘겨 호출한다.
"""
import datetime
import re
import sys
import zipfile
from collections import defaultdict

from lxml import etree

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
RNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
XMLNS = "http://www.w3.org/XML/1998/namespace"


def q(t):
    return f"{{{NS}}}{t}"


MANUAL_LABEL = "인터뷰 필요"
RESULT_ALIAS = {
    "양호": "양호", "GOOD": "양호", "PASS": "양호", "OK": "양호", "SAFE": "양호",
    "취약": "취약", "VULN": "취약", "VULNERABLE": "취약", "FAIL": "취약", "BAD": "취약",
    "N/A": "N/A", "NA": "N/A", "해당없음": "N/A", "해당 없음": "N/A", "": "N/A",
    # 서버 보고서는 양호/취약/N/A 3분류 → 수동확인/인터뷰는 N/A(판단 보류)
    "수동확인": "N/A", MANUAL_LABEL: "N/A", "MAN": "N/A", "NA/": "N/A",
}

SPECS = {
    "linux": {
        "cover": "0. 표지", "target": "1. 진단 대상", "detail": "3-1. 진단 결과(Linux)",
        "summary": "2-2. 요약 진단결과(Linux)",
        "label": "Linux", "id_col": "C", "detail_first": 6, "detail_last": 72,
        "result_cols": ["F", "H", "J", "L"], "evid_cols": ["G", "I", "K", "M"],
        "sum_cols": ["F", "G", "H", "I"], "servers": 4,
        "b1": "  ※ 진단 대상 리스트 - 서버 {n}대 (Linux {n}대)",
    },
    "windows": {
        "cover": "0. 표지", "target": "1. 진단 대상", "detail": "3-1. 진단 결과(window)",
        "summary": "2-2. 요약 진단결과(Window)",
        "label": "Windows", "id_col": "C", "detail_first": 6, "detail_last": 69,
        "result_cols": ["F", "H"], "evid_cols": ["G", "I"],
        "sum_cols": ["F", "G"], "servers": 2,
        "b1": "  ※ 진단 대상 리스트 - 서버 {n}대 (Windows {n}대)",
    },
    "dbms": {
        "cover": "0. 표지", "target": "1. 진단 대상", "detail": "3-1. 진단 결과(Oracle)",
        "summary": "2-2. 요약 진단결과(Oracle)",
        "label": "Oracle", "id_col": "C", "detail_first": 6, "detail_last": 31,
        "result_cols": ["F"], "evid_cols": ["G"], "sum_cols": ["F"], "servers": 1,
        "b1": "  ※ 진단 대상 리스트 - DBMS {n}대 (Oracle {n}대)",
    },
    # 클라우드: 단일 대상(계정/구독). CSP별 양식 파일이 다르지만 채우는 구조는 동일.
    "cloud": {
        "cover": "0. 표지", "target": "1. 진단 대상", "detail": "3-1. 진단 결과",
        "summary": "2-2. 요약 진단결과",
        "label": "Cloud", "id_col": "C", "detail_first": 6, "detail_last": 60,
        "result_cols": ["F"], "evid_cols": ["G"], "sum_cols": ["F"], "servers": 1,
        "b1": "  ※ 진단 대상 리스트 - 클라우드 {n}대",
        "cloud": True,   # 판정값을 서버 3분류로 축약하지 않음(인터뷰 필요 유지)
    },
    # 웹서버: 소프트웨어(IIS/Nginx/Tomcat)별 상세시트 + 진단대상 섹션이 나뉜 특수 구조
    "web": {
        "cover": "0. 표지", "target": "1. 진단 대상",
        "id_col": "C", "detail_first": 6, "detail_last": 31, "servers": 4,
        "software": {
            "iis":    {"detail": "3-1. 진단 결과(IIS)",   "cols": ["F"],      "evid": ["G"],      "rows": [5]},
            "nginx":  {"detail": "3-2. 진단 결과(Nginx)", "cols": ["F"],      "evid": ["G"],      "rows": [7]},
            "tomcat": {"detail": "3-3. 진단 결과(Tomcat)", "cols": ["F", "H"], "evid": ["G", "I"], "rows": [15, 16]},
        },
    },
}


def _detect_sw(sv):
    """서버 dict 에서 웹 소프트웨어 판별(iis/nginx/tomcat)."""
    s = f"{sv.get('osver','')} {sv.get('target','')} {sv.get('host','')}".lower()
    if "iis" in s:
        return "iis"
    if "nginx" in s:
        return "nginx"
    if "tomcat" in s or "was" in s or "spring" in s:
        return "tomcat"
    return None
TARGET_FIRST_ROW = 5
COVER = {"docno": "L3", "author": "L4", "grade": "L5", "ver": "L6", "date": "B18"}


def norm_result(v):
    k = (v or "").strip()
    k = k.upper() if k.isascii() else k
    return RESULT_ALIAS.get(k, RESULT_ALIAS.get((v or "").strip(), "N/A"))


def norm_cloud(v):
    """클라우드: 양호/취약/N/A/인터뷰 필요 4분류(수동확인→인터뷰 필요)."""
    s = (v or "").strip()
    if s in ("수동확인", "인터뷰 필요", "MAN"):
        return "인터뷰 필요"
    if s in ("N/A", "NA", ""):
        return "N/A"
    if s in ("취약", "VULN"):
        return "취약"
    if s in ("양호", "GOOD"):
        return "양호"
    return s or "N/A"


def _col_idx(letters):
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n


def _split_ref(ref):
    m = re.fullmatch(r"([A-Z]+)(\d+)", ref)
    return m.group(1), int(m.group(2))


class Book:
    """xlsx 를 zip 으로 열어 입력 셀 값만 교체(양식/차트/수식 100% 보존)."""

    def __init__(self, path):
        self.zin = zipfile.ZipFile(path)
        self.parts = {}
        self.drop = set()
        wb = self._root("xl/workbook.xml")
        rels = etree.fromstring(self.zin.read("xl/_rels/workbook.xml.rels"))
        rid2target = {r.get("Id"): r.get("Target") for r in rels}
        self.sheet_path = {}
        for s in wb.find(q("sheets")):
            t = rid2target[s.get(f"{{{RNS}}}id")]
            self.sheet_path[s.get("name")] = t.lstrip("/") if t.startswith("/") else "xl/" + t
        self.wb_root = wb
        self.shared = self._load_shared()

    def _root(self, name):
        if name not in self.parts:
            self.parts[name] = etree.fromstring(self.zin.read(name))
        return self.parts[name]

    def _load_shared(self):
        try:
            root = etree.fromstring(self.zin.read("xl/sharedStrings.xml"))
        except KeyError:
            return []
        return ["".join(t.text or "" for t in si.iter(q("t"))) for si in root.findall(q("si"))]

    def sheet(self, name):
        if name not in self.sheet_path:
            sys.exit(f"시트 '{name}' 를 찾을 수 없습니다. 시트명을 확인하세요. (있는 시트: {list(self.sheet_path)})")
        return self._root(self.sheet_path[name])

    def _cell(self, sheet, ref, create=True):
        col, row = _split_ref(ref)
        sd = sheet.find(q("sheetData"))
        rows = sd.findall(q("row"))
        row_el = next((r for r in rows if int(r.get("r")) == row), None)
        if row_el is None:
            if not create:
                return None
            row_el = etree.Element(q("row")); row_el.set("r", str(row))
            sd.insert(sum(1 for r in rows if int(r.get("r")) < row), row_el)
        cells = row_el.findall(q("c"))
        for c in cells:
            if c.get("r") == ref:
                return c
        if not create:
            return None
        c = etree.Element(q("c")); c.set("r", ref)
        row_el.insert(sum(1 for x in cells if _col_idx(_split_ref(x.get("r"))[0]) < _col_idx(col)), c)
        return c

    def get(self, sheet, ref):
        c = self._cell(sheet, ref, create=False)
        if c is None:
            return None
        t = c.get("t")
        if t == "inlineStr":
            return "".join(x.text or "" for x in c.iter(q("t")))
        v = c.find(q("v"))
        if v is None or v.text is None:
            return None
        return self.shared[int(v.text)] if t == "s" else v.text

    def put(self, sheet, ref, value):
        """값만 교체(셀 스타일 s 속성 보존). 수식 셀이면 중단."""
        c = self._cell(sheet, ref)
        if c.find(q("f")) is not None:
            sys.exit(f"{ref} 는 수식 셀입니다. 입력 좌표를 확인하세요.")
        for ch in list(c):
            c.remove(ch)
        if "t" in c.attrib:
            del c.attrib["t"]
        if isinstance(value, (int, float)):
            etree.SubElement(c, q("v")).text = str(value)
        else:
            c.set("t", "inlineStr")
            t = etree.SubElement(etree.SubElement(c, q("is")), q("t"))
            t.text = str(value)
            t.set(f"{{{XMLNS}}}space", "preserve")

    def put_formula(self, sheet, ref, formula):
        """셀을 수식 셀로 만든다(캐시값 없음 → 열 때 재계산). --fix-template 전용."""
        c = self._cell(sheet, ref)
        for ch in list(c):
            c.remove(ch)
        if "t" in c.attrib:
            del c.attrib["t"]
        etree.SubElement(c, q("f")).text = formula.lstrip("=")

    def strip_external_links(self):
        """외부 파일 링크(열 때 '업데이트' 창)를 제거한다. 부품·관계·콘텐츠타입 정리."""
        # 1) workbook.xml <externalReferences> 제거
        er = self.wb_root.find(q("externalReferences"))
        if er is not None:
            self.wb_root.remove(er)
        # 2) workbook rels 에서 externalLink 관계 제거
        try:
            rels = self._root("xl/_rels/workbook.xml.rels")
            for rel in list(rels):
                if "externalLink" in (rel.get("Type") or ""):
                    rels.remove(rel)
        except KeyError:
            pass
        # 3) [Content_Types].xml 에서 externalLink override 제거
        try:
            ct = self._root("[Content_Types].xml")
            for ov in list(ct):
                if "/xl/externalLinks/" in (ov.get("PartName") or ""):
                    ct.remove(ov)
        except KeyError:
            pass
        # 4) 실제 externalLinks/* 파트는 저장에서 제외
        for name in self.zin.namelist():
            if name.startswith("xl/externalLinks/"):
                self.drop.add(name)

    def save(self, out):
        cp = self.wb_root.find(q("calcPr"))
        if cp is None:
            cp = etree.SubElement(self.wb_root, q("calcPr"))
        cp.set("fullCalcOnLoad", "1")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in self.zin.infolist():
                if item.filename in self.drop:
                    continue    # 외부 링크 등 제거 대상
                if item.filename in self.parts:
                    data = etree.tostring(self.parts[item.filename], xml_declaration=True,
                                          encoding="UTF-8", standalone=True)
                else:
                    data = self.zin.read(item.filename)
                zout.writestr(item, data)


def _date_serial(d):
    return (datetime.datetime(d.year, d.month, d.day) - datetime.datetime(1899, 12, 30)).days


def _fix_template(bk, os_kind, n):
    """양식 자체 결함 보정(선택): 2-2 하드코딩 셀 → 수식 복원, 2-1 외부 링크 제거.
    원본 양식은 그대로 두고 --fix-template 을 줄 때만 호출한다."""
    spec = SPECS[os_kind]
    det, summ = spec["detail"], spec["summary"]
    if os_kind == "linux":
        last = spec["detail_last"]           # 72 (U-67)
        sw = bk.sheet(summ)
        for c in spec["sum_cols"]:           # F,G,H,I 의 마지막행 하드코딩 → HLOOKUP
            bk.put_formula(sw, f"{c}{last}",
                           f"HLOOKUP({c}$3,'{det}'!$F$3:$M$72,ROW(A{last-2}),FALSE)")
        gw = bk.sheet("2-1. 요약결과(그래프)")   # 외부 링크 걸린 수식들을 로컬로 복원
        sm = f"'{summ}'!$F$74:$I$74"
        tg = f"'{spec['target']}'!$B$5:$B${4 + n}"
        for ref, fx in (("C5", f"AVERAGE({sm})"), ("C6", f"AVERAGE({sm})"),
                        ("D5", "D6"), ("D6", f"COUNTA({tg})"), ("D17", f"COUNTA({tg})"),
                        ("D18", f'COUNTIF({sm},">=0.85")'), ("D19", "D17-(D18+D20)"),
                        ("D20", f'COUNTIF({sm},"<0.7")')):
            bk.put_formula(gw, ref, fx)
        for i, r in enumerate(range(72, 77)):
            src = [6, 19, 39, 69, 70][i]
            bk.put_formula(gw, f"B{r}", f"'{summ}'!B{src}")
            bk.put_formula(gw, f"C{r}", f"'{summ}'!K{src}")
            bk.put_formula(gw, f"D{r}", "$C$6")
        for r in range(36, 51):
            if r - 35 <= n:
                bk.put_formula(gw, f"W{r}", f"HLOOKUP($V{r},'{summ}'!$F$3:$I$53,2,0)")
                bk.put_formula(gw, f"X{r}", f"HLOOKUP($V{r},'{summ}'!$F$3:$I$74,72,0)")
    bk.strip_external_links()


def _fill_web(bk, spec, servers, meta):
    """웹서버: 소프트웨어별 진단대상 섹션 + 3-x 상세시트를 채운다(양식 100% 보존)."""
    # 0. 표지
    cov = bk.sheet(spec["cover"])
    for key, val in (("docno", meta.get("docno", "XXXXX-VA-2026XXX")),
                     ("author", meta.get("author", "취약점진단팀")),
                     ("grade", meta.get("grade", "Confidential")),
                     ("ver", meta.get("version", "ver 1.0"))):
        bk.put(cov, COVER[key], val)
    d = meta.get("date") or datetime.date.today()
    if isinstance(d, str):
        d = datetime.datetime.strptime(d, "%Y-%m-%d").date()
    bk.put(cov, COVER["date"], _date_serial(d))

    # 소프트웨어별 그룹
    groups = {"iis": [], "nginx": [], "tomcat": []}
    for sv in servers:
        sw = _detect_sw(sv)
        if sw:
            groups[sw].append(sv)

    tw = bk.sheet(spec["target"])
    first, last = spec["detail_first"], spec["detail_last"]
    for sw, sconf in spec["software"].items():
        svs = groups[sw]
        if not svs:
            continue
        # 진단 대상 섹션(해당 소프트웨어 행)
        for i, row in enumerate(sconf["rows"]):
            if i >= len(svs):
                break
            sv = svs[i]
            bk.put(tw, f"B{row}", i + 1)
            bk.put(tw, f"C{row}", (sv.get("host") or "").strip())
            bk.put(tw, f"D{row}", (sv.get("ip") or "-").strip())
            bk.put(tw, f"E{row}", (sv.get("osver") or "").strip())
            bk.put(tw, f"F{row}", (sv.get("role") or "-").strip())
        # 상세 시트
        dw = bk.sheet(sconf["detail"])
        row_of = {}
        for r in range(first, last + 1):
            v = bk.get(dw, f"{spec['id_col']}{r}")
            if v:
                row_of[v.strip().upper()] = r
        for i, sv in enumerate(svs[: len(sconf["cols"])]):
            rc, ec = sconf["cols"][i], sconf["evid"][i]
            by_code = {(x.get("code", "") or "").strip().upper(): x for x in sv.get("results", [])}
            for code, r in row_of.items():
                x = by_code.get(code)
                if x is None:
                    bk.put(dw, f"{rc}{r}", "N/A")
                    bk.put(dw, f"{ec}{r}", "점검 결과 없음")
                    continue
                bk.put(dw, f"{rc}{r}", norm_result(x.get("final") or x.get("status", "")))
                ev = " / ".join(x.get("evidence", []))
                note = (x.get("note") or "").strip()
                if note:
                    ev = f"{ev}  [검증자: {note}]" if ev else f"[검증자: {note}]"
                bk.put(dw, f"{ec}{r}", ev)


# ---------------- 진입점 ----------------
def fill_report(os_kind, servers, template_path, out_path, meta=None, fix_template=False):
    """서버 여러 대 결과를 계열 양식(다중서버)에 채워 저장(양식 100% 보존).

    os_kind : 'linux' | 'windows'
    servers : [{host, ip, osver, role, results:[{code,status,evidence,(final,note)}]}...]
    fix_template : True 면 양식 결함(2-2 F72 하드코딩·2-1 외부링크) 보정.
    """
    spec = SPECS[os_kind]
    meta = meta or {}

    if isinstance(servers, dict):
        servers = [servers]
    elif servers and isinstance(servers[0], dict) and "results" not in servers[0] and "code" in servers[0]:
        servers = [{"results": servers}]
    servers = [s for s in servers if s.get("results")][: spec.get("servers", 99)]
    if not servers:
        raise ValueError("진단 결과(servers)가 비어 있습니다.")

    bk = Book(template_path)

    # 웹서버는 소프트웨어별 특수 구조 → 전용 필러
    if spec.get("software"):
        _fill_web(bk, spec, servers, meta)
        bk.save(out_path)
        return out_path

    # 0. 표지 (날짜는 일련번호로 → 기존 표시형식 유지)
    cov = bk.sheet(spec["cover"])
    for key, val in (("docno", meta.get("docno", "XXXXX-VA-2026XXX")),
                     ("author", meta.get("author", "취약점진단팀")),
                     ("grade", meta.get("grade", "Confidential")),
                     ("ver", meta.get("version", "ver 1.0"))):
        bk.put(cov, COVER[key], val)
    d = meta.get("date") or datetime.date.today()
    if isinstance(d, str):
        d = datetime.datetime.strptime(d, "%Y-%m-%d").date()
    bk.put(cov, COVER["date"], _date_serial(d))

    # 1. 진단 대상
    tw = bk.sheet(spec["target"])
    for i, sv in enumerate(servers):
        r = TARGET_FIRST_ROW + i
        bk.put(tw, f"B{r}", i + 1)
        bk.put(tw, f"C{r}", (sv.get("host") or "").strip())
        bk.put(tw, f"D{r}", (sv.get("ip") or "-").strip())
        bk.put(tw, f"E{r}", (sv.get("osver") or "").strip())
        bk.put(tw, f"F{r}", (sv.get("role") or "-").strip())
    b1 = spec.get("b1", "  ※ 진단 대상 리스트 - 서버 {n}대 (" + spec["label"] + " {n}대)")
    bk.put(tw, "B1", b1.format(n=len(servers)))

    # 3-1. 진단 결과 (서버별 판정 + 근거)
    dw = bk.sheet(spec["detail"])
    first, last = spec["detail_first"], spec["detail_last"]
    row_of = {}
    for r in range(first, last + 1):
        v = bk.get(dw, f"{spec['id_col']}{r}")
        if v:
            row_of[v.strip().upper()] = r
    nf = norm_cloud if spec.get("cloud") else norm_result
    for idx, sv in enumerate(servers):
        rc, ec = spec["result_cols"][idx], spec["evid_cols"][idx]
        by_code = {(x.get("code", "") or "").strip().upper(): x for x in sv.get("results", [])}
        for code, r in row_of.items():
            x = by_code.get(code)
            if x is None:
                bk.put(dw, f"{rc}{r}", "N/A")
                bk.put(dw, f"{ec}{r}", "점검 결과 없음")
                continue
            bk.put(dw, f"{rc}{r}", nf(x.get("final") or x.get("status", "")))
            ev = " / ".join(x.get("evidence", []))
            note = (x.get("note") or "").strip()
            if note:
                ev = f"{ev}  [검증자: {note}]" if ev else f"[검증자: {note}]"
            bk.put(dw, f"{ec}{r}", ev)

    if fix_template:
        _fix_template(bk, os_kind, len(servers))

    bk.save(out_path)
    return out_path
