#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""makereport_all.py 단일 파일 생성기 — CSV/JSON → 결과보고서(xlsx) 변환을 파일 하나로.

make_reports.py·make_report.py·server_report.py·tpl_xml.py 와 공식 양식(보고서_양식_*.xlsx)을
base64 로 내장한 makereport_all.py 를 만든다. 서버/PC 어디서든 이 파일 하나만 있으면
(파이썬3 + lxml) 스캔 결과 CSV 를 바로 엑셀 보고서로 변환한다.

    python build_report_onefile.py     # → makereport_all.py
"""
import base64
import glob
import hashlib
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "makereport_all.py")


def main():
    embed = {}
    tops = ["make_reports.py", "make_report.py", "server_report.py", "tpl_xml.py"]
    tops += [os.path.basename(p) for p in sorted(glob.glob(os.path.join(HERE, "보고서_양식_*.xlsx")))]
    for top in tops:
        p = os.path.join(HERE, top)
        if not os.path.exists(p):
            raise SystemExit(f"[!] 없음: {top} (server/cloud 양식을 먼저 build 하세요)")
        with open(p, "rb") as f:
            data = f.read()
        if top.endswith(".py"):                 # 줄바꿈 통일(양식 xlsx 는 바이너리라 그대로)
            data = data.replace(b"\r\n", b"\n")
        embed[top] = base64.b64encode(data).decode("ascii")

    h = hashlib.sha1("".join(sorted(embed.values())).encode()).hexdigest()[:12]
    parts = [
        "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\n",
        ('r"""makereport_all.py — CSV/JSON 진단결과 → 결과보고서(xlsx) 단일 파일(자동 생성, 편집 금지).\n'
         "양식·변환코드를 내장한다. build_report_onefile.py 로 재생성.\n\n"
         "사용(파이썬3 + lxml 필요):\n"
         "  python makereport_all.py <입력폴더>            # 폴더 안 CSV/JSON 전부 → reports_out/\n"
         "  python makereport_all.py a.csv b.csv           # 파일 지정\n"
         "  python makereport_all.py --kind linux x.csv    # 종류 직접 지정\n"
         '"""\n'),
        "import base64 as _b64, os as _os, sys as _sys, tempfile as _tf\n\n",
        "_EMBED = {\n",
    ]
    for name, b in embed.items():
        parts.append(f"    {name!r}: {b!r},\n")
    parts.append("}\n\n")
    parts.append(f"_EMBED_ID = {h!r}\n\n")
    parts.append(
        "def _bootstrap():\n"
        "    d = _os.path.join(_tf.gettempdir(), 'makereport_embed_' + _EMBED_ID)\n"
        "    for _name, _b in _EMBED.items():\n"
        "        _p = _os.path.join(d, _name)\n"
        "        _os.makedirs(_os.path.dirname(_p), exist_ok=True)\n"
        "        _data = _b64.b64decode(_b)\n"
        "        try:\n"
        "            with open(_p, 'rb') as _f: _cur = _f.read()\n"
        "        except OSError:\n"
        "            _cur = None\n"
        "        if _cur != _data:\n"
        "            with open(_p, 'wb') as _f: _f.write(_data)\n"
        "    _os.environ['INFRA_DIR'] = d\n"
        "    if d in _sys.path: _sys.path.remove(d)\n"
        "    _sys.path.insert(0, d)\n"
        "    return d\n\n"
        "_DIR = _bootstrap()\n"
        "try:\n"
        "    import lxml.etree  # noqa: F401\n"
        "except Exception:\n"
        "    _sys.exit('[!] lxml 이 필요합니다:  pip install lxml   (또는 pip3 install --user lxml)')\n"
        "import make_reports  # noqa: E402\n\n"
        "if __name__ == '__main__':\n"
        "    make_reports.main()\n"
    )
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(parts))
    print(f"생성: {OUT}  ({os.path.getsize(OUT)} bytes, 내장 {len(embed)}개, id={h})")


if __name__ == "__main__":
    main()
