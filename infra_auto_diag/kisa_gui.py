#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KISA 취약점 점검 GUI 도구 (원격 EC2/Linux SSH 실행기)
- 접속정보(IP/포트/계정/비밀번호 또는 SSH키)를 입력하고 [점검 실행]을 누르면
  같은 폴더의 kisa_check.py 를 원격 서버 /tmp 에 올려 실행하고,
  결과(JSON)를 회수해 표에 표시합니다.
- [엑셀로 추출] 버튼으로 .xlsx 저장.
- 읽기 전용 점검 스크립트를 실행하며, 접속정보는 화면 입력값만 사용합니다(저장/전송 안 함).

필요 패키지:
    pip install paramiko openpyxl
실행:
    python kisa_gui.py
"""
import os
import io
import json
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

# ---- 선택적 의존성 (없으면 안내) ----
try:
    import paramiko
except ImportError:
    paramiko = None
try:
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment
except ImportError:
    openpyxl = None

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_CHECK = os.path.join(SCRIPT_DIR, "kisa_unix_check.sh")  # 원격에 올릴 점검 셸 스크립트
REMOTE_SCRIPT = "/tmp/kisa_check.sh"
REMOTE_JSON = "/tmp/kisa_result.json"

# 결과보고서 양식(같은 폴더). 있으면 이 서식 그대로 채워서 저장한다.
REPORT_TEMPLATE = os.path.join(SCRIPT_DIR, "보고서_양식_Linux.xlsx")
RESULT_SHEET = "3-1. 진단 결과(Linux)"
TARGET_SHEET = "1. 진단 대상"

STATUS_COLORS = {          # 표 행 배경색
    "취약": "#f8d7da",
    "양호": "#d4edda",
    "N/A": "#fff3cd",
    "수동확인": "#d1ecf1",
}
XLSX_FILL = {              # 엑셀 셀 채우기
    "취약": "F8D7DA",
    "양호": "D4EDDA",
    "N/A": "FFF3CD",
    "수동확인": "D1ECF1",
}


class App:
    def __init__(self, root):
        self.root = root
        self.results = []          # 회수된 점검 결과 리스트
        self.host_label = ""
        self.os_label = ""
        self.conn_host = ""
        # 게이트웨이(bastion) 경유 설정
        self.gateway = {"enabled": False, "host": "", "port": 22, "user": "ec2-user",
                        "auth": "password", "password": "", "key": ""}
        root.title("KISA Unix 취약점 점검 도구 (SSH)")
        root.geometry("1000x680")
        self._build_ui()

    # ---------------- UI 구성 ----------------
    def _build_ui(self):
        conn = ttk.LabelFrame(self.root, text="접속 정보")
        conn.pack(fill="x", padx=10, pady=8)

        # 1행: 호스트/포트/계정
        r1 = ttk.Frame(conn); r1.pack(fill="x", padx=8, pady=4)
        ttk.Label(r1, text="IP/호스트").grid(row=0, column=0, sticky="w")
        self.e_host = ttk.Entry(r1, width=24); self.e_host.grid(row=0, column=1, padx=6)
        ttk.Label(r1, text="포트").grid(row=0, column=2, sticky="w")
        self.e_port = ttk.Entry(r1, width=6); self.e_port.insert(0, "22"); self.e_port.grid(row=0, column=3, padx=6)
        ttk.Label(r1, text="계정(ID)").grid(row=0, column=4, sticky="w")
        self.e_user = ttk.Entry(r1, width=16); self.e_user.insert(0, "ec2-user"); self.e_user.grid(row=0, column=5, padx=6)

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
        ttk.Label(r3, text="(NOPASSWD sudo면 비워두세요)").grid(row=0, column=2, sticky="w")

        self.btn_run = ttk.Button(r3, text="▶ 점검 실행", command=self.on_run)
        self.btn_run.grid(row=0, column=3, padx=12)
        self.btn_xlsx = ttk.Button(r3, text="⬇ 엑셀로 추출", command=self.on_export, state="disabled")
        self.btn_xlsx.grid(row=0, column=4)

        self._toggle_auth()

        # 상태 라벨
        self.lbl_sum = ttk.Label(self.root, text="대기 중…", anchor="w")
        self.lbl_sum.pack(fill="x", padx=12)

        # 결과 표
        table_frame = ttk.Frame(self.root)
        table_frame.pack(fill="both", expand=True, padx=10, pady=6)
        cols = ("code", "imp", "title", "status", "evidence")
        self.tree = ttk.Treeview(table_frame, columns=cols, show="headings")
        for c, t, w in (("code", "코드", 70), ("imp", "중요도", 60), ("title", "점검 항목", 260),
                        ("status", "판정", 80), ("evidence", "근거", 500)):
            self.tree.heading(c, text=t)
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

        # 로그
        logf = ttk.LabelFrame(self.root, text="로그")
        logf.pack(fill="x", padx=10, pady=6)
        self.txt = tk.Text(logf, height=7, wrap="word")
        self.txt.pack(fill="x", padx=4, pady=4)

        if paramiko is None:
            self.log("⚠ paramiko 미설치 → 터미널에서:  pip install paramiko")
        if openpyxl is None:
            self.log("⚠ openpyxl 미설치 → 터미널에서:  pip install openpyxl")
        if not os.path.exists(LOCAL_CHECK):
            self.log(f"⚠ 점검 스크립트 없음: {LOCAL_CHECK} (kisa_check.py를 같은 폴더에 두세요)")

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

    # ---------------- 게이트웨이(bastion) 설정 다이얼로그 ----------------
    def _open_gateway_dialog(self):
        g = self.gateway
        dlg = tk.Toplevel(self.root)
        dlg.title("게이트웨이(Bastion) 설정")
        dlg.transient(self.root)
        dlg.resizable(False, False)
        dlg.grab_set()

        pad = dict(padx=6, pady=5)
        en = tk.BooleanVar(value=g["enabled"])
        ttk.Checkbutton(dlg, text="게이트웨이(bastion) 경유 접속 사용", variable=en)\
            .grid(row=0, column=0, columnspan=4, sticky="w", **pad)
        ttk.Label(dlg, text="private 서브넷 서버는 bastion을 점프호스트로 경유합니다.")\
            .grid(row=1, column=0, columnspan=4, sticky="w", padx=6)

        ttk.Label(dlg, text="Bastion IP").grid(row=2, column=0, sticky="e", **pad)
        e_host = ttk.Entry(dlg, width=24); e_host.insert(0, g["host"]); e_host.grid(row=2, column=1, **pad)
        ttk.Label(dlg, text="포트").grid(row=2, column=2, sticky="e", **pad)
        e_port = ttk.Entry(dlg, width=6); e_port.insert(0, str(g["port"])); e_port.grid(row=2, column=3, sticky="w", **pad)

        ttk.Label(dlg, text="계정(ID)").grid(row=3, column=0, sticky="e", **pad)
        e_user = ttk.Entry(dlg, width=24); e_user.insert(0, g["user"]); e_user.grid(row=3, column=1, **pad)

        auth = tk.StringVar(value=g["auth"])
        af = ttk.Frame(dlg); af.grid(row=4, column=0, columnspan=4, sticky="w", padx=6)
        ttk.Label(af, text="인증").grid(row=0, column=0)
        ttk.Radiobutton(af, text="비밀번호", variable=auth, value="password").grid(row=0, column=1, padx=6)
        ttk.Radiobutton(af, text="SSH 키", variable=auth, value="key").grid(row=0, column=2, padx=6)

        ttk.Label(dlg, text="비밀번호").grid(row=5, column=0, sticky="e", **pad)
        e_pass = ttk.Entry(dlg, width=24, show="*"); e_pass.insert(0, g["password"]); e_pass.grid(row=5, column=1, **pad)

        ttk.Label(dlg, text="키 파일").grid(row=6, column=0, sticky="e", **pad)
        e_key = ttk.Entry(dlg, width=30); e_key.insert(0, g["key"]); e_key.grid(row=6, column=1, columnspan=2, sticky="we", **pad)

        def browse():
            path = filedialog.askopenfilename(title="Bastion SSH 개인키 선택", parent=dlg)
            if path:
                e_key.delete(0, "end"); e_key.insert(0, path)
        ttk.Button(dlg, text="찾기", width=6, command=browse).grid(row=6, column=3, **pad)

        def save():
            self.gateway = {
                "enabled": en.get(),
                "host": e_host.get().strip(),
                "port": int(e_port.get().strip() or "22"),
                "user": e_user.get().strip() or "ec2-user",
                "auth": auth.get(),
                "password": e_pass.get(),
                "key": e_key.get().strip(),
            }
            self._refresh_gw_button()
            dlg.destroy()

        bf = ttk.Frame(dlg); bf.grid(row=7, column=0, columnspan=4, pady=8)
        ttk.Button(bf, text="저장", width=10, command=save).grid(row=0, column=0, padx=6)
        ttk.Button(bf, text="취소", width=10, command=dlg.destroy).grid(row=0, column=1, padx=6)

        dlg.wait_window()

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
        if paramiko is None:
            messagebox.showerror("의존성 오류", "paramiko가 필요합니다.\npip install paramiko")
            return
        if not os.path.exists(LOCAL_CHECK):
            messagebox.showerror("파일 없음", f"점검 스크립트를 찾을 수 없습니다:\n{LOCAL_CHECK}")
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
        )
        self.set_busy(True)
        self._clear_table()
        self.lbl_sum.configure(text="점검 실행 중…")
        threading.Thread(target=self._worker, args=(params,), daemon=True).start()

    def _worker(self, p):
        client = None
        gw_client = None
        try:
            g = self.gateway
            sock = None
            if g.get("enabled"):
                if not g.get("host"):
                    raise RuntimeError("게이트웨이 사용이 켜져 있으나 Bastion IP가 비어 있습니다.")
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

            self.log("[2/4] 점검 스크립트 업로드…")
            sftp = client.open_sftp()
            sftp.put(LOCAL_CHECK, REMOTE_SCRIPT)

            self.log("[3/4] 원격 점검 실행 (수 초~수십 초 소요)…")
            base = f"bash {REMOTE_SCRIPT} --json {REMOTE_JSON} --no-color"
            if p["sudo"]:
                cmd = f"sudo -S -p '' {base}"
            else:
                cmd = f"sudo -n {base} 2>/dev/null || {base}"
            stdin, stdout, stderr = client.exec_command(cmd, get_pty=True, timeout=600)
            if p["sudo"]:
                stdin.write(p["sudo"] + "\n")
                stdin.flush()
            stdout.channel.recv_exit_status()   # 완료 대기

            self.log("[4/4] 결과 회수…")
            buf = io.BytesIO()
            sftp.getfo(REMOTE_JSON, buf)
            data = json.loads(buf.getvalue().decode("utf-8", "replace"))
            # 원격 임시파일 정리
            try:
                sftp.remove(REMOTE_JSON); sftp.remove(REMOTE_SCRIPT)
            except Exception:
                pass
            sftp.close()

            self.host_label = data.get("host", p["host"])
            self.os_label = data.get("os", "")
            self.conn_host = p["host"]
            self.results = data.get("results", [])
            self.log(f"      완료: {len(self.results)}개 항목 (OS: {data.get('os','?')})")
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
        cnt = {"양호": 0, "취약": 0, "N/A": 0, "수동확인": 0}
        for r in self.results:
            st = r.get("status", "")
            cnt[st] = cnt.get(st, 0) + 1
            self.tree.insert("", "end",
                             values=(r.get("code", ""), r.get("importance", ""),
                                     r.get("title", ""), st,
                                     " / ".join(r.get("evidence", []))),
                             tags=(st,))
        self.lbl_sum.configure(
            text=f"[{self.host_label}]  양호 {cnt['양호']}   취약 {cnt['취약']}   "
                 f"N/A {cnt['N/A']}   수동확인 {cnt['수동확인']}   (총 {len(self.results)})")
        self.btn_xlsx.configure(state="normal" if self.results else "disabled")

    # ---------------- 엑셀 추출 ----------------
    def on_export(self):
        if openpyxl is None:
            messagebox.showerror("의존성 오류", "openpyxl이 필요합니다.\npip install openpyxl")
            return
        if not self.results:
            messagebox.showwarning("데이터 없음", "먼저 점검을 실행하세요.")
            return
        default = f"kisa_{self.host_label or 'result'}.xlsx".replace(":", "_")
        path = filedialog.asksaveasfilename(defaultextension=".xlsx",
                                            initialfile=default,
                                            filetypes=[("Excel", "*.xlsx")])
        if not path:
            return
        # 보고서 양식이 있으면 그 서식대로 채워서 저장
        if os.path.exists(REPORT_TEMPLATE):
            try:
                self._export_with_template(path)
                self.log(f"✔ 엑셀 저장(보고서 양식): {path}")
                messagebox.showinfo("저장 완료", f"보고서 양식으로 저장했습니다:\n{path}")
                return
            except Exception as e:
                self.log(f"⚠ 양식 채우기 실패({e}) → 기본 형식으로 저장합니다.")
        self._export_plain(path)

    def _export_with_template(self, path):
        wb = openpyxl.load_workbook(REPORT_TEMPLATE)
        ws = wb[RESULT_SHEET]
        by_code = {r.get("code", ""): r for r in self.results}
        # U-01 → 6행, U-67 → 72행
        for n in range(1, 68):
            code = f"U-{n:02d}"
            r = by_code.get(code)
            if not r:
                continue
            row = 5 + n
            ws.cell(row=row, column=6).value = r.get("status", "")            # F: 판정
            ws.cell(row=row, column=7).value = " / ".join(r.get("evidence", []))  # G: 상세결과

        # 진단 대상 시트에 점검 호스트 1대 기록
        try:
            wt = wb[TARGET_SHEET]
            wt.cell(row=5, column=2).value = 1
            wt.cell(row=5, column=3).value = self.host_label or self.conn_host   # Hostname
            wt.cell(row=5, column=4).value = self.conn_host                      # IP Address
            wt.cell(row=5, column=5).value = self.os_label                       # 버전정보
        except Exception:
            pass

        wb.save(path)

    def _export_plain(self, path):
        try:
            wb = openpyxl.Workbook()
            ws = wb.active
            ws.title = "KISA 점검결과"
            headers = ["호스트", "코드", "중요도", "점검 항목", "판정", "근거"]
            ws.append(headers)
            for c in ws[1]:
                c.font = Font(bold=True, color="FFFFFF")
                c.fill = PatternFill("solid", fgColor="404040")
                c.alignment = Alignment(horizontal="center")
            for r in self.results:
                ws.append([self.host_label, r.get("code", ""), r.get("importance", ""),
                           r.get("title", ""), r.get("status", ""),
                           " / ".join(r.get("evidence", []))])
                fill = XLSX_FILL.get(r.get("status", ""))
                if fill:
                    for c in ws[ws.max_row]:
                        c.fill = PatternFill("solid", fgColor=fill)
            widths = [16, 8, 8, 34, 10, 90]
            for i, w in enumerate(widths, start=1):
                ws.column_dimensions[openpyxl.utils.get_column_letter(i)].width = w
            ws.freeze_panes = "A2"
            ws.auto_filter.ref = f"A1:F{ws.max_row}"
            wb.save(path)
            self.log(f"✔ 엑셀 저장: {path}")
            messagebox.showinfo("저장 완료", f"엑셀로 저장했습니다:\n{path}")
        except Exception as e:
            messagebox.showerror("저장 오류", str(e))


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()