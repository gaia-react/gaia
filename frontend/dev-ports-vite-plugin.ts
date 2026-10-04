import type {Plugin} from 'vite';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import type {ListenerOwner} from './dev-ports.ts';
import {
  buildPortInUseMessage,
  findListenerOwner,
  resolveDevPorts,
  resolveServerProcessScriptPath,
} from './dev-ports.ts';

// A config restart builds the new server (running this hook) before it closes
// the old one, so the old one still holds the port. Vite re-bundles the config
// into a fresh module on restart, so module state does not survive it: the
// restart is told from a foreign holder by asking who owns the listener. This
// flag keeps a restart, in this module or a fresh one, from recording the launch twice.
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
  const takenStateByAddress = await Promise.all(
    LOOPBACK_ADDRESSES.map(async (host) => isTakenOn(port, host))
  );

  return takenStateByAddress.includes(true);
};

const describePortHolder = ({
  owner,
  treeRoot,
}: {
  owner: ListenerOwner;
  treeRoot: string | undefined;
}): {ownerPath?: string; pid?: number} => {
  if (owner.kind === 'foreign') {
    return {
      ownerPath: owner.ownerPath,
      pid: owner.pid > 0 ? owner.pid : undefined,
    };
  }
  if (owner.kind === 'own') return {ownerPath: treeRoot, pid: owner.pid};

  return {};
};

const recordLaunch = ({
  port,
  treeRoot,
}: {
  port: number;
  treeRoot: string;
}): void => {
  if (!process.env.CLAUDE_CODE_SESSION_ID) return;
  const scriptPath = resolveServerProcessScriptPath(treeRoot);
  if (!fs.existsSync(scriptPath)) return;

  // Fire and forget: the record is bookkeeping and must never slow the server.
  const child = spawn(
    // eslint-disable-next-line sonarjs/no-os-command-from-path
    'bash',
    [
      scriptPath,
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

    if (await isTaken(devPort)) {
      const owner = findListenerOwner({port: devPort, treeRoot});

      if (owner.kind !== 'own' || owner.pid !== process.pid) {
        throw new Error(
          buildPortInUseMessage({
            ...describePortHolder({owner, treeRoot}),
            port: devPort,
            service: 'dev server',
          })
        );
      }
      // This process already holds the port: a restart, whose launch was recorded.
      hasListenedInThisProcess = true;
    }

    server.httpServer?.once('listening', () => {
      if (hasListenedInThisProcess) return;
      hasListenedInThisProcess = true;
      if (treeRoot !== undefined) recordLaunch({port: devPort, treeRoot});
    });
  },
  name: 'gaia-dev-ports',
});
