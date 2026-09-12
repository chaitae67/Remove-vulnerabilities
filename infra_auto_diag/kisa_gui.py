#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KISA 취약점 점검 GUI 도구 (원격 EC2/Linux SSH 실행기) — 메인 모듈

역할: 화면 구성 + SSH 실행(게이트웨이 경유) + 결과 표 관리(App 클래스가 상태 보유).
세부 기능은 모듈로 분리되어 있고, 이 파일은 그 모듈들을 호출한다.
    common.py         공용 상수/헬퍼
    excel_export.py   엑셀 추출 (양식/기본)
    gateway_dialog.py 게이트웨이 설정 다이얼로그
    detail_dialog.py  행 더블클릭 상세/최종판정

필요 패키지:  pip install paramiko openpyxl
실행:        python kisa_gui.py
"""
import os
import io
import json
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

try:
    import paramiko
except ImportError:
    paramiko = None

from common import (SCRIPT_BY_OS, LOCAL_CHECK_LINUX, REMOTE, build_run_cmd,
                    STATUS_COLORS, MANUAL_LABEL, REPORT_STATUS, set_window_icon,
                    CLOUD_TARGETS, TARGET_LABEL, is_cloud)
import excel_export
import gateway_dialog
import detail_dialog
import cloud_dialog
import cloud_check


class App:
    def __init__(self, root):
        self.root = root
        self.results = []          # 회수된 점검 결과 리스트
        self.host_label = ""
        self.os_label = ""
        self.conn_host = ""
        self.family = "linux"      # 점검 결과 계열 (linux / windows / cloud) — 엑셀 양식 선택에 사용
        self.cloud_creds = {}      # {csp: {자격증명 dict}}  — 클라우드 진단용
        self._cloud_vars = {}      # 현재 표시 중인 클라우드 폼의 입력 변수
        self.mode = None           # "infra" | "cloud"  (UI 에서 설정)
        # 게이트웨이(bastion) 경유 설정
        self.gateway = {"enabled": False, "host": "", "port": 22, "user": "team",
                        "auth": "password", "password": "", "key": ""}
        root.title("취약점 빼기 팀 infra 진단 자동화 툴")
        root.geometry("1000x680")
        self._build_ui()

    # ---------------- UI 구성 ----------------
    def _build_ui(self):
        # 모드 선택: 인프라(서버 SSH) / 클라우드(CSP API)
        modebar = ttk.Frame(self.root)
        modebar.pack(fill="x", padx=10, pady=(8, 0))
        self.mode = tk.StringVar(value="infra")
        ttk.Label(modebar, text="진단 유형:").pack(side="left", padx=(2, 8))
        ttk.Radiobutton(modebar, text="인프라 진단(서버)", variable=self.mode,
                        value="infra", command=self._on_mode_change).pack(side="left")
        ttk.Radiobutton(modebar, text="클라우드 진단(AWS/Azure/GCP)", variable=self.mode,
                        value="cloud", command=self._on_mode_change).pack(side="left", padx=8)

        # 상단: (접속 정보 | 클라우드 자격증명) + 진단 대상 좌우 분할
        top = ttk.Frame(self.root)
        top.pack(fill="x", padx=10, pady=8)
        top.columnconfigure(0, weight=8)
        top.columnconfigure(1, weight=2)

        conn = ttk.LabelFrame(top, text="접속 정보")
        conn.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        self.conn_frame = conn

        # 클라우드 자격증명(인라인) — conn 과 같은 칸을 공유, 모드에 따라 토글
        self.cloudf = ttk.LabelFrame(top, text="클라우드 자격증명")
        self.cloudf.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        self.cloudf.grid_remove()

        osf = ttk.LabelFrame(top, text="진단 대상")
        osf.grid(row=0, column=1, sticky="nsew")
        self.os_choice = tk.StringVar(value="linux")
        self._targets_holder = ttk.Frame(osf)
        self._targets_holder.pack(anchor="w", fill="x")
        self.lbl_os_script = ttk.Label(osf, text="", foreground="#555", wraplength=180)
        self.lbl_os_script.pack(anchor="w", padx=10, pady=(4, 8))

        # 1행: 호스트/포트/계정
        r1 = ttk.Frame(conn); r1.pack(fill="x", padx=8, pady=4)
        ttk.Label(r1, text="IP/호스트").grid(row=0, column=0, sticky="w")
        self.e_host = ttk.Entry(r1, width=24); self.e_host.grid(row=0, column=1, padx=6)
        ttk.Label(r1, text="포트").grid(row=0, column=2, sticky="w")
        self.e_port = ttk.Entry(r1, width=6); self.e_port.insert(0, "22"); self.e_port.grid(row=0, column=3, padx=6)
        ttk.Label(r1, text="계정(ID)").grid(row=0, column=4, sticky="w")
        self.e_user = ttk.Entry(r1, width=16); self.e_user.insert(0, "team"); self.e_user.grid(row=0, column=5, padx=6)

        # 2행: 인증 방식
        r2 = ttk.Frame(conn); r2.pack(fill="x", padx=8, pady=4)
        self.auth = tk.StringVar(value="password")
        ttk.Radiobutton(r2, text="비밀번호", variable=self.auth, value="password",
                        command=self._toggle_auth).grid(row=0, column=0, sticky="w")
        ttk.Radiobutton(r2, text="SSH 키", variable=self.auth, value="key",
                        command=self._toggle_auth).grid(row=0, column=1, sticky="w", padx=(0, 12))

        ttk.Label(r2, text="비밀번호").grid(row=0, column=2, sticky="w")
        self.e_pass = ttk.Entry(r2, width=18, show="*"); self.e_pass.grid(row=0, column=3, padx=6)

        ttk.Label(r2, text="키 파일").grid(row=0, column=4, sticky="w")
        self.e_key = ttk.Entry(r2, width=26); self.e_key.grid(row=0, column=5, padx=6)
        self.btn_key = ttk.Button(r2, text="찾기", width=6, command=self._browse_key)
        self.btn_key.grid(row=0, column=6)
        self.btn_gw = ttk.Button(r2, text="게이트웨이 설정", command=self._open_gateway_dialog)
        self.btn_gw.grid(row=0, column=7, padx=(10, 0))

        # 3행: sudo 비밀번호 + 실행 버튼
        r3 = ttk.Frame(conn); r3.pack(fill="x", padx=8, pady=4)
        ttk.Label(r3, text="sudo 비밀번호(선택)").grid(row=0, column=0, sticky="w")
        self.e_sudo = ttk.Entry(r3, width=18, show="*"); self.e_sudo.grid(row=0, column=1, padx=6)

        self._toggle_auth()

        # 버튼들을 한 행에 묶어줄 프레임 생성
        self.btn_frame = ttk.Frame(self.root)
        self.btn_frame.pack(fill="x", padx=12)  # 양옆 여백 설정

        # 상태 라벨
        self.lbl_sum = ttk.Label(self.btn_frame, text="대기 중…", anchor="w")
        self.lbl_sum.pack(side="left", padx=12, pady=5)

        # 엑셀 버튼 (오른쪽 정렬을 위해 오른쪽부터 채워 넣음)
        self.btn_xlsx = ttk.Button(self.btn_frame, text="엑셀로 추출", command=self.on_export, state="disabled")
        self.btn_xlsx.pack(side="right", padx=2)

        # 점검 실행 버튼 (엑셀 버튼 왼쪽에 배치됨)
        self.btn_run = ttk.Button(self.btn_frame, text="▶ 점검 실행", command=self.on_run)
        self.btn_run.pack(side="right", padx=2)

        # 결과 표
        table_frame = ttk.Frame(self.root)
        table_frame.pack(fill="both", expand=True, padx=10, pady=6)
        cols = ("code", "imp", "title", "auto", "final", "evidence")
        self.tree = ttk.Treeview(table_frame, columns=cols, show="headings")
        self._col_title = {"code": "코드", "imp": "중요도", "title": "점검 항목",
                           "auto": "최초판정", "final": "최종판정", "evidence": "근거"}
        self._sort_key = None
        self._sort_rev = False
        for c, w in (("code", 60), ("imp", 55), ("title", 240),
                     ("auto", 75), ("final", 75), ("evidence", 430)):
            self.tree.heading(c, text=self._col_title[c],
                              command=lambda cc=c: self._sort_col(cc))
            self.tree.column(c, width=w, anchor="w")
        vsb = ttk.Scrollbar(table_frame, orient="vertical", command=self.tree.yview)
        hsb = ttk.Scrollbar(table_frame, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=vsb.set, xscrollcommand=hsb.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        vsb.grid(row=0, column=1, sticky="ns")
        hsb.grid(row=1, column=0, sticky="ew")
        table_frame.rowconfigure(0, weight=1)
        table_frame.columnconfigure(0, weight=1)
        for st, color in STATUS_COLORS.items():
            self.tree.tag_configure(st, background=color)
        self.tree.bind("<Double-1>", self._on_row_dblclick)
        ttk.Label(self.root,
                  text="↳ 행 더블클릭 → 최종판정(양호/취약/인터뷰 필요) 지정.  열 머리글 클릭 → 정렬(최종판정/자동판정 클릭 시 판정별로 묶임).  엑셀은 '최종판정' 기준 추출, 취약은 빨강.",
                  foreground="#555").pack(fill="x", padx=12)

        # 로그
        logf = ttk.LabelFrame(self.root, text="로그")
        logf.pack(fill="x", padx=10, pady=6)
        self.txt = tk.Text(logf, height=7, wrap="word")
        self.txt.pack(fill="x", padx=4, pady=4)

        if paramiko is None:
            self.log("⚠ paramiko 미설치 → 터미널에서:  pip install paramiko")
        if excel_export.openpyxl is None:
            self.log("⚠ openpyxl 미설치 → 터미널에서:  pip install openpyxl")
        self._on_mode_change()   # 모드/대상 라디오·폼 초기화

    # ---------------- 진단 대상 선택 ----------------
    def local_check(self):
        """현재 선택된 OS 에 해당하는 로컬 점검 스크립트 경로."""
        return SCRIPT_BY_OS.get(self.os_choice.get(), LOCAL_CHECK_LINUX)

    _TARGETS = {"infra": (("Linux 서버", "linux"), ("Windows 서버", "windows")),
                "cloud": (("AWS", "aws"), ("Azure", "azure"), ("GCP", "gcp"))}

    def _on_mode_change(self):
        mode = self.mode.get()
        # 대상 라디오 다시 그리기
        for w in self._targets_holder.winfo_children():
            w.destroy()
        opts = self._TARGETS[mode]
        if self.os_choice.get() not in [v for _, v in opts]:
            self.os_choice.set(opts[0][1])
        for txt, val in opts:
            ttk.Radiobutton(self._targets_holder, text=txt, variable=self.os_choice,
                            value=val, command=self._on_os_change).pack(anchor="w", padx=10, pady=1)
        # 접속 정보 ↔ 클라우드 자격증명 패널 토글
        if mode == "cloud":
            self.conn_frame.grid_remove()
            self.cloudf.grid()
        else:
            self.cloudf.grid_remove()
            self.conn_frame.grid()
        self._on_os_change()

    def _on_os_change(self):
        target = self.os_choice.get()
        if is_cloud(target):
            self._build_cloud_form(target)
            if not cloud_check.available(target):
                self.lbl_os_script.configure(
                    text=f"{TARGET_LABEL[target]} SDK 미설치 → pip install "
                         f"{cloud_check.missing_package(target)}", foreground="#c00")
            else:
                self.lbl_os_script.configure(
                    text=f"{TARGET_LABEL[target]} API 진단 (읽기 전용)", foreground="#555")
            self.btn_run.configure(text="▶ 클라우드 진단")
            return
        # 서버(SSH) 모드
        self.btn_run.configure(text="▶ 점검 실행")
        p = self.local_check()
        name = os.path.basename(p)
        if os.path.exists(p):
            self.lbl_os_script.configure(text="실행: " + name, foreground="#555")
        else:
            self.lbl_os_script.configure(text="실행: " + name + "  (파일 없음!)",
                                         foreground="#c00")
            self.log(f"점검 스크립트 없음: {p}")

    def _build_cloud_form(self, csp):
        """선택한 CSP 에 맞는 자격증명 입력 필드를 cloudf 안에 그린다."""
        for w in self.cloudf.winfo_children():
            w.destroy()
        self._cloud_vars = {}
        spec = cloud_dialog.CLOUD_FIELDS[csp]
        ttk.Label(self.cloudf, text=spec["note"], foreground="#666",
                  wraplength=620).grid(row=0, column=0, columnspan=3, sticky="w",
                                       padx=8, pady=(6, 4))
        saved = self.cloud_creds.get(csp, {})
        for i, (label, key, secret, default) in enumerate(spec["fields"], start=1):
            ttk.Label(self.cloudf, text=label).grid(row=i, column=0, sticky="w",
                                                    padx=(10, 6), pady=3)
            var = tk.StringVar(value=saved.get(key, default))
            ent = ttk.Entry(self.cloudf, textvariable=var, width=52,
                            show="*" if secret else "")
            ent.grid(row=i, column=1, sticky="ew", pady=3)
            self._cloud_vars[key] = var
            if key == "sa_key_path":
                ttk.Button(self.cloudf, text="찾기", width=6,
                           command=self._browse_sa_key).grid(row=i, column=2, padx=4)
        self.cloudf.columnconfigure(1, weight=1)

    def _browse_sa_key(self):
        p = filedialog.askopenfilename(title="서비스계정 키(JSON)",
                                       filetypes=[("JSON", "*.json")])
        if p and "sa_key_path" in self._cloud_vars:
            self._cloud_vars["sa_key_path"].set(p)

    def _collect_cloud_creds(self, csp):
        raw = {k: v.get() for k, v in self._cloud_vars.items()}
        creds = cloud_dialog.normalize_creds(csp, raw)
        self.cloud_creds[csp] = creds
        return creds

    def _toggle_auth(self):
        if self.auth.get() == "password":
            self.e_pass.configure(state="normal")
            self.e_key.configure(state="disabled")
            self.btn_key.configure(state="disabled")
        else:
            self.e_pass.configure(state="disabled")
            self.e_key.configure(state="normal")
            self.btn_key.configure(state="normal")

    def _browse_key(self):
        path = filedialog.askopenfilename(title="SSH 개인키 선택")
        if path:
            self.e_key.delete(0, "end")
            self.e_key.insert(0, path)

    # ---------------- 게이트웨이 설정 (모듈 위임) ----------------
    def _open_gateway_dialog(self):
        gateway_dialog.open_gateway(self)

    def _refresh_gw_button(self):
        g = self.gateway
        if g["enabled"] and g["host"]:
            self.btn_gw.configure(text=f"게이트웨이 ✓ ({g['host']})")
        else:
            self.btn_gw.configure(text="게이트웨이 설정")

    # ---------------- SSH 클라이언트 생성 (게이트웨이 지원) ----------------
    def _make_client(self, host, port, user, auth, password, key, sock=None):
        cli = paramiko.SSHClient()
        cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        kw = dict(hostname=host, port=port, username=user,
                  timeout=15, banner_timeout=15, auth_timeout=15)
        if sock is not None:
            kw["sock"] = sock
        if auth == "key":
            if not key or not os.path.exists(key):
                raise RuntimeError(f"키 파일 경로가 올바르지 않습니다: {key}")
            kw["key_filename"] = key
        else:
            kw["password"] = password
            kw["look_for_keys"] = False
            kw["allow_agent"] = False
        cli.connect(**kw)
        return cli

    # ---------------- 스레드 안전 UI 갱신 ----------------
    def log(self, msg):
        self.root.after(0, self._log, msg)

    def _log(self, msg):
        self.txt.insert("end", msg + "\n")
        self.txt.see("end")

    def set_busy(self, busy):
        self.root.after(0, lambda: self.btn_run.configure(state="disabled" if busy else "normal"))

    # ---------------- 실행 ----------------
    def on_run(self):
        target = self.os_choice.get()
        if is_cloud(target):
            self._run_cloud(target)
            return
        if paramiko is None:
            messagebox.showerror("의존성 오류", "paramiko가 필요합니다.\npip install paramiko")
            return
        script = self.local_check()
        if not os.path.exists(script):
            messagebox.showerror("파일 없음", f"점검 스크립트를 찾을 수 없습니다:\n{script}")
            return
        host = self.e_host.get().strip()
        if not host:
            messagebox.showwarning("입력 필요", "IP/호스트를 입력하세요.")
            return
        params = dict(
            host=host,
            port=int(self.e_port.get().strip() or "22"),
            user=self.e_user.get().strip() or "ec2-user",
            auth=self.auth.get(),
            password=self.e_pass.get(),
            key=self.e_key.get().strip(),
            sudo=self.e_sudo.get(),
            script=script,
            osname=self.os_choice.get(),
        )
        self.set_busy(True)
        self._clear_table()
        self.lbl_sum.configure(text="점검 실행 중…")
        threading.Thread(target=self._worker, args=(params,), daemon=True).start()

    # ---------------- 클라우드 진단 ----------------
    def _run_cloud(self, target):
        if not cloud_check.available(target):
            messagebox.showerror(
                "SDK 미설치",
                f"{TARGET_LABEL[target]} 진단에는 SDK가 필요합니다.\n"
                f"pip install {cloud_check.missing_package(target)}")
            return
        creds = self._collect_cloud_creds(target)
        # 필수값 안내 (비우면 환경/ADC 자격 시도)
        need = {"azure": ["subscription_id"], "gcp": ["project_id"]}.get(target, [])
        missing = [k for k in need if not creds.get(k)]
        if missing:
            messagebox.showwarning(
                "입력 필요",
                {"subscription_id": "Subscription ID 를 입력하세요.",
                 "project_id": "Project ID 를 입력하세요."}[missing[0]])
            return
        self.set_busy(True)
        self._clear_table()
        self.lbl_sum.configure(text=f"{TARGET_LABEL[target]} 진단 실행 중…")
        threading.Thread(target=self._cloud_worker, args=(target, creds),
                         daemon=True).start()

    def _cloud_worker(self, target, creds):
        try:
            self.log(f"[{TARGET_LABEL[target]}] API 진단 시작 "
                     f"(READ-ONLY, describe/list/get 만 호출)")
            data = cloud_check.run(target, creds)
            self.host_label = data.get("host", TARGET_LABEL[target])
            self.os_label = data.get("os", TARGET_LABEL[target])
            self.conn_host = data.get("host", "")
            self.results = data.get("results", [])
            self.family = (data.get("family", "") or "cloud").lower()
            self.log(f"      완료: {len(self.results)}개 항목 "
                     f"(대상: {self.os_label}, 계열: {self.family})")
            self.root.after(0, self._show_results)
        except Exception as e:
            self.log(f"오류: {e}")
            self.root.after(0, lambda: messagebox.showerror("클라우드 진단 오류", str(e)))
            self.root.after(0, lambda: self.lbl_sum.configure(text="오류 발생"))
        finally:
            self.set_busy(False)

    def _worker(self, p):
        client = None
        gw_client = None
        try:
            g = self.gateway
            sock = None
            if g.get("enabled"):
                if not g.get("host"):
                    raise RuntimeError("게이트웨이 사용이 켜져 있지만 Bastion IP 공백.")
                self.log(f"[게이트웨이] {g['host']}:{g['port']} ({g['user']}) 접속 중…")
                gw_client = self._make_client(g["host"], g["port"], g["user"],
                                              g["auth"], g["password"], g["key"])
                self.log("      게이트웨이 접속 성공")
                tr = gw_client.get_transport()
                sock = tr.open_channel("direct-tcpip",
                                       (p["host"], p["port"]), ("127.0.0.1", 0))
                self.log(f"      터널 생성: bastion → {p['host']}:{p['port']}")

            via = " (게이트웨이 경유)" if sock else ""
            self.log(f"[1/4] {p['host']}:{p['port']} ({p['user']}) 접속 중…{via}")
            client = self._make_client(p["host"], p["port"], p["user"],
                                       p["auth"], p["password"], p["key"], sock=sock)
            self.log("      접속 성공")

            # OS별 원격 경로/실행 명령 (linux=/tmp+bash, windows=홈+powershell)
            cfg = REMOTE.get(p["osname"], REMOTE["linux"])
            r_script, r_json = cfg["script"], cfg["json"]

            self.log(f"[2/4] 점검 스크립트 업로드… ({os.path.basename(p['script'])} → {r_script})")
            sftp = client.open_sftp()
            if p["osname"] == "windows":
                sftp.put(p["script"], r_script)
            else:
                # Windows에서 편집·저장한 .sh 는 CRLF 가 섞여 원격 bash 가 깨진다
                # (line X: $'\r': command not found / syntax error). LF 로 정규화해 업로드.
                with open(p["script"], "rb") as f:
                    body = f.read().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
                sftp.putfo(io.BytesIO(body), r_script)

            self.log("[3/4] 원격 점검 실행 (수 초~수십 초 소요)…")
            cmd = build_run_cmd(p["osname"], r_script, r_json, p["sudo"])
            stdin, stdout, stderr = client.exec_command(cmd, get_pty=True, timeout=600)
            if p["osname"] != "windows" and p["sudo"]:
                stdin.write(p["sudo"] + "\n")
                stdin.flush()
            stdout.channel.recv_exit_status()   # 완료 대기

            self.log("[4/4] 결과 회수…")
            buf = io.BytesIO()
            sftp.getfo(r_json, buf)
            # PowerShell 5.1 은 UTF-8 BOM 을 붙이므로 utf-8-sig 로 디코딩(리눅스는 BOM 없어 동일)
            data = json.loads(buf.getvalue().decode("utf-8-sig", "replace"))
            # 원격 임시파일 정리
            try:
                sftp.remove(r_json); sftp.remove(r_script)
            except Exception:
                pass
            sftp.close()

            self.host_label = data.get("host", p["host"])
            self.os_label = data.get("os", "")
            self.conn_host = p["host"]
            self.results = data.get("results", [])
            self.family = (data.get("family", "") or p["osname"] or "linux").lower()
            self.log(f"      완료: {len(self.results)}개 항목 "
                     f"(OS: {data.get('os','?')}, 계열: {self.family})")
            self.root.after(0, self._show_results)
        except Exception as e:
            self.log(f"✖ 오류: {e}")
            self.root.after(0, lambda: messagebox.showerror("실행 오류", str(e)))
            self.root.after(0, lambda: self.lbl_sum.configure(text="오류 발생"))
        finally:
            if client:
                client.close()
            if gw_client:
                gw_client.close()
            self.set_busy(False)

    # ---------------- 결과 표시 ----------------
    def _clear_table(self):
        for i in self.tree.get_children():
            self.tree.delete(i)

    def _show_results(self):
        self._clear_table()
        self._sort_key = None
        self._sort_rev = False
        for c in ("code", "imp", "title", "auto", "final", "evidence"):
            self.tree.heading(c, text=self._col_title[c])
        for idx, r in enumerate(self.results):
            # 최종판정 초기값 = 자동판정을 보고서 용어로 (N/A→양호, 수동확인→인터뷰 필요)
            r.setdefault("final", REPORT_STATUS.get(r.get("status", ""), r.get("status", "")))
            r.setdefault("note", "")                      # 검증자 비고
            self._insert_row(idx, r)
        self._update_summary()
        self.btn_xlsx.configure(state="normal" if self.results else "disabled")

    # 판정 정렬 우선순위 (양호 → 취약 → 인터뷰 필요)
    _VERDICT_ORDER = {"양호": 0, "취약": 1, "수동확인": 2, "인터뷰 필요": 2, "N/A": 0}
    _IMP_ORDER = {"상": 0, "중": 1, "하": 2}

    def _sort_col(self, col):
        """열 머리글 클릭 → 해당 열 기준 정렬. 같은 열 다시 클릭하면 역순."""
        self._sort_rev = (not self._sort_rev) if self._sort_key == col else False
        self._sort_key = col

        def keyfn(iid):
            r = self.results[int(iid)]
            code = r.get("code", "")
            if col == "final":
                v = self._VERDICT_ORDER.get(r.get("final") or r.get("status", ""), 9)
                return (v, code)                      # 판정 묶고, 그 안에서는 코드순
            if col == "auto":
                return (self._VERDICT_ORDER.get(r.get("status", ""), 9), code)
            if col == "imp":
                return (self._IMP_ORDER.get(r.get("importance", ""), 9), code)
            if col == "title":
                return (r.get("title", ""), code)
            if col == "evidence":
                return (" / ".join(r.get("evidence", [])), code)
            return code

        items = sorted(self.tree.get_children(""), key=keyfn, reverse=self._sort_rev)
        for pos, iid in enumerate(items):
            self.tree.move(iid, "", pos)
        arrow = " ▼" if self._sort_rev else " ▲"
        for c in ("code", "imp", "title", "auto", "final", "evidence"):
            self.tree.heading(c, text=self._col_title[c] + (arrow if c == col else ""))

    def _insert_row(self, idx, r):
        fin = r.get("final", r.get("status", ""))
        auto = REPORT_STATUS.get(r.get("status", ""), r.get("status", ""))  # 표시용(수동확인→인터뷰 필요)
        self.tree.insert("", "end", iid=str(idx),
                         values=(r.get("code", ""), r.get("importance", ""),
                                 r.get("title", ""), auto, fin,
                                 " / ".join(r.get("evidence", []))),
                         tags=(fin,))

    def _update_row(self, idx):
        r = self.results[idx]
        fin = r.get("final", r.get("status", ""))
        auto = REPORT_STATUS.get(r.get("status", ""), r.get("status", ""))
        self.tree.item(str(idx),
                       values=(r.get("code", ""), r.get("importance", ""),
                               r.get("title", ""), auto, fin,
                               " / ".join(r.get("evidence", []))),
                       tags=(fin,))

    def _update_summary(self):
        cnt = {}
        for r in self.results:
            f = r.get("final", r.get("status", ""))
            f = REPORT_STATUS.get(f, f)              # N/A→양호, 수동확인→인터뷰 필요
            cnt[f] = cnt.get(f, 0) + 1
        self.lbl_sum.configure(
            text=f"[{self.host_label}]  (최종판정 기준)  양호 {cnt.get('양호', 0)}   "
                 f"취약 {cnt.get('취약', 0)}   인터뷰필요 {cnt.get(MANUAL_LABEL, 0)}   "
                 f"(총 {len(self.results)})")

    # ---------------- 행 더블클릭 → 상세/최종판정 (모듈 위임) ----------------
    def _on_row_dblclick(self, event):
        iid = self.tree.identify_row(event.y)
        if iid != "":
            detail_dialog.open_detail(self, int(iid))

    # ---------------- 엑셀 추출 (모듈 위임) ----------------
    def on_export(self):
        excel_export.export(self)


def main():
    root = tk.Tk()
    set_window_icon(root)
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
