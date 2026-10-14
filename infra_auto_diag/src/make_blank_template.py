#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""공식 결과보고서(데이터·증적 포함) → 빈 보고서 양식(.xlsx) 생성기(단순 버전).

※ 저장소의 보고서_양식_Linux/Windows/DBMS/Webserver.xlsx 는 이제 build_server_templates.py 로 만든다
  (값 비우기 + 공식 파일 결함 수리 + 인쇄 설정 + 숨은 옛 데이터 제거). 이 스크립트는 참고용.

입력 셀(표지 값/진단대상/3-x 판정·근거)을 비우고, 상세시트에 박혀 있는
증적 스크린샷(drawing)만 제거한다. 표지 로고·2-1 차트·수식·서식·조건부서식은 보존.
→ 이렇게 만든 양식을 server_report.py 가 채운다(리눅스/윈도우와 동일 방식).

사용:
  python make_blank_template.py "결과보고서/주통기/DBMS_..._v2.1.xlsx" 보고서_양식_DBMS.xlsx \
        --detail "3-1. 진단 결과(Oracle)" --clear-detail 6:31
"""
import argparse
import re
import zipfile
from lxml import etree

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
RNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PRNS = "http://schemas.openxmlformats.org/package/2006/relationships"


def q(t):
    return f"{{{NS}}}{t}"


def pr(t):
    return f"{{{PRNS}}}{t}"


class Zip:
    def __init__(self, path):
        self.zin = zipfile.ZipFile(path)
        self.parts = {}
        self.drop = set()

    def root(self, name):
        if name not in self.parts:
            self.parts[name] = etree.fromstring(self.zin.read(name))
        return self.parts[name]

    def sheet_index(self):
        """sheet 이름 → xl/worksheets/sheetN.xml 경로."""
        wb = self.root("xl/workbook.xml")
        rels = etree.fromstring(self.zin.read("xl/_rels/workbook.xml.rels"))
        rid2t = {r.get("Id"): r.get("Target") for r in rels}
        out = {}
        for s in wb.find(q("sheets")):
            t = rid2t[s.get(f"{{{RNS}}}id")]
            out[s.get("name")] = t.lstrip("/") if t.startswith("/") else "xl/" + t
        return out

    def clear_cell(self, sheet_xml, ref):
        m = re.fullmatch(r"([A-Z]+)(\d+)", ref)
        row = int(m.group(2))
        sd = sheet_xml.find(q("sheetData"))
        row_el = next((r for r in sd.findall(q("row")) if int(r.get("r")) == row), None)
        if row_el is None:
            return
        for c in row_el.findall(q("c")):
            if c.get("r") == ref:
                if c.find(q("f")) is not None:      # 수식 셀은 건드리지 않음
                    return
                for ch in list(c):
                    c.remove(ch)
                if "t" in c.attrib:
                    del c.attrib["t"]
                return

    def remove_drawing(self, sheet_path):
        """워크시트의 <drawing> 참조와 drawing 파트·전용 media 를 제거."""
        sx = self.root(sheet_path)
        dr = sx.find(q("drawing"))
        if dr is None:
            return
        rid = dr.get(f"{{{RNS}}}id")
        sx.remove(dr)
        # 워크시트 rels 에서 drawing 대상 찾기
        base = sheet_path.rsplit("/", 1)
        rels_path = base[0] + "/_rels/" + base[1] + ".rels"
        try:
            rels = self.root(rels_path)
        except KeyError:
            return
        target = None
        for rel in list(rels):
            if rel.get("Id") == rid:
                target = rel.get("Target")
                rels.remove(rel)
        if not target:
            return
        draw_path = "xl/" + target.replace("../", "")
        self.drop.add(draw_path)
        # drawing 이 참조하는 media + drawing rels 제거
        d_rels = "xl/drawings/_rels/" + draw_path.rsplit("/", 1)[1] + ".rels"
        if d_rels in self.zin.namelist():
            self.drop.add(d_rels)
            dr_rel = etree.fromstring(self.zin.read(d_rels))
            for rel in dr_rel:
                tg = rel.get("Target", "")
                if "media" in tg:
                    self.drop.add("xl/" + tg.replace("../", ""))

    def save(self, out):
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zo:
            for item in self.zin.infolist():
                if item.filename in self.drop:
                    continue
                if item.filename in self.parts:
                    data = etree.tostring(self.parts[item.filename], xml_declaration=True,
                                          encoding="UTF-8", standalone=True)
                else:
                    data = self.zin.read(item.filename)
                zo.writestr(item, data)


def col_range(spec):
    # "F:G" 또는 "F,H,J,L"
    if ":" in spec:
        a, b = spec.split(":")
        return [chr(c) for c in range(ord(a), ord(b) + 1)]
    return spec.split(",")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("out")
    ap.add_argument("--cover", default="0. 표지")
    ap.add_argument("--cover-cells", default="L3,L4,L5,L6,B18")
    ap.add_argument("--target", default="1. 진단 대상")
    ap.add_argument("--target-rows", default="5:8",
                    help="진단대상 데이터 행. 범위 '5:8' 또는 개별 '5,7,15,16' (B~F 열 비움)")
    ap.add_argument("--detail", action="append", default=[],
                    help="상세 시트명. --detail 여러 번. 각 시트의 판정/근거 열을 비우고 스크린샷 제거")
    ap.add_argument("--detail-rows", default="6:31")
    ap.add_argument("--detail-cols", default="F:M", help="비울 판정+근거 열 범위")
    a = ap.parse_args()

    z = Zip(a.src)
    idx = z.sheet_index()

    # 표지
    cov = z.root(idx[a.cover])
    for ref in a.cover_cells.split(","):
        z.clear_cell(cov, ref.strip())
    # 진단 대상 (B~F 열)
    if ":" in a.target_rows:
        tr0, tr1 = map(int, a.target_rows.split(":"))
        target_rows = range(tr0, tr1 + 1)
    else:
        target_rows = [int(x) for x in a.target_rows.split(",")]
    tw = z.root(idx[a.target])
    for r in target_rows:
        for col in "BCDEF":
            z.clear_cell(tw, f"{col}{r}")
    # 상세 시트들
    dr0, dr1 = map(int, a.detail_rows.split(":"))
    cols = col_range(a.detail_cols)
    for sname in a.detail:
        if sname not in idx:
            print(f"[!] 시트 없음: {sname}"); continue
        path = idx[sname]
        dw = z.root(path)
        for r in range(dr0, dr1 + 1):
            for col in cols:
                z.clear_cell(dw, f"{col}{r}")
        z.remove_drawing(path)

    z.save(a.out)
    print(f"빈 양식 저장: {a.out}")


if __name__ == "__main__":
    main()
