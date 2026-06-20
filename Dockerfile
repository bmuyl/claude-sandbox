# Claude Code sandbox — covers all bmuyl projects
# Stacks: Node/pnpm/Turbo, Python/uv, ffmpeg, Rust/cargo, cmake/conan, gh

FROM node:20-bookworm

# ── System packages ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    git curl wget \
    python3 python3-pip python3-venv \
    cmake ninja-build \
    ffmpeg \
    ripgrep \
    perl \
    lsof \
    unzip \
    jq \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ─────────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ── Node tooling (system-wide) ─────────────────────────────────────────────────
RUN npm install -g pnpm turbo

# ── uv (system-wide) ──────────────────────────────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# ── Python libs ───────────────────────────────────────────────────────────────
RUN rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED \
    && pip3 install --no-cache-dir matplotlib numpy scipy conan

# ── Rust (system-wide) ────────────────────────────────────────────────────────
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
ENV PATH="/usr/local/cargo/bin:$PATH"

# ── Git identity (system-wide so all users inherit it) ────────────────────────
RUN git config --system user.email "claude-sandbox@local" \
    && git config --system user.name "claude-sandbox" \
    && git config --system credential.helper "gh auth git-credential"

# ── Playwright system dependencies (needed before USER switch) ─────────────────
RUN npx -y playwright install-deps chromium

# ── Non-root user (Claude Code refuses --dangerously-skip-permissions as root) ─
RUN useradd -m -s /bin/bash claude

# Passwordless sudo for apt-get so Claude can install system packages
RUN apt-get install -y sudo \
    && echo "claude ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" \
       >> /etc/sudoers.d/claude-sandbox \
    && chmod 440 /etc/sudoers.d/claude-sandbox

# ── Entrypoint: copies host credentials with correct permissions ───────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Strip CR in case the script was checked out with CRLF on a Windows host,
# otherwise the kernel can't find the "/bin/bash\r" interpreter.
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

USER claude
ENV HOME=/home/claude
ENV PATH="/home/claude/.npm-global/bin:${PATH}"

# Install claude-code into a user-owned npm prefix.
# `npm config set prefix` writes to ~/.npmrc — more reliable than NPM_CONFIG_PREFIX env.
# Auto-updates write to ~/.npm-global/ (user-owned) so no "no write permission" warning.
RUN mkdir -p /home/claude/.npm-global \
    && npm config set prefix /home/claude/.npm-global \
    && npm install -g @anthropic-ai/claude-code

# Install Playwright Chromium browser for the claude user
RUN npx -y playwright install chromium

# Global Claude Code settings: Playwright MCP for browser access
RUN mkdir -p /home/claude/.claude/projects
COPY --chown=claude:claude container-settings.json /home/claude/.claude/settings.json

# Sandbox context doc: tells Claude what env it's in, what tools are available
COPY --chown=claude:claude sandbox-CLAUDE.md /home/claude/CLAUDE.md

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
