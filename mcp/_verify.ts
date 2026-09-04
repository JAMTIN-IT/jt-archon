/**
 * MCP connectivity verifier — run INSIDE the Archon container.
 *
 *   ./archon mcp <config> [tool] [jsonArgs]
 *
 * Deliberately reuses Archon's own loader (`@archon/providers` mcp/config.ts),
 * so what this proves is what a workflow node gets: identical JSON parsing,
 * identical `$VAR` expansion from the container's environment, identical
 * server names. A hand-rolled parser here could pass while a node still fails.
 *
 * Then it connects with the official MCP SDK that ships in the image and runs
 * a real `initialize` + `tools/list`, optionally calling one tool. Reaching the
 * port is not proof — a server that answers TCP but rejects the handshake, or
 * connects with zero tools, is a broken node. Only a tool list is proof.
 *
 * Absolute import specifiers throughout: this file lives on the read-only
 * /opt/archon-mcp mount, which has no node_modules to resolve up into.
 */
import { loadMcpConfig } from '/app/packages/providers/src/mcp/config.ts';
import { Client } from '/app/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
import { StreamableHTTPClientTransport } from '/app/node_modules/@modelcontextprotocol/sdk/dist/esm/client/streamableHttp.js';
import { SSEClientTransport } from '/app/node_modules/@modelcontextprotocol/sdk/dist/esm/client/sse.js';
import { StdioClientTransport } from '/app/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js';

const [configPath, toolName, toolArgsRaw] = process.argv.slice(2);

if (!configPath) {
  console.error('usage: bun /opt/archon-mcp/_verify.ts <config-path> [tool-name] [json-args]');
  process.exit(2);
}

/** Redact anything that came from a `$VAR`, so logs stay pasteable. */
function redact(value: unknown): unknown {
  if (typeof value !== 'object' || value === null) return value;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    if (/token|key|secret|authorization|password/i.test(k)) {
      const s = typeof v === 'string' ? v : '';
      out[k] = s === '' ? '<EMPTY — env var missing>' : `<set, ${s.length} chars>`;
    } else if (typeof v === 'object' && v !== null) {
      out[k] = redact(v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

function buildTransport(name: string, cfg: Record<string, unknown>) {
  const type = (cfg.type as string | undefined) ?? (cfg.command ? 'stdio' : 'http');
  const headers = (cfg.headers as Record<string, string> | undefined) ?? {};

  if (type === 'http') {
    // requestInit carries the headers on POSTs; the SDK merges its own
    // Accept/Content-Type/session headers on top.
    return new StreamableHTTPClientTransport(new URL(cfg.url as string), {
      requestInit: { headers },
    });
  }
  if (type === 'sse') {
    return new SSEClientTransport(new URL(cfg.url as string), {
      requestInit: { headers },
      eventSourceInit: {
        fetch: (url: string | URL, init?: RequestInit) =>
          fetch(url, { ...init, headers: { ...(init?.headers as object), ...headers } }),
      },
    });
  }
  if (type === 'stdio') {
    return new StdioClientTransport({
      command: cfg.command as string,
      args: (cfg.args as string[]) ?? [],
      // Inherit the container env so a stdio server finds PATH/HOME, then layer
      // the config's own expanded env on top.
      env: { ...(process.env as Record<string, string>), ...((cfg.env as Record<string, string>) ?? {}) },
      stderr: 'pipe',
    });
  }
  throw new Error(`unsupported transport "${type}" for server "${name}"`);
}

let failures = 0;

const { servers, serverNames, missingVars } = await loadMcpConfig(configPath, process.cwd());

console.log(`config      ${configPath}`);
console.log(`servers     ${serverNames.join(', ')}`);

if (missingVars.length > 0) {
  const unique = [...new Set(missingVars)];
  console.log('');
  console.log(`FAIL  unset env vars: ${unique.join(', ')}`);
  console.log('      Archon expands these to empty strings, so the server will');
  console.log('      see a blank credential and reject the connection.');
  console.log('      Set them in .env, then ./archon restart.');
  process.exit(1);
}

for (const name of serverNames) {
  const cfg = servers[name] as Record<string, unknown>;
  const target = (cfg.url as string) ?? `${cfg.command} ${((cfg.args as string[]) ?? []).join(' ')}`;

  console.log('');
  console.log(`--- ${name} ---`);
  console.log(`target      ${target}`);
  console.log(`resolved    ${JSON.stringify(redact(cfg))}`);

  const client = new Client({ name: 'archon-mcp-verify', version: '1.0.0' }, { capabilities: {} });
  const started = Date.now();

  try {
    const transport = buildTransport(name, cfg);
    // Cap the wait: an unreachable host otherwise sits in TCP retry for minutes
    // and reads as a hang rather than a failure.
    await Promise.race([
      client.connect(transport),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error('timed out after 30s')), 30_000)
      ),
    ]);

    const info = client.getServerVersion();
    console.log(`handshake   OK (${Date.now() - started}ms) — ${info?.name ?? '?'} ${info?.version ?? ''}`);

    // Figma Desktop answers `initialize` whenever the app is running, but only
    // serves tools while a design/FigJam file is the ACTIVE TAB. Out of that
    // state it does not error — it simply never replies, so a default 60s
    // timeout reads as "Archon is broken" when the real cause is a foreground
    // window. Fail fast and say which one it is.
    let tools;
    try {
      ({ tools } = await client.listTools(undefined, { timeout: 20_000 }));
    } catch (err) {
      const msg = (err as Error).message;
      if (/timed out|-32001/.test(msg)) {
        console.log('TOOLS       timed out after 20s — handshake succeeded, tool list never came');
        if (target.includes('3845')) {
          console.log('            Figma Desktop does this when a design or FigJam file is not the');
          console.log('            ACTIVE TAB. Focus the app, open the design file, and retry.');
        }
        failures++;
        await client.close();
        continue;
      }
      throw err;
    }
    if (tools.length === 0) {
      console.log('TOOLS       none — connected but exposes nothing callable');
      failures++;
    } else {
      console.log(`TOOLS       ${tools.length} callable as mcp__${name}__<tool>:`);
      for (const t of tools) {
        const desc = (t.description ?? '').split('\n')[0].slice(0, 88);
        console.log(`              - ${t.name}${desc ? ` — ${desc}` : ''}`);
      }
    }

    if (toolName) {
      const args = toolArgsRaw ? JSON.parse(toolArgsRaw) : {};
      console.log('');
      console.log(`CALL        ${toolName}(${JSON.stringify(args)})`);
      // get_design_context on a large frame routinely exceeds the SDK's 60s
      // default, and a timeout there reads as "broken" when the server is just
      // working. Give a real call room to finish.
      const result = await client.callTool(
        { name: toolName, arguments: args },
        undefined,
        { timeout: 180_000 }
      );
      const text = JSON.stringify(result, null, 2);
      console.log(text.length > 4000 ? `${text.slice(0, 4000)}\n… (${text.length} bytes total)` : text);
      if (result.isError) failures++;
    }

    await client.close();
  } catch (err) {
    console.log(`FAIL        ${(err as Error).message}`);
    failures++;
  }
}

console.log('');
console.log(failures === 0 ? 'RESULT      all servers reachable and exposing tools' : `RESULT      ${failures} problem(s)`);
process.exit(failures === 0 ? 0 : 1);
