import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export const DEV_BASE_PORT = 5173;

export const STORYBOOK_BASE_PORT = 6006;

export type DevPorts = {
  devPort: number;
  siteUrl: string | undefined;
  slot: number;
  source: 'default' | 'port-file';
  storybookPort: number;
  treeRoot: string | undefined;
};

export type DevPortsResolution =
  | {kind: 'malformed-port-file'; message: string; portFilePath: string}
  | {
      kind: 'missing-port-file';
      message: string;
      portFilePath: string;
      treeRoot: string;
    }
  | {kind: 'resolved'; ports: DevPorts};

export type ListenerOwner =
  | {kind: 'foreign'; ownerPath: string | undefined; pid: number}
  | {kind: 'free'}
  | {kind: 'own'; pid: number}
  | {kind: 'unknown'};

export const PORT_FILE_NAME = '.gaia-ports';

export const ASK_FIRST_SENTENCE =
  'Never stop a process on a port another live tree owns without asking the user first.';

export const PORTS_HINT =
  "Run bash .gaia/scripts/ports.sh to see this tree's ports.";

const MAXIMUM_PORT = 65_535;
const LISTENER_PROBE_TIMEOUT_MILLISECONDS = 5000;
const REQUIRED_KEYS = [
  'GAIA_PORT_SLOT',
  'DEV_PORT',
  'STORYBOOK_PORT',
  'SITE_URL',
] as const;

const isPort = (text: string): boolean => {
  if (!/^\d+$/.test(text)) return false;
  const value = Number(text);

  return value >= 1 && value <= MAXIMUM_PORT;
};

/** Parses the port file text; undefined means malformed. */
export const parsePortFile = (text: string): DevPorts | undefined => {
  const values = new Map<string, string>();

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();

    if (line !== '' && !line.startsWith('#')) {
      const separatorIndex = line.indexOf('=');
      if (separatorIndex === -1) return undefined;
      const key = line.slice(0, separatorIndex);
      if (values.has(key)) return undefined;
      values.set(key, line.slice(separatorIndex + 1));
    }
  }
  const [slot, devPort, storybookPort, siteUrl] = REQUIRED_KEYS.map((key) =>
    values.get(key)
  );

  if (
    slot === undefined ||
    devPort === undefined ||
    storybookPort === undefined ||
    siteUrl === undefined ||
    !/^\d+$/.test(slot) ||
    !isPort(devPort) ||
    !isPort(storybookPort)
  ) {
    return undefined;
  }

  return {
    devPort: Number(devPort),
    siteUrl,
    slot: Number(slot),
    source: 'port-file',
    storybookPort: Number(storybookPort),
    treeRoot: undefined,
  };
};

const readGitdirTarget = (gitPath: string): string | undefined => {
  try {
    const match = /^gitdir:[ \t]*(\S.*)$/m.exec(
      fs.readFileSync(gitPath, 'utf8')
    );

    return match?.[1].trim();
  } catch {
    return undefined;
  }
};

/** Walks up to the first `.git` and applies the linked-worktree predicate. */
export const findCheckout = (
  packageDirectory: string
): {isLinkedWorktree: boolean; treeRoot: string | undefined} => {
  let current = path.resolve(packageDirectory);

  for (;;) {
    const gitPath = path.join(current, '.git');

    if (fs.existsSync(gitPath)) {
      const treeRoot = fs.realpathSync(current);

      if (!fs.statSync(gitPath).isFile()) {
        return {isLinkedWorktree: false, treeRoot};
      }
      const target = readGitdirTarget(gitPath);
      const isLinkedWorktree =
        target !== undefined && /\/worktrees\/[^/]+\/?$/.test(target);

      return {isLinkedWorktree, treeRoot};
    }
    const parent = path.dirname(current);
    if (parent === current)
      return {isLinkedWorktree: false, treeRoot: undefined};
    current = parent;
  }
};

/** The refusal text for a linked worktree that has no port file. */
export const missingPortFileMessage = ({
  portFilePath,
  treeRoot,
}: {
  portFilePath: string;
  treeRoot: string;
}): string =>
  `GAIA: ${treeRoot} is a linked worktree with no port file at ${portFilePath}, so it has no ports of its own and will not borrow the main checkout's. Run: bash .claude/hooks/provision-worktree.sh ${treeRoot} ${ASK_FIRST_SENTENCE} ${PORTS_HINT}`;

const malformedPortFileMessage = ({
  portFilePath,
  treeRoot,
}: {
  portFilePath: string;
  treeRoot: string | undefined;
}): string =>
  `GAIA: the port file at ${portFilePath} is malformed, so this tree has no usable ports. Run: bash .claude/hooks/provision-worktree.sh ${treeRoot ?? '<tree-root>'} ${ASK_FIRST_SENTENCE} ${PORTS_HINT}`;

/** The refusal text for a dev or Storybook port that is already taken. */
export const portInUseMessage = ({
  ownerPath,
  pid,
  port,
  service,
}: {
  ownerPath?: string;
  pid?: number;
  port: number;
  service: 'dev server' | 'Storybook';
}): string => {
  const pidPart = pid === undefined ? '' : ` by PID ${pid}`;
  const pathPart = ownerPath === undefined ? '' : ` in ${ownerPath}`;

  return `GAIA: port ${port}, this tree's ${service} port, is already in use${pidPart}${pathPart}. Refusing to start on a different port. ${ASK_FIRST_SENTENCE} ${PORTS_HINT}`;
};

/** The refusal text for Playwright declining a server this tree does not own. */
export const foreignServerMessage = ({
  ownerPath,
  port,
}: {
  ownerPath: string | undefined;
  port: number;
}): string =>
  `GAIA: port ${port} is held by a server that is not this tree's own (${ownerPath ?? 'owner unknown'}), so Playwright will not reuse it. ${ASK_FIRST_SENTENCE} ${PORTS_HINT}`;

/** Resolves this package's ports from its port file, or the slot-0 default. */
export const resolveDevPorts = (
  packageDirectory: string
): DevPortsResolution => {
  const portFilePath = path.join(packageDirectory, PORT_FILE_NAME);
  const {isLinkedWorktree, treeRoot} = findCheckout(packageDirectory);

  let text: string | undefined;

  try {
    text = fs.readFileSync(portFilePath, 'utf8');
  } catch {
    text = undefined;
  }

  if (text !== undefined) {
    const parsed = parsePortFile(text);

    if (parsed === undefined) {
      return {
        kind: 'malformed-port-file',
        message: malformedPortFileMessage({portFilePath, treeRoot}),
        portFilePath,
      };
    }

    return {kind: 'resolved', ports: {...parsed, treeRoot}};
  }

  if (isLinkedWorktree && treeRoot !== undefined) {
    return {
      kind: 'missing-port-file',
      message: missingPortFileMessage({portFilePath, treeRoot}),
      portFilePath,
      treeRoot,
    };
  }

  return {
    kind: 'resolved',
    ports: {
      devPort: DEV_BASE_PORT,
      siteUrl: undefined,
      slot: 0,
      source: 'default',
      storybookPort: STORYBOOK_BASE_PORT,
      treeRoot,
    },
  };
};

/** Returns the resolved ports or throws the refusal message. */
export const requireDevPorts = (packageDirectory: string): DevPorts => {
  const resolution = resolveDevPorts(packageDirectory);
  if (resolution.kind !== 'resolved') throw new Error(resolution.message);

  return resolution.ports;
};

/** An exported SITE_URL wins, else the port file's, else undefined. */
export const resolveSiteUrl = ({
  exportedSiteUrl,
  ports,
}: {
  exportedSiteUrl: string | undefined;
  ports: DevPorts;
}): string | undefined => {
  if (exportedSiteUrl !== undefined && exportedSiteUrl !== '') {
    return exportedSiteUrl;
  }

  return ports.siteUrl;
};

const parseListenerOwner = (output: string): ListenerOwner => {
  const [kind, pidText, ...rest] = output.trim().split(/\s+/);
  const pid = Number(pidText);
  const hasPid = Number.isInteger(pid) && pid > 0;
  if (kind === 'free' && output.trim() === 'free') return {kind: 'free'};
  if (kind === 'own' && hasPid && rest.length === 0) return {kind: 'own', pid};

  // `ss` omits the PID of another user's socket, so the process library
  // reports that listener as `foreign 0`; it is still a foreign server.
  const hasForeignPid = Number.isInteger(pid) && pid >= 0;

  if (kind === 'foreign' && hasForeignPid && rest.length > 0) {
    const ownerPath = rest.join(' ');

    return {
      kind: 'foreign',
      ownerPath: ownerPath === 'unknown' ? undefined : ownerPath,
      pid,
    };
  }

  return {kind: 'unknown'};
};

/** Asks the process library who owns the listener on a port. */
export const listenerOwner = ({
  port,
  treeRoot,
}: {
  port: number;
  treeRoot: string | undefined;
}): ListenerOwner => {
  if (treeRoot === undefined) return {kind: 'unknown'};

  try {
    // The script path is built from the resolved tree root; `bash` is the only PATH lookup.
    const output = execFileSync(
      // eslint-disable-next-line sonarjs/no-os-command-from-path
      'bash',
      [
        path.join(treeRoot, '.gaia', 'scripts', 'server-process-lib.sh'),
        '--listener-owner',
        String(port),
        treeRoot,
      ],
      {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: LISTENER_PROBE_TIMEOUT_MILLISECONDS,
      }
    );

    return parseListenerOwner(output);
  } catch {
    return {kind: 'unknown'};
  }
};
