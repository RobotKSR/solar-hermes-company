from __future__ import annotations

import os
import queue
import re
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, scrolledtext


INSTALLER_URL = "https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.ps1"
APP_TITLE = "Solar Hermes"
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)")
BOX_CHARS = set("─━│┃┌┐└┘╭╮╰╯├┤┬┴┼┏┓┗┛╔╗╚╝═║╠╣╦╩╬ ")


def user_home() -> Path:
    return Path.home()


def solar_cmd_path() -> Path:
    return user_home() / ".solar-hermes" / "bin" / "solar-hermes.cmd"


def find_hermes_home() -> Path:
    candidates: list[Path] = []
    if os.environ.get("HERMES_HOME"):
        candidates.append(Path(os.environ["HERMES_HOME"]))
    if os.environ.get("LOCALAPPDATA"):
        candidates.append(Path(os.environ["LOCALAPPDATA"]) / "hermes")
    candidates.append(user_home() / ".hermes")

    for candidate in candidates:
        if (candidate / "hermes-agent" / "venv" / "Scripts" / "python.exe").exists():
            return candidate
    return candidates[0]


def windows_creation_flags() -> int:
    if sys.platform != "win32":
        return 0
    return getattr(subprocess, "CREATE_NO_WINDOW", 0)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def clean_assistant_output(text: str) -> str:
    lines = []
    for raw_line in strip_ansi(text).replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = raw_line.strip()
        if not line:
            lines.append("")
            continue
        if line.startswith(("Hermes Agent", "usage: hermes", "[Hermes exited", "session_id:")):
            continue
        if line in {"Initializing agent...", "Resume this session with:"}:
            continue
        if line and all(ch in BOX_CHARS for ch in line):
            continue
        line = line.strip("".join(BOX_CHARS))
        if line:
            lines.append(line)
    return "\n".join(lines).strip()


def looks_like_approval_prompt(text: str) -> bool:
    lowered = strip_ansi(text).lower()
    has_choice_words = (
        "once" in lowered
        and ("session" in lowered or "always" in lowered)
        and ("deny" in lowered or "cancel" in lowered)
    )
    has_prompt_shape = "[o]" in lowered or "(o)" in lowered or "approval" in lowered
    return has_choice_words and has_prompt_shape


class SolarHermesApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("880x650")
        self.minsize(760, 560)

        self.worker: threading.Thread | None = None
        self.ui_queue: queue.Queue[tuple[str, str]] = queue.Queue()
        self.install_details: list[str] = []
        self.detail_widget: scrolledtext.ScrolledText | None = None
        self.chat_canvas: tk.Canvas | None = None
        self.messages_frame: tk.Frame | None = None
        self.current_assistant_label: tk.Label | None = None
        self.current_assistant_text = ""
        self.approval_frame: tk.Frame | None = None
        self.active_process: subprocess.Popen | None = None
        self.message_entry: tk.Entry | None = None
        self.primary_button: tk.Button | None = None
        self.secondary_button: tk.Button | None = None
        self.status_var = tk.StringVar(value="Ready.")
        self.token_var = tk.StringVar()
        self.show_token_var = tk.BooleanVar(value=False)

        self.root_frame = tk.Frame(self, padx=24, pady=20)
        self.root_frame.pack(fill=tk.BOTH, expand=True)

        self._show_token_step()
        self.after(100, self._drain_ui_queue)

    def _clear(self) -> None:
        for child in self.root_frame.winfo_children():
            child.destroy()
        self.primary_button = None
        self.secondary_button = None

    def _header(self, active_step: int) -> None:
        tk.Label(
            self.root_frame,
            text="Solar Hermes",
            font=("Segoe UI", 22, "bold"),
        ).pack(anchor="w")
        tk.Label(
            self.root_frame,
            text="Корпоративный Hermes Agent для qwen3.6 через Solar LLM Platform.",
            fg="#4b5563",
            font=("Segoe UI", 10),
        ).pack(anchor="w", pady=(2, 18))

        steps = tk.Frame(self.root_frame)
        steps.pack(fill=tk.X, pady=(0, 22))
        labels = ["1. Токен", "2. Установка", "3. Чат"]
        for idx, label in enumerate(labels, start=1):
            bg = "#2563eb" if idx == active_step else "#e5e7eb"
            fg = "white" if idx == active_step else "#374151"
            tk.Label(
                steps,
                text=label,
                bg=bg,
                fg=fg,
                padx=16,
                pady=8,
                font=("Segoe UI", 10, "bold"),
            ).pack(side=tk.LEFT, padx=(0, 8))

    def _footer(self) -> None:
        tk.Label(
            self.root_frame,
            textvariable=self.status_var,
            anchor="w",
            fg="#374151",
        ).pack(side=tk.BOTTOM, fill=tk.X, pady=(12, 0))

    def _button_row(self) -> tk.Frame:
        row = tk.Frame(self.root_frame)
        row.pack(fill=tk.X, pady=(18, 0))
        return row

    def _show_token_step(self) -> None:
        self._clear()
        self._header(1)

        card = tk.Frame(self.root_frame, bd=1, relief=tk.SOLID, padx=18, pady=18)
        card.pack(fill=tk.X)
        tk.Label(
            card,
            text="Введите API token",
            font=("Segoe UI", 15, "bold"),
        ).pack(anchor="w")
        tk.Label(
            card,
            text=(
                "Токен сохраняется только локально в Hermes config. "
                "Без него установка не начнётся."
            ),
            wraplength=760,
            justify="left",
            fg="#4b5563",
        ).pack(anchor="w", pady=(4, 14))

        token_line = tk.Frame(card)
        token_line.pack(fill=tk.X)
        self.token_entry = tk.Entry(
            token_line,
            textvariable=self.token_var,
            show="*",
            font=("Segoe UI", 11),
        )
        self.token_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.token_entry.focus_set()
        tk.Checkbutton(
            token_line,
            text="показать",
            variable=self.show_token_var,
            command=self._toggle_token_visibility,
        ).pack(side=tk.RIGHT, padx=(10, 0))

        hint = tk.Label(
            self.root_frame,
            text=(
                "Если Hermes уже установлен, можно сразу перейти к чату. "
                "Если token изменился, нажмите установку заново."
            ),
            fg="#6b7280",
            wraplength=760,
            justify="left",
        )
        hint.pack(anchor="w", pady=(14, 0))

        row = self._button_row()
        self.primary_button = tk.Button(
            row,
            text="Продолжить установку",
            command=self._start_install_from_token_step,
            width=22,
            height=2,
        )
        self.primary_button.pack(side=tk.RIGHT)
        self.secondary_button = tk.Button(
            row,
            text="Открыть чат",
            command=self._open_chat_if_installed,
            width=16,
            height=2,
        )
        self.secondary_button.pack(side=tk.RIGHT, padx=(0, 10))
        self._footer()

    def _toggle_token_visibility(self) -> None:
        if hasattr(self, "token_entry"):
            self.token_entry.configure(show="" if self.show_token_var.get() else "*")

    def _start_install_from_token_step(self) -> None:
        token = self.token_var.get().strip()
        if not token:
            messagebox.showwarning(APP_TITLE, "Введите LLM Platform API token.")
            self.token_entry.focus_set()
            return
        self._show_install_step()
        self._start_install(token)

    def _show_install_step(self) -> None:
        self._clear()
        self._header(2)

        self.install_title_var = tk.StringVar(value="Готовим установку...")
        self.install_body_var = tk.StringVar(value="Проверяем Hermes, Headroom и локальную конфигурацию.")

        tk.Label(
            self.root_frame,
            textvariable=self.install_title_var,
            font=("Segoe UI", 16, "bold"),
        ).pack(anchor="w")
        tk.Label(
            self.root_frame,
            textvariable=self.install_body_var,
            wraplength=760,
            justify="left",
            fg="#4b5563",
        ).pack(anchor="w", pady=(6, 18))

        self.install_steps_frame = tk.Frame(self.root_frame)
        self.install_steps_frame.pack(fill=tk.X)
        self.install_step_labels: dict[str, tk.Label] = {}
        for key, label in [
            ("hermes", "Hermes Agent"),
            ("headroom", "Headroom compression"),
            ("config", "Solar LLM configuration"),
            ("launcher", "Local command and chat app"),
        ]:
            row = tk.Frame(self.install_steps_frame)
            row.pack(fill=tk.X, pady=3)
            status = tk.Label(row, text="○", width=3, fg="#6b7280", font=("Segoe UI", 12, "bold"))
            status.pack(side=tk.LEFT)
            tk.Label(row, text=label, font=("Segoe UI", 10)).pack(side=tk.LEFT)
            self.install_step_labels[key] = status

        details_button = tk.Button(
            self.root_frame,
            text="Показать технические детали",
            command=self._toggle_details,
        )
        details_button.pack(anchor="w", pady=(18, 6))
        self.details_button = details_button
        self.detail_widget = scrolledtext.ScrolledText(self.root_frame, height=11, wrap=tk.WORD)
        self.detail_widget.pack_forget()

        row = self._button_row()
        self.primary_button = tk.Button(
            row,
            text="Перейти в чат",
            command=self._show_chat_step,
            state=tk.DISABLED,
            width=18,
            height=2,
        )
        self.primary_button.pack(side=tk.RIGHT)
        self.secondary_button = tk.Button(
            row,
            text="Назад",
            command=self._show_token_step,
            state=tk.DISABLED,
            width=14,
            height=2,
        )
        self.secondary_button.pack(side=tk.RIGHT, padx=(0, 10))
        self._footer()

    def _toggle_details(self) -> None:
        if self.detail_widget is None:
            return
        if self.detail_widget.winfo_ismapped():
            self.detail_widget.pack_forget()
            self.details_button.configure(text="Показать технические детали")
        else:
            self.detail_widget.pack(fill=tk.BOTH, expand=True, pady=(0, 8))
            self.details_button.configure(text="Скрыть технические детали")

    def _start_install(self, token: str) -> None:
        if self.worker and self.worker.is_alive():
            return
        self._set_install_busy(True)
        self.status_var.set("Installing...")
        self.worker = threading.Thread(target=self._install_worker, args=(token,), daemon=True)
        self.worker.start()

    def _set_install_busy(self, busy: bool) -> None:
        if self.primary_button is not None:
            self.primary_button.configure(state=tk.DISABLED if busy else tk.NORMAL)
        if self.secondary_button is not None:
            self.secondary_button.configure(state=tk.DISABLED if busy else tk.NORMAL)

    def _install_worker(self, token: str) -> None:
        env = self._base_env()
        env["LLM_PLATFORM_TOKEN"] = token

        command = (
            "$ErrorActionPreference = 'Stop'; "
            f"irm {INSTALLER_URL} | iex"
        )
        self.ui_queue.put(("install_stage", "hermes"))
        self.ui_queue.put(("install_detail", f"Installer: {INSTALLER_URL}\n"))
        try:
            process = subprocess.Popen(
                [
                    "powershell",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    command,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=env,
                creationflags=windows_creation_flags(),
            )
        except FileNotFoundError:
            self.ui_queue.put(("install_failed", "PowerShell не найден. Это приложение рассчитано на Windows."))
            return

        assert process.stdout is not None
        for line in process.stdout:
            self.ui_queue.put(("install_detail", line))
            lowered = line.lower()
            if "ensuring pip" in lowered or "installing headroom" in lowered:
                self.ui_queue.put(("install_stage", "headroom"))
            elif "patching hermes" in lowered or "config.yaml" in lowered:
                self.ui_queue.put(("install_stage", "config"))
            elif "done." in lowered:
                self.ui_queue.put(("install_stage", "launcher"))

        code = process.wait()
        if code == 0:
            self.ui_queue.put(("install_done", ""))
        else:
            self.ui_queue.put(("install_failed", f"Установщик завершился с кодом {code}. Откройте технические детали."))

    def _show_chat_step(self) -> None:
        if not solar_cmd_path().exists():
            messagebox.showinfo(APP_TITLE, "Сначала завершите установку.")
            return

        self._clear()
        self._header(3)
        self.current_assistant_label = None
        self.current_assistant_text = ""

        top = tk.Frame(self.root_frame)
        top.pack(fill=tk.X, pady=(0, 10))
        tk.Label(
            top,
            text="Чат с Hermes",
            font=("Segoe UI", 16, "bold"),
        ).pack(side=tk.LEFT)
        tk.Button(top, text="Настройки", command=self._show_token_step).pack(side=tk.RIGHT)

        chat_shell = tk.Frame(self.root_frame, bg="#f3f4f6", bd=1, relief=tk.SOLID)
        chat_shell.pack(fill=tk.BOTH, expand=True)
        self.chat_canvas = tk.Canvas(chat_shell, bg="#f3f4f6", highlightthickness=0)
        scrollbar = tk.Scrollbar(chat_shell, orient=tk.VERTICAL, command=self.chat_canvas.yview)
        self.messages_frame = tk.Frame(self.chat_canvas, bg="#f3f4f6")
        window_id = self.chat_canvas.create_window((0, 0), window=self.messages_frame, anchor="nw")
        self.chat_canvas.configure(yscrollcommand=scrollbar.set)
        self.chat_canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.messages_frame.bind(
            "<Configure>",
            lambda _event: self.chat_canvas.configure(scrollregion=self.chat_canvas.bbox("all"))
            if self.chat_canvas is not None
            else None,
        )
        self.chat_canvas.bind(
            "<Configure>",
            lambda event: self.chat_canvas.itemconfigure(window_id, width=event.width)
            if self.chat_canvas is not None
            else None,
        )

        self.approval_frame = tk.Frame(self.root_frame, bg="#fff7ed", bd=1, relief=tk.SOLID)
        tk.Label(
            self.approval_frame,
            text="Hermes просит подтверждение действия",
            bg="#fff7ed",
            fg="#9a3412",
            font=("Segoe UI", 10, "bold"),
        ).pack(side=tk.LEFT, padx=10, pady=8)
        for text, choice in [
            ("Разрешить 1 раз", "once"),
            ("Разрешить на сессию", "session"),
            ("Всегда разрешать", "always"),
            ("Отклонить", "deny"),
        ]:
            tk.Button(
                self.approval_frame,
                text=text,
                command=lambda selected=choice: self._send_approval(selected),
            ).pack(side=tk.LEFT, padx=(0, 8), pady=6)

        input_frame = tk.Frame(self.root_frame)
        input_frame.pack(fill=tk.X, pady=(12, 0))
        self.message_var = tk.StringVar()
        self.message_entry = tk.Entry(
            input_frame,
            textvariable=self.message_var,
            font=("Segoe UI", 12),
            relief=tk.SOLID,
            bd=1,
        )
        self.message_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, ipady=8)
        self.message_entry.bind("<Return>", lambda _event: self.send_message())
        self.send_button = tk.Button(
            input_frame,
            text="Отправить",
            command=self.send_message,
            width=14,
            height=2,
            bg="#2563eb",
            fg="white",
            activebackground="#1d4ed8",
            activeforeground="white",
        )
        self.send_button.pack(side=tk.RIGHT, padx=(10, 0))
        self.message_entry.focus_set()
        self._footer()
        self.status_var.set("Ready.")
        self._append_chat(
            "system",
            "Готово. Пишите сообщение ниже. Ответ Hermes будет появляться в реальном времени.",
        )

    def _open_chat_if_installed(self) -> None:
        if not solar_cmd_path().exists():
            messagebox.showinfo(APP_TITLE, "Hermes ещё не установлен. Сначала нажмите установку.")
            return
        self._show_chat_step()

    def send_message(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        if self.message_entry is None:
            return
        message = self.message_var.get().strip()
        if not message:
            return
        self.message_var.set("")
        self._append_chat("user", message)
        self._set_chat_busy(True)
        self._hide_approval_controls()
        self.status_var.set("Hermes отвечает...")
        self.worker = threading.Thread(target=self._chat_worker, args=(message,), daemon=True)
        self.worker.start()

    def _chat_worker(self, message: str) -> None:
        env = self._base_env()
        command = [
            "cmd.exe",
            "/c",
            str(solar_cmd_path()),
            "chat",
            "--query",
            message,
        ]
        self.ui_queue.put(("chat_assistant_start", ""))
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                cwd=str(user_home()),
                env=env,
                creationflags=windows_creation_flags(),
            )
        except Exception as exc:
            self.ui_queue.put(("chat_failed", f"Не удалось запустить Hermes: {exc}"))
            return

        self.active_process = process
        assert process.stdout is not None
        raw_parts: list[str] = []
        last_display = ""
        approval_shown = False
        while True:
            chunk = process.stdout.read(1)
            if chunk == "":
                break
            raw_parts.append(chunk)
            raw_text = "".join(raw_parts)
            display = clean_assistant_output(raw_text)
            if display and display != last_display:
                self.ui_queue.put(("chat_replace", display))
                last_display = display
            if not approval_shown and looks_like_approval_prompt(raw_text):
                approval_shown = True
                self.ui_queue.put(("approval_needed", ""))

        code = process.wait()
        raw_output = "".join(raw_parts)
        cleaned = clean_assistant_output(raw_output)
        if code == 0:
            self.ui_queue.put(("chat_done", cleaned))
        else:
            error_text = cleaned or strip_ansi(raw_output).strip() or f"Exit code {code}"
            self.ui_queue.put(("chat_failed", error_text))

    def _scroll_chat(self) -> None:
        if self.chat_canvas is None:
            return
        self.chat_canvas.update_idletasks()
        self.chat_canvas.yview_moveto(1.0)

    def _append_chat(self, role: str, text: str) -> tk.Label | None:
        if self.messages_frame is None:
            return None
        colors = {
            "system": ("#e5e7eb", "#374151", tk.LEFT),
            "user": ("#2563eb", "white", tk.RIGHT),
            "assistant": ("white", "#111827", tk.LEFT),
            "error": ("#fee2e2", "#991b1b", tk.LEFT),
        }
        bg, fg, side = colors[role]
        row = tk.Frame(self.messages_frame, bg="#f3f4f6")
        row.pack(fill=tk.X, padx=12, pady=6)
        bubble = tk.Label(
            row,
            text=text.strip() or "…",
            bg=bg,
            fg=fg,
            justify=tk.LEFT,
            anchor="w",
            wraplength=580,
            padx=14,
            pady=10,
            font=("Segoe UI", 10),
        )
        bubble.pack(side=side, anchor="e" if side == tk.RIGHT else "w")
        self._scroll_chat()
        return bubble

    def _replace_current_assistant(self, text: str) -> None:
        if self.current_assistant_label is None:
            self.current_assistant_label = self._append_chat("assistant", "…")
        self.current_assistant_text = text.strip() or "…"
        if self.current_assistant_label is not None:
            self.current_assistant_label.configure(text=self.current_assistant_text)
        self._scroll_chat()

    def _show_approval_controls(self) -> None:
        if self.approval_frame is not None and not self.approval_frame.winfo_ismapped():
            self.approval_frame.pack(fill=tk.X, pady=(10, 0))
            self._append_chat("system", "Нужно подтверждение. Выберите действие кнопками ниже.")

    def _hide_approval_controls(self) -> None:
        if self.approval_frame is not None and self.approval_frame.winfo_ismapped():
            self.approval_frame.pack_forget()

    def _send_approval(self, choice: str) -> None:
        mapping = {
            "once": "o\n",
            "session": "s\n",
            "always": "a\n",
            "deny": "d\n",
        }
        process = self.active_process
        if process is None or process.stdin is None:
            return
        try:
            process.stdin.write(mapping[choice])
            process.stdin.flush()
            self._hide_approval_controls()
            self._append_chat("system", f"Ответ на подтверждение отправлен: {choice}.")
        except Exception as exc:
            self._append_chat("error", f"Не удалось отправить подтверждение: {exc}")

    def _set_chat_busy(self, busy: bool) -> None:
        state = tk.DISABLED if busy else tk.NORMAL
        if hasattr(self, "send_button"):
            self.send_button.configure(state=state)
        if self.message_entry is not None:
            self.message_entry.configure(state=state)

    def _base_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env["NO_PROXY"] = "*"
        env["HTTPS_PROXY"] = ""
        env["HTTP_PROXY"] = ""
        env["ALL_PROXY"] = ""
        env["PYTHONUNBUFFERED"] = "1"
        return env

    def _drain_ui_queue(self) -> None:
        while True:
            try:
                event, payload = self.ui_queue.get_nowait()
            except queue.Empty:
                break
            self._handle_ui_event(event, payload)
        self.after(100, self._drain_ui_queue)

    def _handle_ui_event(self, event: str, payload: str) -> None:
        if event == "install_stage":
            self._mark_install_stage(payload)
        elif event == "install_detail":
            self.install_details.append(payload)
            detail = payload.strip()
            if detail and hasattr(self, "install_body_var"):
                if len(detail) > 180:
                    detail = detail[:177] + "..."
                self.install_body_var.set(detail)
            if self.detail_widget is not None:
                self.detail_widget.configure(state=tk.NORMAL)
                self.detail_widget.insert(tk.END, payload)
                self.detail_widget.configure(state=tk.DISABLED)
                self.detail_widget.see(tk.END)
        elif event == "install_done":
            self._mark_install_stage("launcher")
            for label in self.install_step_labels.values():
                label.configure(text="✓", fg="#16a34a")
            self.install_title_var.set("Установка завершена")
            self.install_body_var.set("Hermes + Headroom настроены. Теперь можно перейти к чату.")
            self.status_var.set("Installed.")
            self._set_install_busy(False)
        elif event == "install_failed":
            self.install_title_var.set("Установка не завершилась")
            self.install_body_var.set(payload)
            self.status_var.set("Install failed.")
            if self.primary_button is not None:
                self.primary_button.configure(state=tk.DISABLED)
            if self.secondary_button is not None:
                self.secondary_button.configure(state=tk.NORMAL)
        elif event == "chat_assistant_start":
            self.current_assistant_label = self._append_chat("assistant", "Hermes думает…")
            self.current_assistant_text = ""
        elif event == "chat_replace":
            self._replace_current_assistant(payload)
        elif event == "approval_needed":
            self._show_approval_controls()
        elif event == "chat_done":
            if payload:
                self._replace_current_assistant(payload)
            self._hide_approval_controls()
            self.status_var.set("Ready.")
            self._set_chat_busy(False)
            self.current_assistant_label = None
            self.active_process = None
        elif event == "chat_failed":
            if self.current_assistant_label is not None:
                self._replace_current_assistant(payload)
            else:
                self._append_chat("error", payload)
            self._hide_approval_controls()
            self.status_var.set("Hermes error.")
            self._set_chat_busy(False)
            self.current_assistant_label = None
            self.active_process = None

    def _mark_install_stage(self, active: str) -> None:
        order = ["hermes", "headroom", "config", "launcher"]
        if active not in order:
            return
        active_index = order.index(active)
        friendly = {
            "hermes": "Проверяем и устанавливаем Hermes Agent...",
            "headroom": "Ставим pip/Headroom в окружение Hermes...",
            "config": "Записываем конфигурацию Solar LLM...",
            "launcher": "Создаём локальный запуск и проверяем готовность...",
        }
        self.install_title_var.set(friendly[active])
        for idx, key in enumerate(order):
            label = self.install_step_labels.get(key)
            if label is None:
                continue
            if idx < active_index:
                label.configure(text="✓", fg="#16a34a")
            elif idx == active_index:
                label.configure(text="●", fg="#2563eb")
            else:
                label.configure(text="○", fg="#6b7280")

def main() -> int:
    if sys.platform != "win32":
        print("SolarHermes.exe is intended for Windows.")
    app = SolarHermesApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
