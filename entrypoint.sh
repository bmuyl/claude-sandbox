#!/bin/bash
# Copy host credentials into the claude user's home with correct permissions.

if [ -f /tmp/claude-auth/claude.json ]; then
  cp /tmp/claude-auth/claude.json "$HOME/.claude.json"
  chmod 600 "$HOME/.claude.json"
fi

# Interactive sessions (docker run -it): exec for proper TTY/signal handling.
# Headless sessions (docker run without -t): wrap so we can write credentials
# back after the command exits (exec would replace this shell, losing write-back).
if [ -t 1 ]; then
  exec "$@"
else
  "$@"
  EXIT_CODE=$?
  if [ -f "$HOME/.claude.json" ] && [ -d /tmp/claude-auth ]; then
    cp "$HOME/.claude.json" /tmp/claude-auth/claude.json
  fi
  exit $EXIT_CODE
fi
