import type {Plugin} from 'vite';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {portInUseMessage, resolveDevPorts} from './dev-ports.ts';

// A config restart builds the new server (running this hook) before it closes
// the old one, and the old one still holds the port. Module state survives the
// restart, so it tells a restart from a first start.
let hasListenedInThisProcess = false;

const LOOPBACK_ADDRESSES = ['127.0.0.1', '::1'];

const isTakenOn = async (port: number, host: string): Promise<boolean> =>
  new Promise((resolve) => {
    const probe = net.createServer();

    probe.once('error', (error: NodeJS.ErrnoException) => {
      // Only EADDRINUSE means taken; an absent address family (EADDRNOTAVAIL,
      // EAFNOSUPPORT) just means that loopback does not exist here.
      resolve(error.code === 'EADDRINUSE');
    });
    probe.once('listening', () => {
      probe.close(() => resolve(false));
    });
    probe.listen({exclusive: true, host, port});
  });

const isTaken = async (port: number): Promise<boolean> => {
  const results = await Promise.all(
    LOOPBACK_ADDRESSES.map(async (host) => isTakenOn(port, host))
  );

  return results.includes(true);
};

const recordLaunch = ({
  port,
  treeRoot,
}: {
  port: number;
  treeRoot: string;
}): void => {
  if (!process.env.CLAUDE_CODE_SESSION_ID) return;
  const script = path.join(
    treeRoot,
    '.gaia',
    'scripts',
    'server-process-lib.sh'
  );
  if (!fs.existsSync(script)) return;

  // Fire and forget: the record is bookkeeping and must never slow the server.
  const child = spawn(
    // eslint-disable-next-line sonarjs/no-os-command-from-path
    'bash',
    [
      script,
      '--record-launch',
      '--pid',
      String(process.pid),
      '--port',
      String(port),
      '--kind',
      'dev',
      '--tree',
      treeRoot,
    ],
    {detached: true, stdio: 'ignore'}
  );

  child.on('error', () => {});
  child.unref();
};

/**
 * Pins the dev server to this tree's port without drifting, refuses a taken
 * port with the ask-first message, and records a Claude-launched server so a
 * dead session's server can be cleaned up.
 */
export const devPortsPlugin = (packageDirectory: string): Plugin => ({
  config: (_, {command}) => {
    if (command !== 'serve') return;
    const resolution = resolveDevPorts(packageDirectory);
    if (resolution.kind !== 'resolved') return;

    return {server: {port: resolution.ports.devPort, strictPort: true}};
  },
  configureServer: async (server) => {
    const resolution = resolveDevPorts(packageDirectory);
    if (resolution.kind !== 'resolved') throw new Error(resolution.message);
    const {devPort, treeRoot} = resolution.ports;

    if (!hasListenedInThisProcess && (await isTaken(devPort))) {
      throw new Error(portInUseMessage({port: devPort, service: 'dev server'}));
    }

    server.httpServer?.once('listening', () => {
      if (hasListenedInThisProcess) return;
      hasListenedInThisProcess = true;
      if (treeRoot !== undefined) recordLaunch({port: devPort, treeRoot});
    });
  },
  name: 'gaia-dev-ports',
});
