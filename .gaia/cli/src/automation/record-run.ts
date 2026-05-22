/**
 * `gaia automation record-run <tool> --sha <sha> --trigger <kind> --cost <dollars> [--at <iso>]` handler.
 *
 * Writes a fresh state-file shape after a real run. Resets `skip_count`
 * to 0, sets `cost_overage = (cost > 5)` (strict-greater-than: equal-to-
 * ceiling is NOT overage), and overwrites any existing state.
 */
import {EXIT_CODES} from '../exit.js';
import {TOOL_IDS, type ToolId} from '../schemas/automation-config.js';
import type {
  AutomationStateFile,
  Trigger,
} from '../schemas/automation-state.js';
import {AutomationStateFileSchema} from '../schemas/automation-state.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {writeStateFile} from './util/state-write.js';

const COST_CEILING_DOLLARS = 5;

const HELP_TEXT = `Usage: gaia automation record-run <tool> --sha <sha> --trigger <cron|force|workflow_dispatch> --cost <dollars> [--at <iso>]

  Records a real run. Resets skip_count to 0; sets cost_overage = (cost > 5)
  (strict-greater-than: cost == 5 is NOT overage).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const VALID_TRIGGERS: readonly Trigger[] = [
  'cron',
  'force',
  'workflow_dispatch',
];
const VALID_TRIGGER_SET: ReadonlySet<string> = new Set(VALID_TRIGGERS);
const TOOL_ID_SET: ReadonlySet<string> = new Set(TOOL_IDS);

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
  let trigger: Trigger | undefined;
  let costStr: string | undefined;
  let atIso: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--sha') {
      sha = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--trigger') {
      const value = argv[index + 1];

      if (value === undefined || !VALID_TRIGGER_SET.has(value)) {
        structuredError({
          code: 'invalid_arguments',
          message: `--trigger must be one of ${VALID_TRIGGERS.join(', ')}`,
          subcommand: 'automation record-run',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }

      trigger = value as Trigger;
      index += 1;

      continue;
    }

    if (token === '--cost') {
      costStr = argv[index + 1];
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
        subcommand: 'automation record-run',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (tool === undefined) {
      if (!TOOL_ID_SET.has(token)) {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown tool: ${token}`,
          subcommand: 'automation record-run',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      tool = token as ToolId;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'automation record-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (tool === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'record-run requires <tool>',
      subcommand: 'automation record-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (sha === undefined || trigger === undefined || costStr === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'record-run requires --sha, --trigger, --cost',
      subcommand: 'automation record-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cost = Number.parseFloat(costStr);

  if (!Number.isFinite(cost) || cost < 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `--cost must be a non-negative number; got: "${costStr}"`,
      subcommand: 'automation record-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation record-run must run inside a git repository',
      subcommand: 'automation record-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const nowDate = (options.now ?? (() => new Date()))();
  const isoNow = atIso ?? nowDate.toISOString();

  const candidate: AutomationStateFile = {
    cost_overage: cost > COST_CEILING_DOLLARS,
    last_run_at: isoNow,
    last_run_cost: cost,
    last_run_sha: sha,
    last_run_trigger: trigger,
    skip_count: 0,
    version: 1,
  };

  const validation = AutomationStateFileSchema.safeParse(candidate);

  if (!validation.success) {
    structuredError({
      code: 'state_malformed',
      message: validation.error.issues
        .map((i) => `${i.path.join('.') || '<root>'}: ${i.message}`)
        .join('; '),
      subcommand: 'automation record-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  writeStateFile(repoRoot, tool, validation.data);

  return EXIT_CODES.OK;
};
