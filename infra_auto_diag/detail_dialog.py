#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""행 더블클릭 → 상세정보 / 최종판정 변경 다이얼로그.

근거를 보여주고 검증자가 최종판정(양호/취약/인터뷰 필요)을 지정 + 비고 입력.
저장 시 app.results[idx] 를 갱신하고 표/요약을 다시 그린다.

TODO(추후): 이 창에서 원격 명령을 실행해 결과를 직접 뽑아보는 기능 추가 예정.
"""
import tkinter as tk
from tkinter import ttk

from common import set_window_icon, FINAL_CHOICES


def open_detail(app, idx):
    r = app.results[idx]
    dlg = tk.Toplevel(app.root)
    set_window_icon(dlg)
    dlg.title(f"{r.get('code','')} 상세 / 최종판정")
    dlg.transient(app.root); dlg.grab_set(); dlg.geometry("580x480")

    head = ttk.Frame(dlg); head.pack(fill="x", padx=10, pady=8)
    ttk.Label(head, text=f"{r.get('code','')}  [{r.get('importance','')}]  {r.get('title','')}",
              font=("", 11, "bold")).pack(anchor="w")
    ttk.Label(head, text=f"자동판정: {r.get('status','')}", foreground="#555").pack(anchor="w")

    ttk.Label(dlg, text="■ 근거", font=("", 9, "bold")).pack(anchor="w", padx=10)
    ev = tk.Text(dlg, height=9, wrap="word")
    ev.pack(fill="both", expand=True, padx=10, pady=(0, 6))
    ev.insert("1.0", "\n".join(r.get("evidence", []) or ["(근거 없음)"]))
    ev.configure(state="disabled")

    fr = ttk.LabelFrame(dlg, text="최종판정 (검증자 지정)")
    fr.pack(fill="x", padx=10, pady=4)
    fv = tk.StringVar(value=r.get("final", r.get("status", "")))
    for i, s in enumerate(FINAL_CHOICES):
        ttk.Radiobutton(fr, text=s, variable=fv, value=s).grid(
            row=i // 3, column=i % 3, padx=10, pady=4, sticky="w")

    ttk.Label(dlg, text="■ 비고(검증자 의견)", font=("", 9, "bold")).pack(anchor="w", padx=10)
    note = tk.Text(dlg, height=3, wrap="word")
    note.pack(fill="x", padx=10)
    note.insert("1.0", r.get("note", ""))

    def save():
        r["final"] = fv.get()
        r["note"] = note.get("1.0", "end").strip()
        app._update_row(idx)
        app._update_summary()
        app.log(f"  · {r.get('code','')} 최종판정 저장: {r['final']}")
        dlg.destroy()

    bf = ttk.Frame(dlg); bf.pack(pady=10)
    ttk.Button(bf, text="저장", width=10, command=save).grid(row=0, column=0, padx=8)
    ttk.Button(bf, text="닫기", width=10, command=dlg.destroy).grid(row=0, column=1, padx=8)
    dlg.wait_window()
