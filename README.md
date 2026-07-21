# claude-sandbox

Rootless Podman container for Claude Code, pinned to a specific version with
a minimal attack surface and no in-container firewall magic.

## Files

| File | Purpose |
|------|---------|
| `Containerfile` | Image definition — debian:bookworm-slim + native Claude Code binary |
| `claude-sandbox` | Host-side launcher script (replaces devcontainer.json entirely) |
| `tinyproxy.conf` | tinyproxy config — ALLOW_HOST_IP placeholder is substituted at runtime |
| `tinyproxy.filter` | Domain allowlist for tinyproxy (ERE, one entry per line) |

## Prerequisites

Install on the host before first use:

```bash
# Arch Linux
sudo pacman -S --needed podman tinyproxy jq iproute2

# Debian / Ubuntu
sudo apt install podman tinyproxy jq iproute2
```

`tinyproxy` is required unless you pass `--no-proxy` (not recommended — disables
all egress filtering). `iproute2` is used by the launcher at runtime (to derive
the host LAN IP). `jq` is needed for the token management workflow below.

## Quick start

```bash
# 1. Build the image (only needs network access once)
The `-t` adds the `claudecode:<version>` and `claudecode:latest` tags. Add, remove, or edit to your liking and needs.

podman build --build-arg CLAUDE_CODE_VERSION=2.1.197 \
             -t localhost/claudecode:2.1.197 \
             -t localhost/claudecode:latest .

# 2. First-time login (saves OAuth token to ~/.claude)
./claude-sandbox --login

# 3. Work on a project
cd ~/projects/myapp
./claude-sandbox

# 4. Or invoke claude directly
./claude-sandbox -- "explain the auth flow in src/"
```

## Design decisions

### Why debian:bookworm-slim instead of node:20?

The native Claude Code binary is self-contained — it does not need Node.js to
run.  Using the slim Debian base drops the image from ~1 GB to ~150 MB and
removes a large chunk of attack surface.  Node/npm are still available *inside*
a session if Claude Code needs to run them as tools (it will install them on
demand into `/workspace`).

### Why no in-container iptables / NET_ADMIN?

The upstream `init-firewall.sh` approach requires `--cap-add=NET_ADMIN` and
`--cap-add=NET_RAW`.  Under rootless Podman with pasta networking, those
capabilities operate on the container's own user namespace — they cannot
manipulate the host netfilter tables — and the `xt_set` kernel module for
`ipset` is typically not loadable by an unprivileged user.  It's fundamentally
the wrong layer for this job.

Egress filtering belongs on the **host**, outside the container, where it can
actually be enforced.  This setup uses tinyproxy as an allowlist HTTPS proxy
(see below).  An nftables approach is equally valid if you prefer it — the
proxy env vars (`HTTPS_PROXY` / `HTTP_PROXY`) just need to point at your
filtering mechanism.

### Credentials mount strategy

| Mode | `~/.claude` mount | Use case |
|------|-------------------|---------|
| default | `:rw` | Day-to-day work |
| `--login` | `:rw` | First auth / token refresh |
| `--no-creds` | not mounted | Fully isolated / CI |

Shell history is persisted to `~/.local/share/claude-sandbox/history/` (or
`$CLAUDE_SANDBOX_DATA/history/`) and shared across sessions.

### Version pinning

`CLAUDE_CODE_VERSION=2.1.197` is baked into the image at build time.  The
`DISABLE_AUTOUPDATER=1` env var prevents the binary from trying to update
itself at runtime.  To upgrade:

```bash
# 1. Check the current stable release
curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r .version

# 2. Review the changelog
# https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md

# 3. Build a new image with the new version
podman build --build-arg CLAUDE_CODE_VERSION=<NEW_VERSION> \
             -t localhost/claudecode:<NEW_VERSION> \
             -t localhost/claudecode:latest .

# 4. Test, then update the default in the claude-sandbox script
```

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLAUDE_SANDBOX_IMAGE` | `localhost/claudecode:latest` | Image name/tag to run |
| `CLAUDE_SANDBOX_DATA` | `~/.local/share/claude-sandbox` | Persistent data root (history) |

---

## Egress filtering with tinyproxy

tinyproxy runs on-demand (started before the container, stopped after).
The launcher derives your host LAN IP at runtime via `ip route get 1.1.1.1`
and injects it into the config — no manual editing needed on DHCP changes.

Only these domains are reachable from the container at runtime:

| Domain | Purpose |
|--------|---------|
| `api.anthropic.com` | Claude API |
| `claude.ai` | OAuth authentication |
| `platform.claude.com` | Console authentication |

All other outbound HTTPS connections are rejected with a 403.

`storage.googleapis.com` and `downloads.claude.ai` are only needed at **build
time** (inside `podman build`).  At runtime with `DISABLE_AUTOUPDATER=1` they
can be blocked.

> **Note — untrusted networks:** tinyproxy listens on `0.0.0.0:8888`.  On
> shared or public networks, other hosts on the same segment could in principle
> connect to it and use it as a proxy to reach Anthropic's API endpoints (the
> domain allowlist still applies).  If this is a concern, add a host firewall
> rule to block inbound port 8888 from non-loopback addresses.

### Adding extra domains for a session

```bash
# Allow github.com for this session only
./claude-sandbox --allow-net github.com

# Allow multiple
./claude-sandbox --allow-net github.com,raw.githubusercontent.com
```

To allow a domain for a running session without restarting:

```bash
echo "github\.com$" >> /tmp/claude-sandbox-tinyproxy.filter
kill -HUP $(cat /tmp/claude-sandbox-tinyproxy.pid)
```

---

## Adding optional mounts at runtime

```bash
# Expose ~/.gitconfig (read-only)
./claude-sandbox -r ~/.gitconfig

# Expose ~/.ssh (read-only — lets Claude Code use git over SSH)
./claude-sandbox -r ~/.ssh

# Expose a second repo read-write
./claude-sandbox -w ~/projects/shared-lib

# Combine
./claude-sandbox -p ~/projects/myapp -r ~/.gitconfig -r ~/.ssh
```

No container rebuild required for any of these — they're composable flags on
the launcher script.

---

## Token management

Cloudflare blocks OAuth token refresh from container environments (HTTP 403),
causing short-lived tokens to expire.  The fix is to write a long-lived token
directly into `~/.claude/.credentials.json`.

Setup / renewal:

```bash
# 1. Start a login session
./claude-sandbox --login

# 2. Inside the container
claude setup-token   # copy the sk-ant-oat01-... value

# 3. Exit the container, then on the host:
jq '.claudeAiOauth.accessToken = "sk-ant-oat01-YOURTOKEN"' \
   ~/.claude/.credentials.json > /tmp/c.tmp \
&& mv /tmp/c.tmp ~/.claude/.credentials.json
```

---

## Troubleshooting

**Container exits immediately**
The Containerfile sets `CMD ["/bin/zsh"]` so it needs a TTY.  Make sure you're
passing `-t` (the launcher does this automatically) or override the command.

**`claude --version` shows wrong version**
The build-time verification step (`grep -F ${CLAUDE_CODE_VERSION}`) should
catch this.  If you're running a pre-built image, check:
`podman run --rm localhost/claudecode:2.1.197 claude --version`

**OAuth browser flow**
Run with `--login`.  Claude Code will print a URL — since there's no display
from inside the container, copy the URL and open it in your host browser.
The token is saved to the `:rw`-mounted `~/.claude` directory.

**`permission denied` on mounted files**
Check `--userns=keep-id` is being passed (the launcher always does this).
If your host UID is not 1000, rebuild the image with
`--build-arg UID=$(id -u) --build-arg GID=$(id -g)` after adding those ARGs
to the Containerfile.

**`bwrap: Can't create file at /home/claude/.bash_profile: Read-only file system`**
This was a bug in Claude Code ≥ 2.1.88 where the internal sandbox (bubblewrap)
tries to create shell dotfiles at startup, but finds the home directory
read-only.  Fixed in this Containerfile: all dotfiles (`~/.bash_profile`,
`~/.bashrc`, `~/.zshrc`, `~/.zprofile`, `~/.profile`) are pre-created and
owned by the `claude` user during the image build, so bubblewrap finds them
already in place and doesn't need to write them.  If you're using a
pre-built image older than this fix, rebuild.

Versions of claudecode >=2.1.88 issues, build with 2.1.87:

podman build --build-arg CLAUDE_CODE_VERSION=2.1.87 \
             -t localhost/claudecode:2.1.87 \
             -t localhost/claudecode:working .

**tinyproxy fails to start**
Check the log: `cat /tmp/claude-sandbox-tinyproxy.log`
Common causes: port 8888 already in use (`ss -tlnp | grep 8888`), or
tinyproxy not installed (`which tinyproxy`).

**Connection refused / 403 from inside the container**
The domain isn't in the allowlist.  Check the tinyproxy log to see what was
blocked, then use `--allow-net <domain>` or add it permanently to
`tinyproxy.filter`.
