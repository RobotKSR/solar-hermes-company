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

$SolarHome = Join-Path $HOME ".solar-hermes"
$BinDir = Join-Path $SolarHome "bin"
New-Item -ItemType Directory -Force -Path $SolarHome, $BinDir | Out-Null

function Sync-ProcessPath {
    $Parts = @()
    $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($MachinePath) {
        $Parts += $MachinePath
    }
    if ($UserPath) {
        $Parts += $UserPath
    }
    if ($Parts.Count -gt 0) {
        $env:Path = ($Parts -join ";")
    }
}

Sync-ProcessPath

$Token = $env:LLM_PLATFORM_TOKEN
if (-not $Token) {
    Write-Host "Paste your LLM Platform API token for $LlmModel."
    Write-Host "Input is hidden. The token will be stored locally in Hermes config."
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

if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Hermes Agent..."
    $HermesInstaller = Join-Path $env:TEMP "hermes-install.ps1"
    Invoke-WebRequest -UseBasicParsing `
        -Uri "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1" `
        -OutFile $HermesInstaller
    try {
        & powershell -ExecutionPolicy Bypass -File $HermesInstaller -SkipSetup -NoPlaywright -NonInteractive
        if ($LASTEXITCODE -ne 0) {
            throw "Hermes installer exited with code $LASTEXITCODE"
        }
    }
    catch {
        Write-Warning "Non-interactive Hermes install failed, retrying default installer: $_"
        & powershell -ExecutionPolicy Bypass -File $HermesInstaller
        if ($LASTEXITCODE -ne 0) {
            throw "Hermes installer exited with code $LASTEXITCODE"
        }
    }
    Sync-ProcessPath
}

function Resolve-HermesHome {
    $Candidates = @()
    if ($env:HERMES_HOME) {
        $Candidates += $env:HERMES_HOME
    }
    if ($env:LOCALAPPDATA) {
        $Candidates += (Join-Path $env:LOCALAPPDATA "hermes")
    }
    $Candidates += (Join-Path $HOME ".hermes")

    foreach ($Candidate in $Candidates) {
        if (-not $Candidate) {
            continue
        }
        $Python = Join-Path $Candidate "hermes-agent\venv\Scripts\python.exe"
        if (Test-Path $Python) {
            return $Candidate
        }
    }

    if ($Candidates.Count -gt 0) {
        return $Candidates[0]
    }
    return (Join-Path $HOME ".hermes")
}

$HermesHome = Resolve-HermesHome
New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null
$env:HERMES_HOME = $HermesHome

$HermesPython = Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"
if (-not (Test-Path $HermesPython)) {
    throw "Hermes Python venv not found at $HermesPython. Detected Hermes home: $HermesHome. Re-run Install / Update from SolarHermes.exe."
}

function Ensure-HermesPip {
    Write-Host "Ensuring pip in Hermes environment..."

    & $HermesPython -m pip --version | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    & $HermesPython -m ensurepip --upgrade | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & $HermesPython -m pip --version | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }
    }

    Write-Host "ensurepip was unavailable; downloading get-pip.py..."
    $GetPip = Join-Path $SolarHome "get-pip.py"
    Invoke-WebRequest -UseBasicParsing -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $GetPip
    & $HermesPython $GetPip | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not bootstrap pip in Hermes environment."
    }

    & $HermesPython -m pip --version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "pip is still unavailable in Hermes environment after bootstrap."
    }
}

Ensure-HermesPip

Write-Host "Installing Headroom into Hermes environment..."
Write-Host "Installing headroom-ai[proxy] with binary wheels only. This can take several minutes on first install."
& $HermesPython -m pip install `
    --disable-pip-version-check `
    --prefer-binary `
    --only-binary=:all: `
    --progress-bar on `
    --upgrade `
    "headroom-ai[proxy]"
if ($LASTEXITCODE -ne 0) {
    throw "Headroom install failed. Check the technical details above. If pip reports 'No matching distribution found', install Python 3.11/3.12 Hermes or use a newer Headroom wheel."
}
& $HermesPython -c "import headroom.cli" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Headroom Python package is installed incorrectly: cannot import headroom.cli."
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
`$HermesPython = Join-Path "`$env:HERMES_HOME" "hermes-agent\venv\Scripts\python.exe"
`$Hermes = Join-Path "`$env:HERMES_HOME" "hermes-agent\venv\Scripts\hermes.exe"
function Resolve-HeadroomLaunch {
    `$ScriptsDir = Join-Path "`$env:HERMES_HOME" "hermes-agent\venv\Scripts"
    foreach (`$Name in @("headroom.exe", "headroom.cmd", "headroom.ps1", "headroom")) {
        `$Candidate = Join-Path `$ScriptsDir `$Name
        if (Test-Path `$Candidate) {
            return @{ File = `$Candidate; Args = @() }
        }
    }
    if (Test-Path `$HermesPython) {
        & `$HermesPython -c "import headroom.cli" | Out-Null
        if (`$LASTEXITCODE -eq 0) {
            return @{ File = `$HermesPython; Args = @("-m", "headroom.cli") }
        }
    }
    throw "Headroom executable not found and python -m headroom.cli is unavailable. Re-run Install / Update."
}
if (-not (Test-Path `$Hermes)) {
    `$HermesCommand = Get-Command hermes -ErrorAction SilentlyContinue
    if (`$HermesCommand) {
        `$Hermes = `$HermesCommand.Source
    }
    else {
        throw "Hermes executable not found in `$env:HERMES_HOME or PATH"
    }
}
try {
    Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:`$Port/health" -TimeoutSec 2 | Out-Null
}
catch {
    New-Item -ItemType Directory -Force -Path (Join-Path "`$env:HERMES_HOME" "logs") | Out-Null
    `$HeadroomLaunch = Resolve-HeadroomLaunch
    `$HeadroomArgs = @() + `$HeadroomLaunch.Args + @("proxy","--host","127.0.0.1","--port",`$Port,"--openai-api-url","$LlmPublicBaseUrl")
    Start-Process -FilePath `$HeadroomLaunch.File -ArgumentList `$HeadroomArgs -WindowStyle Hidden
    Start-Sleep -Seconds 3
}
& `$Hermes @args
"@ | Set-Content -Encoding UTF8 $SolarHermesPs1

$SolarHermesCmd = Join-Path $BinDir "solar-hermes.cmd"
@"
@echo off
powershell -ExecutionPolicy Bypass -File "$SolarHermesPs1" %*
"@ | Set-Content -Encoding ASCII $SolarHermesCmd

$CurrentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($CurrentUserPath -notlike "*$BinDir*") {
    if ($CurrentUserPath) {
        [Environment]::SetEnvironmentVariable("Path", "$CurrentUserPath;$BinDir", "User")
    }
    else {
        [Environment]::SetEnvironmentVariable("Path", $BinDir, "User")
    }
}
Sync-ProcessPath

Write-Host ""
Write-Host "Done."
Write-Host "Run: solar-hermes"
Write-Host "If PowerShell cannot find it yet, run:"
Write-Host "  $SolarHermesCmd"
