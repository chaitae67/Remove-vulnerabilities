#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""클라우드 진단 공용 헬퍼 — CSP 모듈이 공유한다."""

# 진단 결과 상태값 (서버 진단과 동일)
GOOD = "양호"
VULN = "취약"
NA = "N/A"
MAN = "수동확인"      # 정책/인터뷰 필요 → 보고서에선 "인터뷰 필요"


class Reporter:
    """항목 메타(코드/제목/중요도/기준)를 미리 담아두고, 판정만 채워 넣는다.

    items : {code: {"title":..., "imp":"상|중|하", "crit":"양호 - ...\\n취약 - ...", "path":...}}
    """

    def __init__(self, items):
        self.items = items
        self._out = {}        # code -> result dict

    def rep(self, code, status, evidence, resources=None):
        meta = self.items.get(code, {})
        if isinstance(evidence, str):
            evidence = [evidence]
        self._out[code] = {
            "code": code,
            "importance": meta.get("imp", ""),
            "title": meta.get("title", code),
            "status": status,
            "evidence": [e for e in (evidence or []) if e],
            "resources": resources or [],
            "criteria": meta.get("crit", ""),
            "path": meta.get("path", ""),
        }

    def good(self, code, ev, res=None): self.rep(code, GOOD, ev, res)
    def vuln(self, code, ev, res=None): self.rep(code, VULN, ev, res)
    def na(self, code, ev, res=None):   self.rep(code, NA, ev, res)
    def man(self, code, ev, res=None):  self.rep(code, MAN, ev, res)

    def done(self, code):
        return code in self._out

    def fill_missing(self, status=MAN, note="점검 로직 미구현 또는 조회 실패 → 수동 확인 필요"):
        """rep() 호출이 안 된 항목을 일괄 채운다(항상 41/41 행이 나오도록)."""
        for code, meta in self.items.items():
            if code not in self._out:
                self.rep(code, status, note)

    def results(self):
        """항목 코드 순서(1.1, 1.2, ... 4.15)대로 정렬해서 반환."""
        def key(c):
            try:
                a, b = c.split(".")
                return (int(a), int(b))
            except Exception:
                return (99, 99)
        return [self._out[c] for c in sorted(self._out, key=key)]


def safe(reporter, code, fn):
    """fn() 을 호출하되 권한오류/일시오류는 '수동확인'으로 흡수한다.

    fn 은 판정을 직접 reporter.rep(...) 로 기록해야 한다.
    """
    try:
        fn()
    except PermissionError as e:
        reporter.man(code, f"권한 부족으로 조회 불가: {e}")
    except Exception as e:
        name = type(e).__name__
        # boto3 AccessDenied 류
        if "AccessDenied" in str(e) or "UnauthorizedOperation" in str(e) or "AuthorizationError" in str(e):
            reporter.man(code, f"권한 부족으로 조회 불가 ({name}): {e}")
        else:
            reporter.man(code, f"조회 중 오류 ({name}): {e}")
