#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""보고서 양식(xlsx) 을 XML 수준에서 고치는 공용 도구(양식 제작용, 런타임 불필요).

openpyxl 로 열어 저장하면 표지 로고·그래프 제목 도형·3D 차트 설정이 사라진다.
여기서는 xlsx(zip) 의 필요한 XML 파트만 lxml 로 수정하고 나머지는 원본 바이트 그대로 둔다.
build_cloud_templates.py / build_server_templates.py 가 사용한다.
"""
import copy
import re
import zipfile

from lxml import etree

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
RNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PRNS = "http://schemas.openxmlformats.org/package/2006/relationships"
CTNS = "http://schemas.openxmlformats.org/package/2006/content-types"
CNS = "http://schemas.openxmlformats.org/drawingml/2006/chart"
ANS = "http://schemas.openxmlformats.org/drawingml/2006/main"
VTNS = "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"
XMLNS = "http://www.w3.org/XML/1998/namespace"


def q(tag):
    return f"{{{NS}}}{tag}"


def col_idx(letters):
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n


def col_letter(n):
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def split_ref(ref):
    m = re.fullmatch(r"\$?([A-Z]+)\$?(\d+)", ref)
    return m.group(1), int(m.group(2))


class Pkg:
    """xlsx 패키지. part() 로 꺼낸 XML 만 저장 시 다시 직렬화된다."""

    def __init__(self, path):
        self.zin = zipfile.ZipFile(path)
        self.parts = {}
        self.drop = set()
        wb = self.part("xl/workbook.xml")
        rels = self.part("xl/_rels/workbook.xml.rels")
        rid2t = {r.get("Id"): r.get("Target") for r in rels}
        self.sheet_path = {}
        for s in wb.find(q("sheets")):
            t = rid2t[s.get(f"{{{RNS}}}id")]
            self.sheet_path[s.get("name")] = t.lstrip("/") if t.startswith("/") else "xl/" + t
        self._sst = None

    # ---- 파트 ----
    def names(self):
        return [n for n in self.zin.namelist() if n not in self.drop]

    def part(self, name):
        if name not in self.parts:
            self.parts[name] = etree.fromstring(self.zin.read(name))
        return self.parts[name]

    def sheet(self, name):
        return self.part(self.sheet_path[name])

    def rels_of(self, part_name):
        base, fn = part_name.rsplit("/", 1)
        rp = f"{base}/_rels/{fn}.rels"
        return self.part(rp) if rp in self.zin.namelist() else None

    def target_of(self, part_name, rid):
        """part 의 rels 에서 rid 대상 파트 경로(절대)."""
        rels = self.rels_of(part_name)
        base = part_name.rsplit("/", 1)[0]
        for r in rels:
            if r.get("Id") == rid:
                t = r.get("Target")
                if t.startswith("/"):
                    return t.lstrip("/")
                parts = (base + "/" + t).split("/")
                out = []
                for p in parts:
                    if p == "..":
                        out.pop()
                    elif p != ".":
                        out.append(p)
                return "/".join(out)
        return None

    def drawing_of(self, sheet_name):
        ws = self.sheet(sheet_name)
        d = ws.find(q("drawing"))
        if d is None:
            return None
        return self.target_of(self.sheet_path[sheet_name], d.get(f"{{{RNS}}}id"))

    def charts_of(self, drawing_part):
        rels = self.rels_of(drawing_part)
        out = []
        for r in rels if rels is not None else []:
            if r.get("Type", "").endswith("/chart"):
                out.append(self.target_of(drawing_part, r.get("Id")))
        return out

    # ---- 공유 문자열 ----
    def sst(self):
        if self._sst is None:
            try:
                root = self.part("xl/sharedStrings.xml")
                self._sst = ["".join(t.text or "" for t in si.iter(q("t"))) for si in root.findall(q("si"))]
            except KeyError:
                self._sst = []
        return self._sst

    # ---- 시트 이름 ----
    def rename_sheet(self, old, new):
        """시트 이름 변경 + 수식/차트/정의된 이름/문서속성의 참조까지 모두 변경."""
        if old == new:
            return
        wb = self.part("xl/workbook.xml")
        for s in wb.find(q("sheets")):
            if s.get("name") == old:
                s.set("name", new)
        self.sheet_path[new] = self.sheet_path.pop(old)
        self.replace_refs(f"'{old}'!", f"'{new}'!")
        try:
            app = self.part("docProps/app.xml")
            for e in app.iter(f"{{{VTNS}}}lpstr"):
                if e.text == old:
                    e.text = new
        except KeyError:
            pass

    def replace_refs(self, old, new):
        """모든 워크시트 수식(<f>), 정의된 이름, 차트 참조(<c:f>) 의 문자열 치환."""
        wb = self.part("xl/workbook.xml")
        dn = wb.find(q("definedNames"))
        if dn is not None:
            for d in dn:
                if d.text and old in d.text:
                    d.text = d.text.replace(old, new)
        for path in self.sheet_path.values():
            for f in self.part(path).iter(q("f")):
                if f.text and old in f.text:
                    f.text = f.text.replace(old, new)
        for n in self.names():
            if n.startswith("xl/charts/chart") and n.endswith(".xml"):
                raw = self.zin.read(n) if n not in self.parts else None
                if raw is not None and old.encode("utf-8") not in raw and \
                        old.replace("'", "&apos;").encode("utf-8") not in raw:
                    continue
                for f in self.part(n).iter(f"{{{CNS}}}f"):
                    if f.text and old in f.text:
                        f.text = f.text.replace(old, new)

    # ---- 계산 ----
    def drop_calc_chain(self):
        """calcChain 제거(행/수식이 바뀌면 엑셀이 '복구' 창을 띄우므로) + 열 때 전체 재계산."""
        if "xl/calcChain.xml" in self.zin.namelist():
            self.drop.add("xl/calcChain.xml")
            rels = self.part("xl/_rels/workbook.xml.rels")
            for r in list(rels):
                if r.get("Type", "").endswith("/calcChain"):
                    rels.remove(r)
            ct = self.part("[Content_Types].xml")
            for o in list(ct):
                if o.get("PartName") == "/xl/calcChain.xml":
                    ct.remove(o)
        wb = self.part("xl/workbook.xml")
        cp = wb.find(q("calcPr"))
        if cp is None:
            cp = etree.SubElement(wb, q("calcPr"))
            ext = wb.find(q("extLst"))
            if ext is not None:          # calcPr 는 extLst 앞에 와야 한다
                ext.addprevious(cp)
        cp.set("fullCalcOnLoad", "1")

    # ---- 스타일 ----
    def derive_xf(self, s, **sides):
        """셀 스타일 s 를 복제해 테두리 일부만 바꾼 새 스타일 번호를 돌려준다.
        sides: top/bottom/left/right = 'medium' | 'thin' | None(테두리 없음)."""
        key = (int(s), tuple(sorted(sides.items())))
        cache = self.__dict__.setdefault("_xf_cache", {})
        if key in cache:
            return cache[key]
        st = self.part("xl/styles.xml")
        borders, xfs = st.find(q("borders")), st.find(q("cellXfs"))
        xf = copy.deepcopy(xfs[int(s)])
        bd = copy.deepcopy(borders[int(xf.get("borderId", "0"))])
        order = ["left", "right", "top", "bottom", "diagonal"]
        for side, style in sides.items():
            el = bd.find(q(side))
            if el is None:
                el = etree.Element(q(side))
                pos = order.index(side)
                after = [bd.find(q(o)) for o in order[:pos]]
                after = [a for a in after if a is not None]
                (after[-1].addnext(el) if after else bd.insert(0, el))
            for ch in list(el):
                el.remove(ch)
            if style:
                el.set("style", style)
                etree.SubElement(el, q("color")).set("indexed", "64")
            elif "style" in el.attrib:
                del el.attrib["style"]
        borders.append(bd)
        borders.set("count", str(len(borders)))
        xf.set("borderId", str(len(borders) - 1))
        xf.set("applyBorder", "1")
        xfs.append(xf)
        xfs.set("count", str(len(xfs)))
        cache[key] = len(xfs) - 1
        return cache[key]

    # ---- 저장 ----
    # ---- 정리(원본 보고서 잔여 데이터 제거) ----
    def clean(self, author="취약점진단팀"):
        """양식에 남은 이전 보고서 흔적 제거.
        - 수식 셀의 캐시 값(<v>)·차트 캐시: 재계산 안 하는 뷰어(미리보기·보호된 보기)에 옛 호스트/점수가 보이던 문제
        - 참조되지 않는 공유 문자열(지운 셀의 근거 문장 등)
        - 추가기능 작업창·작성자 로컬 경로·구글시트 메타데이터·없는 파트의 콘텐츠 형식"""
        for path in self.sheet_path.values():
            for c in self.part(path).iter(q("c")):
                if c.find(q("f")) is not None:
                    v = c.find(q("v"))
                    if v is not None:
                        c.remove(v)
                    if c.get("t") in ("str", "e", "b", "n"):
                        del c.attrib["t"]
        for n in self.names():
            if n.startswith("xl/charts/chart") and n.endswith(".xml"):
                root = self.part(n)
                for tag in ("strCache", "numCache"):
                    for e in list(root.iter(f"{{{CNS}}}{tag}")):
                        e.getparent().remove(e)
        self._gc_shared_strings()
        # 추가기능 작업창(webextensions)
        root_rels = self.part("_rels/.rels")
        for r in list(root_rels):
            if "webextension" in (r.get("Type") or "").lower():
                root_rels.remove(r)
        for n in self.zin.namelist():
            if n.startswith("xl/webextensions/"):
                self.drop.add(n)
        # 작성자 PC 경로(absPath), 구글시트 메타데이터
        wb = self.part("xl/workbook.xml")
        for ac in list(wb):
            if ac.tag.endswith("}AlternateContent") and b"absPath" in etree.tostring(ac):
                wb.remove(ac)
        ext = wb.find(q("extLst"))
        if ext is not None:
            for e in list(ext):
                if "GoogleSheets" in (e.get("uri") or ""):
                    ext.remove(e)
        wrels = self.part("xl/_rels/workbook.xml.rels")
        for r in list(wrels):
            if "customschemas.google.com" in (r.get("Type") or ""):
                self.drop.add("xl/" + r.get("Target").lstrip("/").replace("xl/", ""))
                wrels.remove(r)
        # 문서 속성: 작성자 이름 → 팀명
        try:
            core = self.part("docProps/core.xml")
            for e in core:
                if e.tag.endswith("}creator") or e.tag.endswith("}lastModifiedBy"):
                    e.text = author
        except KeyError:
            pass
        # 없는 파트를 가리키는 콘텐츠 형식 Override 제거
        ct = self.part("[Content_Types].xml")
        have = set(self.names())
        for o in list(ct):
            pn = o.get("PartName")
            if pn and pn.lstrip("/") not in have:
                ct.remove(o)

    def _gc_shared_strings(self):
        if "xl/sharedStrings.xml" not in self.zin.namelist():
            return
        sst = self.part("xl/sharedStrings.xml")
        sis = sst.findall(q("si"))
        cells = []
        for path in self.sheet_path.values():
            for c in self.part(path).iter(q("c")):
                if c.get("t") == "s" and c.find(q("v")) is not None:
                    cells.append(c)
        order, remap = [], {}
        for c in cells:
            i = int(c.find(q("v")).text)
            if i not in remap:
                remap[i] = len(order)
                order.append(i)
            c.find(q("v")).text = str(remap[i])
        for si in sis:
            sst.remove(si)
        ext = sst.find(q("extLst"))
        for i in order:
            (ext.addprevious(sis[i]) if ext is not None else sst.append(sis[i]))
        sst.set("count", str(len(cells)))
        sst.set("uniqueCount", str(len(order)))
        self._sst = None

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


# ---------------- 셀/행 ----------------
def rows_of(ws):
    return {int(r.get("r")): r for r in ws.find(q("sheetData"))}


def get_row(ws, r, create=True):
    sd = ws.find(q("sheetData"))
    for row in sd:
        rr = int(row.get("r"))
        if rr == r:
            return row
        if rr > r:
            if not create:
                return None
            new = etree.Element(q("row"))
            new.set("r", str(r))
            row.addprevious(new)
            return new
    if not create:
        return None
    new = etree.SubElement(sd, q("row"))
    new.set("r", str(r))
    return new


def get_cell(ws, ref, create=True):
    col, r = split_ref(ref)
    row = get_row(ws, r, create)
    if row is None:
        return None
    ci = col_idx(col)
    for c in row.findall(q("c")):
        cc = col_idx(split_ref(c.get("r"))[0])
        if cc == ci:
            return c
        if cc > ci:
            if not create:
                return None
            new = etree.Element(q("c"))
            new.set("r", ref)
            c.addprevious(new)
            return new
    if not create:
        return None
    new = etree.SubElement(row, q("c"))
    new.set("r", ref)
    return new


def _clear(c):
    for ch in list(c):
        c.remove(ch)
    for a in ("t", "cm", "vm"):
        if a in c.attrib:
            del c.attrib[a]


def set_str(ws, ref, text, style=None):
    c = get_cell(ws, ref)
    _clear(c)
    if style is not None:
        c.set("s", str(style))
    if text is None or text == "":
        return c
    c.set("t", "inlineStr")
    t = etree.SubElement(etree.SubElement(c, q("is")), q("t"))
    t.text = str(text)
    t.set(f"{{{XMLNS}}}space", "preserve")
    return c


def set_num(ws, ref, value, style=None):
    c = get_cell(ws, ref)
    _clear(c)
    if style is not None:
        c.set("s", str(style))
    etree.SubElement(c, q("v")).text = str(value)
    return c


def set_formula(ws, ref, formula, style=None):
    c = get_cell(ws, ref)
    _clear(c)
    if style is not None:
        c.set("s", str(style))
    etree.SubElement(c, q("f")).text = formula.lstrip("=")
    return c


def cell_text(pkg, ws, ref):
    c = get_cell(ws, ref, create=False)
    if c is None:
        return None
    if c.get("t") == "inlineStr":
        return "".join(t.text or "" for t in c.iter(q("t")))
    v = c.find(q("v"))
    if v is None or v.text is None:
        return None
    return pkg.sst()[int(v.text)] if c.get("t") == "s" else v.text


def set_merges(ws, refs):
    """mergeCells 를 refs 목록으로 교체."""
    mc = ws.find(q("mergeCells"))
    if mc is None:
        mc = etree.Element(q("mergeCells"))
        anchor = ws.find(q("sheetData"))
        for tag in ("sheetCalcPr", "sheetProtection", "protectedRanges", "scenarios",
                    "autoFilter", "sortState", "dataConsolidate", "customSheetViews"):
            e = ws.find(q(tag))
            if e is not None:
                anchor = e
        anchor.addnext(mc)
    for m in list(mc):
        mc.remove(m)
    for ref in refs:
        etree.SubElement(mc, q("mergeCell")).set("ref", ref)
    mc.set("count", str(len(refs)))


def merges(ws):
    mc = ws.find(q("mergeCells"))
    return [m.get("ref") for m in mc] if mc is not None else []


def set_conditional_formats(ws, blocks):
    """조건부서식 전부 교체. blocks: [(sqref, [rule dict...])]
    rule: {type:'cellIs', operator:'equal', dxfId, formula} | {type:'containsText', text, dxfId}"""
    for cf in ws.findall(q("conditionalFormatting")):
        ws.remove(cf)
    anchor = ws.find(q("mergeCells"))
    if anchor is None:
        anchor = ws.find(q("sheetData"))
    for tag in ("phoneticPr",):
        e = ws.find(q(tag))
        if e is not None:
            anchor = e
    prio = 1
    for sqref, rules in blocks:
        cf = etree.Element(q("conditionalFormatting"))
        cf.set("sqref", sqref)
        first = sqref.split()[0].split(":")[0]
        for rd in rules:
            r = etree.SubElement(cf, q("cfRule"))
            r.set("type", rd["type"])
            r.set("dxfId", str(rd["dxfId"]))
            r.set("priority", str(prio))
            prio += 1
            if rd["type"] == "cellIs":
                r.set("operator", rd.get("operator", "equal"))
                etree.SubElement(r, q("formula")).text = rd["formula"]
            elif rd["type"] == "containsText":
                r.set("operator", "containsText")
                r.set("text", rd["text"])
                etree.SubElement(r, q("formula")).text = \
                    f'NOT(ISERROR(SEARCH("{rd["text"]}",{first.replace("$", "")})))'
        anchor.addnext(cf)
        anchor = cf


def renumber_tail(ws, start, delta):
    """start 행 이후(빈 서식 행)를 delta 만큼 이동. 셀 r 속성까지 변경."""
    if delta == 0:
        return
    sd = ws.find(q("sheetData"))
    for row in sd:
        r = int(row.get("r"))
        if r >= start:
            nr = r + delta
            row.set("r", str(nr))
            for c in row.findall(q("c")):
                col, _ = split_ref(c.get("r"))
                c.set("r", f"{col}{nr}")


def set_dimension(ws):
    sd = ws.find(q("sheetData"))
    last_r = max((int(r.get("r")) for r in sd), default=1)
    last_c = 1
    for row in sd:
        for c in row.findall(q("c")):
            last_c = max(last_c, col_idx(split_ref(c.get("r"))[0]))
    d = ws.find(q("dimension"))
    if d is not None:
        d.set("ref", f"A1:{col_letter(last_c)}{last_r}")


def col_widths(ws):
    """{열번호: 너비(문자 단위)}"""
    out = {}
    cols = ws.find(q("cols"))
    fmt = ws.find(q("sheetFormatPr"))
    default = float(fmt.get("defaultColWidth", "8.43")) if fmt is not None else 8.43
    for c in cols if cols is not None else []:
        for i in range(int(c.get("min")), int(c.get("max")) + 1):
            out[i] = float(c.get("width", default))
    out["default"] = default
    return out


def set_page_fit_width(ws):
    """가로 1페이지에 맞추고 세로는 여러 페이지(긴 표가 깨알같이 인쇄되는 것 방지)."""
    sp = ws.find(q("sheetPr"))
    if sp is None:
        sp = etree.Element(q("sheetPr"))
        ws.insert(0, sp)
    ps = sp.find(q("pageSetUpPr"))
    if ps is None:
        ps = etree.SubElement(sp, q("pageSetUpPr"))
    ps.set("fitToPage", "1")
    pg = ensure_child(ws, "pageSetup")
    if not pg.get("paperSize"):
        pg.set("paperSize", "9")
    pg.set("fitToWidth", "1")
    pg.set("fitToHeight", "0")


# ---------------- 양식 공통 손질 ----------------
def clear_value(ws, ref):
    """값만 비움(수식 셀·스타일은 유지)."""
    c = get_cell(ws, ref, create=False)
    if c is None or c.find(q("f")) is not None:
        return
    _clear(c)


def remove_drawing(pkg, sheet_name):
    """시트의 그림(증적 스크린샷) 드로잉과 그 그림 파일을 제거. 차트가 있는 드로잉은 건드리지 않는다."""
    path = pkg.sheet_path[sheet_name]
    ws = pkg.part(path)
    d = ws.find(q("drawing"))
    if d is None:
        return 0
    rid = d.get(f"{{{RNS}}}id")
    dpath = pkg.target_of(path, rid)
    if pkg.charts_of(dpath):
        return 0
    ws.remove(d)
    rels = pkg.rels_of(path)
    for r in list(rels):
        if r.get("Id") == rid:
            rels.remove(r)
    drels = dpath.rsplit("/", 1)[0] + "/_rels/" + dpath.rsplit("/", 1)[1] + ".rels"
    media = []
    if drels in pkg.zin.namelist():
        for r in pkg.part(drels):
            if r.get("Type", "").endswith("/image"):
                media.append(pkg.target_of(dpath, r.get("Id")))
        pkg.drop.add(drels)
    pkg.drop.add(dpath)
    # 다른 파트가 여전히 참조하는 그림 파일은 남긴다
    used = set()
    for n in pkg.names():
        if not n.endswith(".rels") or n == drels or "/" not in n.replace("_rels/", "", 1):
            continue
        src = n.replace("_rels/", "")[: -len(".rels")]
        for r in pkg.part(n):
            if r.get("TargetMode") != "External" and r.get("Target"):
                used.add(pkg.target_of(src, r.get("Id")))
    for m in media:
        if m not in used:
            pkg.drop.add(m)
    ct = pkg.part("[Content_Types].xml")
    for o in list(ct):
        if (o.get("PartName") or "").lstrip("/") in pkg.drop:
            ct.remove(o)
    return len(media)


def strip_external_links(pkg):
    """외부 파일 링크(열 때 '연결 업데이트' 경고, #REF/#VALUE 원인) 제거."""
    wb = pkg.part("xl/workbook.xml")
    er = wb.find(q("externalReferences"))
    if er is not None:
        wb.remove(er)
    rels = pkg.part("xl/_rels/workbook.xml.rels")
    for r in list(rels):
        if "externalLink" in (r.get("Type") or ""):
            rels.remove(r)
    ct = pkg.part("[Content_Types].xml")
    for o in list(ct):
        if "/xl/externalLinks/" in (o.get("PartName") or ""):
            ct.remove(o)
    for n in pkg.zin.namelist():
        if n.startswith("xl/externalLinks/"):
            pkg.drop.add(n)


def set_print_titles(pkg, sheet_name, rows="$2:$5"):
    """인쇄 시 매 페이지 위에 반복할 제목행(기존 설정은 교체)."""
    wb = pkg.part("xl/workbook.xml")
    names = [s.get("name") for s in wb.find(q("sheets"))]
    idx = str(names.index(sheet_name))
    dn = wb.find(q("definedNames"))
    if dn is None:
        dn = etree.Element(q("definedNames"))
        wb.find(q("sheets")).addnext(dn)
    for d in list(dn):
        if d.get("name") == "_xlnm.Print_Titles" and d.get("localSheetId") == idx:
            dn.remove(d)
    d = etree.SubElement(dn, q("definedName"))
    d.set("name", "_xlnm.Print_Titles")
    d.set("localSheetId", idx)
    d.text = f"'{sheet_name}'!{rows}"
    # definedName 은 이름순 정렬이 규칙은 아니지만 localSheetId 순으로 정리
    items = sorted(dn, key=lambda e: (e.get("name"), int(e.get("localSheetId", "-1"))))
    for e in items:
        dn.append(e)


def open_on_first_sheet(pkg, first_row_of=None):
    """열면 표지(첫 시트)부터 보이게. first_row_of={시트명: 첫 데이터행} 이면 틀고정 스크롤도 처음으로."""
    wb = pkg.part("xl/workbook.xml")
    for v in wb.find(q("bookViews")):
        v.set("activeTab", "0")
        v.set("firstSheet", "0")
    names = [s.get("name") for s in wb.find(q("sheets"))]
    for i, name in enumerate(names):
        ws = pkg.sheet(name)
        for sv in ws.iter(q("sheetView")):
            if i == 0:
                sv.set("tabSelected", "1")
            elif "tabSelected" in sv.attrib:
                del sv.attrib["tabSelected"]
            fr = (first_row_of or {}).get(name)
            if fr:
                if "topLeftCell" in sv.attrib:
                    sv.set("topLeftCell", "A1")
                # 틀고정 시 오른쪽 아래 창의 시작 셀은 고정 영역 바깥이어야 한다(아니면 엑셀이 못 연다)
                for p in sv.findall(q("pane")):
                    xs = int(float(p.get("xSplit", "0"))) if p.get("state") in ("frozen", "frozenSplit") else 0
                    ys = int(float(p.get("ySplit", "0"))) if p.get("state") in ("frozen", "frozenSplit") else 0
                    p.set("topLeftCell", f"{col_letter(xs + 1)}{max(fr, ys + 1)}")


# ---------------- 인쇄 영역 ----------------
XDR = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
EMU_PER_PT = 12700


def max_digit_px(pkg):
    """통합문서 기본 글꼴의 숫자 폭(px). 열 너비 1 = 이 폭. Calibri 11 = 7, 맑은 고딕/돋움 11 = 8."""
    if "_mdw" not in pkg.__dict__:
        st = pkg.part("xl/styles.xml")
        f0 = st.find(q("fonts"))[0]
        name = (f0.find(q("name")).get("val") if f0.find(q("name")) is not None else "Calibri")
        size = float(f0.find(q("sz")).get("val")) if f0.find(q("sz")) is not None else 11.0
        base = 7.0 if name.isascii() and name.lower() not in ("dotum", "gulim", "malgun gothic", "batang") else 8.0
        pkg._mdw = max(5.0, round(base * size / 11.0))
    return pkg._mdw


def _col_pt(widths, i, mdw=7.0):
    """열 i(1부터) 너비(pt). XML 너비는 여백 포함 문자수 → 픽셀 = 너비*숫자폭, pt = 픽셀*0.75.
    (엑셀 실측: 돋움 11 기준 너비 90.63 → 544pt)"""
    w = widths.get(i, widths["default"])
    return w * mdw * 0.75


def _row_heights(ws):
    fmt = ws.find(q("sheetFormatPr"))
    dflt = float(fmt.get("defaultRowHeight", "15")) if fmt is not None else 15.0
    hts = {int(r.get("r")): float(r.get("ht")) for r in ws.find(q("sheetData")) if r.get("ht")}
    return hts, dflt


def drawing_bbox(pkg, sheet_name):
    """드로잉 개체(차트·도형·그림)가 차지하는 마지막 열/행 번호(1부터)."""
    dpath = pkg.drawing_of(sheet_name)
    if not dpath:
        return 0, 0
    ws = pkg.sheet(sheet_name)
    widths = col_widths(ws)
    mdw = max_digit_px(pkg)
    hts, dflt = _row_heights(ws)
    last_c = last_r = 0
    for anc in pkg.part(dpath):
        fr = anc.find(f"{{{XDR}}}from")
        to = anc.find(f"{{{XDR}}}to")
        if fr is None:
            continue
        c0 = int(fr.find(f"{{{XDR}}}col").text) + 1
        r0 = int(fr.find(f"{{{XDR}}}row").text) + 1
        if to is not None:
            c1 = int(to.find(f"{{{XDR}}}col").text) + 1
            r1 = int(to.find(f"{{{XDR}}}row").text) + 1
        else:
            ext = anc.find(f"{{{XDR}}}ext")
            wpt = int(ext.get("cx")) / EMU_PER_PT + int(fr.find(f"{{{XDR}}}colOff").text) / EMU_PER_PT
            hpt = int(ext.get("cy")) / EMU_PER_PT + int(fr.find(f"{{{XDR}}}rowOff").text) / EMU_PER_PT
            c1, acc = c0, 0.0
            while acc + _col_pt(widths, c1, mdw) < wpt:
                acc += _col_pt(widths, c1, mdw)
                c1 += 1
            r1, acc = r0, 0.0
            while acc + hts.get(r1, dflt) < hpt:
                acc += hts.get(r1, dflt)
                r1 += 1
        last_c, last_r = max(last_c, c1), max(last_r, r1)
    return last_c, last_r


def set_print_area(pkg, sheet_name, ref):
    wb = pkg.part("xl/workbook.xml")
    names = [s.get("name") for s in wb.find(q("sheets"))]
    idx = str(names.index(sheet_name))
    dn = wb.find(q("definedNames"))
    if dn is None:
        dn = etree.Element(q("definedNames"))
        wb.find(q("sheets")).addnext(dn)
    for d in list(dn):
        if d.get("name") == "_xlnm.Print_Area" and d.get("localSheetId") == idx:
            dn.remove(d)
    d = etree.SubElement(dn, q("definedName"))
    d.set("name", "_xlnm.Print_Area")
    d.set("localSheetId", idx)
    # 여러 구역('$A$1:$U$64,$A$65:$T$85')이면 구역마다 시트 이름을 붙인다
    d.text = ",".join(a if "!" in a else f"'{sheet_name}'!{a}" for a in ref.split(","))
    for e in sorted(dn, key=lambda e: (e.get("name"), int(e.get("localSheetId", "-1")))):
        dn.append(e)


def set_row_breaks(ws, rows):
    """수동 페이지 나눔(각 값 = 그 페이지의 마지막 행)."""
    rb = ensure_child(ws, "rowBreaks")
    for b in list(rb):
        rb.remove(b)
    for r in rows:
        b = etree.SubElement(rb, q("brk"))
        b.set("id", str(r))
        b.set("max", "16383")
        b.set("man", "1")
    rb.set("count", str(len(rows)))
    rb.set("manualBreakCount", str(len(rows)))


def graph_page_setup(pkg, sheet_name, breaks, extra_cells_to=(4, 0)):
    """그래프 시트: 인쇄 영역 = 차트/도형 + 왼쪽 표(B~D) 범위, 가로 방향, 폭에 맞춘 배율, 구역별 페이지 나눔.
    (페이지 맞춤 옵션을 쓰면 엑셀이 수동 나눔을 무시하므로 배율을 직접 계산)"""
    ws = pkg.sheet(sheet_name)
    c1, r1 = drawing_bbox(pkg, sheet_name)
    c1, r1 = max(c1, extra_cells_to[0]), max(r1, extra_cells_to[1])
    set_print_area(pkg, sheet_name, f"$A$1:${col_letter(c1)}${r1}")
    widths = col_widths(ws)
    mdw = max_digit_px(pkg)
    width_pt = sum(_col_pt(widths, i, mdw) for i in range(1, c1 + 1)) * 1.1    # 실측 대비 여유
    pm = ws.find(q("pageMargins"))
    lr = (float(pm.get("left", 0.7)) + float(pm.get("right", 0.7))) * 72 if pm is not None else 100.8
    tb = (float(pm.get("top", 0.75)) + float(pm.get("bottom", 0.75))) * 72 if pm is not None else 108
    hts, dflt = _row_heights(ws)
    bounds = [0] + [b for b in breaks if b < r1] + [r1]
    tallest = max(sum(hts.get(r, dflt) for r in range(a + 1, b + 1)) for a, b in zip(bounds, bounds[1:]))
    # 가로는 한 장 폭에, 세로는 가장 긴 구역이 한 장에 들어가도록(차트가 페이지 경계에서 잘리지 않게)
    scale = max(10, min(100, int((842 - lr) / width_pt * 100), int((595 - tb - 10) / tallest * 100)))
    pg = ensure_child(ws, "pageSetup")
    for a in ("fitToWidth", "fitToHeight"):
        if a in pg.attrib:
            del pg.attrib[a]
    pg.set("paperSize", "9")
    pg.set("orientation", "landscape")
    pg.set("scale", str(scale))
    sp = ws.find(q("sheetPr"))
    if sp is not None and sp.find(q("pageSetUpPr")) is not None:
        sp.find(q("pageSetUpPr")).set("fitToPage", "0")
    set_row_breaks(ws, breaks)
    return c1, r1, scale


def set_col_breaks(ws, cols):
    """수동 열 페이지 나눔(각 값 = 그 페이지의 마지막 열 번호)."""
    cb = ensure_child(ws, "colBreaks")
    for b in list(cb):
        cb.remove(b)
    for c in cols:
        b = etree.SubElement(cb, q("brk"))
        b.set("id", str(c))
        b.set("max", "1048575")
        b.set("man", "1")
    cb.set("count", str(len(cols)))
    cb.set("manualBreakCount", str(len(cols)))
    if not cols:
        ws.remove(cb)


def detail_page_setup(pkg, sheet_name, groups, last_row, title_rows="$2:$5", first_row=6):
    """상세 시트 인쇄 설정(가로 방향, 제목행 2~5 매 장 반복).
    - 대상 1개(DBMS·클라우드·IIS·Nginx): 진단항목~근거(B~G)를 가로 한 장 폭에 맞춤.
    - 대상 여러 개(리눅스·윈도우·Tomcat): 대상별 판정+근거 묶음마다 페이지를 나누고,
      매 장 왼쪽에 진단항목·No.·세부 진단항목(B:D, 제목 병합 B2 포함)을 반복. 첫 장은 진단기준(E)+첫 대상.
      ※ 엑셀은 반복 열 폭을 두 번 빼고 쪽 폭을 계산한다(실측) → 배율 계산에 반영."""
    ws = pkg.sheet(sheet_name)
    wb = pkg.part("xl/workbook.xml")
    names = [s_.get("name") for s_ in wb.find(q("sheets"))]
    widths = col_widths(ws)
    mdw = max_digit_px(pkg)

    def span(a, b):
        return sum(_col_pt(widths, i, mdw) for i in range(col_idx(a), col_idx(b) + 1)) * 1.08

    pg = ensure_child(ws, "pageSetup")
    for a in ("fitToWidth", "fitToHeight", "scale"):
        if a in pg.attrib:
            del pg.attrib[a]
    pg.set("paperSize", "9")
    pg.set("orientation", "landscape")
    sp = ensure_child(ws, "sheetPr")
    ps = sp.find(q("pageSetUpPr"))
    if ps is None:
        ps = etree.SubElement(sp, q("pageSetUpPr"))
    set_print_titles(pkg, sheet_name, title_rows)
    if len(groups) == 1:
        set_print_area(pkg, sheet_name, f"$B${first_row}:${groups[0][1]}${last_row}")
        ps.set("fitToPage", "1")
        pg.set("fitToWidth", "1")
        pg.set("fitToHeight", "0")
        set_col_breaks(ws, [])
        return 0
    ps.set("fitToPage", "0")
    pm = ws.find(q("pageMargins"))
    lr = (float(pm.get("left", 0.7)) + float(pm.get("right", 0.7))) * 72 if pm is not None else 100.8
    first_page = span("E", groups[0][1])
    widest = max([first_page] + [span(a, b) for a, b in groups[1:]])
    scale = max(10, min(100, int((842 - lr) / (2 * span("B", "D") + widest) * 100)))
    pg.set("scale", str(scale))
    set_print_area(pkg, sheet_name, f"$E${first_row}:${groups[-1][1]}${last_row}")
    for d in wb.find(q("definedNames")):
        if d.get("name") == "_xlnm.Print_Titles" and d.get("localSheetId") == str(names.index(sheet_name)):
            d.text = f"'{sheet_name}'!$B:$D,'{sheet_name}'!{title_rows}"
    set_col_breaks(ws, [col_idx(b) for _a, b in groups[:-1]])
    return scale


_WS_ORDER = ["sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData", "sheetCalcPr",
             "sheetProtection", "protectedRanges", "scenarios", "autoFilter", "sortState", "dataConsolidate",
             "customSheetViews", "mergeCells", "phoneticPr", "conditionalFormatting", "dataValidations",
             "hyperlinks", "printOptions", "pageMargins", "pageSetup", "headerFooter", "rowBreaks",
             "colBreaks", "customProperties", "cellWatches", "ignoredErrors", "smartTags", "drawing",
             "legacyDrawing", "legacyDrawingHF", "drawingHF", "picture", "oleObjects", "controls",
             "webPublishItems", "tableParts", "extLst"]


def ensure_child(ws, tag):
    """워크시트 직계 자식 tag 를 찾거나, 스키마 순서에 맞는 자리에 새로 만든다."""
    el = ws.find(q(tag))
    if el is not None:
        return el
    el = etree.Element(q(tag))
    pos = _WS_ORDER.index(tag)
    prev = None
    for t in _WS_ORDER[:pos]:
        found = ws.findall(q(t))
        if found:
            prev = found[-1]
    if prev is None:
        ws.insert(0, el)
    else:
        prev.addnext(el)
    return el


# ---------------- 판정 셀 서식 / 조건부서식 ----------------
def ensure_dxf(pkg, kind):
    """조건부서식용 차등 서식 번호. kind: vuln(굵은 빨강) | na(회색 기울임) | interview(주황 채움) | check(파랑)."""
    cache = pkg.__dict__.setdefault("_dxf_cache", {})
    if kind in cache:
        return cache[kind]
    st = pkg.part("xl/styles.xml")
    dxfs = st.find(q("dxfs"))
    if dxfs is None:
        dxfs = etree.Element(q("dxfs"))
        anchor = st.find(q("cellStyles")) if st.find(q("cellStyles")) is not None else st.find(q("cellXfs"))
        anchor.addnext(dxfs)
    body = {
        "vuln": '<font><b/><color rgb="FFFF0000"/></font>',
        "na": '<font><i/><color rgb="FF7F7F7F"/></font>',
        "interview": ('<fill><patternFill patternType="solid"><fgColor rgb="FFFFC000"/>'
                      '<bgColor rgb="FFFFC000"/></patternFill></fill>'),
        "check": '<font><b/><color rgb="FF0070C0"/></font>',
    }[kind]
    dxfs.append(etree.fromstring(f'<dxf xmlns="{NS}">{body}</dxf>'))
    dxfs.set("count", str(len(dxfs)))
    cache[kind] = len(dxfs) - 1
    return cache[kind]


def add_verdict_cf(pkg, ws, sqref):
    """판정 칸 공통 규칙(최우선): 취약=굵은 빨강, N/A=회색 기울임, 인터뷰=주황 채움. 기존 규칙은 유지."""
    first = sqref.split()[0].split(":")[0]
    for cf in ws.findall(q("conditionalFormatting")):
        for r in cf.findall(q("cfRule")):
            r.set("priority", str(int(r.get("priority", "1")) + 3))
    cf = etree.Element(q("conditionalFormatting"))
    cf.set("sqref", sqref)
    rules = (("cellIs", '"취약"', "vuln"), ("cellIs", '"N/A"', "na"), ("containsText", "인터뷰", "interview"))
    for prio, (typ, val, kind) in enumerate(rules, 1):
        r = etree.SubElement(cf, q("cfRule"))
        r.set("type", typ)
        r.set("dxfId", str(ensure_dxf(pkg, kind)))
        r.set("priority", str(prio))
        if typ == "cellIs":
            r.set("operator", "equal")
            etree.SubElement(r, q("formula")).text = val
        else:
            r.set("operator", "containsText")
            r.set("text", val)
            etree.SubElement(r, q("formula")).text = f'NOT(ISERROR(SEARCH("{val}",{first})))'
    existing = ws.findall(q("conditionalFormatting"))
    if existing:
        existing[0].addprevious(cf)
        return
    prev = None
    for t in _WS_ORDER[:_WS_ORDER.index("conditionalFormatting")]:
        found = ws.findall(q(t))
        if found:
            prev = found[-1]
    prev.addnext(cf)


def restyle(pkg, s, font_from=None, **align):
    """스타일 s 복제: font_from 스타일의 글꼴로 바꾸고(색·굵기 초기화), 정렬 속성 덮어쓰기."""
    key = ("restyle", int(s), font_from, tuple(sorted(align.items())))
    cache = pkg.__dict__.setdefault("_xf_cache", {})
    if key in cache:
        return cache[key]
    st = pkg.part("xl/styles.xml")
    xfs = st.find(q("cellXfs"))
    xf = copy.deepcopy(xfs[int(s)])
    if font_from is not None:
        xf.set("fontId", xfs[int(font_from)].get("fontId"))
        xf.set("applyFont", "1")
    if align:
        al = xf.find(q("alignment"))
        if al is None:
            al = etree.Element(q("alignment"))
            xf.insert(0, al)
        for k, v in align.items():
            al.set(k, v)
        xf.set("applyAlignment", "1")
    xfs.append(xf)
    xfs.set("count", str(len(xfs)))
    cache[key] = len(xfs) - 1
    return cache[key]


def restyle_range(pkg, ws, cols, rows, font_from=None, **align):
    for r in rows:
        for c in cols:
            cell = get_cell(ws, f"{c}{r}")
            cell.set("s", str(restyle(pkg, cell.get("s", "0"), font_from, **align)))


def set_col_width(ws, col, width):
    """열 너비 변경(<cols> 범위를 쪼개서 해당 열만)."""
    ci = col_idx(col)
    cols = ensure_child(ws, "cols")
    for c in list(cols):
        lo, hi = int(c.get("min")), int(c.get("max"))
        if lo <= ci <= hi:
            parts = []
            if lo < ci:
                a = copy.deepcopy(c)
                a.set("max", str(ci - 1))
                parts.append(a)
            m = copy.deepcopy(c)
            m.set("min", str(ci))
            m.set("max", str(ci))
            m.set("width", str(width))
            m.set("customWidth", "1")
            parts.append(m)
            if ci < hi:
                b = copy.deepcopy(c)
                b.set("min", str(ci + 1))
                parts.append(b)
            for p_ in parts:
                c.addprevious(p_)
            cols.remove(c)
            return
    new = etree.Element(q("col"))
    for k, v in (("min", ci), ("max", ci), ("width", width), ("customWidth", 1)):
        new.set(k, str(v))
    after = [c for c in cols if int(c.get("max")) < ci]
    (after[-1].addnext(new) if after else cols.insert(0, new))


# ---------------- 표지 / 보기 / 차트 ----------------
def cover_one_page(pkg, sheet_name, last_row=23):
    """표지를 한 장에(문서정보 상자가 2쪽으로 밀리던 문제)."""
    ws = pkg.sheet(sheet_name)
    sp = ensure_child(ws, "sheetPr")
    ps = sp.find(q("pageSetUpPr"))
    if ps is None:
        ps = etree.SubElement(sp, q("pageSetUpPr"))
    ps.set("fitToPage", "1")
    po = ensure_child(ws, "printOptions")
    po.set("horizontalCentered", "1")
    pg = ensure_child(ws, "pageSetup")
    pg.set("paperSize", "9")
    pg.set("orientation", "portrait")
    pg.set("fitToWidth", "1")
    pg.set("fitToHeight", "1")
    cb = ws.find(q("colBreaks"))
    if cb is not None:
        ws.remove(cb)
    set_print_area(pkg, sheet_name, f"$A$1:$L${last_row}")


def reset_all_views(pkg):
    """모든 시트: 스크롤 맨 위, 선택 A1. 틀고정 시트는 고정 영역 바깥 첫 셀."""
    wb = pkg.part("xl/workbook.xml")
    for name in [s.get("name") for s in wb.find(q("sheets"))]:
        for sv in pkg.sheet(name).iter(q("sheetView")):
            if "topLeftCell" in sv.attrib:
                del sv.attrib["topLeftCell"]
            pane = sv.find(q("pane"))
            xs = ys = 0
            if pane is not None and pane.get("state") in ("frozen", "frozenSplit"):
                xs = int(float(pane.get("xSplit", "0")))
                ys = int(float(pane.get("ySplit", "0")))
                pane.set("topLeftCell", f"{col_letter(xs + 1)}{ys + 1}")
            for sel in sv.findall(q("selection")):
                cell = {"bottomRight": f"{col_letter(xs + 1)}{ys + 1}", "bottomLeft": f"A{ys + 1}",
                        "topRight": f"{col_letter(xs + 1)}1"}.get(sel.get("pane"), "A1")
                sel.set("activeCell", cell)
                sel.set("sqref", cell)


def pie_hide_zero_labels(pkg, chart_part):
    """원형 차트: 0% 조각 라벨 숨김(0.0%0.0% 겹침 방지)."""
    root = pkg.part(chart_part)
    for dl in root.iter(f"{{{CNS}}}dLbls"):
        if dl.getparent().tag != f"{{{CNS}}}ser":
            continue
        nf = dl.find(f"{{{CNS}}}numFmt")
        if nf is None:
            nf = etree.Element(f"{{{CNS}}}numFmt")
            before = [e for e in dl if e.tag in (f"{{{CNS}}}dLbl", f"{{{CNS}}}delete")]
            (before[-1].addnext(nf) if before else dl.insert(0, nf))
        nf.set("formatCode", "0.0%;;;")
        nf.set("sourceLinked", "0")


def radar_scale_0_1(pkg, chart_part):
    """레이더 값 축 0~100% 고정(자동 축이면 60%가 최대처럼 보임)."""
    root = pkg.part(chart_part)
    for ax in root.iter(f"{{{CNS}}}valAx"):
        sc = ax.find(f"{{{CNS}}}scaling")
        orient = sc.find(f"{{{CNS}}}orientation")
        for tag in ("max", "min"):
            e = sc.find(f"{{{CNS}}}{tag}")
            if e is not None:
                sc.remove(e)
        mx = etree.Element(f"{{{CNS}}}max")
        mx.set("val", "1")
        mn = etree.Element(f"{{{CNS}}}min")
        mn.set("val", "0")
        orient.addnext(mx)
        mx.addnext(mn)


def remove_grade_legend_picture(pkg, drawing_part):
    """막대그래프 옆 '안전(A)/양호(B)/보통이하(C~E)' 고정 그림 범례 제거(3단계 기준과 안 맞음)."""
    d = pkg.part(drawing_part)
    removed = 0
    for pic in list(d.iter(f"{{{XDR}}}pic")):
        parent = pic.getparent()
        if parent.tag == f"{{{XDR}}}grpSp":
            parent.remove(pic)
            removed += 1
    return removed
