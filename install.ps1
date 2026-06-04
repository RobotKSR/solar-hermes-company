param(
    [string]$LlmPublicBaseUrl = "https://llm.solar-group.com",
    [string]$LlmApiBaseUrl = "https://llm.solar-group.com/v1",
    [string]$LlmModel = "qwen3.6",
    [int]$HeadroomPort = 8787
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Solar Hermes installer"
Write-Host "LLM: $LlmApiBaseUrl ($LlmModel)"
Write-Host ""

$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $HOME ".hermes" }
$SolarHome = Join-Path $HOME ".solar-hermes"
$BinDir = Join-Path $SolarHome "bin"
New-Item -ItemType Directory -Force -Path $HermesHome, $BinDir | Out-Null

if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Hermes Agent..."
    $HermesInstaller = Join-Path $env:TEMP "hermes-install.ps1"
    Invoke-WebRequest -UseBasicParsing `
        -Uri "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1" `
        -OutFile $HermesInstaller
    try {
        & powershell -ExecutionPolicy Bypass -File $HermesInstaller -SkipSetup -NoPlaywright -NonInteractive
    }
    catch {
        Write-Warning "Non-interactive Hermes install failed, retrying default installer: $_"
        & powershell -ExecutionPolicy Bypass -File $HermesInstaller
    }
}

$HermesPython = Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"
if (-not (Test-Path $HermesPython)) {
    throw "Hermes Python venv not found at $HermesPython. Open a new PowerShell and rerun installer."
}

Write-Host "Installing Headroom into Hermes environment..."
& $HermesPython -m pip install --upgrade pip | Out-Null
& $HermesPython -m pip install --upgrade "headroom-ai[proxy,mcp]" | Out-Null

$Token = $env:LLM_PLATFORM_TOKEN
if (-not $Token) {
    Write-Host ""
    Write-Host "Paste your LLM Platform API token for $LlmModel."
    $SecureToken = Read-Host "LLM Platform token" -AsSecureString
    $Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
    try {
        $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr)
    }
}
if (-not $Token) {
    throw "Token is required."
}

$EnvPath = Join-Path $HermesHome ".env"
$ConfigPath = Join-Path $HermesHome "config.yaml"

@"
# Solar Hermes local secrets/config. Do not commit.
ALL_PROXY=
HEADROOM_PORT=$HeadroomPort
HEADROOM_TELEMETRY=off
HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=*
OPENAI_API_KEY=$Token
OPENAI_TARGET_API_URL=$LlmPublicBaseUrl
"@ | Set-Content -Encoding UTF8 $EnvPath

@"
model:
  default: $LlmModel
  provider: custom
  base_url: http://127.0.0.1:$HeadroomPort/v1
  api_key: headroom-local
agent:
  max_tokens: 32768
  disable_api_streaming: true
display:
  streaming: false
compression:
  enabled: true
"@ | Set-Content -Encoding UTF8 $ConfigPath

Write-Host "Patching Hermes to honor agent.disable_api_streaming and agent.max_tokens..."
$PatchScript = @'
from pathlib import Path
import os

home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
path = home / "hermes-agent" / "agent" / "agent_init.py"
text = path.read_text(encoding="utf-8")
if "agent.disable_api_streaming" not in text:
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
'@
$PatchPath = Join-Path $SolarHome "patch_hermes.py"
$PatchScript | Set-Content -Encoding UTF8 $PatchPath
$env:HERMES_HOME = $HermesHome
& $HermesPython $PatchPath

$SolarHermesPs1 = Join-Path $BinDir "solar-hermes.ps1"
@"
`$ErrorActionPreference = "Stop"
`$env:HERMES_HOME = "$HermesHome"
Get-Content "`$env:HERMES_HOME\.env" | ForEach-Object {
    if (`$_ -match "^\s*([^#][^=]+)=(.*)$") {
        [Environment]::SetEnvironmentVariable(`$matches[1], `$matches[2], "Process")
    }
}
`$Port = if (`$env:HEADROOM_PORT) { `$env:HEADROOM_PORT } else { "$HeadroomPort" }
`$Headroom = Join-Path "`$env:HERMES_HOME" "hermes-agent\venv\Scripts\headroom.exe"
`$Hermes = Join-Path "`$env:HERMES_HOME" "hermes-agent\venv\Scripts\hermes.exe"
try {
    Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:`$Port/health" -TimeoutSec 2 | Out-Null
}
catch {
    New-Item -ItemType Directory -Force -Path (Join-Path "`$env:HERMES_HOME" "logs") | Out-Null
    Start-Process -FilePath `$Headroom -ArgumentList @("proxy","--host","127.0.0.1","--port",`$Port,"--openai-api-url","$LlmPublicBaseUrl") -WindowStyle Hidden
    Start-Sleep -Seconds 3
}
& `$Hermes @args
"@ | Set-Content -Encoding UTF8 $SolarHermesPs1

$SolarHermesCmd = Join-Path $BinDir "solar-hermes.cmd"
@"
@echo off
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.solar-hermes\bin\solar-hermes.ps1" %*
"@ | Set-Content -Encoding ASCII $SolarHermesCmd

$CurrentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($CurrentUserPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$CurrentUserPath;$BinDir", "User")
}

Write-Host ""
Write-Host "Done."
Write-Host "Run: solar-hermes"
Write-Host "If PowerShell cannot find it yet, open a new terminal or run:"
Write-Host "  $SolarHermesCmd"
