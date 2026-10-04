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
// into a fresh module on restart, so module state does not survive it. The port
// this process is listening on is therefore recorded in a globalThis slot, which
// does survive, so a restart is told from a foreign holder without needing the
// listener-owner probe (which reads unknown without lsof/ss or outside a git
// checkout). The owner probe stays as the fallback for a port the slot does not
// name. The slot also keeps a restart from recording the launch twice.
const LISTENING_PORT_SLOT = Symbol.for('gaia.dev-ports.listening-port');

type ListeningPortHolder = {[LISTENING_PORT_SLOT]?: number};

const getRecordedPort = (): number | undefined =>
  (globalThis as ListeningPortHolder)[LISTENING_PORT_SLOT];

const recordPort = (port: number): void => {
  (globalThis as ListeningPortHolder)[LISTENING_PORT_SLOT] = port;
};

// The wildcards are probed too: on macOS a loopback bind succeeds beside a
// server bound to 0.0.0.0 or ::, so the loopback probes alone read it as free.
// The probes run one at a time: on Linux a wildcard bind fails beside this
// process's own still-open loopback probe, so concurrent probes read a free
// port as taken.
const PROBE_ADDRESSES = ['127.0.0.1', '::1', '0.0.0.0', '::'];

const isTakenOn = async (port: number, host: string): Promise<boolean> =>
  new Promise((resolve) => {
    const probe = net.createServer();

    probe.once('error', (error: NodeJS.ErrnoException) => {
      // Only EADDRINUSE means taken; an absent address family (EADDRNOTAVAIL,
      // EAFNOSUPPORT) just means that address does not exist here.
      resolve(error.code === 'EADDRINUSE');
    });
    probe.once('listening', () => {
      probe.close(() => resolve(false));
    });
    probe.listen({exclusive: true, host, port});
  });

const isTaken = async (port: number): Promise<boolean> => {
  for (const host of PROBE_ADDRESSES) {
    // eslint-disable-next-line no-await-in-loop -- concurrent probes collide on Linux
    if (await isTakenOn(port, host)) return true;
  }

  return false;
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

    if ((await isTaken(devPort)) && getRecordedPort() !== devPort) {
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
    }

    server.httpServer?.once('listening', () => {
      // A restart's port is already recorded, and so is its launch.
      const isRestart = getRecordedPort() === devPort;
      recordPort(devPort);
      if (isRestart) return;
      if (treeRoot !== undefined) recordLaunch({port: devPort, treeRoot});
    });
  },
  name: 'gaia-dev-ports',
});
