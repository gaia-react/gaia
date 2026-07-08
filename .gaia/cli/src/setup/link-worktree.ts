/**
 * `gaia setup link-worktree [--json]` handler.
 *
 * Idempotently creates the six SPEC-005 shared-state symlinks from the
 * current linked worktree into the main checkout:
 *
 *   <worktree>/.gaia/local/setup-state.json -> <main>/.gaia/local/setup-state.json
 *   <worktree>/.gaia/local/mentorship.json  -> <main>/.gaia/local/mentorship.json
 *   <worktree>/.gaia/local/cache/shared/     -> <main>/.gaia/local/cache/shared/
 *   <worktree>/.gaia/local/audit/            -> <main>/.gaia/local/audit/
 *   <worktree>/.gaia/local/telemetry/        -> <main>/.gaia/local/telemetry/
 *   <worktree>/.gaia/local/debt/             -> <main>/.gaia/local/debt/
 *
 * Also links gitignored checkout-root `.env` / `.env.*` files (excluding the
 * committed `.env.example`) from the main checkout, one symlink per file,
 * reported separately in the `env_actions` field so the frozen six-entry
 * `actions` contract above is untouched.
 *
 * No-op on a main checkout (not a linked worktree). Pre-existing plain
 * files / dirs are moved to <path>.bak.<timestamp> before the symlink is
 * created. Exits 1 on any `failed` action; the user explicitly invoked
 * the CLI, so surfacing the error is correct (the script counterpart
 * always exits 0 because it must not break worktree creation).
 *
 * Frozen JSON shape; see SPEC-005 plan README.md for the contract.
 */
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  symlinkSync,
} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveMainWorktreeRoot} from './util/state-file.js';

const HELP_TEXT = `Usage: gaia setup link-worktree [--json]

  Idempotently create the six worktree shared-state symlinks pointing at
  the main checkout. Also links gitignored checkout-root .env / .env.*
  files (excluding .env.example) from the main checkout. Backs up
  pre-existing plain files to <path>.bak.<ts>. No-op on a main checkout
  (not a linked worktree); exits 0 with a one-line "not a linked worktree"
  message.

  --json   Print a single JSON line describing the result instead of the
           human-readable summary.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type Action = {
  backup?: string;
  error?: string;
  path: string;
  result: ActionResult;
};

type ActionResult =
  | 'already-linked'
  | 'failed'
  | 'linked'
  | 'linked-after-backup'
  | 'skipped-no-target';

type LinkOutput = {
  actions: Action[];
  env_actions: Action[];
  is_worktree: boolean;
  main_root: null | string;
  worktree_root: null | string;
};

type RunOptions = {
  cwd?: string;
  /** Override "now" for deterministic tests. */
  now?: () => Date;
  /** Override symlink creation for failure-injection tests. */
  symlink?: (target: string, source: string) => void;
};

type SharedPathSpec = {
  /**
   * Whether the main-side target should be ensured (created if missing) as
   * a directory before the symlink is made. `setup-state.json` is a file
   * and is intentionally NOT pre-created; the symlink dangles until the
   * normal setup flow writes it; readers treat missing as "no state yet".
   */
  ensureTargetDir: boolean;
  relativePath: string;
};

/**
 * Frozen path set; six entries, in this order, always present in the
 * output `actions` array regardless of result. See SPEC-005 plan README.
 *
 * `mentorship.json` is a per-machine file entry alongside `setup-state.json`
 * (ensureTargetDir: false, dangles until first write). Sharing it keeps the
 * finalize gate, which resolves from the main-worktree root, and the
 * mentorship write/read path, which resolves from the linked root, pointing
 * at one file so a decision made in a linked worktree satisfies the gate.
 *
 * `debt/` holds the `/gaia-debt` count cache and its `refresh-requested`
 * sentinel. Sharing it means a tech-debt fix merged from inside a linked
 * worktree arms the main checkout's sentinel, so the statusline debt nudge
 * recomputes instead of freezing on its TTL until the backlog empties.
 */
const SHARED_PATHS: readonly SharedPathSpec[] = [
  {ensureTargetDir: false, relativePath: '.gaia/local/setup-state.json'},
  {ensureTargetDir: false, relativePath: '.gaia/local/mentorship.json'},
  {ensureTargetDir: true, relativePath: '.gaia/local/cache/shared'},
  {ensureTargetDir: true, relativePath: '.gaia/local/audit'},
  {ensureTargetDir: true, relativePath: '.gaia/local/telemetry'},
  {ensureTargetDir: true, relativePath: '.gaia/local/debt'},
];

// Shareable env-file basename set: `.env` and any `.env.*` variant under the
// checkout root, except the committed `.env.example`. Mirrors .gitignore's
// `.env` / `.env.*` / `!.env.example` and the `is_dotenv_path` definition in
// `.claude/hooks/block-env-read.sh`. See SPEC-005 plan README.md.
const ENV_BASENAME_RE = /^\.env(\.[A-Za-z0-9_-]+)*$/;
const isShareableEnvironmentFile = (base: string): boolean =>
  ENV_BASENAME_RE.test(base) && base !== '.env.example';

const formatTimestamp = (date: Date): string => {
  const pad = (value: number): string => String(value).padStart(2, '0');
  const yyyy = date.getFullYear();
  const mm = pad(date.getMonth() + 1);
  const dd = pad(date.getDate());
  const hh = pad(date.getHours());
  const mi = pad(date.getMinutes());
  const ss = pad(date.getSeconds());

  return `${String(yyyy)}${mm}${dd}-${hh}${mi}${ss}`;
};

const ensureParentDir = (filePath: string): void => {
  const parent = path.dirname(filePath);

  if (!existsSync(parent)) {
    mkdirSync(parent, {mode: 0o755, recursive: true});
  }
};

type LinkOneInputs = {
  mainRoot: string;
  spec: SharedPathSpec;
  symlink: (target: string, source: string) => void;
  timestamp: string;
  worktreeRoot: string;
};

const linkOne = (inputs: LinkOneInputs): Action => {
  const {mainRoot, spec, symlink, timestamp, worktreeRoot} = inputs;
  const sourcePath = path.join(worktreeRoot, spec.relativePath);
  const targetPath = path.join(mainRoot, spec.relativePath);

  try {
    // Ensure the worktree-side parent dir exists (e.g. .gaia/local/).
    ensureParentDir(sourcePath);

    // Ensure the main-side target exists where appropriate so the symlink
    // does not dangle at creation. Files are not pre-created.
    if (spec.ensureTargetDir && !existsSync(targetPath)) {
      mkdirSync(targetPath, {mode: 0o755, recursive: true});
    }

    // Inspect the worktree-side source.
    let sourceStat;

    try {
      sourceStat = lstatSync(sourcePath);
    } catch {
      sourceStat = null;
    }

    if (sourceStat === null) {
      // No source: simply create the symlink.
      symlink(targetPath, sourcePath);

      return {path: spec.relativePath, result: 'linked'};
    }

    if (sourceStat.isSymbolicLink()) {
      const existing = readlinkSync(sourcePath);

      if (existing === targetPath) {
        return {path: spec.relativePath, result: 'already-linked'};
      }

      // Wrong target; back up the symlink and recreate.
      const backupPath = `${sourcePath}.bak.${timestamp}`;
      renameSync(sourcePath, backupPath);
      symlink(targetPath, sourcePath);

      return {
        backup: path.relative(worktreeRoot, backupPath),
        path: spec.relativePath,
        result: 'linked-after-backup',
      };
    }

    // Plain file / directory present; move aside and replace.
    const backupPath = `${sourcePath}.bak.${timestamp}`;
    renameSync(sourcePath, backupPath);
    symlink(targetPath, sourcePath);

    return {
      backup: path.relative(worktreeRoot, backupPath),
      path: spec.relativePath,
      result: 'linked-after-backup',
    };
  } catch (error) {
    return {
      error: error instanceof Error ? error.message : String(error),
      path: spec.relativePath,
      result: 'failed',
    };
  }
};

const ACTION_HUMAN_LABELS: Readonly<Record<ActionResult, string>> = {
  'already-linked': 'already-linked',
  failed: 'failed',
  linked: 'linked',
  'linked-after-backup': 'linked-after-backup',
  'skipped-no-target': 'skipped-no-target',
};

// The frozen fixed-path summary lines, byte-for-byte identical to the
// pre-env-sharing output (link-worktree.test.ts asserts the exact
// substrings). Returns lines instead of writing directly so `printHuman`
// can append the env summary after it.
const buildFixedSummaryLines = (output: LinkOutput): string[] => {
  const failed = output.actions.filter((action) => action.result === 'failed');

  if (failed.length > 0) {
    const lines = [
      `Failed to link ${String(failed.length)} of ${String(output.actions.length)} paths to ${String(output.main_root)}.`,
    ];

    for (const action of output.actions) {
      const label = ACTION_HUMAN_LABELS[action.result];
      const suffix =
        action.result === 'failed' && action.error !== undefined ?
          `: ${action.error}`
        : '';
      lines.push(`  ${label}: ${action.path}${suffix}`);
    }

    return lines;
  }

  const allAlreadyLinked = output.actions.every(
    (action) => action.result === 'already-linked'
  );

  if (allAlreadyLinked) {
    return [`All ${String(output.actions.length)} paths already linked.`];
  }

  const backedUp = output.actions.filter(
    (action) => action.result === 'linked-after-backup'
  );

  const lines = [
    `Linked ${String(output.actions.length)} paths to ${String(output.main_root)}.`,
  ];

  for (const action of backedUp) {
    lines.push(`  Backed up: ${action.path} -> ${String(action.backup)}`);
  }

  return lines;
};

// Env-file summary, appended after the fixed shared-path summary. Empty
// `env_actions` (no gitignored .env files in the main checkout) produces no
// lines at all.
const buildEnvironmentSummaryLines = (
  envActions: readonly Action[]
): string[] => {
  if (envActions.length === 0) return [];

  const allAlreadyLinked = envActions.every(
    (action) => action.result === 'already-linked'
  );

  if (allAlreadyLinked) {
    return [`All ${String(envActions.length)} env file(s) already linked.`];
  }

  const lines = [
    `Linked ${String(envActions.length)} env file(s): ${envActions
      .map((action) => `${action.path} (${action.result})`)
      .join(', ')}.`,
  ];

  const failed = envActions.filter((action) => action.result === 'failed');

  for (const action of failed) {
    lines.push(`  failed: ${action.path}: ${String(action.error)}`);
  }

  return lines;
};

const printHuman = (output: LinkOutput): void => {
  if (!output.is_worktree) {
    process.stdout.write('not a linked worktree\n');

    return;
  }

  const lines = [
    ...buildFixedSummaryLines(output),
    ...buildEnvironmentSummaryLines(output.env_actions),
  ];

  process.stdout.write(`${lines.join('\n')}\n`);
};

// Extracted out of `run` (kept its cognitive complexity under the frozen
// limit): the main-root / worktree-root resolution, independent of the
// json/human output that follows.
const resolveWorktreeRoots = (
  cwd: string
): {exitCode: number} | {mainRoot: string; worktreeRoot: string} => {
  // Canonicalize the cwd (resolve symlinks like macOS /var -> /private/var)
  // so the main_root and worktree_root paths emitted in the JSON are
  // self-consistent; git always returns canonical paths from --show-toplevel,
  // so the input cwd must be canonicalized before comparison.
  let canonicalCwd: string;

  try {
    canonicalCwd = realpathSync(cwd);
  } catch {
    canonicalCwd = cwd;
  }

  let mainRoot: string;

  try {
    mainRoot = resolveMainWorktreeRoot(canonicalCwd);
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup link-worktree must run inside a git repository',
      subcommand: 'setup link-worktree',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  // Resolve the current worktree root (may equal mainRoot on a main checkout).
  // Use git --show-toplevel mirroring the script. If `resolveMainWorktreeRoot`
  // succeeded above, this fork is essentially guaranteed to succeed too, but
  // guard for the unlikely case anyway.
  try {
    const worktreeRoot = execFileSync('git', ['rev-parse', '--show-toplevel'], {
      cwd: canonicalCwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();

    return {mainRoot, worktreeRoot};
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup link-worktree must run inside a git repository',
      subcommand: 'setup link-worktree',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  let json = false;

  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'setup link-worktree',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
  }

  const cwd = options.cwd ?? process.cwd();
  const roots = resolveWorktreeRoots(cwd);

  if ('exitCode' in roots) return roots.exitCode;

  const {mainRoot, worktreeRoot} = roots;

  if (mainRoot === worktreeRoot) {
    const output: LinkOutput = {
      actions: [],
      env_actions: [],
      is_worktree: false,
      main_root: mainRoot,
      worktree_root: worktreeRoot,
    };

    if (json) {
      process.stdout.write(`${JSON.stringify(output)}\n`);
    } else {
      printHuman(output);
    }

    return EXIT_CODES.OK;
  }

  const nowDate = (options.now ?? (() => new Date()))();
  const timestamp = formatTimestamp(nowDate);
  const symlink = options.symlink ?? symlinkSync;

  const actions = SHARED_PATHS.map((spec) =>
    linkOne({mainRoot, spec, symlink, timestamp, worktreeRoot})
  );

  // Env files are a separate, discovered (not fixed) set: every gitignored
  // `.env` / `.env.*` under the main checkout root except `.env.example`.
  // Reported in the new `env_actions` field; the frozen six-entry `actions`
  // array above is untouched.
  const envSpecs: SharedPathSpec[] = readdirSync(mainRoot)
    .filter((name) => isShareableEnvironmentFile(name))
    .toSorted((a, b) => a.localeCompare(b))
    .map((name) => ({ensureTargetDir: false, relativePath: name}));
  const envActions = envSpecs.map((spec) =>
    linkOne({mainRoot, spec, symlink, timestamp, worktreeRoot})
  );

  const output: LinkOutput = {
    actions,
    env_actions: envActions,
    is_worktree: true,
    main_root: mainRoot,
    worktree_root: worktreeRoot,
  };

  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  const anyFailed = [...actions, ...envActions].some(
    (action) => action.result === 'failed'
  );

  return anyFailed ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
};
