/**
 * `gaia setup link-worktree [--json]` handler.
 *
 * Idempotently symlinks the current linked worktree's whole `.gaia/local`
 * to the main checkout's own `.gaia/local`:
 *
 *   <worktree>/.gaia/local -> <main>/.gaia/local
 *
 * Every registry-declared entry (`.gaia/state-registry.json`) lives under
 * that one shared directory now; the per-tree entries (red-ledger/,
 * worthiness-ledger/, forensics/, handoff/) address themselves under a
 * subdirectory keyed by the acting tree's own `gaia_tree_key`
 * (`.gaia/scripts/main-root-lib.sh`), so they stay private to the tree that
 * wrote them even though the physical directory is shared.
 *
 * Also links gitignored checkout-root `.env` / `.env.*` files (excluding the
 * committed `.env.example`) from the main checkout, one symlink per file,
 * reported separately in the `env_actions` field so the frozen single-entry
 * `actions` contract above is untouched.
 *
 * No-op on a main checkout (not a linked worktree). A pre-existing plain
 * `.gaia/local` (file or directory) is moved to
 * `.gaia/local.bak.<timestamp>` before the symlink is created; nothing
 * under it is inspected or merged. Exits 1 on any `failed` action; the
 * user explicitly invoked the CLI, so surfacing the error is correct (the
 * script counterpart always exits 0 because it must not break worktree
 * creation).
 *
 * Frozen JSON shape.
 */
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
import {resolveMainWorktreeRoot} from '../util/main-root.js';
import {resolveRepoRoot} from '../util/repo-root.js';

const HELP_TEXT = `Usage: gaia setup link-worktree [--json]

  Idempotently symlink the worktree's whole .gaia/local to the main
  checkout's own .gaia/local. Also links gitignored checkout-root .env /
  .env.* files (excluding .env.example) from the main checkout. Backs up
  a pre-existing plain .gaia/local to .gaia/local.bak.<ts>. No-op on a main
  checkout (not a linked worktree); exits 0 with a one-line "not a linked
  worktree" message.

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
   * a directory before the symlink is made. `.gaia/local` is always a
   * directory.
   */
  ensureTargetDir: boolean;
  relativePath: string;
};

// The one shared path every linked worktree gets: its whole `.gaia/local`,
// symlinked wholesale to the main checkout's own `.gaia/local`. Every
// registry-declared entry (`.gaia/state-registry.json`) lives under that one
// directory now; a per-tree entry addresses itself under a subdirectory
// keyed by the acting tree's own `gaia_tree_key`
// (`.gaia/scripts/main-root-lib.sh`), so it stays private to the tree that
// wrote it even though the physical directory is shared.
const GAIA_LOCAL_SPEC: SharedPathSpec = {
  ensureTargetDir: true,
  relativePath: path.join('.gaia', 'local'),
};

// Shareable env-file basename set: `.env` and any `.env.*` variant under the
// checkout root, except the committed `.env.example`. Mirrors .gitignore's
// `.env` / `.env.*` / `!.env.example` and the `is_dotenv_path` definition in
// `.claude/hooks/block-env-read.sh`.
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
  } catch (error) {
    structuredError({
      code: 'not_a_git_repo',
      message: `gaia setup link-worktree must run inside a git repository: ${error instanceof Error ? error.message : String(error)}`,
      subcommand: 'setup link-worktree',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  // Resolve the current worktree root (may equal mainRoot on a main checkout).
  // Use git --show-toplevel mirroring the script. If `resolveMainWorktreeRoot`
  // succeeded above, this fork is essentially guaranteed to succeed too, but
  // guard for the unlikely case anyway.
  try {
    const worktreeRoot = resolveRepoRoot(canonicalCwd);

    return {mainRoot, worktreeRoot};
  } catch (error) {
    structuredError({
      code: 'not_a_git_repo',
      message: `gaia setup link-worktree must run inside a git repository: ${error instanceof Error ? error.message : String(error)}`,
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

  const actions = [
    linkOne({
      mainRoot,
      spec: GAIA_LOCAL_SPEC,
      symlink,
      timestamp,
      worktreeRoot,
    }),
  ];

  // Env files are a separate, discovered (not fixed) set: every gitignored
  // `.env` / `.env.*` under the main checkout root except `.env.example`.
  // Reported in the new `env_actions` field; the frozen single-entry
  // `actions` array above is untouched.
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
