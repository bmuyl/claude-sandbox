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

# ── Claude Code (system-wide) ─────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code

# ── Git identity (system-wide so all users inherit it) ────────────────────────
RUN git config --system user.email "claude-sandbox@local" \
    && git config --system user.name "claude-sandbox"

# ── Non-root user (Claude Code refuses --dangerously-skip-permissions as root) ─
RUN useradd -m -s /bin/bash claude
USER claude
ENV HOME=/home/claude

WORKDIR /workspace
