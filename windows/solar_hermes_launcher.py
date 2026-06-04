from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, scrolledtext


INSTALLER_URL = "https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.ps1"
APP_TITLE = "Solar Hermes"
SESSION_NAME = "SolarHermesGUI"


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


class SolarHermesApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("760x520")
        self.minsize(680, 440)

        self.log_queue: queue.Queue[str] = queue.Queue()
        self.worker: threading.Thread | None = None

        self._build_ui()
        self.after(100, self._drain_log_queue)

    def _build_ui(self) -> None:
        root = tk.Frame(self, padx=16, pady=14)
        root.pack(fill=tk.BOTH, expand=True)

        tk.Label(
            root,
            text="Solar Hermes for Windows",
            font=("Segoe UI", 17, "bold"),
        ).pack(anchor="w")
        tk.Label(
            root,
            text=(
                "Окно чата с Hermes Agent. При первом запуске установит "
                "Hermes + Headroom и настроит qwen3.6 через LLM Platform."
            ),
            wraplength=700,
            justify="left",
        ).pack(anchor="w", pady=(4, 14))

        token_frame = tk.LabelFrame(root, text="LLM Platform API token")
        token_frame.pack(fill=tk.X, pady=(0, 12))
        self.token_var = tk.StringVar()
        self.token_entry = tk.Entry(token_frame, textvariable=self.token_var, show="*", width=80)
        self.token_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=10, pady=10)
        self.show_token_var = tk.BooleanVar(value=False)
        tk.Checkbutton(
            token_frame,
            text="show",
            variable=self.show_token_var,
            command=self._toggle_token_visibility,
        ).pack(side=tk.RIGHT, padx=(0, 10))

        buttons = tk.Frame(root)
        buttons.pack(fill=tk.X, pady=(0, 12))
        self.install_button = tk.Button(
            buttons,
            text="Install / Update",
            command=self.install_or_update,
            width=18,
        )
        self.install_button.pack(side=tk.LEFT)
        self.send_button = tk.Button(
            buttons,
            text="Send",
            command=self.send_message,
            width=18,
        )
        self.send_button.pack(side=tk.LEFT, padx=(10, 0))
        tk.Button(buttons, text="Check Status", command=self.check_status, width=14).pack(
            side=tk.LEFT, padx=(10, 0)
        )

        self.status_var = tk.StringVar(value="Ready.")
        tk.Label(root, textvariable=self.status_var, anchor="w").pack(fill=tk.X)

        self.log = scrolledtext.ScrolledText(root, height=16, wrap=tk.WORD)
        self.log.pack(fill=tk.BOTH, expand=True, pady=(8, 8))

        input_frame = tk.Frame(root)
        input_frame.pack(fill=tk.X)
        self.message_var = tk.StringVar()
        self.message_entry = tk.Entry(input_frame, textvariable=self.message_var)
        self.message_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.message_entry.bind("<Return>", lambda _event: self.send_message())
        tk.Button(input_frame, text="Send", command=self.send_message, width=12).pack(
            side=tk.RIGHT, padx=(10, 0)
        )

        self._write_log(
            "1. Вставьте fixed API token из LLM Platform.\n"
            "2. Нажмите Install / Update.\n"
            "3. Пишите сообщения в поле внизу. Ответы Hermes появятся здесь.\n"
        )

    def _toggle_token_visibility(self) -> None:
        self.token_entry.configure(show="" if self.show_token_var.get() else "*")

    def _write_log(self, text: str) -> None:
        self.log.insert(tk.END, text)
        self.log.see(tk.END)

    def _queue_log(self, text: str) -> None:
        self.log_queue.put(text)

    def _drain_log_queue(self) -> None:
        while True:
            try:
                item = self.log_queue.get_nowait()
            except queue.Empty:
                break
            self._write_log(item)
        self.after(100, self._drain_log_queue)

    def _set_busy(self, busy: bool) -> None:
        state = tk.DISABLED if busy else tk.NORMAL
        self.install_button.configure(state=state)
        self.send_button.configure(state=state)
        self.message_entry.configure(state=state)

    def install_or_update(self) -> None:
        token = self.token_var.get().strip()
        if not token:
            messagebox.showwarning(APP_TITLE, "Введите LLM Platform API token.")
            self.token_entry.focus_set()
            return
        if self.worker and self.worker.is_alive():
            return
        self._set_busy(True)
        self.status_var.set("Installing...")
        self.worker = threading.Thread(target=self._install_worker, args=(token,), daemon=True)
        self.worker.start()

    def _install_worker(self, token: str) -> None:
        env = os.environ.copy()
        env["LLM_PLATFORM_TOKEN"] = token
        # Avoid broken system proxy values inherited from VPN tools.
        env["NO_PROXY"] = "*"
        env["HTTPS_PROXY"] = ""
        env["HTTP_PROXY"] = ""
        env["ALL_PROXY"] = ""

        command = (
            "$ErrorActionPreference = 'Stop'; "
            f"irm {INSTALLER_URL} | iex"
        )
        self._queue_log("\nStarting installer...\n")
        self._queue_log(f"Installer: {INSTALLER_URL}\n\n")
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
            )
        except FileNotFoundError:
            self._queue_log("PowerShell not found. This launcher is for Windows.\n")
            self.after(0, lambda: self.status_var.set("PowerShell not found."))
            self.after(0, lambda: self._set_busy(False))
            return

        assert process.stdout is not None
        for line in process.stdout:
            self._queue_log(line)
        code = process.wait()
        if code == 0:
            self._queue_log("\nInstall complete.\n")
            self.after(0, lambda: self.status_var.set("Installed. You can chat now."))
        else:
            self._queue_log(f"\nInstaller failed with exit code {code}.\n")
            self.after(0, lambda: self.status_var.set(f"Install failed: {code}"))
        self.after(0, lambda: self._set_busy(False))

    def send_message(self) -> None:
        message = self.message_var.get().strip()
        if not message:
            return
        cmd = solar_cmd_path()
        if not cmd.exists():
            messagebox.showinfo(
                APP_TITLE,
                "solar-hermes.cmd не найден. Сначала нажмите Install / Update.",
            )
            return
        if self.worker and self.worker.is_alive():
            return
        self.message_var.set("")
        self._write_log(f"\nYou: {message}\n")
        self._set_busy(True)
        self.status_var.set("Hermes is thinking...")
        self.worker = threading.Thread(target=self._chat_worker, args=(message,), daemon=True)
        self.worker.start()

    def _chat_worker(self, message: str) -> None:
        env = os.environ.copy()
        env["NO_PROXY"] = "*"
        env["HTTPS_PROXY"] = ""
        env["HTTP_PROXY"] = ""
        env["ALL_PROXY"] = ""

        command = [
            "cmd.exe",
            "/c",
            str(solar_cmd_path()),
            "--oneshot",
            message,
            "--continue",
            SESSION_NAME,
        ]
        self._queue_log("Hermes: ")
        try:
            kwargs = {}
            if sys.platform == "win32":
                kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                cwd=str(user_home()),
                env=env,
                **kwargs,
            )
        except Exception as exc:
            self._queue_log(f"\nFailed to start Hermes: {exc}\n")
            self.after(0, lambda: self.status_var.set("Hermes start failed."))
            self.after(0, lambda: self._set_busy(False))
            return

        assert process.stdout is not None
        output_parts: list[str] = []
        for line in process.stdout:
            output_parts.append(line)
        code = process.wait()
        output = "".join(output_parts).strip()
        if output:
            self._queue_log(output + "\n")
        if code != 0:
            self._queue_log(f"\n[Hermes exited with code {code}]\n")
            self.after(0, lambda: self.status_var.set(f"Hermes failed: {code}"))
        else:
            self.after(0, lambda: self.status_var.set("Ready."))
        self.after(0, lambda: self._set_busy(False))

    def check_status(self) -> None:
        hermes_home = find_hermes_home()
        cmd = solar_cmd_path()
        lines = [
            "\nStatus:",
            f"  Hermes home: {hermes_home}",
            f"  Hermes python: {hermes_home / 'hermes-agent' / 'venv' / 'Scripts' / 'python.exe'}",
            f"  solar-hermes.cmd: {cmd}",
            f"  installed: {'yes' if cmd.exists() else 'no'}",
            f"  GUI session: {SESSION_NAME}",
            "",
        ]
        self._write_log("\n".join(lines))


def main() -> int:
    if sys.platform != "win32":
        print("SolarHermes.exe is intended for Windows.")
    app = SolarHermesApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
