/**
 * `gaia setup link-worktree [--json]` handler.
 *
 * Idempotently creates the three SPEC-005 shared-state symlinks from the
 * current linked worktree into the main checkout:
 *
 *   <worktree>/.gaia/local/setup-state.json -> <main>/.gaia/local/setup-state.json
 *   <worktree>/.gaia/cache/                  -> <main>/.gaia/cache/
 *   <worktree>/.gaia/local/audit/            -> <main>/.gaia/local/audit/
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

  Idempotently create the three worktree shared-state symlinks pointing at
  the main checkout. Backs up pre-existing plain files to <path>.bak.<ts>.
  No-op on a main checkout (not a linked worktree); exits 0 with a
  one-line "not a linked worktree" message.

  --json   Print a single JSON line describing the result instead of the
           human-readable summary.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type ActionResult =
  | 'already-linked'
  | 'failed'
  | 'linked'
  | 'linked-after-backup'
  | 'skipped-no-target';

type Action = {
  backup?: string;
  error?: string;
  path: string;
  result: ActionResult;
};

type LinkOutput = {
  actions: Action[];
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
 * Frozen path set; three entries, in this order, always present in the
 * output `actions` array regardless of result. See SPEC-005 plan README.
 */
const SHARED_PATHS: readonly SharedPathSpec[] = [
  {ensureTargetDir: false, relativePath: '.gaia/local/setup-state.json'},
  {ensureTargetDir: true, relativePath: '.gaia/cache'},
  {ensureTargetDir: true, relativePath: '.gaia/local/audit'},
];

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

const printHuman = (output: LinkOutput): void => {
  if (!output.is_worktree) {
    process.stdout.write('not a linked worktree\n');

    return;
  }

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
    process.stdout.write(`${lines.join('\n')}\n`);

    return;
  }

  const allAlreadyLinked = output.actions.every(
    (action) => action.result === 'already-linked'
  );

  if (allAlreadyLinked) {
    process.stdout.write(
      `All ${String(output.actions.length)} paths already linked.\n`
    );

    return;
  }

  const backedUp = output.actions.filter(
    (action) => action.result === 'linked-after-backup'
  );

  if (backedUp.length > 0) {
    const lines = [
      `Linked ${String(output.actions.length)} paths to ${String(output.main_root)}.`,
    ];

    for (const action of backedUp) {
      lines.push(`  Backed up: ${action.path} -> ${String(action.backup)}`);
    }
    process.stdout.write(`${lines.join('\n')}\n`);

    return;
  }

  process.stdout.write(
    `Linked ${String(output.actions.length)} paths to ${String(output.main_root)}.\n`
  );
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
      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${token}`,
      subcommand: 'setup link-worktree',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();

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

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Resolve the current worktree root (may equal mainRoot on a main checkout).
  // Use git --show-toplevel mirroring the script. If `resolveMainWorktreeRoot`
  // succeeded above, this fork is essentially guaranteed to succeed too, but
  // guard for the unlikely case anyway.
  let worktreeRoot: string;

  try {
    worktreeRoot = execFileSync('git', ['rev-parse', '--show-toplevel'], {
      cwd: canonicalCwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup link-worktree must run inside a git repository',
      subcommand: 'setup link-worktree',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (mainRoot === worktreeRoot) {
    const output: LinkOutput = {
      actions: [],
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

  const output: LinkOutput = {
    actions,
    is_worktree: true,
    main_root: mainRoot,
    worktree_root: worktreeRoot,
  };

  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  const anyFailed = actions.some((action) => action.result === 'failed');

  return anyFailed ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
};
