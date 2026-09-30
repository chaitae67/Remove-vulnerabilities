#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""진단 결과(JSON) → 공식 결과보고서 양식(xlsx) 채우기. 리눅스/윈도우/DBMS/웹서버/클라우드 공통.

양식 보존: xlsx 를 zip 으로 열어 '입력 셀의 값'만 XML 에서 교체한다.
차트/색상/서식/병합/수식은 양식 그대로 → 엑셀에서 열면 2-2 요약·2-1 그래프가 자동 재계산.
채우는 곳: 0.표지(문서정보·날짜) / 1.진단대상(대상 목록) / 3-x.상세(대상별 판정 + 근거).
양식 자체의 결함 수리는 build_server_templates.py / build_cloud_templates.py 가 한다.

의존성: lxml.  make_report.py(CLI)·cloud_scan.py 가 servers 리스트를 넘겨 호출한다.
"""
import copy
import datetime
import re
import sys
import unicodedata
import zipfile

from lxml import etree

# 항목코드 패턴: 1.1 / AC-01 / D-01 / WEB-01 / U-01  (결과행 '취약항목 개수' 등 제외)
_CODE_RE = re.compile(r"^[A-Za-z]{0,5}-?\d+(\.\d+)?$")

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
RNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
XMLNS = "http://www.w3.org/XML/1998/namespace"


def q(t):
    return f"{{{NS}}}{t}"


# ---------------- 판정값 ----------------
MANUAL_LABEL = "인터뷰 필요"
_GOOD = {"GOOD", "PASS", "PASSED", "OK", "SAFE", "SECURE"}
_VULN = {"VULN", "VULNERABLE", "FAIL", "FAILED", "BAD", "WEAK"}
_NA = {"N/A", "NA", "NOT APPLICABLE", "NONE", "-"}
_MANUAL = {"MAN", "MANUAL", "CHECK", "REVIEW", "INFO", "UNKNOWN"}


def normalize_status(v):
    """판정 4분류: 양호 / 취약 / N/A / 인터뷰 필요 (모든 보고서 공통).
    수동확인·인터뷰는 N/A(해당 없음)와 다르다 — 주황색으로 표시하고 점수에서는 제외한다."""
    s = str(v if v is not None else "").strip()
    u = s.upper()
    if not s or u in _NA or s.replace(" ", "") in ("해당없음", "미해당"):
        return "N/A"
    if "취약" in s or u in _VULN:
        return "취약"
    if "양호" in s or u in _GOOD:
        return "양호"
    if s.replace(" ", "") in ("수동확인", "인터뷰필요", "인터뷰", "확인필요", "담당자확인") or u in _MANUAL:
        return MANUAL_LABEL
    sys.stderr.write(f"[!] 알 수 없는 판정값 '{s}' → '{MANUAL_LABEL}'(으)로 표시\n")
    return MANUAL_LABEL


# 예전 이름(다른 모듈 호환)
norm_result = normalize_status
norm_cloud = normalize_status


_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_CTRL = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿\ud800-\udfff]")
CELL_MAX = 32000     # 엑셀 셀 최대 32,767자


def clean_text(v):
    """셀에 넣을 문자열: 터미널 색상코드·제어문자 제거(있으면 xlsx 저장 실패), 길이 제한."""
    if v is None:
        return ""
    s = _CTRL.sub("", _ANSI.sub("", str(v)))
    return s if len(s) <= CELL_MAX else s[:CELL_MAX] + " …(이하 생략)"


def evidence_text(x, cloud=False):
    """근거: 항목별 문장을 줄바꿈으로(공식 보고서처럼 한 줄에 하나), 검증 의견·대상 리소스는 별도 줄."""
    ev = x.get("evidence") or []
    if isinstance(ev, str):
        ev = [ev]
    lines = [clean_text(e).strip() for e in ev if e is not None and str(e).strip()]
    note = clean_text(x.get("note") or "").strip()
    if note:
        lines.append(f"[검증 의견] {note}")
    res = [clean_text(r) for r in (x.get("resources") or []) if r]
    if cloud and res:
        more = f" 외 {len(res) - 20}건" if len(res) > 20 else ""
        lines.append("[대상 리소스] " + ", ".join(res[:20]) + more)
    return "\n".join(lines)


# ---------------- 양식별 채우기 좌표 ----------------
SPECS = {
    "linux": {
        "detail": "3-1. 진단 결과(Linux)", "summary": "2-2. 요약 진단결과(Linux)",
        "detail_first": 6, "detail_last": 72,
        "result_cols": ["F", "H", "J", "L"], "evid_cols": ["G", "I", "K", "M"],
        "sum_cols": ["F", "G", "H", "I"], "servers": 4,
        "b1": "  ※ 진단 대상 리스트 - 서버 {n}대 (Linux {n}대)",
    },
    "windows": {
        "detail": "3-1. 진단 결과(window)", "summary": "2-2. 요약 진단결과(Window)",
        "detail_first": 6, "detail_last": 69,
        "result_cols": ["F", "H"], "evid_cols": ["G", "I"], "sum_cols": ["F", "G"], "servers": 2,
        "b1": "※ 진단 대상 리스트 - 서버 {n}대 (Windows {n}대)",      # 공식 윈도우 양식은 앞 공백 없음
    },
    "dbms": {
        "detail": "3-1. 진단 결과(Oracle)", "summary": "2-2. 요약 진단결과(Oracle)",
        "detail_first": 6, "detail_last": 31,
        "result_cols": ["F"], "evid_cols": ["G"], "sum_cols": ["F"], "servers": 1,
        "b1": "  ※ 진단 대상 리스트 - DBMS {n}대 (Oracle {n}대)",
    },
    # 클라우드: 계정(구독/프로젝트) 1개. 시트 이름은 '3-1. 진단 결과(AWS)' 처럼 CSP 가 붙는다(접두어로 찾음)
    "cloud": {
        "detail": "3-1. 진단 결과", "summary": "2-2. 요약 진단결과",
        "detail_first": 6, "detail_last": 200,
        "result_cols": ["F"], "evid_cols": ["G"], "sum_cols": ["F"], "servers": 1,
        "b1": "  ※ 진단 대상 리스트 - 클라우드 계정 {n}개 ({label} {n}개)",
        "cloud": True,
    },
    # 웹서버: 소프트웨어(IIS/Nginx/Tomcat)별 요약·상세 시트와 진단대상 칸이 나뉜 구조
    "web": {
        "detail_first": 6, "detail_last": 31,
        "software": {
            "iis": {"label": "IIS", "detail": "3-1. 진단 결과(IIS)", "summary": "2-2. 요약 진단결과(IIS)",
                    "cols": ["F"], "evid": ["G"], "sum_cols": ["F"], "rows": [5], "radar": "$A$65:$T$85"},
            "nginx": {"label": "Nginx", "detail": "3-2. 진단 결과(Nginx)", "summary": "2-3. 요약 진단결과(Nginx)",
                      "cols": ["F"], "evid": ["G"], "sum_cols": ["F"], "rows": [7], "radar": "$U$65:$AE$85"},
            "tomcat": {"label": "Tomcat", "detail": "3-3. 진단 결과(Tomcat)",
                       "summary": "2-4. 요약 진단결과(Tomcat)",
                       "cols": ["F", "H"], "evid": ["G", "I"], "sum_cols": ["F", "G"], "rows": [15, 16],
                       "radar": "$AF$65:$AS$85"},
        },
        "graph_area": "$A$1:$U$64",       # 2-1 요약·분포·대상별 막대(레이더는 소프트웨어별 영역)
    },
}
TARGET_SHEET, COVER_SHEET = "1. 진단 대상", "0. 표지"
TARGET_FIRST_ROW = 5
COVER = {"title": "B11", "docno": "L3", "author": "L4", "grade": "L5", "ver": "L6", "date": "B18"}


def detect_software(sv):
    """웹 소프트웨어 판별(iis/nginx/tomcat). 명시값(sw) → 대상 표기 '(iis)' → 버전 문자열 → 호스트명 순."""
    hint = (sv.get("sw") or "").lower()
    tgt = str(sv.get("target") or "")
    m = re.search(r"\((iis|nginx|tomcat)\)", tgt, re.I)
    if hint in ("iis", "nginx", "tomcat"):
        if m and m.group(1).lower() != hint:     # 명령에서 지정한 종류와 스캔 결과가 다르면 알린다
            sys.stderr.write(f"[!] {sv.get('host') or '?'}: 지정한 종류 '{hint}' 와 스캔 결과 "
                             f"'{m.group(1).lower()}' 가 다릅니다 — 지정한 '{hint}' 시트에 채웁니다.\n")
        return hint
    if m:
        return m.group(1).lower()
    text = f"{sv.get('osver', '')} {tgt}".lower()
    for key, sw in (("nginx", "nginx"), ("tomcat", "tomcat"), ("spring", "tomcat"), ("iis", "iis")):
        if key in text:
            return sw
    host = str(sv.get("host") or "").lower()
    if re.search(r"\b(was|tomcat)\b", host):
        return "tomcat"
    if re.search(r"\bnginx\b", host):
        return "nginx"
    if re.search(r"\biis\b", host):
        return "iis"
    return None


_detect_sw = detect_software   # 예전 이름


# ---------------- 행 높이 ----------------
def _text_units(s):
    """열 너비 단위(숫자 '0' 한 글자 폭) 기준 문자열 폭. 한글·전각 1.9, 영문 대문자 1.1, 소문자 0.95, 공백 0.7.
    공백 없는 한 단어(IP·버전 번호)는 구두점을 좁게 친다 — 문장은 줄바꿈 손실이 있어 그대로 둔다."""
    narrow = ".,:;|!'" if " " not in s.strip() else ""
    u = 0.0
    for ch in s:
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            u += 1.9
        elif ch in narrow:                      # 13.124.134.131 이 두 줄 높이로 잡히던 문제
            u += 0.55
        elif ch.isupper():
            u += 1.1
        elif ch.islower():
            u += 0.95
        elif ch == " ":
            u += 0.7
        else:
            u += 1.0
    return u


def estimate_height(pairs, pt=10, min_ht=31.65, max_ht=409.0):
    """셀 내용이 잘리지 않을 행 높이(pt). pairs: [(텍스트, 열너비)] — 자동 줄바꿈 셀 기준.
    실제 엑셀 AutoFit(10pt 한 줄 15.6pt)으로 보정 — 리눅스·웹·DBMS·클라우드 3-x 227행에서 과소 추정 0건."""
    lines = 1
    for text, width in pairs:
        if not text or not width:
            continue
        per_line = max(1.0, (float(width) - 1.0) * 11.0 / pt * 0.9)    # 단어 단위 줄바꿈 여유 10%
        n = 0
        for para in str(text).split("\n"):
            n += max(1, -(-_text_units(para) // per_line))
        lines = max(lines, int(n))
    return max(min_ht, min(max_ht, lines * 15.6 * pt / 10.0 + 1.5))


def _col_idx(letters):
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n


def _split_ref(ref):
    m = re.fullmatch(r"([A-Z]+)(\d+)", ref)
    return m.group(1), int(m.group(2))


class Book:
    """xlsx 를 zip 으로 열어 입력 셀 값만 교체(양식/차트/수식 보존)."""

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

    def resolve(self, name):
        """시트 이름 확인. 정확히 없으면 그 이름으로 시작하는 시트가 하나뿐일 때 그것을 쓴다
        (클라우드 양식: '3-1. 진단 결과' → '3-1. 진단 결과(AWS)')."""
        if name in self.sheet_path:
            return name
        cand = [s for s in self.sheet_path if s.startswith(name)]
        if len(cand) == 1:
            return cand[0]
        raise ValueError(f"시트 '{name}' 없음(있는 시트: {list(self.sheet_path)})")

    def sheet(self, name):
        return self._root(self.sheet_path[self.resolve(name)])

    def row(self, sheet, row, create=True):
        sd = sheet.find(q("sheetData"))
        rows = sd.findall(q("row"))
        row_el = next((r for r in rows if int(r.get("r")) == row), None)
        if row_el is None and create:
            row_el = etree.Element(q("row"))
            row_el.set("r", str(row))
            sd.insert(sum(1 for r in rows if int(r.get("r")) < row), row_el)
        return row_el

    def _cell(self, sheet, ref, create=True):
        col, row = _split_ref(ref)
        row_el = self.row(sheet, row, create)
        if row_el is None:
            return None
        cells = row_el.findall(q("c"))
        for c in cells:
            if c.get("r") == ref:
                return c
        if not create:
            return None
        c = etree.Element(q("c"))
        c.set("r", ref)
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
        """값만 교체(셀 스타일 s 속성 보존). 수식 셀이면 오류(양식 좌표 확인)."""
        c = self._cell(sheet, ref)
        if c.find(q("f")) is not None:
            raise ValueError(f"{ref} 는 수식 셀입니다. 입력 좌표를 확인하세요.")
        for ch in list(c):
            c.remove(ch)
        if "t" in c.attrib:
            del c.attrib["t"]
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            etree.SubElement(c, q("v")).text = str(value)
            return
        text = clean_text(value)
        if not text:
            return
        c.set("t", "inlineStr")
        t = etree.SubElement(etree.SubElement(c, q("is")), q("t"))
        t.text = text
        t.set(f"{{{XMLNS}}}space", "preserve")

    def put_formula(self, sheet, ref, formula):
        """셀을 수식 셀로 만든다(캐시값 없음 → 열 때 재계산)."""
        c = self._cell(sheet, ref)
        for ch in list(c):
            c.remove(ch)
        if "t" in c.attrib:
            del c.attrib["t"]
        etree.SubElement(c, q("f")).text = formula.lstrip("=")

    def _widths(self, sheet):
        fmt = sheet.find(q("sheetFormatPr"))
        dflt = float(fmt.get("defaultColWidth") or 8.43) if fmt is not None else 8.43
        widths = {}
        cols_el = sheet.find(q("cols"))
        for c in cols_el if cols_el is not None else []:
            for i in range(int(c.get("min")), int(c.get("max")) + 1):
                widths[i] = float(c.get("width", dflt))
        return widths, dflt

    def fit_rows(self, sheet, rows, cols, min_ht=31.2):
        """행 높이를 내용에 맞춘다(긴 근거가 잘리지 않게, 스크린샷용 빈 높이 없이)."""
        widths, dflt = self._widths(sheet)
        for r in rows:
            pairs = [(self.get(sheet, f"{c}{r}"), widths.get(_col_idx(c), dflt)) for c in cols]
            row_el = self.row(sheet, r)
            row_el.set("ht", f"{estimate_height(pairs, min_ht=min_ht):.2f}")
            row_el.set("customHeight", "1")

    def hide_cols(self, sheet, letters):
        """열 숨기기(<cols> 범위를 쪼개 해당 열만 hidden). 양식 칸보다 대상이 적을 때 빈 칸 감춤."""
        cols = sheet.find(q("cols"))
        if cols is None:
            cols = etree.Element(q("cols"))
            sheet.find(q("sheetData")).addprevious(cols)
        for letter in letters:
            ci = _col_idx(letter)
            hit = None
            for c in list(cols):
                lo, hi = int(c.get("min")), int(c.get("max"))
                if lo <= ci <= hi:
                    parts = []
                    if lo < ci:
                        a = copy.deepcopy(c)
                        a.set("max", str(ci - 1))
                        parts.append(a)
                    hit = copy.deepcopy(c)
                    hit.set("min", str(ci))
                    hit.set("max", str(ci))
                    parts.append(hit)
                    if ci < hi:
                        b = copy.deepcopy(c)
                        b.set("min", str(ci + 1))
                        parts.append(b)
                    for p in parts:
                        c.addprevious(p)
                    cols.remove(c)
                    break
            if hit is None:
                hit = etree.Element(q("col"))
                hit.set("min", str(ci))
                hit.set("max", str(ci))
                hit.set("width", "8.43")
                after = [c for c in cols if int(c.get("max")) < ci]
                (after[-1].addnext(hit) if after else cols.insert(0, hit))
            hit.set("hidden", "1")

    def set_print_area(self, sheet_name, areas):
        """인쇄 영역 교체(areas: ['$A$1:$U$64', ...]). 해당 정의가 이미 있을 때만."""
        real = self.resolve(sheet_name)
        names = [s.get("name") for s in self.wb_root.find(q("sheets"))]
        dn = self.wb_root.find(q("definedNames"))
        for d in dn if dn is not None else []:
            if d.get("name") == "_xlnm.Print_Area" and d.get("localSheetId") == str(names.index(real)):
                d.text = ",".join(f"'{real}'!{a}" for a in areas)

    def align(self, sheet, ref, **attrs):
        """셀 스타일을 복제해 정렬 속성만 바꾼다(같은 조합은 재사용)."""
        c = self._cell(sheet, ref)
        s = int(c.get("s", "0"))
        key = (s, tuple(sorted(attrs.items())))
        cache = self.__dict__.setdefault("_align_cache", {})
        if key not in cache:
            xfs = self._root("xl/styles.xml").find(q("cellXfs"))
            xf = copy.deepcopy(xfs[s])
            al = xf.find(q("alignment"))
            if al is None:
                al = etree.Element(q("alignment"))
                xf.insert(0, al)
            for k, v in attrs.items():
                al.set(k, v)
            xf.set("applyAlignment", "1")
            xfs.append(xf)
            xfs.set("count", str(len(xfs)))
            cache[key] = len(xfs) - 1
        c.set("s", str(cache[key]))

    def top_align_tall_merges(self, sheet, first, max_pt=400):
        """세로로 긴 병합칸(영역명·영역별점수)이 여러 쪽에 걸치면 엑셀은 전체 높이의 가운데 쪽에만
        글자를 찍어 나머지 쪽은 빈칸이 된다 → 위쪽 정렬로 영역이 시작하는 쪽에 찍히게."""
        mc = sheet.find(q("mergeCells"))
        if mc is None:
            return
        fmt = sheet.find(q("sheetFormatPr"))
        dflt = float(fmt.get("defaultRowHeight", "15")) if fmt is not None else 15.0
        hts = {int(r.get("r")): float(r.get("ht") or dflt) for r in sheet.find(q("sheetData"))}
        for m in mc:
            a, b = m.get("ref").split(":")
            (c1, r1), (c2, r2) = _split_ref(a), _split_ref(b)
            if c1 == c2 and r1 >= first and r2 > r1 and sum(hts.get(r, dflt) for r in range(r1, r2 + 1)) > max_pt:
                self.align(sheet, a, vertical="top")

    def hide_sheet(self, name):
        """시트 숨기기(진단하지 않은 웹 소프트웨어의 2-x/3-x 시트)."""
        real = self.resolve(name)
        for s in self.wb_root.find(q("sheets")):
            if s.get("name") == real:
                s.set("state", "hidden")

    def strip_external_links(self):
        """외부 파일 링크(열 때 '업데이트' 창)를 제거한다. 부품·관계·콘텐츠타입 정리."""
        er = self.wb_root.find(q("externalReferences"))
        if er is not None:
            self.wb_root.remove(er)
        try:
            rels = self._root("xl/_rels/workbook.xml.rels")
            for rel in list(rels):
                if "externalLink" in (rel.get("Type") or ""):
                    rels.remove(rel)
        except KeyError:
            pass
        try:
            ct = self._root("[Content_Types].xml")
            for ov in list(ct):
                if "/xl/externalLinks/" in (ov.get("PartName") or ""):
                    ct.remove(ov)
        except KeyError:
            pass
        for name in self.zin.namelist():
            if name.startswith("xl/externalLinks/"):
                self.drop.add(name)

    def set_properties(self, author):
        """문서 속성: 작성자/수정자 = 진단팀, 작성·수정 시각 = 지금."""
        try:
            core = self._root("docProps/core.xml")
        except KeyError:
            return
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        for e in core:
            tag = e.tag.rsplit("}", 1)[-1]
            if tag in ("creator", "lastModifiedBy"):
                e.text = author
            elif tag in ("created", "modified"):
                e.text = now

    def save(self, out):
        cp = self.wb_root.find(q("calcPr"))
        if cp is None:
            cp = etree.Element(q("calcPr"))
            ext = self.wb_root.find(q("extLst"))
            (ext.addprevious(cp) if ext is not None else self.wb_root.append(cp))
        cp.set("fullCalcOnLoad", "1")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in self.zin.infolist():
                if item.filename in self.drop:
                    continue
                if item.filename in self.parts:
                    data = etree.tostring(self.parts[item.filename], xml_declaration=True,
                                          encoding="UTF-8", standalone=True)
                else:
                    data = self.zin.read(item.filename)
                zout.writestr(item, data)


def _date_serial(d):
    return (datetime.datetime(d.year, d.month, d.day) - datetime.datetime(1899, 12, 30)).days


# ---------------- 공통 채우기 ----------------
def _fill_cover(bk, meta):
    cov = bk.sheet(COVER_SHEET)
    for key, val in (("docno", meta.get("docno") or f"XXXXX-VA-{datetime.date.today():%Y}XXX"),
                     ("author", meta.get("author") or "취약점진단팀"),
                     ("grade", meta.get("grade") or "Confidential"),
                     ("ver", meta.get("version") or "ver 1.0")):
        bk.put(cov, COVER[key], val)
    if meta.get("project"):
        bk.put(cov, COVER["title"], f'"{meta["project"]}" 취약점 진단')
    d = meta.get("date") or datetime.date.today()
    if isinstance(d, str):
        d = datetime.datetime.strptime(d, "%Y-%m-%d").date()
    bk.put(cov, COVER["date"], _date_serial(d))


def _cloud_target(sv, label):
    """클라우드 진단대상 칸: (계정 ID, 리전, 구분). 스캐너가 준 값(account/region/kind) 우선,
    없으면 'AWS 계정 123 (리전: ap-northeast-2)' 같은 옛 host 문자열에서 뽑는다."""
    host = str(sv.get("host") or "")
    osver = str(sv.get("osver") or "")
    region = sv.get("region")
    if not region:
        m = re.search(r"리전\s*:\s*([^)]+)\)", f"{host} {osver}")
        region = m.group(1).strip() if m else "-"
    account = sv.get("account")
    if not account:
        h = re.sub(r"\s*\(리전[^)]*\)", "", host).strip()
        m = re.search(r"\(([^()]+)\)\s*$", h)            # 'Azure 구독 이름 (uuid)' → uuid
        if m and "," not in m.group(1):
            account = m.group(1).strip()
        else:
            last = h.split()[-1] if h.split() else ""
            # 'NCP 계정'처럼 식별자가 없으면 '계정'을 ID 로 쓰지 않는다
            account = last if last and re.search(r"[0-9\-_.@]", last) else "-"
    kind = sv.get("kind")
    if not kind:
        kind = next((f"{label} {w}" for w in ("구독", "프로젝트") if w in host), f"{label} 계정")
    return account, region, kind


def _fill_targets(bk, os_kind, servers, spec):
    tw = bk.sheet(TARGET_SHEET)
    rows = []
    label = (bk.get(tw, "B4") or "").strip() or "Cloud"
    for i, sv in enumerate(servers):
        r = TARGET_FIRST_ROW + i
        rows.append(r)
        bk.put(tw, f"B{r}", i + 1)
        if spec.get("cloud"):
            account, region, kind = _cloud_target(sv, label)
            vals = (account, region, kind, sv.get("role") or "클라우드 계정")
        else:
            vals = ((sv.get("host") or "").strip(), (sv.get("ip") or "-").strip(),
                    (sv.get("osver") or "").strip(), (sv.get("role") or "-").strip())
        for col, v in zip("CDEF", vals):
            bk.put(tw, f"{col}{r}", v)
    b1 = spec["b1"].format(n=len(servers), label=label)
    bk.put(tw, "B1", b1)
    bk.fit_rows(tw, rows, list("CDEF"), min_ht=16.5)


def _code_rows(bk, dw, first, last):
    row_of = {}
    for r in range(first, last + 1):
        v = bk.get(dw, f"C{r}")
        if v and _CODE_RE.match(v.strip()):
            row_of[v.strip().upper()] = r
        elif v and ("취약항목" in v or "점검결과" in v):
            break
    return row_of


def _fill_detail(bk, dw, row_of, rc, ec, results, cloud=False):
    by_code = {(x.get("code", "") or "").strip().upper(): x for x in results}
    if by_code and row_of and not (set(by_code) & set(row_of)):
        raise ValueError(f"항목코드가 양식과 하나도 맞지 않습니다(양식 {sorted(row_of)[:3]}… / 결과 "
                         f"{sorted(by_code)[:3]}…). 보고서 종류(linux/windows/…)를 확인하세요.")
    missing = [c for c in by_code if c not in row_of]
    no_result = []
    for code, r in row_of.items():
        x = by_code.get(code)
        if x is None:     # 스캔 결과에 없는 항목 — N/A(해당 없음)로 두면 점수에서 조용히 빠지므로 확인 필요로 표시
            no_result.append(code)
            bk.put(dw, f"{rc}{r}", MANUAL_LABEL)
            bk.put(dw, f"{ec}{r}", "점검 결과 없음(스캔 결과에 이 항목이 없음) — 재점검 또는 담당자 확인 필요")
            continue
        bk.put(dw, f"{rc}{r}", normalize_status(x.get("final") or x.get("status", "")))
        bk.put(dw, f"{ec}{r}", evidence_text(x, cloud))
    if no_result:
        more = " …" if len(no_result) > 10 else ""
        sys.stderr.write(f"[!] 스캔 결과에 없는 항목 {len(no_result)}개 → '{MANUAL_LABEL}'로 표시: "
                         f"{', '.join(no_result[:10])}{more}\n")
    if missing:
        sys.stderr.write(f"[!] 양식에 없는 항목코드 {len(missing)}개는 보고서에서 빠짐: {', '.join(missing[:10])}\n")


def _hide_unused_slots(bk, spec_sheets, n, first=6):
    """대상 칸이 남으면(리눅스 4칸에 2대 등) 그 칸의 열을 숨긴다. 수식은 양식에서 빈칸 처리됨."""
    det, summ, rcols, ecols, scols = spec_sheets
    if n >= len(rcols):
        return
    dws = bk.sheet(det)
    bk.hide_cols(dws, [c for pair in zip(rcols[n:], ecols[n:]) for c in pair])
    bk.hide_cols(bk.sheet(summ), scols[n:])
    # 인쇄: 쓰는 칸까지만(숨긴 칸 때문에 빈 페이지가 나오지 않게)
    last_used = _col_idx(ecols[n - 1])
    cb = dws.find(q("colBreaks"))
    if cb is not None:
        for b in list(cb):
            if int(b.get("id")) >= last_used:
                cb.remove(b)
        if len(cb):
            cb.set("count", str(len(cb)))
            cb.set("manualBreakCount", str(len(cb)))
        else:
            dws.remove(cb)
    real = bk.resolve(det)
    names = [s.get("name") for s in bk.wb_root.find(q("sheets"))]
    dn = bk.wb_root.find(q("definedNames"))
    for d in dn if dn is not None else []:
        if d.get("localSheetId") != str(names.index(real)):
            continue
        if d.get("name") == "_xlnm.Print_Area":
            d.text = re.sub(r"(:\$)[A-Z]+(\$\d+)$", lambda m: f"{m.group(1)}{ecols[n - 1]}{m.group(2)}", d.text)
            if n == 1:        # 대상 1개: 진단항목~근거(B~G)를 한 장 폭에
                d.text = re.sub(r"!\$[A-Z]+\$\d+:", f"!$B${first}:", d.text)
        elif d.get("name") == "_xlnm.Print_Titles" and n == 1:
            d.text = f"'{real}'!$2:$5"
    if n == 1:            # 다중 서버용 고정 배율·반복 열 대신 가로 한 장 맞춤
        pg = dws.find(q("pageSetup"))
        if pg is not None:
            if "scale" in pg.attrib:
                del pg.attrib["scale"]
            pg.set("fitToWidth", "1")
            pg.set("fitToHeight", "0")
        sp = dws.find(q("sheetPr"))
        if sp is None:
            sp = etree.Element(q("sheetPr"))
            dws.insert(0, sp)
        ps = sp.find(q("pageSetUpPr"))
        if ps is None:
            ps = etree.SubElement(sp, q("pageSetUpPr"))
        ps.set("fitToPage", "1")


def _warn_dropped(kind, dropped, cap):
    if dropped:
        sys.stderr.write(f"[!] {kind} 양식은 최대 {cap}대 — 빠진 대상: {', '.join(dropped)}\n")


def _fill_web(bk, spec, servers, meta):
    """웹서버: 소프트웨어별 진단대상 칸 + 2-x/3-x 시트. 진단 안 한 소프트웨어 시트는 숨긴다."""
    groups = {"iis": [], "nginx": [], "tomcat": []}
    unknown = []
    for sv in servers:
        sw = detect_software(sv)
        (groups[sw] if sw else unknown).append(sv)
    if unknown:
        sys.stderr.write("[!] 웹 소프트웨어(IIS/Nginx/Tomcat)를 판별 못해 제외: "
                         + ", ".join(str(s.get("host") or "?") for s in unknown) + "\n")
    if not any(groups.values()):
        raise ValueError("웹 소프트웨어를 판별할 수 없습니다 — 보고서 종류를 iis/nginx/tomcat 로 지정하세요 "
                         "(예: make_report.py nginx --result web.json).")

    tw = bk.sheet(TARGET_SHEET)
    first, last = spec["detail_first"], spec["detail_last"]
    for sw, sc in spec["software"].items():
        svs = groups[sw][: len(sc["rows"])]
        _warn_dropped(sc["label"], [str(s.get("host")) for s in groups[sw][len(sc["rows"]):]], len(sc["rows"]))
        if not svs:
            bk.hide_sheet(sc["detail"])
            bk.hide_sheet(sc["summary"])
            continue
        for i, row in enumerate(sc["rows"][: len(svs)]):
            sv = svs[i]
            bk.put(tw, f"B{row}", i + 1)
            for col, v in zip("CDEF", ((sv.get("host") or "").strip(), (sv.get("ip") or "-").strip(),
                                       (sv.get("osver") or "").strip(), (sv.get("role") or "-").strip())):
                bk.put(tw, f"{col}{row}", v)
        bk.fit_rows(tw, sc["rows"][: len(svs)], list("CDEF"), min_ht=16.5)
        dw = bk.sheet(sc["detail"])
        row_of = _code_rows(bk, dw, first, last)
        for i, sv in enumerate(svs):
            _fill_detail(bk, dw, row_of, sc["cols"][i], sc["evid"][i], sv.get("results", []))
        bk.fit_rows(dw, sorted(row_of.values()), ["D", "E"] + sc["evid"][: len(svs)])
        _hide_unused_slots(bk, (sc["detail"], sc["summary"], sc["cols"], sc["evid"], sc["sum_cols"]), len(svs),
                           first)
        for name in (sc["detail"], sc["summary"]):
            bk.top_align_tall_merges(bk.sheet(name), first)

    # 2-1 인쇄: 진단한 소프트웨어의 레이더만
    bk.set_print_area("2-1. 요약결과(그래프)", [spec["graph_area"]] + [sc["radar"] for k, sc in
                                                               spec["software"].items() if groups[k]])
    ni, nn, nt = (min(len(groups[k]), len(spec["software"][k]["rows"])) for k in ("iis", "nginx", "tomcat"))
    parts = [p for p in (f"IIS {ni}대" if ni else "", f"Nginx {nn}대" if nn else "") if p]
    bk.put(tw, "B1", f"  ※ 진단 대상 리스트 - WEB {ni + nn}대 ({', '.join(parts) or '해당 없음'})")
    bk.put(tw, "B12", f"  ※ 진단 대상 리스트 - WAS {nt}대 (Tomcat {nt}대)" if nt
           else "  ※ 진단 대상 리스트 - WAS 0대 (해당 없음)")


# ---------------- 진입점 ----------------
def fill_report(os_kind, servers, template_path, out_path, meta=None, fix_template=False):
    """대상 여러 대의 결과를 계열 양식에 채워 저장(양식 보존).

    os_kind : 'linux' | 'windows' | 'dbms' | 'web' | 'cloud'
    servers : [{host, ip, osver, role, results:[{code,status,evidence,(final,note,resources)}]}...]
              클라우드는 account/region/kind 를 주면 진단대상 칸에 그대로 쓴다.
    meta    : {project, docno, author, grade, version, date(YYYY-MM-DD)} — 표지
    fix_template : 호환용(양식 결함은 이제 양식 파일에서 고쳐져 있음)
    """
    spec = SPECS[os_kind]
    meta = meta or {}

    if isinstance(servers, dict):
        servers = [servers]
    elif servers and isinstance(servers[0], dict) and "results" not in servers[0] and "code" in servers[0]:
        servers = [{"results": servers}]
    empty = [str(s.get("host") or "?") for s in servers if not s.get("results")]
    if empty:
        sys.stderr.write(f"[!] 결과가 비어 제외: {', '.join(empty)}\n")
    servers = [s for s in servers if s.get("results")]
    if not servers:
        raise ValueError("진단 결과(servers)가 비어 있습니다.")

    bk = Book(template_path)
    _fill_cover(bk, meta)
    if spec.get("software"):
        _fill_web(bk, spec, servers, meta)
    else:
        cap = spec["servers"]
        _warn_dropped(os_kind, [str(s.get("host") or "?") for s in servers[cap:]], cap)
        servers = servers[:cap]
        _fill_targets(bk, os_kind, servers, spec)
        dw = bk.sheet(spec["detail"])
        row_of = _code_rows(bk, dw, spec["detail_first"], spec["detail_last"])
        for idx, sv in enumerate(servers):
            _fill_detail(bk, dw, row_of, spec["result_cols"][idx], spec["evid_cols"][idx],
                         sv.get("results", []), cloud=bool(spec.get("cloud")))
        bk.fit_rows(dw, sorted(row_of.values()), ["D", "E"] + spec["evid_cols"][: len(servers)])
        _hide_unused_slots(bk, (spec["detail"], spec["summary"], spec["result_cols"], spec["evid_cols"],
                                spec["sum_cols"]), len(servers), spec["detail_first"])
        for name in (spec["detail"], spec["summary"]):
            bk.top_align_tall_merges(bk.sheet(name), spec["detail_first"])
    bk.strip_external_links()
    bk.set_properties(meta.get("author") or "취약점진단팀")
    bk.save(out_path)
    return out_path
