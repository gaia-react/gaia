/**
 * `gaia automation cron-decide <tool> [--json] [--now <iso>]` handler.
 *
 * The smart-cron decision primitive. Returns a deterministic
 * `{decision, reason, skip_log_line}` triple per the SPEC's per-tool
 * cron logic. Pure: never mutates state. Workflows inspect `decision`
 * and act; `skip_count` advancement after a `floor_24h` skip is the
 * caller's responsibility (via `bump-state`).
 *
 * Exit code 0 covers both `run` and `skip` decisions. Non-zero covers
 * configuration errors (missing/malformed config or malformed state).
 *
 * `--now <iso>` is a hidden, tests-only flag that overrides `new Date()`.
 */
import {EXIT_CODES} from '../exit.js';
import {
  TOOL_IDS,
  TOOL_ID_TO_CONFIG_KEY,
  type AutomationConfig,
  type ToolConfig,
  type ToolId,
} from '../schemas/automation-config.js';
import {readAutomationConfig} from '../schemas/automation-config.js';
import {readAutomationState} from '../schemas/automation-state.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {appChangedSince} from './util/source-changed.js';

type CronReason =
  | 'app_changed'
  | 'ceiling_14d'
  | 'cost_overage'
  | 'first_run'
  | 'floor_24h'
  | 'no_app_change'
  | 'skip_safety_5'
  | 'tool_off';

type CronDecision = {
  decision: 'run' | 'skip';
  reason: CronReason;
  skip_log_line: string | null;
};

const HELP_TEXT = `Usage: gaia automation cron-decide <tool> [--json]

  Smart-cron decision primitive. Reads .gaia/automation.json and the
  per-tool state file, then emits {decision, reason, skip_log_line}.
  Decision priority:
    1. tool_off       (config.<tool>.mode == "off")
    2. first_run      (state file missing)
    3. cost_overage   (state.cost_overage == true)
    4. ceiling_14d    (last_run_at > 14 days ago)
    5. skip_safety_5  (skip_count > 5)
    6. floor_24h      (last_run_at < 24 hours ago)
    7. app_changed    (commits to app/** since last_run_sha) — wiki only
    8. no_app_change  (otherwise) — wiki only
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const TOOL_ID_SET: ReadonlySet<string> = new Set(TOOL_IDS);

const MS_PER_HOUR = 60 * 60 * 1000;
const FLOOR_HOURS = 24;
const CEILING_DAYS = 14;
const SKIP_SAFETY_THRESHOLD = 5;

const toolConfigFor = (config: AutomationConfig, tool: ToolId): ToolConfig =>
  // `TOOL_ID_TO_CONFIG_KEY` is typed `Record<ToolId, ToolConfigKey>`, so the
  // indexed access resolves directly to `ToolConfig` — no cast needed.
  config[TOOL_ID_TO_CONFIG_KEY[tool]];

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
  let json = false;
  let nowOverride: Date | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--json') {
      json = true;

      continue;
    }

    if (token === '--now') {
      const value = argv[index + 1];

      if (value === undefined) {
        structuredError({
          code: 'invalid_arguments',
          message: '--now requires an ISO timestamp',
          subcommand: 'automation cron-decide',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }

      const parsed = new Date(value);

      if (Number.isNaN(parsed.getTime())) {
        structuredError({
          code: 'invalid_arguments',
          message: `--now must be a parseable ISO timestamp; got: "${value}"`,
          subcommand: 'automation cron-decide',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }

      nowOverride = parsed;
      index += 1;

      continue;
    }

    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'automation cron-decide',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (tool === undefined) {
      if (!TOOL_ID_SET.has(token)) {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown tool: ${token}`,
          subcommand: 'automation cron-decide',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      tool = token as ToolId;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'automation cron-decide',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (tool === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'cron-decide requires <tool>',
      subcommand: 'automation cron-decide',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation cron-decide must run inside a git repository',
      subcommand: 'automation cron-decide',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const configResult = readAutomationConfig(repoRoot);

  if (configResult.status === 'missing') {
    structuredError({
      code: 'config_missing',
      message:
        'cron-decide requires .gaia/automation.json — running cron-decide on an unconfigured repo is a setup bug',
      subcommand: 'automation cron-decide',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (configResult.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: configResult.error,
      subcommand: 'automation cron-decide',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const toolConfig = toolConfigFor(configResult.config, tool);

  const decision = decide({
    appChangedSince: (sha) => appChangedSince(repoRoot, sha),
    now: nowOverride ?? options.now?.() ?? new Date(),
    repoRoot,
    stateResult: readAutomationState(repoRoot, tool),
    tool,
    toolConfig,
  });

  if (decision === 'state_malformed') {
    return EXIT_CODES.CONFIG_INVALID;
  }

  if (json) {
    process.stdout.write(`${JSON.stringify(decision)}\n`);
  } else {
    process.stdout.write(
      `decision: ${decision.decision}\n` +
        `reason: ${decision.reason}\n` +
        `skip_log_line: ${decision.skip_log_line ?? '(none)'}\n`
    );
  }

  return EXIT_CODES.OK;
};

type DecideArgs = {
  appChangedSince: (sha: string) => boolean;
  now: Date;
  repoRoot: string;
  stateResult: ReturnType<typeof readAutomationState>;
  tool: ToolId;
  toolConfig: ToolConfig;
};

const decide = (args: DecideArgs): CronDecision | 'state_malformed' => {
  const {
    appChangedSince: appChanged,
    now,
    stateResult,
    tool,
    toolConfig,
  } = args;

  // 1. tool_off
  if (toolConfig.mode === 'off') {
    return {
      decision: 'skip',
      reason: 'tool_off',
      skip_log_line: 'tool mode is off; skipping',
    };
  }

  // Slice-1 limitation: cron-decide governs only the wiki tool. Non-wiki
  // tools land in a future slice that adds per-tool source sets; for now,
  // emit a clearly-tagged tool_off-shaped placeholder so the workflow can
  // see the limitation and bail.
  if (tool !== 'wiki') {
    return {
      decision: 'skip',
      reason: 'tool_off',
      skip_log_line: `cron-decide not yet implemented for ${tool}; skipping`,
    };
  }

  // 2. first_run / state_malformed and 3. cost_overage
  if (stateResult.status === 'malformed') {
    structuredError({
      code: 'state_malformed',
      message: stateResult.error,
      subcommand: 'automation cron-decide',
    });

    return 'state_malformed';
  }

  if (stateResult.status === 'missing') {
    return {decision: 'run', reason: 'first_run', skip_log_line: null};
  }

  const state = stateResult.state;

  if (state.cost_overage) {
    return {
      decision: 'skip',
      reason: 'cost_overage',
      skip_log_line: 'cost overage; suppressed',
    };
  }

  // 4. ceiling_14d
  const lastRunMs = new Date(state.last_run_at).getTime();
  const ageMs = now.getTime() - lastRunMs;

  if (ageMs > CEILING_DAYS * 24 * MS_PER_HOUR) {
    return {decision: 'run', reason: 'ceiling_14d', skip_log_line: null};
  }

  // 5. skip_safety_5
  if (state.skip_count > SKIP_SAFETY_THRESHOLD) {
    return {decision: 'run', reason: 'skip_safety_5', skip_log_line: null};
  }

  // 6. floor_24h
  if (ageMs < FLOOR_HOURS * MS_PER_HOUR) {
    return {
      decision: 'skip',
      reason: 'floor_24h',
      skip_log_line: 'within 24h floor; skipping',
    };
  }

  // 7. app_changed (wiki only)
  if (appChanged(state.last_run_sha)) {
    return {decision: 'run', reason: 'app_changed', skip_log_line: null};
  }

  // 8. no_app_change (wiki only)
  const shortSha = state.last_run_sha.slice(0, 7);

  return {
    decision: 'skip',
    reason: 'no_app_change',
    skip_log_line: `skipped — no app/** changes since ${shortSha}`,
  };
};
