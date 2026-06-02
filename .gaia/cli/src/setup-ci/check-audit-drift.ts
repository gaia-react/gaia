/**
 * `gaia setup-ci check-audit-drift [--workflows-dir <path>] [--json]` handler.
 *
 * Byte-compares the installed `.github/workflows/code-review-audit.yml`
 * against the canonical template. The `/setup-gaia-ci` slash command's
 * Step 2 drift probe calls this alongside `check-drift` to detect whether
 * the audit workflow is present and up-to-date.
 *
 * JSON shape (canonical contract):
 *
 *   { "state": "in_sync" | "drifted" | "missing" }
 *
 * - `in_sync`  — installed file matches the template byte-for-byte.
 * - `drifted`  — installed file exists but bytes differ from the template.
 * - `missing`  — the file is absent (audit not yet installed or excluded).
 *
 * This is a read-only query command; it always exits 0.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {workflowAuditTemplatePath} from '../automation/paths.js';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

const HELP_TEXT = `Usage: gaia setup-ci check-audit-drift [--workflows-dir <p>] [--json]

  Compare installed audit workflow vs template.

  Byte-compares <workflows-dir>/code-review-audit.yml against the canonical
  template. Reports state: in_sync | drifted | missing.

  --workflows-dir <path>   Optional. Override of .github/workflows. Defaults
                           to <repoRoot>/.github/workflows.
  --json                   Emit machine-readable JSON instead of a human
                           report.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type AuditDriftState = 'drifted' | 'in_sync' | 'missing';

type ParsedArgs = {
  json: boolean;
  workflowsDir?: string;
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  let json = false;
  let workflowsDir: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--json') {
      json = true;

      continue;
    }

    if (token === '--workflows-dir') {
      const next = argv[index + 1];

      if (next === undefined || next.startsWith('--')) {
        return {error: '--workflows-dir requires a path argument'};
      }
      workflowsDir = next;
      index += 1;

      continue;
    }

    return {error: `unknown flag: ${token}`};
  }

  return {json, workflowsDir};
};

const safeReadFile = (filePath: string): string | null => {
  try {
    return readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'setup-ci check-audit-drift',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message:
        'gaia setup-ci check-audit-drift must run inside a git repository',
      subcommand: 'setup-ci check-audit-drift',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const workflowsDir =
    parsed.workflowsDir ?? path.join(repoRoot, '.github', 'workflows');

  const installedPath = path.join(workflowsDir, 'code-review-audit.yml');
  const onDisk = safeReadFile(installedPath);

  let state: AuditDriftState;

  if (onDisk === null) {
    state = 'missing';
  } else {
    const template = readFileSync(workflowAuditTemplatePath(), 'utf8');
    state = onDisk === template ? 'in_sync' : 'drifted';
  }

  if (parsed.json) {
    process.stdout.write(`${JSON.stringify({state})}\n`);
  } else {
    process.stdout.write(`audit workflow: ${state}\n`);
  }

  return EXIT_CODES.OK;
};
