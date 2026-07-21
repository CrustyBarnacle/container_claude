# =============================================================================
# Claude Code — Rootless Podman Container
# =============================================================================
# Base: debian:bookworm-slim  (glibc, no Node runtime required)
# Claude Code: native binary, pinned — no npm, no auto-update
#
# Build args:
#   CLAUDE_CODE_VERSION  — pin to a specific release (default: 2.1.87)
#   TZ                   — timezone string  (default: UTC)
#
# Runtime network allowlist (minimum required):
#   api.anthropic.com        — API
#   claude.ai                — OAuth / auth
#   platform.claude.com      — Console auth
#
# Build-time only (can be blocked at runtime):
#   downloads.claude.ai      — install script + binary download
# =============================================================================

FROM debian:bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.197
ARG TZ=UTC

ENV TZ="${TZ}"

# ---------------------------------------------------------------------------
# System packages
#   - curl / ca-certificates : installer + TLS
#   - git                    : Claude Code's git tooling
#   - ripgrep                : search (USE_BUILTIN_RIPGREP=0 prefers this)
#   - fzf / less / jq        : quality-of-life inside the shell
#   - zsh                    : default interactive shell (matches upstream)
#   - procps / iproute2      : ps, ss — useful inside the container
#   - tini                   : PID 1 / zombie reaping (upstream omitted this)
#   - locales                : prevent locale warnings from Claude Code
#   - bubblewrap             : Claude Code's internal /sandbox command (bash
#                              subprocess isolation via Linux namespaces).
#                              Operates at the application layer — one level
#                              deeper than the Podman container boundary.
#   - socat                  : required alongside bubblewrap for Claude Code's
#                              sandbox network proxy
#
# Explicitly NOT installed:
#   - nodejs / npm           : not needed; native binary is self-contained
#   - iptables / ipset / sudo: egress filtering lives on the HOST, not here
#   - aggregate              : not needed without in-container firewall
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        ripgrep \
        fzf \
        less \
        jq \
        zsh \
        procps \
        iproute2 \
        tini \
        locales \
        bubblewrap \
        socat \
    && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# ---------------------------------------------------------------------------
# Non-root user
#   UID/GID 1000 — matches the typical default user on the host via
#   `podman run --userns=keep-id`, so bind-mounted files are accessible
#   without `:U` remapping in most cases.
#   If your UID is not 1000, rebuild with --build-arg UID=$(id -u) GID=$(id -g)
#   after adding those ARGs to this file.
# ---------------------------------------------------------------------------
RUN groupadd --gid 1000 claude && \
    useradd  --uid 1000 --gid 1000 --shell /bin/zsh \
             --create-home --home-dir /home/claude claude

# ---------------------------------------------------------------------------
# Directory layout
#   /workspace           — default project mount point
#   /home/claude/.claude — Claude Code config/credentials volume mount point
#   /commandhistory      — shell history volume mount point
# ---------------------------------------------------------------------------
RUN mkdir -p /workspace /home/claude/.claude /commandhistory && \
    chown -R claude:claude /workspace /home/claude /commandhistory

# ---------------------------------------------------------------------------
# Install Claude Code native binary — pinned to ${CLAUDE_CODE_VERSION}
#
# Key Podman/container-specific details:
#   1. WORKDIR /tmp BEFORE the installer runs — prevents the installer from
#      scanning the entire filesystem (documented Docker/Podman hang issue).
#   2. Run as the claude user so the binary lands in ~/.local/bin/claude
#      (i.e. /home/claude/.local/bin/claude) — no root, no sudo needed.
#   3. Version is passed as a positional argument via `bash -s -- <VERSION>`.
#      install.sh reads it as $1 (TARGET) and passes it to the binary's own
#      `install` subcommand — this is the documented method per the official
#      docs: curl -fsSL https://claude.ai/install.sh | bash -s <VERSION>
#      The VERSION env var does NOT work — install.sh ignores it entirely
#      and always fetches the latest installer binary first, then delegates
#      version selection to the binary via $TARGET.
#   4. DISABLE_AUTOUPDATER=1 prevents the binary from configuring background
#      update machinery at install time.
# ---------------------------------------------------------------------------
WORKDIR /tmp

USER claude

RUN DISABLE_AUTOUPDATER=1 \
    curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"

# Sanity-check: confirm the pinned version is what actually got installed.
# With bash -s -- <VERSION> this should always match, but belt-and-suspenders.
RUN /home/claude/.local/bin/claude --version | grep -F "${CLAUDE_CODE_VERSION}" || \
    { echo "ERROR: installed version does not match pinned ${CLAUDE_CODE_VERSION}"; exit 1; }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

# Make claude available without a full path
ENV PATH="/home/claude/.local/bin:${PATH}"

# Claude Code runtime configuration
ENV CLAUDE_CONFIG_DIR="/home/claude/.claude"

# Disable everything that phones home or tries to self-update.
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC covers: autoupdater, feedback
# command, error reporting (Sentry), and Statsig telemetry — all in one var.
ENV DISABLE_AUTOUPDATER="1"
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"

# Strip credentials from subprocess environments — defence against prompt
# injection attempts that try to exfiltrate API keys via shell expansion.
ENV CLAUDE_CODE_SUBPROCESS_ENV_SCRUB="1"

# Prefer the system ripgrep we installed over the bundled one
ENV USE_BUILTIN_RIPGREP="0"

# Shell / terminal
ENV SHELL="/bin/zsh"
ENV EDITOR="vim"
ENV VISUAL="vim"

# Node memory ceiling (kept for any npm-using tools Claude Code may invoke)
ENV NODE_OPTIONS="--max-old-space-size=4096"

# ---------------------------------------------------------------------------
# Shell history persistence
# ---------------------------------------------------------------------------
RUN echo 'export HISTFILE=/commandhistory/.zsh_history' >> /home/claude/.zshrc && \
    echo 'export SAVEHIST=10000' >> /home/claude/.zshrc && \
    echo 'export HISTSIZE=10000' >> /home/claude/.zshrc && \
    echo 'setopt APPEND_HISTORY SHARE_HISTORY INC_APPEND_HISTORY' >> /home/claude/.zshrc && \
    echo 'export PATH="/home/claude/.local/bin:$PATH"' >> /home/claude/.zshrc

RUN touch /home/claude/.bash_profile /home/claude/.bashrc \
          /home/claude/.zshrc /home/claude/.zprofile /home/claude/.profile && \
    chown claude:claude /home/claude/.bash_profile /home/claude/.bashrc \
          /home/claude/.zshrc /home/claude/.zprofile /home/claude/.profile

WORKDIR /workspace

# ---------------------------------------------------------------------------
# Entrypoint
#   tini as PID 1: proper signal forwarding, zombie reaping.
#   Default CMD: interactive zsh — override at `podman run` time.
# ---------------------------------------------------------------------------
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/zsh"]
