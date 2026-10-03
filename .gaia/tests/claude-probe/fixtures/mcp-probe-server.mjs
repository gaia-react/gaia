#!/usr/bin/env node
// Minimal stdio MCP server for the Claude probe. The temporary root .mcp.json
// that inject-probe-fixtures.sh writes registers it as `gaia-probe`, so the
// MCP rows observe a real server's connection status in the stream-json init
// event (connected from a launch that reads the root .mcp.json, absent from
// one that does not).
//
// Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout, the MCP stdio
// transport. Answers initialize, ping, tools/list (one no-op tool, so a client
// that hides tool-less servers still lists it) and tools/call; every other
// request gets a method-not-found error. No dependencies, no network, no file
// access.
import { createInterface } from 'node:readline';

const serverInfo = { name: 'gaia-probe', version: '1.0.0' };
const probeTool = {
  name: 'probe_ping',
  description: 'Returns the word pong. Exists only so the probe server lists a tool.',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
};

const send = (message) => {
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);
};

const handlers = {
  initialize: (params) => ({
    protocolVersion: params?.protocolVersion ?? '2025-06-18',
    capabilities: { tools: {} },
    serverInfo,
  }),
  ping: () => ({}),
  'tools/list': () => ({ tools: [probeTool] }),
  'tools/call': () => ({ content: [{ type: 'text', text: 'pong' }] }),
};

const lines = createInterface({ input: process.stdin });
lines.on('line', (rawLine) => {
  if (rawLine.trim() === '') return;
  let request;
  try {
    request = JSON.parse(rawLine);
  } catch {
    send({ id: null, error: { code: -32700, message: 'Parse error' } });
    return;
  }
  // A notification carries no id and gets no response.
  if (request.id === undefined || request.id === null) return;
  const handler = handlers[request.method];
  if (!handler) {
    send({ id: request.id, error: { code: -32601, message: `Method not found: ${request.method}` } });
    return;
  }
  send({ id: request.id, result: handler(request.params) });
});
lines.on('close', () => process.exit(0));
