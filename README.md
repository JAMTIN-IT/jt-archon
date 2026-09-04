# Archon Portable

A ready-to-run [Archon](https://archon.diy) stack. Clone it on any machine with
Docker — Windows, macOS, Ubuntu, Fedora — run three commands, and you have a
fully configured Archon driving Claude Code, with an option to share the Web UI
with your team.

Nothing is vendored or forked. The stack pulls the official
`ghcr.io/coleam00/archon` image, so `./archon update` always gets you the latest
upstream release. Everything here is the wrapper: mode switching, credentials,
the LAN gateway, and shared MCP server definitions.

---

## Quick start

```bash
git clone <your-repo-url> archon && cd archon

./archon init            # creates .env from the template
./archon auth claude     # mints a Claude token and stores it
./archon up              # starts Archon on http://localhost:3000
```

On Windows use `.\archon.ps1` instead of `./archon` — same commands throughout.
(`archon.cmd` makes plain `archon <command>` work from `cmd.exe` too.)

Not sure something is right? `./archon doctor` checks the whole configuration
before you start.

---

## Sharing it with your team

Three access modes, one switch. `./archon up <mode>` saves the mode to `.env`,
so every later command acts on what is actually running.

| Mode | Who can reach it | What runs |
|---|---|---|
| `local` *(default)* | only this machine, `http://localhost:3000` | Archon |
| `lan` | your LAN, behind a password | Archon + Caddy gateway |
| `public` | the internet, on your domain with HTTPS | Archon + Caddy + Let's Encrypt |

```bash
./archon password 'a-strong-password'   # set this BEFORE exposing anything
./archon up lan
./archon ip                             # prints the exact URLs to send people
```

Teammates get `http://<your-ip>:8080` and a browser password prompt. Username is
`team` unless you pass a second argument.

Add `,db` to any mode to also run PostgreSQL: `./archon up lan,db` (then
uncomment `DATABASE_URL` in `.env`). SQLite is the default and is fine until you
are running 20+ workflows at once.

### A static address for the Web UI

By default the gateway binds every interface, so it keeps working when DHCP
moves you. For a fixed entry point teammates can bookmark:

1. Reserve this machine's IP in your router's DHCP settings.
2. Put it in `.env` as `LAN_BIND=192.168.1.50`.
3. `./archon restart`.

### How the exposure is actually scoped

Archon's own port stays on `127.0.0.1` (`ARCHON_APP_BIND`), so the *only* way in
from the network is through Caddy, which requires the password. The Caddyfiles
also return `404` for `/internal/*` — that endpoint hands out live GitHub App
tokens and must never be network-reachable.

Don't "simplify" this by setting `ARCHON_APP_BIND=0.0.0.0`; that publishes an
unauthenticated Archon, and anyone who reaches it can run arbitrary code on this
machine through your agent. `./archon doctor` warns if you do.

---

## Claude authentication

Claude Code ships **inside** the Archon image (verified: Claude Code 2.1.209 in
`archon:0.9.0`), so there is nothing to install. You only supply credentials.

`./archon auth claude` runs `claude setup-token` on your machine and writes the
result to `.env`. That token bills to your Claude subscription.

If Claude Code isn't installed locally, put an API key in `.env` instead
(`CLAUDE_API_KEY`, from console.anthropic.com/settings/keys) — that is metered
API billing rather than your subscription.

> A containerised Archon **cannot** reuse your host's `claude /login` session.
> `CLAUDE_USE_GLOBAL_AUTH=true` does nothing here — there is no interactive
> `claude` CLI inside the container to hold that session. The OAuth token above
> is the equivalent, and is what `./archon auth claude` sets up for you.

---

## GitHub

`./archon auth github` copies your existing `gh` CLI token into `.env` and seeds
`GITHUB_ALLOWED_USERS` with your own username.

**Add your teammates to that list** — it is the switch that decides who may
drive Archon from GitHub issues, PRs and comments:

```ini
GITHUB_ALLOWED_USERS=your-name,teammate-one,teammate-two
```

An empty value means *every* GitHub user can trigger it. The same pattern
applies to `SLACK_ALLOWED_USER_IDS`, `DISCORD_ALLOWED_USER_IDS` and
`TELEGRAM_ALLOWED_USER_IDS`.

For webhooks, generate a secret with `./archon secret` and paste the same value
into `.env` (`WEBHOOK_SECRET`) and the repo's webhook settings.

Teams that want commits attributed to each human rather than one shared bot
should use GitHub **App mode** instead — see section 4 of `.env.example`. Note
it needs `ARCHON_ALLOW_INTERNAL_ON_PUBLIC_BIND=1` in this stack; that is safe
here precisely because the gateways block `/internal/*`.

---

## MCP servers (Figma, Supabase, GitHub, your own)

`mcp/` is mounted read-only at `/opt/archon-mcp` in the container, so any config
there is usable from every codebase Archon works on:

```yaml
nodes:
  - id: read-design
    prompt: "Read <figma frame url> and describe its layout and design tokens."
    mcp: /opt/archon-mcp/figma-remote.json
    allowed_tools: []      # MCP tools only
```

Archon adds `mcp__<server>__*` to the node's allow-list automatically, so the
tools are callable as soon as the server connects — there is nothing extra to
permit.

Credentials live in `.env` (`FIGMA_TOKEN`, `SUPABASE_ACCESS_TOKEN`,
`GITHUB_TOKEN`) and are expanded into the config's `headers`/`env` at run time.
Settings that belong in a **URL** can't be — Archon never expands `url` — so
`./archon up` renders those from `.env` into a gitignored `*.local.json`. That
is how `SUPABASE_PROJECT_REF` pins the agent to one project.

Never assume a server works — check it:

```bash
./archon mcp figma-remote      # real handshake + the live list of tools
./archon mcp supabase        # pinned to SUPABASE_PROJECT_REF from .env
```

A silent MCP failure does not stop a node. It logs `MCP server connection
failed: <name>` and the node carries on with no tools, which reads like the
model simply ignoring your design. `./archon mcp` is how you tell those apart.

**Figma:** use `figma-remote.json`. Its tool set is a superset of Figma
Desktop's — same `get_design_context`, `get_variable_defs` and `get_screenshot`,
plus `download_assets` for real exported SVG/PNG and `search_design_system` for
resolving frames against your actual component libraries. It needs no desktop
app, which matters because a workflow node fires unattended. `figma-desktop.json`
is there for the one thing remote cannot do — "use what I have selected right
now" — and needs Figma Desktop running on this machine with a design file as the
active tab.

See [`mcp/README.md`](mcp/README.md) for the full comparison, the config format,
`$VAR` expansion rules, and the Bun-vs-Node caveat for stdio servers.

## Skills

`skills/` holds shared Claude skills. Install one into a project so its nodes
can name it:

```bash
./archon skill kc-bud figma-design-to-code   # -> kc-bud/.claude/skills/
```

```yaml
nodes:
  - id: build-screen
    mcp: /opt/archon-mcp/figma-desktop.json
    skills: [figma-design-to-code]
    allowed_tools: [Read, Write, Edit, Bash]
```

It installs into the project rather than a shared mount on purpose: a node
running under container isolation searches only `<project>/.claude/skills`, and
the server runs as `appuser`, so a home-directory mount resolves differently
depending on how the node was launched. Committing `.claude/skills/` also gets
the skill to your team.

**`figma-design-to-code`** teaches the split this stack needs: Dev Mode MCP for
structure, tokens and code context; the Figma REST API for exporting real
assets, which the desktop MCP server cannot do. It also documents the failure
mode that costs the most time — Figma Desktop answers the connection handshake
whenever the app is running, but never replies to a tool listing unless a design
file is the **active tab**, which surfaces in Archon as
`MCP server connection failed: figma (pending)`.

## Working on local projects

Archon runs inside a container and resolves every codebase path **there**, so a
host path typed into the Web UI cannot be found. Point `PROJECTS_DIR` at the
folder that holds your repos:

```ini
# .env
PROJECTS_DIR=C:/DEV-KC          # Windows, forward slashes
# PROJECTS_DIR=/Users/you/code  # macOS
# PROJECTS_DIR=/home/you/code   # Linux
```

`./archon restart`, then add the codebase using its **container** path:

| You have | You type in the Web UI |
|---|---|
| `C:\DEV-KC\kc-agents` | `/projects/kc-agents` |
| `/Users/you/code/app` | `/projects/app` |

Two helpers so you never have to work it out:

```bash
./archon projects                    # lists every repo Archon can see
./archon path 'C:\DEV-KC\kc-agents'  # -> /projects/kc-agents
```

Git repos register as repo projects (branch detected, worktree isolation); plain
folders register as folder projects. Both work.

Only one folder is mounted, so keep the repos you want Archon to touch under a
single parent — that parent is also the blast radius, which is a feature.


## Platform notes

### Windows

Docker Desktop with the WSL2 backend. Two things to know:

- **WSL mirrored networking blocks teammates.** If `%USERPROFILE%\.wslconfig`
  contains `networkingMode=Mirrored`, published ports bind your LAN address but
  the Hyper-V firewall drops inbound connections. Fix it once, from an
  **elevated** PowerShell:

  ```powershell
  .\archon.ps1 allow-lan
  ```

  `.\archon.ps1 doctor` tells you when this applies. In mirrored mode this
  machine also cannot reach its *own* LAN IP — test from a teammate's machine,
  not this one.

- **Keep LF line endings.** `.gitattributes` enforces this. A CRLF checkout
  breaks scripts inside the Linux container.

### macOS

Works as-is with the default Docker-managed volumes. Only if you set
`ARCHON_DATA` / `ARCHON_USER_HOME` to host paths: VirtioFS refuses to remap
ownership to the container user, the container exits on start, and you need
`ARCHON_ALLOW_ROOT_FALLBACK=1` in `.env`. Leaving those unset avoids the whole
problem.

### Linux (Ubuntu / Fedora)

Install Docker Engine plus the Compose plugin. If you bind-mount host paths, they
must be owned by UID 1001:

```bash
sudo chown -R 1001:1001 /opt/archon-data
```

Do **not** set `ARCHON_ALLOW_ROOT_FALLBACK=1` on Linux — there that failure means
the ownership really is wrong. Open the LAN port if a firewall is active:

```bash
sudo ufw allow 8080/tcp                                  # Ubuntu
sudo firewall-cmd --add-port=8080/tcp --permanent && sudo firewall-cmd --reload  # Fedora
```

---

## Troubleshooting

**`Path does not exist: /app/packages/server/C:\...`** when adding a codebase —
the container cannot see host paths. Set `PROJECTS_DIR`, `./archon restart`, and
use the `/projects/...` path. See [Working on local projects](#working-on-local-projects).

**`Could not determine whether the path is a git repository`** — git refused the
repo as "dubious ownership". Bind-mounted files look root-owned inside the
container, which you cannot chown away on Windows/macOS. The compose file passes
`safe.directory=/projects/*` to every git process to allow it. If your repos sit
more than one level under `PROJECTS_DIR`, the glob misses them — set
`GIT_SAFE_DIRS=*` in `.env` and restart.

**Teammates cannot connect in `lan` mode** — on Windows with WSL mirrored
networking, run `.\archon.ps1 allow-lan` from an elevated PowerShell. On Linux,
open the port in ufw/firewalld. See [Platform notes](#platform-notes).

**`no_ai_credentials` at startup** — run `./archon auth claude`, then
`./archon restart`.

`./archon doctor` catches most of these before you start.


## Commands

| | |
|---|---|
| `./archon init` | create `.env` from the template |
| `./archon auth claude` \| `github` | store credentials in `.env` |
| `./archon password '<pw>' [user]` | set the Web UI password |
| `./archon nopassword` | remove it |
| `./archon secret [hex]` | random value for `WEBHOOK_SECRET` etc. |
| `./archon doctor` | check everything before starting |
| `./archon up [mode]` | start (`local` \| `lan` \| `public`, `+,db`) |
| `./archon down` \| `down -v` | stop / stop and delete all data |
| `./archon restart [service]` | restart |
| `./archon status` | container status |
| `./archon logs [service]` | follow logs |
| `./archon update` | pull a newer Archon image and recreate |
| `./archon ip` | URLs to share |
| `./archon projects` | list the local repos Archon can see |
| `./archon path <host-path>` | translate a host path to its container path |
| `./archon mcp <name> [tool]` | verify an MCP server: handshake + live tool list |
| `./archon skill <project>` | install `skills/` into a project's `.claude/skills` |
| `./archon shell` | bash inside the container |
| `./archon exec <cmd...>` | run one command inside |
| `./archon build` | rebuild the image with Node LTS added |
| `.\archon.ps1 allow-lan` | Windows: open the LAN port in the firewall |

---

## Files

```
docker-compose.yml       the stack: app + caddy-lan + caddy-public + postgres
.env.example             every setting that matters, commented
archon / archon.ps1      the launcher (POSIX / Windows, same commands)
caddy/Caddyfile.lan      LAN gateway: password gate, /internal blocked
caddy/Caddyfile.public   public gateway: same, plus Let's Encrypt
caddy/auth.conf          your password hash (generated, gitignored)
mcp/                     shared MCP server definitions -> /opt/archon-mcp
mcp/_verify.ts           what `./archon mcp` runs inside the container
skills/                  shared Claude skills, installed per project
PROJECTS_DIR (in .env)   your code, mounted at /projects inside the container
Dockerfile.user          optional image layer: Node LTS and your own tools
```

## Sharing this repo with your team

`.env` and `caddy/auth.conf` are gitignored — they hold your credentials.
Everything else is safe to commit and is all a teammate needs:

```bash
git clone <repo> && cd archon
./archon init && ./archon auth claude && ./archon up
```

Pin `ARCHON_VERSION` in `.env` (e.g. `0.9.0` instead of `latest`) when you want
the whole team on an identical build.

## Upstream

- Archon: <https://github.com/coleam00/Archon> · docs <https://docs.archon.diy>
- Settings beyond `.env.example`:
  <https://github.com/coleam00/Archon/blob/main/.env.example>
