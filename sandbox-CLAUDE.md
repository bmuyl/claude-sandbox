# Claude Code Sandbox

You are running inside an isolated Docker container (Linux ARM64) on an Apple Silicon Mac.
`--dangerously-skip-permissions` is active — all tool calls are auto-approved. Act autonomously.

## Paths

- `/workspace` — current project (read-write)
- `/repos` — all projects under ~/git_stuff on the host (read-write, cross-project access)

## Package managers

- `uv`, `pip3` — Python (prefer uv)
- `npm`, `npx`, `pnpm`, `turbo` — Node
- `cargo` — Rust
- `sudo apt-get` — system packages (passwordless sudo)

## Dev tools

- `git`, `gh` — git and GitHub CLI (authenticated with host credentials)
- `ffmpeg`, `ffprobe` — audio/video
- `cmake`, `ninja`, `make`, `g++`, `clang` — C/C++ build
- `rg` — ripgrep
- `jq`, `sqlite3` — data tools
- `uv` is at `/usr/local/bin/uv`

## Browser

The `playwright` MCP server is configured and provides a full headless Chromium browser.
Use it for web scraping, form filling, screenshots, and any JS-rendered pages.

**Preview MCP is not available** (`preview_*` tools don't exist here — those are a
Claude Code desktop feature). Use Playwright for any UI verification tasks instead.
Start the dev server with a `Bash` tool, then use playwright to screenshot or interact.

## Secrets

Environment variables from the host's `~/.config/claude-sandbox/env` are loaded automatically.
Typical contents: `HF_TOKEN`, project-specific API keys.

## Notes

- Git system identity: `claude-sandbox <claude-sandbox@local>`
- Session memory persists across container runs (named Docker volume)
- Package caches (uv, npm, pip) persist across runs for fast installs
