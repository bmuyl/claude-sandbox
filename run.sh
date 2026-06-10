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

PROJECT="${1:-$(pwd)}"
PROMPT="${2:-}"

# Resolve to absolute path
PROJECT="$(cd "$PROJECT" && pwd)"

IMAGE="claude-sandbox"

# Build image if it doesn't exist yet
if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "🔨  Building $IMAGE (first run, takes ~5 min)…"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

# Mount credentials to /tmp/claude-auth/ so the entrypoint can copy them
# with correct ownership — direct home mounts hit permission issues (file is 600)
DOCKER_ARGS=(
  --rm
  -v "$PROJECT:/workspace"
  -w /workspace
)

if [ -f "$HOME/.claude.json" ]; then
  DOCKER_ARGS+=(-v "$HOME/.claude.json:/tmp/claude-auth/claude.json:ro")
fi

if [ -d "$HOME/.claude" ]; then
  DOCKER_ARGS+=(-v "$HOME/.claude:/tmp/claude-auth/claude-dir:ro")
fi

# API key takes precedence over mounted credentials if set
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  DOCKER_ARGS+=(-e ANTHROPIC_API_KEY)
fi

if [ -n "$PROMPT" ]; then
  echo "🤖  Running headless in $PROJECT"
  docker run "${DOCKER_ARGS[@]}" "$IMAGE" claude --dangerously-skip-permissions -p "$PROMPT"
else
  echo "🤖  Starting interactive session in $PROJECT"
  docker run -it "${DOCKER_ARGS[@]}" "$IMAGE" claude --dangerously-skip-permissions
fi
