#!/usr/bin/env node
// Throwaway TCP listener for the port suites: `node listen.mjs <port> <host>`.
// Prints exactly `listening <pid>` once bound and then waits; exits 0 on
// SIGTERM, and 1 with the error on stderr when the bind fails (EADDRINUSE).
// It never changes directory, so a caller places a listener "inside" a tree by
// starting it from that directory. No dependencies.
import {createServer} from 'node:net';

const [portArgument, host] = process.argv.slice(2);
const port = Number(portArgument);

if (!Number.isInteger(port) || port < 1 || port > 65_535 || !host) {
  process.stderr.write('usage: listen.mjs <port> <host>\n');
  process.exit(2);
}

const server = createServer((socket) => socket.end());

server.on('error', (error) => {
  process.stderr.write(`${error.code ?? 'ERROR'}: ${error.message}\n`);
  process.exit(1);
});

process.on('SIGTERM', () => {
  server.close();
  process.exit(0);
});

// exclusive: a second instance must fail to bind rather than share the port
// through a cluster handle.
server.listen({exclusive: true, host, port}, () => {
  process.stdout.write(`listening ${process.pid}\n`);
});
