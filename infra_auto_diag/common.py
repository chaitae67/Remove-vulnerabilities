#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""공용 상수/헬퍼 — 모든 모듈이 공유한다.

여기에는 UI·엑셀·다이얼로그가 공통으로 쓰는 값만 둔다.
(SSH·표 로직은 kisa_gui.py, 엑셀은 excel_export.py 로 분리)
"""
import os
import tkinter as tk

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# OS 선택에 따라 원격에 올릴 점검 셸 스크립트
LOCAL_CHECK_LINUX = os.path.join(SCRIPT_DIR, "kisa_unix_check.sh")
LOCAL_CHECK_WINDOWS = os.path.join(SCRIPT_DIR, "kisa_win_check.ps1")
SCRIPT_BY_OS = {"linux": LOCAL_CHECK_LINUX, "windows": LOCAL_CHECK_WINDOWS}

# ---- OS별 원격 실행 설정 (경로/실행 명령을 Linux·Windows 로 분리) ----
#   linux   : /tmp 에 .sh 업로드 → bash 실행 (sudo 지원)
#   windows : SSH 홈(기본 %USERPROFILE%)에 .ps1 업로드 → PowerShell 실행 (sudo 없음)
#             경로는 SFTP 홈 기준 상대경로 → exec_command 의 cwd(홈)와 일치해 안전.
#             (절대경로가 필요하면 예: "C:/Windows/Temp/kisa_check.ps1" 로 바꾸면 됨)
REMOTE = {
    "linux": {
        "script": "/tmp/kisa_check.sh",
        "json":   "/tmp/kisa_result.json",
    },
    "windows": {
        "script": "kisa_check.ps1",
        "json":   "kisa_result.json",
    },
}


def build_run_cmd(osname, script, json_path, sudo_pw):
    """OS별 원격 실행 명령 문자열을 만든다.

    - linux  : bash 로 .sh 실행. sudo 비밀번호가 있으면 sudo -S(stdin 입력),
               없으면 sudo -n 시도 후 실패하면 일반 실행.
    - windows: PowerShell 로 .ps1 실행(sudo 개념 없음).
               kisa_win_check.ps1 은 -Json <경로> / -NoColor 파라미터를 받아
               그 경로에 결과 JSON 을 생성한다.
    두 경우 모두 점검 스크립트가 json_path 파일을 만들고, GUI 가 그 파일을 회수한다.
    (PowerShell 5.1 은 UTF-8 BOM 을 붙이므로 GUI 회수 시 utf-8-sig 로 디코딩)
    """
    if osname == "windows":
        return (f'powershell -NoProfile -ExecutionPolicy Bypass '
                f'-File "{script}" -Json "{json_path}" -NoColor')
    base = f"bash {script} --json {json_path} --no-color"
    if sudo_pw:
        return f"sudo -S -p '' {base}"
    return f"sudo -n {base} 2>/dev/null || {base}"

MANUAL_LABEL = "인터뷰 필요"
# 점검 스크립트 판정 / 검증자 최종판정 → 보고서 기재값
#   N/A(서비스·파일 미설치 → 점검 대상 없음) → "양호" 로 기재
#   수동확인(스크립트 용어)                    → "인터뷰 필요"(보고서 용어) 로 통일
REPORT_STATUS = {
    "양호": "양호", "취약": "취약", "N/A": "양호",
    "수동확인": MANUAL_LABEL, MANUAL_LABEL: MANUAL_LABEL,
}
# 검증자가 최종판정 대화상자에서 고를 수 있는 값 (N/A 는 양호로 처리하므로 제외)
FINAL_CHOICES = ("양호", "취약", "수동확인", MANUAL_LABEL)

STATUS_COLORS = {          # GUI 표(Treeview) 행 배경색
    "취약": "#f8d7da",
    "양호": "#d4edda",
    "N/A": "#fff3cd",
    "수동확인": "#d1ecf1",
    "인터뷰 필요": "#d1ecf1",
}

# 창 아이콘(logo.png) — 실행 위치와 무관하게 스크립트 폴더 기준, 없으면 조용히 무시
LOGO_PATH = os.path.join(SCRIPT_DIR, "logo.png")


def set_window_icon(win):
    try:
        img = tk.PhotoImage(file=LOGO_PATH)
        win._icon_ref = img          # GC 방지용 참조 유지
        win.iconphoto(False, img)
    except Exception:
        pass
