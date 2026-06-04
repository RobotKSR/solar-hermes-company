#!/usr/bin/env bash
set -euo pipefail

LLM_PUBLIC_BASE_URL="${LLM_PUBLIC_BASE_URL:-https://llm.solar-group.com}"
LLM_API_BASE_URL="${LLM_API_BASE_URL:-https://llm.solar-group.com/v1}"
LLM_MODEL="${LLM_MODEL:-qwen3.6}"
HEADROOM_PORT="${HEADROOM_PORT:-8787}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

printf "\nSolar Hermes installer\n"
printf "LLM: %s (%s)\n\n" "$LLM_API_BASE_URL" "$LLM_MODEL"

mkdir -p "$BIN_DIR" "$HERMES_HOME"

if ! command -v hermes >/dev/null 2>&1 && [ ! -x "$BIN_DIR/hermes" ]; then
  printf "Installing Hermes Agent...\n"
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
    | bash -s -- --skip-setup --skip-browser --non-interactive
fi

export PATH="$BIN_DIR:$HERMES_HOME/bin:$PATH"

HERMES_PY="$HERMES_HOME/hermes-agent/venv/bin/python"
HERMES_HEADROOM="$HERMES_HOME/hermes-agent/venv/bin/headroom"

if [ ! -x "$HERMES_PY" ]; then
  echo "Hermes Python venv not found at $HERMES_PY" >&2
  echo "Try opening a new terminal and rerunning this installer." >&2
  exit 1
fi

printf "Installing Headroom into Hermes environment...\n"
"$HERMES_PY" -m pip install --upgrade pip >/dev/null
"$HERMES_PY" -m pip install --upgrade "headroom-ai[proxy,mcp]" >/dev/null

if [ -z "${LLM_PLATFORM_TOKEN:-}" ]; then
  printf "\nPaste your LLM Platform API token for %s.\n" "$LLM_MODEL"
  printf "Input is hidden. The token will be stored locally in %s/.env\n" "$HERMES_HOME"
  read -r -s -p "LLM Platform token: " LLM_PLATFORM_TOKEN
  printf "\n"
fi

if [ -z "$LLM_PLATFORM_TOKEN" ]; then
  echo "Token is required." >&2
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
    "NO_PROXY": "*",
    "HTTPS_PROXY": "",
    "HTTP_PROXY": "",
    "ALL_PROXY": "",
}

lines = []
existing = {}
if env_path.exists():
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            existing[line.split("=", 1)[0]] = line
        else:
            lines.append(line)
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
    "api_key": "headroom-local",
}
agent = dict(config.get("agent") or {})
agent["max_tokens"] = int(os.environ.get("HERMES_MAX_TOKENS", "32768"))
agent["disable_api_streaming"] = True
config["agent"] = agent
display = dict(config.get("display") or {})
display["streaming"] = False
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
HEADROOM_PORT="\${HEADROOM_PORT:-${HEADROOM_PORT}}"
HEADROOM_BIN="\$HERMES_HOME/hermes-agent/venv/bin/headroom"
HERMES_BIN="${BIN_DIR}/hermes"

if ! curl -fsS "http://127.0.0.1:\$HEADROOM_PORT/health" >/dev/null 2>&1; then
  mkdir -p "\$HERMES_HOME/logs"
  nohup "\$HEADROOM_BIN" proxy --host 127.0.0.1 --port "\$HEADROOM_PORT" \\
    --openai-api-url "${LLM_PUBLIC_BASE_URL}" \\
    > "\$HERMES_HOME/logs/headroom-proxy.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS "http://127.0.0.1:\$HEADROOM_PORT/health" >/dev/null 2>&1 && break
    sleep 1
  done
fi

exec "\$HERMES_BIN" "\$@"
EOF
chmod +x "$BIN_DIR/solar-hermes"

printf "\nDone.\n"
printf "Run: solar-hermes\n"
printf "If your shell cannot find it yet, run: export PATH=\"%s:\\$PATH\"\n" "$BIN_DIR"
