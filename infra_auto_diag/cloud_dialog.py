#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""클라우드 자격증명 입력 다이얼로그.

CSP(aws/azure/gcp)별로 필요한 자격증명 필드를 보여주고, 확인 시 dict 를 돌려준다.
읽기 전용 진단이므로 최소 권한(AWS SecurityAudit / Azure Reader /
GCP roles/iam.securityReviewer) 자격을 넣으면 된다.
"""
import tkinter as tk
from tkinter import ttk, filedialog

from common import set_window_icon, TARGET_LABEL


def open_cloud_creds(parent, provider, current=None):
    """모달로 자격증명을 받는다. 취소하면 None, 확인하면 dict."""
    cur = current or {}
    provider = provider.lower()
    win = tk.Toplevel(parent)
    win.title(f"{TARGET_LABEL.get(provider, provider)} 자격증명")
    win.transient(parent)
    win.grab_set()
    set_window_icon(win)
    frm = ttk.Frame(win, padding=12)
    frm.pack(fill="both", expand=True)
    frm.columnconfigure(1, weight=1)

    st = {"row": 0}
    fields = {}          # key -> (StringVar, Entry)

    def note(text):
        ttk.Label(frm, text=text, foreground="#666", wraplength=430).grid(
            row=st["row"], column=0, columnspan=3, sticky="w", pady=(0, 6))
        st["row"] += 1

    def field(label, key, show=None, default=""):
        r = st["row"]
        ttk.Label(frm, text=label).grid(row=r, column=0, sticky="w", pady=3, padx=(0, 8))
        var = tk.StringVar(value=cur.get(key, default))
        ent = ttk.Entry(frm, textvariable=var, width=44, show=show or "")
        ent.grid(row=r, column=1, sticky="ew", pady=3)
        fields[key] = (var, ent)
        st["row"] += 1
        return var

    result = {}

    if provider == "aws":
        note("필요 권한: 관리형 정책 SecurityAudit (읽기 전용)")
        mode = tk.StringVar(value=cur.get("mode", "key"))
        mrow = ttk.Frame(frm)
        mrow.grid(row=st["row"], column=0, columnspan=3, sticky="w", pady=(0, 4))
        st["row"] += 1
        ttk.Radiobutton(mrow, text="액세스 키", variable=mode, value="key").pack(side="left")
        ttk.Radiobutton(mrow, text="프로필(~/.aws)", variable=mode, value="profile").pack(side="left", padx=8)
        ttk.Radiobutton(mrow, text="환경 자격증명", variable=mode, value="env").pack(side="left")
        field("Access Key ID", "access_key")
        field("Secret Access Key", "secret_key", show="*")
        field("Session Token (선택)", "session_token", show="*")
        field("프로필 이름", "profile", default=cur.get("profile", "default"))
        field("리전", "region", default=cur.get("region", "ap-northeast-2"))

        def sync(*_):
            m = mode.get()
            for k, on in (("access_key", m == "key"), ("secret_key", m == "key"),
                          ("session_token", m == "key"), ("profile", m == "profile")):
                fields[k][1].configure(state="normal" if on else "disabled")
        mode.trace_add("write", sync)
        sync()

        def collect():
            result.update(mode=mode.get(),
                          access_key=fields["access_key"][0].get().strip(),
                          secret_key=fields["secret_key"][0].get().strip(),
                          session_token=fields["session_token"][0].get().strip(),
                          profile=fields["profile"][0].get().strip(),
                          region=fields["region"][0].get().strip())

    elif provider == "azure":
        note("필요 권한: 구독 Reader (읽기 전용). 서비스 주체(앱 등록) 자격 사용.")
        field("Tenant ID", "tenant_id")
        field("Client ID", "client_id")
        field("Client Secret", "client_secret", show="*")
        field("Subscription ID", "subscription_id")

        def collect():
            for k in ("tenant_id", "client_id", "client_secret", "subscription_id"):
                result[k] = fields[k][0].get().strip()

    else:  # gcp
        note("필요 권한: roles/iam.securityReviewer + roles/viewer (읽기 전용)")
        field("서비스계정 JSON 키 파일", "sa_key_path")
        field("Project ID", "project_id")

        def browse():
            p = filedialog.askopenfilename(title="서비스계정 키(JSON)",
                                           filetypes=[("JSON", "*.json")])
            if p:
                fields["sa_key_path"][0].set(p)
        ttk.Button(frm, text="찾기", command=browse).grid(row=st["row"] - 2, column=2, padx=4)

        def collect():
            result["sa_key_path"] = fields["sa_key_path"][0].get().strip()
            result["project_id"] = fields["project_id"][0].get().strip()

    btns = ttk.Frame(frm)
    btns.grid(row=st["row"], column=0, columnspan=3, sticky="e", pady=(12, 0))
    ok = {"v": False}

    def on_ok():
        collect()
        ok["v"] = True
        win.destroy()

    ttk.Button(btns, text="확인", command=on_ok).pack(side="right", padx=4)
    ttk.Button(btns, text="취소", command=win.destroy).pack(side="right")
    win.bind("<Return>", lambda e: on_ok())
    win.bind("<Escape>", lambda e: win.destroy())
    parent.wait_window(win)
    return result if ok["v"] else None


def creds_summary(provider, creds):
    """상태 라벨용 짧은 요약."""
    if not creds:
        return "미설정"
    p = provider.lower()
    if p == "aws":
        m = creds.get("mode")
        if m == "profile":
            return f"프로필 {creds.get('profile')} / {creds.get('region')}"
        if m == "env":
            return f"환경 자격증명 / {creds.get('region')}"
        ak = creds.get("access_key", "")
        return f"{ak[:4]}…{ak[-4:]} / {creds.get('region')}" if ak else "미설정"
    if p == "azure":
        s = creds.get("subscription_id", "")
        return f"구독 {s[:8]}…" if s else "미설정"
    return creds.get("project_id") or "미설정"
