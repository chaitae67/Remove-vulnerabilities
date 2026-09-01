#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""게이트웨이(Bastion) 설정 다이얼로그.

private 서브넷 서버를 점프호스트(bastion) 경유로 접속하기 위한 설정 창.
app.gateway 딕셔너리를 읽고/저장하며, 저장 시 app._refresh_gw_button() 호출.
"""
import tkinter as tk
from tkinter import ttk, filedialog

from common import set_window_icon


def open_gateway(app):
    g = app.gateway
    dlg = tk.Toplevel(app.root)
    set_window_icon(dlg)
    dlg.title("게이트웨이(Bastion) 설정")
    dlg.transient(app.root)
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
        app.gateway = {
            "enabled": en.get(),
            "host": e_host.get().strip(),
            "port": int(e_port.get().strip() or "22"),
            "user": e_user.get().strip() or "ec2-user",
            "auth": auth.get(),
            "password": e_pass.get(),
            "key": e_key.get().strip(),
        }
        app._refresh_gw_button()
        dlg.destroy()

    bf = ttk.Frame(dlg); bf.grid(row=7, column=0, columnspan=4, pady=8)
    ttk.Button(bf, text="저장", width=10, command=save).grid(row=0, column=0, padx=6)
    ttk.Button(bf, text="취소", width=10, command=dlg.destroy).grid(row=0, column=1, padx=6)

    dlg.wait_window()
