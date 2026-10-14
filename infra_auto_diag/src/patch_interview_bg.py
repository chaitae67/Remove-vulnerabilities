#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""결과보고서 양식(.xlsx)의 '인터뷰 필요' 주황 배경(dxf fill, FFFFC000) 제거.

공식 양식에서 넘어온 조건부서식 dxf 중 주황(FFFFC000) 배경을 쓰는 것들에서 <fill> 만 지운다
(글자 서식은 유지). 인터뷰 필요는 배경 없이 기본 글자색으로 표시된다.

    python patch_interview_bg.py                 # 보고서_양식_*.xlsx 전부
    python patch_interview_bg.py 보고서_양식_DBMS.xlsx
"""
import glob
import os
import re
import sys
import zipfile

ORANGE = "FFFFC000"                      # 인터뷰 필요 배경색
HERE = os.path.dirname(os.path.abspath(__file__))


def patch_styles(xml):
    """xl/styles.xml 문자열에서 주황 fill 을 쓰는 dxf 의 <fill>…</fill> 제거. (바뀐 xml, 건수)"""
    m = re.search(r"(<dxfs\b[^>]*>)(.*?)(</dxfs>)", xml, re.S)
    if not m:
        return xml, 0
    head, body, tail = m.groups()
    n = [0]

    def fix(dm):
        d = dm.group(0)
        if ORANGE in d and "<fill>" in d:
            d2 = re.sub(r"<fill>.*?</fill>", "", d, flags=re.S)
            if d2 != d:
                n[0] += 1
            return d2
        return d

    body2 = re.sub(r"<dxf>.*?</dxf>", fix, body, flags=re.S)
    return xml[:m.start()] + head + body2 + tail + xml[m.end():], n[0]


def patch_file(path):
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        data = {n: z.read(n) for n in names}
        infos = {n: z.getinfo(n) for n in names}
    styles = data.get("xl/styles.xml", b"").decode("utf-8")
    new, cnt = patch_styles(styles)
    if cnt == 0:
        print(f"  {os.path.basename(path)}: 주황 dxf 없음(변경 없음)")
        return
    data["xl/styles.xml"] = new.encode("utf-8")
    tmp = path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for n in names:
            zi = zipfile.ZipInfo(n, date_time=infos[n].date_time)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = infos[n].external_attr
            zout.writestr(zi, data[n])
    os.replace(tmp, path)
    print(f"  {os.path.basename(path)}: 주황 배경 dxf {cnt}개 → fill 제거")


def main():
    args = sys.argv[1:]
    files = args or sorted(glob.glob(os.path.join(HERE, "보고서_양식_*.xlsx")))
    print(f"[*] 인터뷰 주황 배경 제거: {len(files)}개")
    for f in files:
        f = f if os.path.isabs(f) else os.path.join(HERE, f)
        if os.path.exists(f):
            patch_file(f)
        else:
            print(f"  [!] 없음: {f}")


if __name__ == "__main__":
    main()
