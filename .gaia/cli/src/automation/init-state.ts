/**
 * `gaia automation init-state <tool> --sha <sha> [--at <iso>]` handler.
 *
 * Creates a fresh `.gaia/automation.state-<tool>.json` with the slice-1
 * default shape. Refuses if the state file already exists (parallel to
 * `gaia wiki state-init`). Workflows usually go straight to
 * `record-run`; `init-state` exists for first-run bootstrapping.
 */
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {EXIT_CODES} from '../exit.js';
import {TOOL_IDS, type ToolId} from '../schemas/automation-config.js';
import type {AutomationStateFile} from '../schemas/automation-state.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {automationStatePath} from './paths.js';
import {writeStateFile} from './util/state-write.js';

const HELP_TEXT = `Usage: gaia automation init-state <tool> --sha <sha> [--at <iso>]

  Creates a fresh state file for <tool>. Refuses if it already exists.
  <sha> may be any git ref; it is resolved to a full 40-char sha.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const resolveFullSha = (ref: string, cwd: string): string | null => {
  try {
    const out = execFileSync('git', ['rev-parse', '--verify', `${ref}^{commit}`], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });

    return out.trim();
  } catch {
    return null;
  }
};

type RunOptions = {
  cwd?: string;
  now?: () => Date;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  let tool: ToolId | undefined;
  let sha: string | undefined;
  let atIso: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--sha') {
      sha = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--at') {
      atIso = argv[index + 1];
      index += 1;

      continue;
    }

    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'automation init-state',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (tool === undefined) {
      if (!(TOOL_IDS as readonly string[]).includes(token)) {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown tool: ${token}`,
          subcommand: 'automation init-state',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      tool = token as ToolId;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'automation init-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (tool === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'init-state requires <tool>',
      subcommand: 'automation init-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (sha === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'init-state requires --sha <sha>',
      subcommand: 'automation init-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation init-state must run inside a git repository',
      subcommand: 'automation init-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const fullSha = resolveFullSha(sha, repoRoot);

  if (fullSha === null) {
    structuredError({
      code: 'sha_unresolvable',
      message: `could not resolve --sha via git rev-parse: "${sha}"`,
      subcommand: 'automation init-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const targetPath = automationStatePath(repoRoot, tool);

  if (existsSync(targetPath)) {
    structuredError({
      code: 'state_already_exists',
      message: `${targetPath} already exists — use record-run, bump-state, or clear-overage`,
      subcommand: 'automation init-state',
      tool,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const nowDate = (options.now ?? (() => new Date()))();
  const isoNow = atIso ?? nowDate.toISOString();

  const state: AutomationStateFile = {
    cost_overage: false,
    last_run_at: isoNow,
    last_run_cost: 0,
    last_run_sha: fullSha,
    last_run_trigger: 'cron',
    skip_count: 0,
    version: 1,
  };

  writeStateFile(repoRoot, tool, state);

  return EXIT_CODES.OK;
};
