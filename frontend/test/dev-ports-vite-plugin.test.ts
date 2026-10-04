/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports-vite-plugin */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {ASK_FIRST_SENTENCE, PORTS_HINT} from '../dev-ports';
import type {DevPortsResolution} from '../dev-ports';

const {findListenerOwnerMock, resolveDevPortsMock, spawnMock} = vi.hoisted(
  () => ({
    findListenerOwnerMock: vi.fn(),
    resolveDevPortsMock: vi.fn(),
    spawnMock: vi.fn(),
  })
);

vi.mock('node:child_process', () => ({
  default: {spawn: spawnMock},
  spawn: spawnMock,
}));

vi.mock('../dev-ports', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  findListenerOwner: findListenerOwnerMock,
  resolveDevPorts: resolveDevPortsMock,
}));

type PluginHooks = {
  config: (
    configuration: unknown,
    environment: {command: string}
  ) => undefined | {server?: {port?: number; strictPort?: boolean}};
  configureServer: (server: unknown) => Promise<void>;
};

const loadPlugin = async (): Promise<PluginHooks> => {
  const {devPortsPlugin} = await import('../dev-ports-vite-plugin');

  return devPortsPlugin('/package') as unknown as PluginHooks;
};

const listenOn = async (port: number, host: string): Promise<net.Server> =>
  new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen({exclusive: true, host, port}, () => resolve(server));
  });

const closeServer = async (server: net.Server): Promise<void> =>
  new Promise((resolve) => {
    server.close(() => resolve());
  });

const findFreePort = async (): Promise<number> => {
  const server = await listenOn(0, '127.0.0.1');
  const {port} = server.address() as net.AddressInfo;
  await closeServer(server);

  return port;
};

const hasIpv6 = async (): Promise<boolean> => {
  try {
    await closeServer(await listenOn(0, '::1'));

    return true;
  } catch {
    return false;
  }
};

const isIpv6Available = await hasIpv6();

const buildResolvedResolution = (
  devPort: number,
  treeRoot = '/tree'
): DevPortsResolution => ({
  kind: 'resolved',
  ports: {
    devPort,
    siteUrl: undefined,
    slot: 0,
    source: 'default',
    storybookPort: 6006,
    treeRoot,
  },
});

type FakeServer = {
  httpServer: {
    emit: (event: string) => void;
    once: (event: string, listener: () => void) => void;
  };
};

// The plugin only calls `httpServer.once('listening', ...)`; a handler list is the whole fake.
const makeServer = (): FakeServer => {
  const handlers: Record<string, (() => void)[]> = {};

  return {
    httpServer: {
      emit: (event) => {
        for (const handler of handlers[event] ?? []) handler();
      },
      once: (event, listener) => {
        handlers[event] = [...(handlers[event] ?? []), listener];
      },
    },
  };
};

const heldServers: net.Server[] = [];
let sandbox: string | undefined;

const listenWith = async (treeRoot: string): Promise<void> => {
  resolveDevPortsMock.mockReturnValue(buildResolvedResolution(5301, treeRoot));
  const plugin = await loadPlugin();
  const server = makeServer();
  await plugin.configureServer(server);
  server.httpServer.emit('listening');
};

const makeTreeWithScript = (): string => {
  sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'dev-ports-plugin-'));
  fs.mkdirSync(path.join(sandbox, '.gaia', 'scripts'), {recursive: true});
  fs.writeFileSync(
    path.join(sandbox, '.gaia', 'scripts', 'server-process-lib.sh'),
    ''
  );

  return sandbox;
};

beforeEach(() => {
  vi.resetModules();
  spawnMock.mockReset();
  spawnMock.mockReturnValue({on: vi.fn(), unref: vi.fn()});
  resolveDevPortsMock.mockReset();
  findListenerOwnerMock.mockReset();
  findListenerOwnerMock.mockReturnValue({kind: 'unknown'});
  delete process.env.CLAUDE_CODE_SESSION_ID;
});

afterEach(async () => {
  await Promise.all(
    heldServers.splice(0).map(async (server) => closeServer(server))
  );

  if (sandbox !== undefined) {
    fs.rmSync(sandbox, {force: true, recursive: true});
    sandbox = undefined;
  }
  delete process.env.CLAUDE_CODE_SESSION_ID;
});

describe('config', () => {
  test('serve pins the resolved dev port with strictPort', async () => {
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(5199));
    const plugin = await loadPlugin();

    expect(plugin.config({}, {command: 'serve'})).toEqual({
      server: {port: 5199, strictPort: true},
    });
  });

  test('build returns nothing port-related and never throws on a missing port file', async () => {
    resolveDevPortsMock.mockReturnValue({
      kind: 'missing-port-file',
      message: 'missing',
      portFilePath: '/package/.gaia-ports',
      treeRoot: '/tree',
    });
    const plugin = await loadPlugin();

    expect(plugin.config({}, {command: 'build'})).toBeUndefined();
    expect(resolveDevPortsMock).not.toHaveBeenCalled();
  });
});

describe('configureServer refusals', () => {
  test('a missing port file rejects with the ask-first sentence and ports hint', async () => {
    resolveDevPortsMock.mockReturnValue({
      kind: 'missing-port-file',
      message: `GAIA: no port file. ${ASK_FIRST_SENTENCE} ${PORTS_HINT}`,
      portFilePath: '/package/.gaia-ports',
      treeRoot: '/tree',
    });
    const plugin = await loadPlugin();

    const failure = plugin.configureServer(makeServer());
    await expect(failure).rejects.toThrow(ASK_FIRST_SENTENCE);
    await expect(failure).rejects.toThrow(PORTS_HINT);
  });

  test('a port taken on 127.0.0.1 rejects naming the port, the ask-first sentence, and the hint', async () => {
    const port = await findFreePort();
    heldServers.push(await listenOn(port, '127.0.0.1'));
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    const failure = plugin.configureServer(makeServer());
    await expect(failure).rejects.toThrow(`port ${port}`);
    await expect(failure).rejects.toThrow(ASK_FIRST_SENTENCE);
    await expect(failure).rejects.toThrow(PORTS_HINT);
  });

  test.skipIf(!isIpv6Available)(
    'a port taken on ::1 only rejects the same way',
    async () => {
      const port = await findFreePort();
      heldServers.push(await listenOn(port, '::1'));
      resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
      const plugin = await loadPlugin();

      await expect(plugin.configureServer(makeServer())).rejects.toThrow(
        `port ${port}`
      );
    }
  );

  test('a free port resolves', async () => {
    resolveDevPortsMock.mockReturnValue(
      buildResolvedResolution(await findFreePort())
    );
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).resolves.toBeUndefined();
  });
});

describe('config restart', () => {
  test('does not refuse its own port after a module reload and records the launch once', async () => {
    sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'dev-ports-plugin-'));
    fs.mkdirSync(path.join(sandbox, '.gaia', 'scripts'), {recursive: true});
    fs.writeFileSync(
      path.join(sandbox, '.gaia', 'scripts', 'server-process-lib.sh'),
      ''
    );
    process.env.CLAUDE_CODE_SESSION_ID = 'session-one';
    const port = await findFreePort();
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port, sandbox));
    const plugin = await loadPlugin();

    const firstServer = makeServer();
    await plugin.configureServer(firstServer);
    heldServers.push(await listenOn(port, '127.0.0.1'));
    firstServer.httpServer.emit('listening');

    // A real restart re-bundles the config into a fresh module, so the second
    // configureServer runs against a module with no memory of the first.
    vi.resetModules();
    findListenerOwnerMock.mockReturnValue({kind: 'own', pid: process.pid});
    const restartedPlugin = await loadPlugin();

    const restartedServer = makeServer();
    await expect(
      restartedPlugin.configureServer(restartedServer)
    ).resolves.toBeUndefined();
    restartedServer.httpServer.emit('listening');

    expect(findListenerOwnerMock).toHaveBeenCalledWith({
      port,
      treeRoot: sandbox,
    });
    expect(spawnMock).toHaveBeenCalledTimes(1);
  });

  test('a held port owned by another process still refuses', async () => {
    const port = await findFreePort();
    heldServers.push(await listenOn(port, '127.0.0.1'));
    findListenerOwnerMock.mockReturnValue({kind: 'own', pid: process.pid + 1});
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).rejects.toThrow(
      `port ${port}`
    );
  });

  test('a fresh module with the port held still refuses (control)', async () => {
    const port = await findFreePort();
    heldServers.push(await listenOn(port, '127.0.0.1'));
    resolveDevPortsMock.mockReturnValue(buildResolvedResolution(port));
    const plugin = await loadPlugin();

    await expect(plugin.configureServer(makeServer())).rejects.toThrow(
      `port ${port}`
    );
  });
});

describe('launch recording', () => {
  test('with no session id nothing is spawned', async () => {
    resolveDevPortsMock.mockReturnValue(
      buildResolvedResolution(await findFreePort())
    );
    await listenWith(makeTreeWithScript());

    expect(spawnMock).not.toHaveBeenCalled();
  });

  test('with a session id and the script present exactly one detached recorder is spawned', async () => {
    process.env.CLAUDE_CODE_SESSION_ID = 'session-two';
    const treeRoot = makeTreeWithScript();
    await listenWith(treeRoot);

    expect(spawnMock).toHaveBeenCalledTimes(1);
    expect(spawnMock).toHaveBeenCalledWith(
      'bash',
      [
        path.join(treeRoot, '.gaia', 'scripts', 'server-process-lib.sh'),
        '--record-launch',
        '--pid',
        String(process.pid),
        '--port',
        '5301',
        '--kind',
        'dev',
        '--tree',
        treeRoot,
      ],
      {detached: true, stdio: 'ignore'}
    );
  });

  test('with a session id but no script nothing is spawned', async () => {
    process.env.CLAUDE_CODE_SESSION_ID = 'session-three';
    sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'dev-ports-plugin-'));
    await listenWith(sandbox);

    expect(spawnMock).not.toHaveBeenCalled();
  });
});
