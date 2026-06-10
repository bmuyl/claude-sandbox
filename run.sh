#!/usr/bin/env bash
# claude-sandbox — run Claude Code in an isolated Docker container
#
# Usage:
#   claude-sandbox [project-path] ["prompt"]
#
# Examples:
#   claude-sandbox ~/git_stuff/tactic                        # interactive session
#   claude-sandbox ~/git_stuff/tactic "add wind shadow"      # headless one-shot
#   claude-sandbox                                            # uses current dir

set -euo pipefail

IMAGE="claude-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

build_if_needed() {
  if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "🔨  Building $IMAGE (first run, takes ~5 min)…"
    docker build -t "$IMAGE" "$SCRIPT_DIR"
  fi
}

# ── Normal run ──────────────────────────────────────────────────────────────────
PROJECT="${1:-$(pwd)}"
PROMPT="${2:-}"
PROJECT="$(cd "$PROJECT" && pwd)"

build_if_needed

DOCKER_ARGS=(--rm -v "$PROJECT:/workspace" -w /workspace)

# Mount Mac's ~/.claude.json so the TUI has account metadata (display name,
# subscription info) and skips the first-run login screen.
# The actual auth token comes from the Keychain env var below.
if [ -f "$HOME/.claude.json" ]; then
  DOCKER_ARGS+=(-v "$HOME/.claude.json:/tmp/claude-auth/claude.json:ro")
fi

# Extract the OAuth token from macOS Keychain at runtime — always uses the
# current token, which the Mac Claude Code app keeps refreshed automatically.
OAUTH_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['claudeAiOauth']['accessToken'])" 2>/dev/null || true)

if [ -n "${OAUTH_TOKEN:-}" ]; then
  DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_TOKEN")
  echo "🔑  Auth: using Mac Keychain token (Max subscription)"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  DOCKER_ARGS+=(-e ANTHROPIC_API_KEY)
  echo "🔑  Auth: using ANTHROPIC_API_KEY"
else
  echo "⚠️  No auth found. Make sure Claude Code is running on your Mac, or set ANTHROPIC_API_KEY."
fi

if [ -n "$PROMPT" ]; then
  echo "🤖  Running headless in $PROJECT"
  docker run "${DOCKER_ARGS[@]}" "$IMAGE" claude --dangerously-skip-permissions -p "$PROMPT"
else
  echo "🤖  Starting interactive session in $PROJECT"
  docker run -it "${DOCKER_ARGS[@]}" "$IMAGE" claude --dangerously-skip-permissions
fi
