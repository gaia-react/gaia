/**
 * `gaia ci-stale-check --label <name> --base <branch> [--author <login>] [--json]`
 *
 * The pre-run skip primitive consumed by `gaia-ci-stale-pr-skip`
 * (Phase 2 composite action). UAT-019 requires both `--label` AND
 * `--author` predicates to fire a skip — a label-only or author-only
 * match must NOT skip. We delegate predicate evaluation to `gh pr list`
 * (it does the filtering server-side); the CLI's only job is to ask the
 * question with both predicates and report the answer.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {runGh} from './util/run-process.js';

const HELP_TEXT = `Usage: gaia ci-stale-check --label <name> --base <branch> [--author <login>] [--json]

  Decides whether a workflow run should skip because an existing GAIA CI
  PR is already open. Both --label and --author are required predicates
  (UAT-019); --author defaults to "github-actions[bot]".

  Exit code 0 on either decision; non-zero only on gh invocation failure.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const DEFAULT_AUTHOR = 'github-actions[bot]';

type StaleCheckDecision = {
  decision: 'proceed' | 'skip';
  open_pr_branch: string | null;
  open_pr_number: number | null;
  reason: 'no_open_gaia_ci_pr' | 'open_gaia_ci_pr_exists';
  skip_log_line: string | null;
};

const GhPrEntry = {
  parse(value: unknown): {createdAt: string; headRefName: string; number: number} | null {
    if (typeof value !== 'object' || value === null) return null;
    const v = value as Record<string, unknown>;

    if (typeof v.number !== 'number' || !Number.isFinite(v.number)) return null;
    if (typeof v.headRefName !== 'string') return null;
    if (typeof v.createdAt !== 'string') return null;

    return {
      createdAt: v.createdAt,
      headRefName: v.headRefName,
      number: v.number,
    };
  },
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  let label: string | undefined;
  let base: string | undefined;
  let author: string = DEFAULT_AUTHOR;
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--json') {
      json = true;

      continue;
    }

    if (token === '--label') {
      label = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--base') {
      base = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--author') {
      const value = argv[index + 1];

      if (value === undefined) {
        structuredError({
          code: 'invalid_arguments',
          message: '--author requires a value',
          subcommand: 'ci-stale-check',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      author = value;
      index += 1;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unknown argument: ${token}`,
      subcommand: 'ci-stale-check',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (label === undefined || label === '') {
    structuredError({
      code: 'invalid_arguments',
      message: 'ci-stale-check requires --label <name>',
      subcommand: 'ci-stale-check',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (base === undefined || base === '') {
    structuredError({
      code: 'invalid_arguments',
      message: 'ci-stale-check requires --base <branch>',
      subcommand: 'ci-stale-check',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Order matters for test verbatim-argv assertions — keep --label and
  // --author together as the "predicates" pair, --base last.
  const ghArgs = [
    'pr',
    'list',
    '--state',
    'open',
    '--label',
    label,
    '--author',
    author,
    '--base',
    base,
    '--json',
    'number,headRefName,createdAt',
  ];

  const result = runGh(ghArgs, {cwd: options.cwd});

  if (result.exitCode !== 0) {
    structuredError({
      code: 'gh_invocation_failed',
      exit_code: result.exitCode,
      message: result.stderr.trim() || `gh pr list exited ${result.exitCode}`,
      subcommand: 'ci-stale-check',
    });

    if (json) {
      process.stdout.write(
        `${JSON.stringify({error: 'gh_invocation_failed', exit_code: result.exitCode})}\n`
      );
    }

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(result.stdout);
  } catch (error) {
    structuredError({
      code: 'gh_response_unparseable',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'ci-stale-check',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!Array.isArray(parsed)) {
    structuredError({
      code: 'gh_response_unparseable',
      message: 'gh pr list did not return a JSON array',
      subcommand: 'ci-stale-check',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const entries: Array<{
    createdAt: string;
    headRefName: string;
    number: number;
  }> = [];

  for (const value of parsed) {
    const entry = GhPrEntry.parse(value);

    if (entry !== null) entries.push(entry);
  }

  let decision: StaleCheckDecision;

  if (entries.length === 0) {
    decision = {
      decision: 'proceed',
      open_pr_branch: null,
      open_pr_number: null,
      reason: 'no_open_gaia_ci_pr',
      skip_log_line: null,
    };
  } else {
    const first = entries[0] as {createdAt: string; headRefName: string; number: number};
    decision = {
      decision: 'skip',
      open_pr_branch: first.headRefName,
      open_pr_number: first.number,
      reason: 'open_gaia_ci_pr_exists',
      skip_log_line: `open ${label} PR #${first.number} exists; skipping run`,
    };
  }

  if (json) {
    process.stdout.write(`${JSON.stringify(decision)}\n`);
  } else if (decision.decision === 'skip') {
    process.stdout.write(`${decision.skip_log_line ?? ''}\n`);
  } else {
    process.stdout.write(`no open ${label} PR; proceeding\n`);
  }

  return EXIT_CODES.OK;
};
