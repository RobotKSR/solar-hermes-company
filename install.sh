#!/usr/bin/env bash
set -euo pipefail

LLM_PUBLIC_BASE_URL="${LLM_PUBLIC_BASE_URL:-https://llm.solar-group.com}"
LLM_API_BASE_URL="${LLM_API_BASE_URL:-https://llm.solar-group.com/v1}"
LLM_MODEL="${LLM_MODEL:-qwen3.6}"
HEADROOM_PORT="${HEADROOM_PORT:-8787}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

printf "\nSolar Hermes installer\n"
printf "LLM: %s (%s)\n\n" "$LLM_API_BASE_URL" "$LLM_MODEL"

mkdir -p "$BIN_DIR"

prompt_for_token() {
  local token=""
  printf "Paste your LLM Platform API token for %s.\n" "$LLM_MODEL"
  printf "Input is hidden. The token will be stored locally in Hermes config.\n"
  if [ -t 0 ]; then
    read -r -s -p "LLM Platform token: " token
    printf "\n"
  elif [ -r /dev/tty ]; then
    read -r -s -p "LLM Platform token: " token < /dev/tty
    printf "\n" >/dev/tty
  else
    echo "Cannot prompt for token when stdin is not a terminal." >&2
    echo "Use: LLM_PLATFORM_TOKEN=<token> curl -fsSL .../install.sh | bash" >&2
    echo "Or:  curl -fsSL .../install.sh -o install.sh && bash install.sh" >&2
    exit 1
  fi
  printf "%s" "$token"
}

if [ -z "${LLM_PLATFORM_TOKEN:-}" ]; then
  LLM_PLATFORM_TOKEN="$(prompt_for_token)"
fi

if [ -z "$LLM_PLATFORM_TOKEN" ]; then
  echo "Token is required." >&2
  exit 1
fi

if ! command -v hermes >/dev/null 2>&1 && [ ! -x "$BIN_DIR/hermes" ]; then
  printf "Installing Hermes Agent...\n"
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
    | bash -s -- --skip-setup --skip-browser --non-interactive
fi

export PATH="$BIN_DIR:$PATH"

resolve_hermes_home() {
  local candidate
  if [ -n "${HERMES_HOME:-}" ] && [ -x "$HERMES_HOME/hermes-agent/venv/bin/python" ]; then
    printf "%s" "$HERMES_HOME"
    return 0
  fi
  for candidate in "$HOME/.hermes"; do
    if [ -x "$candidate/hermes-agent/venv/bin/python" ]; then
      printf "%s" "$candidate"
      return 0
    fi
  done
  if [ -n "${HERMES_HOME:-}" ]; then
    printf "%s" "$HERMES_HOME"
  else
    printf "%s" "$HOME/.hermes"
  fi
}

HERMES_HOME="$(resolve_hermes_home)"
export HERMES_HOME
mkdir -p "$HERMES_HOME"

HERMES_PY="$HERMES_HOME/hermes-agent/venv/bin/python"
if [ ! -x "$HERMES_PY" ]; then
  echo "Hermes Python venv not found at $HERMES_PY" >&2
  echo "Detected Hermes home: $HERMES_HOME" >&2
  echo "Re-run the Solar Hermes installer." >&2
  exit 1
fi

ensure_hermes_pip() {
  printf "Ensuring pip in Hermes environment...\n"
  if "$HERMES_PY" -m pip --version >/dev/null 2>&1; then
    return 0
  fi

  if "$HERMES_PY" -m ensurepip --upgrade >/dev/null 2>&1; then
    if "$HERMES_PY" -m pip --version >/dev/null 2>&1; then
      return 0
    fi
  fi

  printf "ensurepip was unavailable; downloading get-pip.py...\n"
  local get_pip="$HOME/.solar-hermes/get-pip.py"
  mkdir -p "$HOME/.solar-hermes"
  curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$get_pip"
  "$HERMES_PY" "$get_pip" >/dev/null
  if ! "$HERMES_PY" -m pip --version >/dev/null 2>&1; then
    echo "Could not bootstrap pip in Hermes environment." >&2
    exit 1
  fi
}

ensure_hermes_pip

printf "Installing Headroom into Hermes environment...\n"
printf "Installing headroom-ai[proxy]. This can take several minutes on first install.\n"
if ! "$HERMES_PY" -m pip install \
  --disable-pip-version-check \
  --prefer-binary \
  --upgrade \
  "headroom-ai[proxy]"; then
  echo "Headroom install failed." >&2
  exit 1
fi

if ! "$HERMES_PY" -c "import headroom.cli" >/dev/null 2>&1; then
  echo "Headroom Python package is installed incorrectly: cannot import headroom.cli." >&2
  exit 1
fi

export LLM_PLATFORM_TOKEN LLM_PUBLIC_BASE_URL LLM_API_BASE_URL LLM_MODEL HEADROOM_PORT HERMES_HOME
"$HERMES_PY" - <<'PY'
import os
from pathlib import Path
import yaml

home = Path(os.environ["HERMES_HOME"])
home.mkdir(parents=True, exist_ok=True)
env_path = home / ".env"
cfg_path = home / "config.yaml"

updates = {
    "OPENAI_API_KEY": os.environ["LLM_PLATFORM_TOKEN"],
    "OPENAI_TARGET_API_URL": os.environ["LLM_PUBLIC_BASE_URL"],
    "HEADROOM_PORT": os.environ["HEADROOM_PORT"],
    "HEADROOM_TELEMETRY": "off",
    "HERMES_STREAM_READ_TIMEOUT": "1800",
    "NO_PROXY": "*",
    "HTTPS_PROXY": "",
    "HTTP_PROXY": "",
    "ALL_PROXY": "",
}

existing = {}
if env_path.exists():
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            existing[line.split("=", 1)[0]] = line

for key, value in updates.items():
    existing[key] = f"{key}={value}"

env_path.write_text(
    "# Solar Hermes local secrets/config. Do not commit.\n"
    + "\n".join(existing[k] for k in sorted(existing))
    + "\n",
    encoding="utf-8",
)
env_path.chmod(0o600)

config = {}
if cfg_path.exists():
    try:
        config = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
    except Exception:
        backup = cfg_path.with_suffix(".yaml.solar-backup")
        cfg_path.replace(backup)
        config = {}

config["model"] = {
    "default": os.environ["LLM_MODEL"],
    "provider": "custom",
    "base_url": f"http://127.0.0.1:{os.environ['HEADROOM_PORT']}/v1",
    "api_key": os.environ["LLM_PLATFORM_TOKEN"],
}
agent = dict(config.get("agent") or {})
agent["max_tokens"] = int(os.environ.get("HERMES_MAX_TOKENS", "32768"))
agent["disable_api_streaming"] = False
config["agent"] = agent
display = dict(config.get("display") or {})
display["streaming"] = True
config["display"] = display
compression = dict(config.get("compression") or {})
compression["enabled"] = True
config["compression"] = compression

cfg_path.write_text(yaml.safe_dump(config, sort_keys=False, allow_unicode=True), encoding="utf-8")
PY

printf "Patching Hermes to honor agent.disable_api_streaming and agent.max_tokens...\n"
"$HERMES_PY" - <<'PY'
from pathlib import Path
import os

path = Path(os.environ["HERMES_HOME"]) / "hermes-agent" / "agent" / "agent_init.py"
text = path.read_text(encoding="utf-8")
marker = "agent.disable_api_streaming"
if marker not in text:
    old = "    agent.max_tokens = max_tokens  # None = use model default\n"
    new = '''    agent.max_tokens = max_tokens  # None = use model default
    try:
        from hermes_cli.config import load_config as _load_agent_cfg

        _agent_cfg = _load_agent_cfg().get("agent", {}) or {}
        if agent.max_tokens is None:
            _configured_max_tokens = _agent_cfg.get("max_tokens") or _agent_cfg.get("max_output_tokens")
            if _configured_max_tokens:
                agent.max_tokens = int(_configured_max_tokens)
        if _agent_cfg.get("disable_api_streaming") is True:
            # Solar Hermes: keep long tool-call responses on the stable
            # non-streaming path while Headroom still optimizes context locally.
            agent._disable_streaming = True
    except Exception:
        pass
'''
    if old not in text:
        raise SystemExit(f"Could not patch {path}: expected marker not found")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

cat > "$BIN_DIR/solar-hermes" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export HERMES_HOME="${HERMES_HOME}"
set -a
[ -f "\$HERMES_HOME/.env" ] && . "\$HERMES_HOME/.env"
set +a
PORT="\${HEADROOM_PORT:-${HEADROOM_PORT}}"
SCRIPTS_DIR="\$HERMES_HOME/hermes-agent/venv/bin"
PY_BIN="\$SCRIPTS_DIR/python"

resolve_hermes_bin() {
  if [ -x "\$SCRIPTS_DIR/hermes" ]; then
    printf "%s" "\$SCRIPTS_DIR/hermes"
    return 0
  fi
  if command -v hermes >/dev/null 2>&1; then
    command -v hermes
    return 0
  fi
  if [ -x "${BIN_DIR}/hermes" ]; then
    printf "%s" "${BIN_DIR}/hermes"
    return 0
  fi
  return 1
}

start_headroom_if_needed() {
  if curl -fsS "http://127.0.0.1:\${PORT}/health" >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "\$HERMES_HOME/logs"
  if [ -x "\$SCRIPTS_DIR/headroom" ]; then
    nohup "\$SCRIPTS_DIR/headroom" proxy --host 127.0.0.1 --port "\$PORT" \\
      --openai-api-url "${LLM_PUBLIC_BASE_URL}" \\
      > "\$HERMES_HOME/logs/headroom-proxy.log" 2>&1 &
  elif [ -x "\$PY_BIN" ] && "\$PY_BIN" -c "import headroom.cli" >/dev/null 2>&1; then
    nohup "\$PY_BIN" -m headroom.cli proxy --host 127.0.0.1 --port "\$PORT" \\
      --openai-api-url "${LLM_PUBLIC_BASE_URL}" \\
      > "\$HERMES_HOME/logs/headroom-proxy.log" 2>&1 &
  else
    echo "Headroom executable not found and python -m headroom.cli is unavailable. Re-run the Solar Hermes installer." >&2
    exit 1
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "http://127.0.0.1:\${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Headroom proxy did not become healthy on port \${PORT}." >&2
  exit 1
}

HERMES_BIN="\$(resolve_hermes_bin || true)"
if [ -z "\$HERMES_BIN" ]; then
  echo "Hermes executable not found in \$HERMES_HOME or PATH." >&2
  exit 1
fi

start_headroom_if_needed
exec "\$HERMES_BIN" "\$@"
EOF
chmod +x "$BIN_DIR/solar-hermes"

printf "\nDone.\n"
printf "Run: solar-hermes\n"
printf "Or pass a token non-interactively:\n"
printf "  LLM_PLATFORM_TOKEN=<token> curl -fsSL https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.sh | bash\n"
if ! printf "%s" "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  printf "If your shell cannot find solar-hermes yet, run:\n"
  printf "  export PATH=\"%s:\$PATH\"\n" "$BIN_DIR"
fi
