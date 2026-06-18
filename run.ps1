#!/usr/bin/env pwsh
# claude-sandbox — run Claude Code in an isolated Docker container (Windows / PowerShell port of run.sh)
#
# Usage:
#   .\run.ps1 [-Project <path>] [-Prompt "<prompt>"] [-Timeout <mins>]
#
# Env overrides (set in shell or %USERPROFILE%\.config\claude-sandbox\env):
#   SANDBOX_CPUS    CPU limit (default: 4)
#   SANDBOX_MEMORY  Memory limit (default: 8g)
#
# Examples:
#   .\run.ps1                                                   # interactive, cwd
#   .\run.ps1 C:\Users\bmuyl\git_stuff\voice                    # interactive
#   .\run.ps1 C:\Users\bmuyl\git_stuff\voice "run pipeline"     # headless
#   .\run.ps1 C:\Users\bmuyl\git_stuff\voice "run pipe" -Timeout 30

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Project = (Get-Location).Path,
  [Parameter(Position = 1)][string]$Prompt  = "",
  [int]$Timeout = 0
)

$ErrorActionPreference = "Stop"
$Image     = "claude-sandbox"
$ScriptDir = $PSScriptRoot

# Docker on Windows wants forward-slash, drive-lettered bind sources (C:/Users/...).
function ConvertTo-DockerPath([string]$p) { return ($p -replace '\\', '/') }

# ── Pre-flight: Docker must be running ─────────────────────────────────────────
docker info *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Error "Docker doesn't appear to be running. Start Docker Desktop and try again."
  exit 1
}

# ── Build image on first run ───────────────────────────────────────────────────
docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "🔨  Building $Image (first run, takes ~10 min)…"
  docker build -t $Image $ScriptDir
  if ($LASTEXITCODE -ne 0) { Write-Error "docker build failed"; exit 1 }
}

# ── Resolve project path ─────────────────────────────────────────────────────
$Project = (Resolve-Path $Project).Path

# ── Docker args ──────────────────────────────────────────────────────────────
$cpus   = if ($env:SANDBOX_CPUS)   { $env:SANDBOX_CPUS }   else { "4" }
$memory = if ($env:SANDBOX_MEMORY) { $env:SANDBOX_MEMORY } else { "8g" }

$dockerArgs = @(
  "--rm"
  "-v", "$(ConvertTo-DockerPath $Project):/workspace"
  "-w", "/workspace"
  "--cpus", $cpus
  "--memory", $memory
)

# All projects at /repos (cross-project access for Claude)
$gitStuff = Join-Path $env:USERPROFILE "git_stuff"
if (Test-Path $gitStuff) {
  $dockerArgs += @("-v", "$(ConvertTo-DockerPath $gitStuff):/repos")
}

# GitHub token: from gh CLI if present, else GH_TOKEN env. Read by both gh and git.
$ghToken = $null
if (Get-Command gh -ErrorAction SilentlyContinue) {
  $ghToken = (gh auth token 2>$null)
}
if (-not $ghToken -and $env:GH_TOKEN) { $ghToken = $env:GH_TOKEN }
if ($ghToken) {
  $dockerArgs += @("-e", "GH_TOKEN=$ghToken")
  $who = $null
  if (Get-Command gh -ErrorAction SilentlyContinue) { $who = (gh api user --jq .login 2>$null) }
  Write-Host "🐙  GitHub: token injected ($(if ($who) { $who } else { 'gh' }))"
} else {
  Write-Host "⚠️  GitHub: no token found (install gh + 'gh auth login', or set GH_TOKEN)"
}

# Persistent memory: Claude Code stores per-project memory here
$dockerArgs += @("-v", "claude-sandbox-memory:/home/claude/.claude/projects")

# Package caches: reuse across runs for fast installs
$dockerArgs += @(
  "-v", "claude-sandbox-uv-cache:/home/claude/.cache/uv"
  "-v", "claude-sandbox-npm-cache:/home/claude/.npm"
  "-v", "claude-sandbox-pip-cache:/home/claude/.cache/pip"
)

# Mount host ~/.claude.json so the TUI has account metadata and skips login
$claudeJson = Join-Path $env:USERPROFILE ".claude.json"
if (Test-Path $claudeJson) {
  $dockerArgs += @("-v", "$(ConvertTo-DockerPath $claudeJson):/tmp/claude-auth/claude.json:ro")
}

# ── Auth ─────────────────────────────────────────────────────────────────────
# If ANTHROPIC_API_KEY is set (env file or shell), use it and skip the OAuth token.
$envFile   = Join-Path $env:USERPROFILE ".config\claude-sandbox\env"
$envApiKey = $null
if (Test-Path $envFile) {
  $match = Select-String -Path $envFile -Pattern '^\s*ANTHROPIC_API_KEY=' -ErrorAction SilentlyContinue | Select-Object -Last 1
  if ($match) { $envApiKey = ($match.Line -replace '^\s*ANTHROPIC_API_KEY=', '').Trim() }
}

if ($envApiKey -or $env:ANTHROPIC_API_KEY) {
  # API key takes explicit priority — don't inject the OAuth token on top of it.
  Write-Host "🔑  Auth: ANTHROPIC_API_KEY"
  # env-file keys are passed below in the secrets loop; pass a shell-only key explicitly.
  if ($env:ANTHROPIC_API_KEY -and -not $envApiKey) {
    $dockerArgs += @("-e", "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY")
  }
} else {
  # Default: read the OAuth token from the Windows credentials file.
  $credPath = Join-Path $env:USERPROFILE ".claude\.credentials.json"
  $oauth = $null; $refresh = $null
  if (Test-Path $credPath) {
    try {
      $creds   = Get-Content $credPath -Raw | ConvertFrom-Json
      $oauth   = $creds.claudeAiOauth.accessToken
      $refresh = $creds.claudeAiOauth.refreshToken
    } catch {}
  }
  if ($oauth) {
    $dockerArgs += @("-e", "CLAUDE_CODE_OAUTH_TOKEN=$oauth")
    if ($refresh) { $dockerArgs += @("-e", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN=$refresh") }
    Write-Host "🔑  Auth: Windows credentials file (Max subscription)"
  } else {
    Write-Host "⚠️  No auth found. Log in with 'claude' on Windows, or add ANTHROPIC_API_KEY to $envFile"
  }
}

# ── Secrets: load extra env vars from %USERPROFILE%\.config\claude-sandbox\env ──
if (-not (Test-Path $envFile)) {
  New-Item -ItemType Directory -Force -Path (Split-Path $envFile) | Out-Null
  @"
# claude-sandbox secrets — one KEY=VALUE per line, comments with #
# Example:
# HF_TOKEN=hf_...
# OPENAI_API_KEY=sk-...
"@ | Set-Content -Path $envFile -Encoding utf8
}
$secretLines = Get-Content $envFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }
if ($secretLines) {
  foreach ($line in $secretLines) { $dockerArgs += @("-e", $line.Trim()) }
  Write-Host "🔐  Secrets: loaded from $envFile"
}

$claudeCmd = @("claude", "--dangerously-skip-permissions", "--model", "opus", "--effort", "high")

# ── Run ──────────────────────────────────────────────────────────────────────
if ($Prompt) {
  $logDir = Join-Path $Project ".claude-sandbox-logs"
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $logFile = Join-Path $logDir ("{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
  Write-Host "🤖  Headless run in $Project"
  if ($Timeout -gt 0) { Write-Host "⏱️   Timeout: ${Timeout}m" }
  Write-Host "📝  Log: $logFile"

  if ($Timeout -gt 0) {
    # Named container (no --rm) so a watchdog job can kill it after the timeout.
    $cname   = "cs-$PID"
    $runArgs = @($dockerArgs | Where-Object { $_ -ne "--rm" }) + @("--name", $cname)
    $watchdog = Start-Job -ScriptBlock {
      param($mins, $name)
      Start-Sleep -Seconds ($mins * 60)
      docker kill $name 2>$null
    } -ArgumentList $Timeout, $cname

    docker run @runArgs $Image @claudeCmd -p $Prompt 2>&1 | Tee-Object -FilePath $logFile
    $exitCode = $LASTEXITCODE

    Stop-Job   $watchdog -ErrorAction SilentlyContinue
    Remove-Job $watchdog -Force -ErrorAction SilentlyContinue
    docker rm  $cname 2>$null | Out-Null
  } else {
    docker run @dockerArgs $Image @claudeCmd -p $Prompt 2>&1 | Tee-Object -FilePath $logFile
    $exitCode = $LASTEXITCODE
  }

  # Desktop notification: BurntToast if installed, else a console beep.
  $name = Split-Path $Project -Leaf
  if ($exitCode -eq 0) { $msg = "✅ Done: $name" } else { $msg = "❌ Failed (exit $exitCode): $name" }
  if (Get-Module -ListAvailable -Name BurntToast) {
    Import-Module BurntToast -ErrorAction SilentlyContinue
    New-BurntToastNotification -Text "claude-sandbox", $msg -ErrorAction SilentlyContinue
  } else {
    try { if ($exitCode -eq 0) { [console]::Beep(880, 200) } else { [console]::Beep(220, 400) } } catch {}
  }
  Write-Host $msg
  exit $exitCode
} else {
  Write-Host "🤖  Interactive session in $Project"
  docker run -it @dockerArgs $Image @claudeCmd
  exit $LASTEXITCODE
}
