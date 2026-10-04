#!/usr/bin/env node
// Throwaway HTTP server for the dev smoke suite:
// `node http-status.mjs <port> <status>`. Answers every request with <status>
// and exits 0 on SIGTERM. Binds localhost, the host the smoke script requests.
// No dependencies.
import {createServer} from 'node:http';

const [portArgument, statusArgument] = process.argv.slice(2);
const port = Number(portArgument);
const status = Number(statusArgument);

if (!Number.isInteger(port) || port < 1 || port > 65_535 || !Number.isInteger(status)) {
  process.stderr.write('usage: http-status.mjs <port> <status>\n');
  process.exit(2);
}

const server = createServer((_request, response) => {
  response.statusCode = status;
  response.end();
});

server.on('error', (error) => {
  process.stderr.write(`${error.code ?? 'ERROR'}: ${error.message}\n`);
  process.exit(1);
});

process.on('SIGTERM', () => process.exit(0));

server.listen({exclusive: true, host: 'localhost', port});
