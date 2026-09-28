#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cloudscan_all.py 단일 파일 생성기.

cloud_check/ 패키지(.py) 전체를 base64 로 cloud_scan.py 안에 심어서
'파일 하나만 넣으면 돌아가는' cloudscan_all.py 를 만든다.
패키지/CLI 를 수정하면 이 스크립트를 다시 실행해 재생성한다:

    python build_onefile.py     # → cloudscan_all.py
"""
import base64
import glob
import hashlib
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "cloudscan_all.py")


def main():
    # 1) 패키지 .py 를 base64 로
    embed = {}
    for path in sorted(glob.glob(os.path.join(HERE, "cloud_check", "*.py"))):
        rel = os.path.basename(path)
        with open(path, "rb") as f:
            embed[rel] = base64.b64encode(f.read()).decode("ascii")

    # 2) cloud_scan.py 본문(부트스트랩이 cloud_check 를 먼저 심은 뒤 실행됨)
    with io.open(os.path.join(HERE, "cloud_scan.py"), encoding="utf-8") as f:
        cli_body = f.read()

    h = hashlib.sha1("".join(sorted(embed.values())).encode()).hexdigest()[:12]

    parts = []
    parts.append("#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\n")
    parts.append('"""cloudscan_all.py — 단일 파일 클라우드 진단 스크립트(자동 생성, 편집 금지).\n'
                 "cloud_check/ 패키지를 내장한다. build_onefile.py 로 재생성한다.\n"
                 "실행: python cloudscan_all.py <aws|azure|gcp|naver> [옵션]  (README 참고)\n"
                 '"""\n')
    parts.append("import base64 as _b64, os as _os, sys as _sys, tempfile as _tf\n\n")
    parts.append("_EMBED = {\n")
    for name, b in embed.items():
        parts.append(f"    {name!r}: {b!r},\n")
    parts.append("}\n\n")
    parts.append(f"_EMBED_ID = {h!r}\n\n")
    parts.append(
        "def _bootstrap():\n"
        "    d = _os.path.join(_tf.gettempdir(), 'cloud_check_embed_' + _EMBED_ID)\n"
        "    pkg = _os.path.join(d, 'cloud_check')\n"
        "    _os.makedirs(pkg, exist_ok=True)\n"
        "    for _name, _b in _EMBED.items():\n"
        "        _p = _os.path.join(pkg, _name)\n"
        "        _data = _b64.b64decode(_b)\n"
        "        try:\n"
        "            with open(_p, 'rb') as _f: _cur = _f.read()\n"
        "        except OSError:\n"
        "            _cur = None\n"
        "        if _cur != _data:\n"
        "            with open(_p, 'wb') as _f: _f.write(_data)\n"
        "    if d not in _sys.path:\n"
        "        _sys.path.insert(0, d)\n"
        "_bootstrap()\n\n"
        "# ==================== cloud_scan.py 본문 ====================\n"
    )
    # cli_body 의 shebang/coding 줄은 주석이라 그대로 둬도 무해
    parts.append(cli_body)

    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(parts))
    size = os.path.getsize(OUT)
    print(f"생성: {OUT}  ({size} bytes, 내장 {len(embed)}개 모듈, id={h})")


if __name__ == "__main__":
    main()
