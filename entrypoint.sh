#!/bin/bash
# Copy host credentials into the claude user's home with correct permissions.
# Files are mounted read-only at /tmp/claude-auth/ to avoid permission issues.

if [ -f /tmp/claude-auth/claude.json ]; then
  cp /tmp/claude-auth/claude.json "$HOME/.claude.json"
  chmod 600 "$HOME/.claude.json"
fi

if [ -d /tmp/claude-auth/claude-dir ]; then
  cp -r /tmp/claude-auth/claude-dir/. "$HOME/.claude/"
  chmod -R 700 "$HOME/.claude"
fi

exec "$@"
