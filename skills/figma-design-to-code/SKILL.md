---
name: figma-design-to-code
description: Build an accurate implementation of a Figma design. Use whenever a task references a Figma frame, screen, component or design-system token — including any figma.com URL, a "make this screen", "match the design", or "export these icons" request. Covers the Dev Mode MCP tools for structure and tokens, and the Figma REST API for exporting production assets the MCP server cannot hand you.
---

# Figma → code, accurately

Two sources of truth, each authoritative for different things. Using the wrong
one is how implementations drift from the design.

| Need | Use | Why |
|---|---|---|
| Layout, hierarchy, sizes | `get_metadata` | Exact tree with ids, x/y, width/height |
| Code + styling for a node | `get_design_context` | Figma's own codegen, resolves variables |
| Design tokens | `get_variable_defs` | Real variable names, not sampled hex |
| What it should look like | `get_screenshot` | Visual check against your build |
| Which component to reuse | `get_code_connect_map` | Maps a node to a file in this repo |
| **Production assets** | **REST API** (below) | MCP returns no downloadable asset files |

## Before anything else

The MCP server is Figma Desktop on the developer's machine. It serves **only the
file that is the active tab**. If a call fails with:

```
The MCP server is only available if your active tab is a design or FigJam file
```

the app is not open on a design file. Stop and say so — do not fall back to
guessing at the design.

It also fails a second, nastier way: the server answers the connection
handshake whenever Figma is running, but **silently never replies** to a tool
listing when no design file is focused. Inside Archon that surfaces as

```
MCP server connection failed: figma (pending)
```

and your session simply has no `mcp__figma__*` tools in it. That is not an
Archon fault and not something to work around — it means nobody has a design
file focused in Figma Desktop. Say so and stop.

In both cases the REST API below still works. It needs no desktop app, so asset
export remains available even when the MCP server does not.

## Node ids: the URL lies

A Figma URL writes node ids with a hyphen; every API and tool wants a colon.

```
https://figma.com/design/wCHS4I7o6q6AhqfAYXpFKd/BOSS?node-id=55-3
                         └──── fileKey ────┘              └ 55:3
```

Converting `55-3` → `55:3` is required. The file key is the path segment after
`/design/`.

## Reading a design

Work top-down. Do not start with `get_design_context` on a whole screen — it
generates code for the entire subtree, which is slow and buries the structure.

**1. Map the file.** `get_metadata` with no arguments lists top-level pages.
Then `get_metadata` with a page or frame `nodeId` returns the tree:

```xml
<frame id="55:3" name="Auth Login" x="0" y="0" width="390" height="844">
  <frame id="55:5" name="Login Content" x="24" y="70" width="342" height="701">
    <instance id="397:136" name="Brand / Logo" x="101" y="0" width="140" height="140" />
```

`<instance>` means a design-system component. Those are the nodes to check
against `get_code_connect_map` before writing anything — an instance that maps
to an existing component must be reused, not reimplemented.

**2. Pull the tokens once.** `get_variable_defs` on the screen frame returns the
variables in play (`{'icon/default/secondary': '#949494'}`). Use the **variable
names** to find the equivalents already in the codebase. Hard-coding the hex is
the single most common way a "pixel-perfect" build silently diverges from the
design system.

**3. Then get code, per component.** `get_design_context` on a leaf-ish frame,
not the root. Treat its output as a description of intent — spacing, hierarchy,
token usage — and re-express it in this repo's conventions. Shipping its raw
React/Tailwind output verbatim is almost always wrong.

**4. Verify visually.** `get_screenshot` on the same node, compare against what
you built, and fix the differences you can see.

### `get_design_context` gotchas

- On first call for a subtree containing unmapped components it does not return
  code. It returns a script asking whether to set up Code Connect. Ask the user
  that question verbatim, or re-call with `disableCodeConnect: true` to skip.
- It is **slow on large nodes** and can exceed a 60s client timeout on a full
  screen. Target smaller frames.
- It rejects page/canvas nodes: `This node type is not supported`. Pass a frame,
  component or instance.

## Exporting assets — the REST API

The Dev Mode MCP server has no `download_assets` tool; that one is exclusive to
Figma's remote MCP server, which this setup cannot use. So when the task needs
**actual files** — icons as SVG, imagery as PNG — use the REST API. It is
authenticated with `FIGMA_TOKEN`, already in the environment, and works whether
or not the desktop app is running.

Export is two steps: ask for a render, then download the URL it returns.

```bash
KEY=wCHS4I7o6q6AhqfAYXpFKd

# 1. render -> temporary S3 URLs, one per node id
curl -s -H "X-Figma-Token: $FIGMA_TOKEN" \
  "https://api.figma.com/v1/images/$KEY?ids=55:3,397:136&format=svg"
# {"err":null,"images":{"55:3":"https://figma-alpha-api.s3...","397:136":"..."}}

# 2. download it
curl -s "<url from step 1>" -o src/assets/brand-logo.svg
```

- `format`: `svg` for icons and vector art, `png` for imagery, also `jpg`/`pdf`.
- `scale`: `1`–`4`, PNG/JPG only. Use `2` for @2x raster assets.
- `ids`: comma-separated, so batch a whole icon set in one request.
- The returned URLs are **temporary**. Download immediately; never store one.

For bitmaps a designer placed into the file (photos, textures), the render
endpoint re-rasterises them. To get the originals instead:

```bash
curl -s -H "X-Figma-Token: $FIGMA_TOKEN" \
  "https://api.figma.com/v1/files/$KEY/images"
# {"meta":{"images":{"<imageRef>":"<signed url>"}}}
```

### Choosing between them

Export via REST when the asset ships in the build: icons, logos, illustrations.
Use `get_screenshot` only to *check your work* — it is a flattened raster of the
design and must never be committed as an asset.

## Working inside Archon

A node reaches Figma only if its config declares the server:

```yaml
nodes:
  - id: build-login
    prompt: "Implement https://figma.com/design/<key>/App?node-id=55-3 as a React screen."
    mcp: /opt/archon-mcp/figma-desktop.json
    skills: [figma-design-to-code]
    allowed_tools: [Read, Write, Edit, Bash]   # Bash is required for REST export
```

Archon adds `mcp__figma__*` to the allow-list automatically — MCP tools need no
entry in `allowed_tools`. But **`Bash` does**, and without it the REST export
half of this skill is unavailable.

Do not use `model: haiku` on a node with MCP servers; tool search is unsupported
there. Use Sonnet or Opus.

Check the connection before blaming the design:
`./archon mcp figma-desktop` prints a live tool list, or tells you exactly what
is wrong.

## Rules

1. Never invent a value you could have read. Spacing, colour and type come from
   `get_variable_defs` and `get_metadata`, not from looking at a screenshot.
2. Reuse mapped components. Check `get_code_connect_map` before writing a
   component that may already exist.
3. Token names over literals. `color/brand/primary`, not `#C8A44D`.
4. Export assets, don't redraw them. A hand-written SVG approximation of a logo
   is a defect.
5. If the MCP server is unreachable, say so and stop. Do not approximate a
   design you cannot read.
