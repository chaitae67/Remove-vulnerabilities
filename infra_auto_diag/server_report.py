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
        "label": "Linux", "id_col": "C", "detail_first": 6, "detail_last": 72,
        "result_cols": ["F", "H", "J", "L"], "evid_cols": ["G", "I", "K", "M"], "servers": 4,
    },
    "windows": {
        "cover": "0. 표지", "target": "1. 진단 대상", "detail": "3-1. 진단 결과(window)",
        "label": "Windows", "id_col": "C", "detail_first": 6, "detail_last": 69,
        "result_cols": ["F", "H"], "evid_cols": ["G", "I"], "servers": 2,
    },
}
TARGET_FIRST_ROW = 5
COVER = {"docno": "L3", "author": "L4", "grade": "L5", "ver": "L6", "date": "B18"}


def norm_result(v):
    k = (v or "").strip()
    k = k.upper() if k.isascii() else k
    return RESULT_ALIAS.get(k, RESULT_ALIAS.get((v or "").strip(), "N/A"))


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

    def save(self, out):
        cp = self.wb_root.find(q("calcPr"))
        if cp is None:
            cp = etree.SubElement(self.wb_root, q("calcPr"))
        cp.set("fullCalcOnLoad", "1")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in self.zin.infolist():
                if item.filename in self.parts:
                    data = etree.tostring(self.parts[item.filename], xml_declaration=True,
                                          encoding="UTF-8", standalone=True)
                else:
                    data = self.zin.read(item.filename)
                zout.writestr(item, data)


def _date_serial(d):
    return (datetime.datetime(d.year, d.month, d.day) - datetime.datetime(1899, 12, 30)).days


# ---------------- 진입점 ----------------
def fill_report(os_kind, servers, template_path, out_path, meta=None):
    """서버 여러 대 결과를 계열 양식(다중서버)에 채워 저장(양식 100% 보존).

    os_kind : 'linux' | 'windows'
    servers : [{host, ip, osver, role, results:[{code,status,evidence,(final,note)}]}...]
    """
    spec = SPECS[os_kind]
    meta = meta or {}

    if isinstance(servers, dict):
        servers = [servers]
    elif servers and isinstance(servers[0], dict) and "results" not in servers[0] and "code" in servers[0]:
        servers = [{"results": servers}]
    servers = [s for s in servers if s.get("results")][: spec["servers"]]
    if not servers:
        raise ValueError("진단 결과(servers)가 비어 있습니다.")

    bk = Book(template_path)

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
    bk.put(tw, "B1", f"  ※ 진단 대상 리스트 - 서버 {len(servers)}대 ({spec['label']} {len(servers)}대)")

    # 3-1. 진단 결과 (서버별 판정 + 근거)
    dw = bk.sheet(spec["detail"])
    first, last = spec["detail_first"], spec["detail_last"]
    row_of = {}
    for r in range(first, last + 1):
        v = bk.get(dw, f"{spec['id_col']}{r}")
        if v:
            row_of[v.strip().upper()] = r
    for idx, sv in enumerate(servers):
        rc, ec = spec["result_cols"][idx], spec["evid_cols"][idx]
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

    bk.save(out_path)
    return out_path
