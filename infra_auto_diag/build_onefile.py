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
    # 1) 패키지 .py 를 base64 로 (cloud_check/*.py → 'cloud_check/이름')
    embed = {}
    #    작업트리 줄바꿈(core.autocrlf)과 무관하게 같은 결과가 나오도록 LF 로 맞춰 내장한다.
    for path in sorted(glob.glob(os.path.join(HERE, "cloud_check", "*.py"))):
        with open(path, "rb") as f:
            src = f.read().replace(b"\r\n", b"\n")
        embed["cloud_check/" + os.path.basename(path)] = base64.b64encode(src).decode("ascii")
    # 단일 파일에서도 공식 양식(5시트) 채우기가 되도록 생성기·양식·폴백을 내장(루트)
    tops = ["infra_report.py", "server_report.py",
            "보고서_양식_AWS.xlsx", "보고서_양식_Azure.xlsx",
            "보고서_양식_GCP.xlsx", "보고서_양식_Naver.xlsx"]
    for top in tops:
        p = os.path.join(HERE, top)
        if os.path.exists(p):
            with open(p, "rb") as f:
                data = f.read()
            if top.endswith(".py"):                     # 양식(xlsx)은 바이너리라 그대로
                data = data.replace(b"\r\n", b"\n")
            embed[top] = base64.b64encode(data).decode("ascii")

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
        "    for _name, _b in _EMBED.items():\n"
        "        _p = _os.path.join(d, *_name.split('/'))\n"
        "        _os.makedirs(_os.path.dirname(_p), exist_ok=True)\n"
        "        _data = _b64.b64decode(_b)\n"
        "        try:\n"
        "            with open(_p, 'rb') as _f: _cur = _f.read()\n"
        "        except OSError:\n"
        "            _cur = None\n"
        "        if _cur != _data:\n"
        "            with open(_p, 'wb') as _f: _f.write(_data)\n"
        "    if d in _sys.path:\n"
        "        _sys.path.remove(d)\n"
        "    _sys.path.insert(0, d)\n"
        "_bootstrap()\n"
        "# 내장 패키지를 먼저 import 해 둔다 — 아래 CLI 본문이 스크립트 폴더를 sys.path 맨 앞에 넣으므로,\n"
        "# 같은 폴더에 옛 cloud_check/ 가 남아 있으면 그쪽이 로드되는 것을 막는다.\n"
        "import cloud_check  # noqa: E402,F401\n\n"
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
