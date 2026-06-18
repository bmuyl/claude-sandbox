#!/usr/bin/env bash
# claude-sandbox — run Claude Code in an isolated Docker container
#
# Usage:
#   claude-sandbox [--timeout MINS] [project-path] ["prompt"]
#
# Env overrides (set in shell or ~/.config/claude-sandbox/env):
#   SANDBOX_CPUS    CPU limit (default: 4)
#   SANDBOX_MEMORY  Memory limit (default: 8g)
#
# Examples:
#   claude-sandbox                                              # interactive, cwd
#   claude-sandbox ~/git_stuff/voice                           # interactive
#   claude-sandbox ~/git_stuff/voice "run pipeline"            # headless
#   claude-sandbox --timeout 30 ~/git_stuff/voice "run pipe"   # with timeout

set -euo pipefail

IMAGE="claude-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

build_if_needed() {
  if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "🔨  Building $IMAGE (first run, takes ~10 min)…"
    docker build -t "$IMAGE" "$SCRIPT_DIR"
  fi
}

# ── Parse flags ──────────────────────────────────────────────────────────────
TIMEOUT_MINS=""
while [[ "${1:-}" == --* ]]; do
  case "${1:-}" in
    --timeout) TIMEOUT_MINS="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

PROJECT="${1:-$(pwd)}"
PROMPT="${2:-}"
PROJECT="$(cd "$PROJECT" && pwd)"

build_if_needed

# ── Docker args ──────────────────────────────────────────────────────────────
DOCKER_ARGS=(
  --rm
  -v "$PROJECT:/workspace"
  -w /workspace
)
# Optional resource limits — only applied when env vars are set
[ -n "${SANDBOX_CPUS:-}" ]   && DOCKER_ARGS+=(--cpus   "$SANDBOX_CPUS")
[ -n "${SANDBOX_MEMORY:-}" ] && DOCKER_ARGS+=(--memory "$SANDBOX_MEMORY")

# All projects at /repos (cross-project access for Claude)
if [ -d "$HOME/git_stuff" ]; then
  DOCKER_ARGS+=(-v "$HOME/git_stuff:/repos")
fi

# GitHub token: extract from live gh CLI (macOS stores tokens in Keychain,
# not in ~/.config/gh/hosts.yml, so mounting the dir alone isn't enough).
# GH_TOKEN is read by both `gh` and `git` (via the credential helper we set).
GH_TOKEN=$(gh auth token 2>/dev/null || true)
if [ -n "${GH_TOKEN:-}" ]; then
  DOCKER_ARGS+=(-e "GH_TOKEN=$GH_TOKEN")
  echo "🐙  GitHub: token injected ($(gh api user --jq .login 2>/dev/null || echo "gh"))"
else
  echo "⚠️  GitHub: no token found (gh auth login may be needed)"
fi

# Persistent memory: Claude Code stores per-project memory here
DOCKER_ARGS+=(-v "claude-sandbox-memory:/home/claude/.claude/projects")

# Package caches: reuse across runs for fast installs
DOCKER_ARGS+=(
  -v "claude-sandbox-uv-cache:/home/claude/.cache/uv"
  -v "claude-sandbox-npm-cache:/home/claude/.npm"
  -v "claude-sandbox-pip-cache:/home/claude/.cache/pip"
)

# Mount Mac's ~/.claude.json so the TUI has account metadata and skips login
if [ -f "$HOME/.claude.json" ]; then
  DOCKER_ARGS+=(-v "$HOME/.claude.json:/tmp/claude-auth/claude.json:ro")
fi

# ── Auth ─────────────────────────────────────────────────────────────────────
# If ANTHROPIC_API_KEY is set in the env file (or shell), use it and skip
# the Keychain — useful for switching to a second account without logging
# out of the Mac account.
_ENV_API_KEY=$(grep -E '^ANTHROPIC_API_KEY=' "$HOME/.config/claude-sandbox/env" 2>/dev/null | tail -1 | cut -d= -f2- || true)

if [ -n "${_ENV_API_KEY:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  # API key takes explicit priority — don't inject Keychain token on top of it
  echo "🔑  Auth: ANTHROPIC_API_KEY (from env file)"
else
  # Default: extract OAuth token from macOS Keychain
  _CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  OAUTH_TOKEN=$(echo "$_CREDS" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['claudeAiOauth']['accessToken'])" 2>/dev/null || true)
  REFRESH_TOKEN=$(echo "$_CREDS" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['claudeAiOauth']['refreshToken'])" 2>/dev/null || true)

  if [ -n "${OAUTH_TOKEN:-}" ]; then
    DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_TOKEN")
    [ -n "${REFRESH_TOKEN:-}" ] && DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_REFRESH_TOKEN=$REFRESH_TOKEN")
    echo "🔑  Auth: Mac Keychain token (Max subscription)"
  else
    echo "⚠️  No auth found. Log in on your Mac, or add ANTHROPIC_API_KEY to ~/.config/claude-sandbox/env"
  fi
fi

# ── Secrets: load extra env vars from ~/.config/claude-sandbox/env ───────────
ENV_FILE="$HOME/.config/claude-sandbox/env"
if [ ! -f "$ENV_FILE" ]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<'EOF'
# claude-sandbox secrets — one KEY=VALUE per line, comments with #
# Example:
# HF_TOKEN=hf_...
# OPENAI_API_KEY=sk-...
EOF
fi
if grep -qvE '^\s*#|^\s*$' "$ENV_FILE" 2>/dev/null; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    DOCKER_ARGS+=(-e "$line")
  done < "$ENV_FILE"
  echo "🔐  Secrets: loaded from $ENV_FILE"
fi

CLAUDE_CMD=(claude --dangerously-skip-permissions --model opus --effort high)

# ── Run ──────────────────────────────────────────────────────────────────────
if [ -n "$PROMPT" ]; then
  LOG_DIR="$PROJECT/.claude-sandbox-logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"
  echo "🤖  Headless run in $PROJECT"
  [ -n "$TIMEOUT_MINS" ] && echo "⏱️   Timeout: ${TIMEOUT_MINS}m"
  echo "📝  Log: $LOG_FILE"

  if [ -n "$TIMEOUT_MINS" ]; then
    # Named container so we can docker-kill it after the timeout
    CNAME="cs-$$"
    TARGS=()
    for arg in "${DOCKER_ARGS[@]}"; do
      [ "$arg" != "--rm" ] && TARGS+=("$arg")
    done
    TARGS+=(--name "$CNAME")

    docker run "${TARGS[@]}" "$IMAGE" "${CLAUDE_CMD[@]}" -p "$PROMPT" 2>&1 | tee "$LOG_FILE" &
    BGPID=$!
    (sleep $((TIMEOUT_MINS * 60)) && echo "⏱️   Timeout reached, stopping..." && docker kill "$CNAME" 2>/dev/null) &
    KILLPID=$!

    set +e
    wait $BGPID
    set -e

    EXIT_CODE=$(docker inspect --format='{{.State.ExitCode}}' "$CNAME" 2>/dev/null || echo "1")
    docker rm "$CNAME" 2>/dev/null || true
    kill $KILLPID 2>/dev/null || true
  else
    set +e
    docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${CLAUDE_CMD[@]}" -p "$PROMPT" 2>&1 | tee "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
    set -e
  fi

  if [ "$EXIT_CODE" -eq 0 ]; then
    osascript -e "display notification \"✅ Done: $(basename "$PROJECT")\" with title \"claude-sandbox\" sound name \"Glass\"" 2>/dev/null || true
  else
    osascript -e "display notification \"❌ Failed (exit $EXIT_CODE): $(basename "$PROJECT")\" with title \"claude-sandbox\" sound name \"Basso\"" 2>/dev/null || true
  fi

  exit "$EXIT_CODE"
else
  echo "🤖  Interactive session in $PROJECT"
  docker run -it "${DOCKER_ARGS[@]}" "$IMAGE" "${CLAUDE_CMD[@]}"
fi
