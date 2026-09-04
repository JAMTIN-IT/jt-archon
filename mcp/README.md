# Shared MCP servers

This folder is mounted read-only into the container at **`/opt/archon-mcp`**.
Archon accepts absolute paths in a workflow node's `mcp:` field, so any file
here is usable from any codebase Archon works on — no per-repo copies:

```yaml
# .archon/workflows/redesign.yaml, in any repo Archon has registered
name: implement-figma-frame
nodes:
  - id: read-design
    prompt: "Read https://figma.com/design/<key>/<name>?node-id=<id> and describe
             its layout and tokens."
    mcp: /opt/archon-mcp/figma-remote.json
    allowed_tools: []          # MCP tools only — no filesystem, no shell

  - id: build
    depends_on: [read-design]
    prompt: "Implement $read-design.output as a React component."
```

Changes to these files take effect on the next workflow **node** run — MCP
configs are read at execution time. No container restart needed. Adding a *new*
file does need `./archon restart` (Docker caches the mount's directory listing
only at start on some platforms; restarting is the reliable path). Changing a
**credential in `.env`** also needs a restart — that is container environment,
not a file read at run time.

## Verify before you trust it

```bash
./archon mcp figma-remote            # handshake + live tool list
./archon mcp figma-remote get_metadata '{"fileKey":"..."}'   # also call a tool
```

This runs `_verify.ts` inside the container using **Archon's own config loader**
(`packages/providers/src/mcp/config.ts`), so the JSON parsing, the `$VAR`
expansion and the network namespace are the ones a node actually gets. It then
performs a real `initialize` + `tools/list` with the MCP SDK that ships in the
image.

A port that answers is not proof. `curl` against Figma Desktop returns a healthy
socket while the server refuses every tool call because the active tab is not a
design file — the node would run, connect, and silently have nothing to call.
Only a tool list is proof, which is why this command prints one.

## What's here

| File | Transport | Needs |
|---|---|---|
| `figma-remote.json` | HTTP → figma.com | `FIGMA_TOKEN` in `.env`; no desktop app |
| `figma-desktop.json` | HTTP → your host | Figma Desktop running, Dev Mode MCP on, a design file as the active tab |
| `supabase.local.json` | HTTP → supabase.com | `SUPABASE_ACCESS_TOKEN` in `.env`; generated, see below |
| `github.json` | HTTP → github.com | `GITHUB_TOKEN` in `.env` |

`$VAR` references inside `env` and `headers` are expanded from Archon's
environment at run time, so secrets stay in `.env` and never land in a file you
might commit. **`command`, `args` and `url` are not expanded** — a `$VAR` in a
URL is sent to the server literally, which fails as a puzzling 4xx that looks
like a bad credential.

## Generated configs (`*.local.json`)

Anything that has to live in a **URL** cannot be a `$VAR`, so `./archon up` and
`./archon restart` render it from `.env` into a gitignored `*.local.json`.

`supabase.local.json` is built this way, from two settings:

```ini
# .env
SUPABASE_PROJECT_REF=abcdefghijklmnop   # pins the agent to one project
SUPABASE_READ_ONLY=false                # optional; default is read-only
```

```json
{ "supabase": { "type": "http",
    "url": "https://mcp.supabase.com/mcp?project_ref=abcdefghijklmnop&read_only=true",
    "headers": { "Authorization": "Bearer $SUPABASE_ACCESS_TOKEN" } } }
```

The **token is not written to the file** — it stays a `$VAR` in `headers`, which
Archon does expand, so the generated file holds no secret. Don't hand-edit it;
the next `up`/`restart` overwrites it. Change `.env` and restart instead.

Leave `SUPABASE_PROJECT_REF` empty and the agent works account-wide: it keeps
`list_projects` and friends, but every project that token can see is in reach.
Pinning is the safer default.

## Figma: which server?

Both are configured. `figma-remote.json` is the one to reach for.

The remote server is a **superset** of the desktop server's tools. Everything
that drives fidelity — `get_design_context` (code + structure), the
`get_variable_defs` design tokens, `get_screenshot`, `get_code_connect_map` —
exists on both. The remote server then adds tools the desktop one has no
equivalent for:

- `download_assets` — real exported PNG/JPG/SVG/PDF assets, instead of the model
  approximating an icon it can only see in a screenshot.
- `search_design_system` / `get_libraries` — resolves a frame against the
  libraries you actually subscribe to, so components map to your design system
  rather than to freshly invented markup.
- `get_context_for_code_connect`, `use_figma`, `create_new_file`, `whoami`.

The desktop server's one real advantage is **selection-based prompting**: "use
what I have selected right now". The remote server needs an explicit frame or
layer link in the prompt.

For Archon that advantage mostly evaporates. A workflow node runs unattended,
often triggered from a GitHub comment — there is no human sitting in Figma
holding a selection at the moment the node fires. A pasted frame URL is the
natural input, and both servers accept one. The desktop server also binds
`127.0.0.1` on the host and requires the app to be open on the *same machine* as
the container, which is a hard stop the day Archon runs on a server.

Use `figma-desktop.json` when you are working interactively next to a running
Figma and want "read my selection", or when policy forbids a token leaving the
machine. Use `figma-remote.json` for everything else.

### Figma tokens

The remote server authenticates a `figd_` personal access token through the
**`X-Figma-Token`** header. It is not a bearer token — send it as
`Authorization: Bearer` and the server answers:

```
401  figd_ tokens must be passed via X-Figma-Token header, not Authorization
```

`figma-remote.json` already uses the right header. Mint the token under
**Figma → Settings → Security → Personal access tokens** with read-only
*File content*, *Dev resources* and *Library content* scopes.

### Figma Desktop

Figma Desktop runs its MCP server on the **host** at `127.0.0.1:3845`. From
inside a container that address is the container itself, so `figma-desktop.json`
points at `host.docker.internal` instead — and the compose file adds a
`host-gateway` entry so this resolves on Linux as well as Docker Desktop.

On **Docker Desktop** (Windows/macOS) the gateway proxies to the host's
loopback, so a server bound to `127.0.0.1` is reachable. Verified on this stack:
`host.docker.internal` resolves to `192.168.65.254` and reaches a host process
listening only on `127.0.0.1`.

On **plain Docker Engine on Linux**, `host-gateway` is the `docker0` bridge
address and a loopback-bound server is *not* reachable. Publish the server on
the bridge address, or run Archon with `--network host`.

Enable it first: **Figma Desktop → open a design file → Dev Mode → inspect
panel → enable the MCP server**. The design file must stay the **active tab** —
otherwise the connection still succeeds and every tool call fails with
`The MCP server is only available if your active tab is a design or FigJam file`.

Linux has no Figma desktop app; use `figma-remote.json` there.

## Adding your own

Drop in a JSON file shaped like the ones above. Three transports are supported:

```jsonc
// stdio — runs a process inside the Archon container
{ "myserver": { "command": "bunx", "args": ["-y", "some-mcp-server"],
                "env": { "API_KEY": "$MY_API_KEY" } } }

// http
{ "myserver": { "type": "http", "url": "https://...",
                "headers": { "Authorization": "Bearer $TOKEN" } } }

// sse
{ "myserver": { "type": "sse", "url": "https://..." } }
```

The `{ "mcpServers": { ... } }` wrapper that other tools export is also accepted
— but only on its own; mixing it with sibling keys is rejected.

### stdio servers need a runtime that exists in the image

The Archon image ships **Bun**. `npm` and `npx` are not installed at all, and
the `node` on `PATH` is only Bun's compatibility wrapper (it runs a script but
has no REPL). Verified against `ghcr.io/coleam00/archon:0.9.0`. Most npm MCP
servers run fine under `bunx` instead:

```json
{ "ntfy": { "command": "bunx", "args": ["-y", "ntfy-me-mcp"],
            "env": { "NTFY_TOPIC": "$NTFY_TOPIC" } } }
```

For a server that genuinely needs real Node or `npx`, add them to the image once:

```
./archon build          # builds Dockerfile.user, which layers Node LTS on top
```

Prefer HTTP/SSE servers where a hosted option exists — nothing to install and
nothing to keep updated.

## Gotchas

- A typo in the `mcp:` path only surfaces when the node runs, not at load time.
- Claude nodes get no ambient MCP servers — only what the node's file declares
  (`strictMcpConfig`). Nothing leaks in from your host's Claude config.
- You do **not** need to list MCP tools in `allowed_tools`. Archon appends
  `mcp__<server>__*` to the allow-list for every server the node's config
  names, and runs with permissions bypassed, so the tools are callable on
  arrival. `allowed_tools: []` therefore means "MCP tools and nothing else".
- Don't use `model: haiku` on MCP nodes; tool search is unsupported there. Use
  Sonnet or Opus.
- A server that fails to connect logs `MCP server connection failed: <name>` and
  the node continues **without** those tools rather than failing outright. This
  is the quiet failure mode `./archon mcp` exists to catch.
