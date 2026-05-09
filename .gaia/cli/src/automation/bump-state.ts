/**
 * `gaia automation bump-state <tool> --field <name> --value <json>` handler.
 *
 * Generic field updater (parallel to `gaia wiki state-bump`). Reads the
 * existing state, parses --value as JSON when possible (otherwise as a
 * raw string), applies the bump, schema-validates the post-bump shape,
 * and atomic-writes. Schema rejection on the post-bump shape exits
 * non-zero with `state_malformed`.
 *
 * Slice-1 workflows use the higher-level record-run / record-overage /
 * clear-overage primitives. bump-state is the low-level fallback used
 * when the workflow needs to advance `skip_count` after a `floor_24h`
 * skip.
 */
import {EXIT_CODES} from '../exit.js';
import {TOOL_IDS, type ToolId} from '../schemas/automation-config.js';
import {
  AutomationStateFileSchema,
  readAutomationState,
} from '../schemas/automation-state.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {writeStateFile} from './util/state-write.js';

const HELP_TEXT = `Usage: gaia automation bump-state <tool> --field <name> --value <json>

  Updates a single field in .gaia/automation.state-<tool>.json.
  --value is parsed as JSON when it parses (numbers, booleans, null,
  arrays, objects); otherwise treated as a raw string. The post-bump
  shape is validated against the schema.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const tryParseJson = (raw: string): unknown => {
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
};

type RunOptions = {
  cwd?: string;
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
  let field: string | undefined;
  let valueRaw: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--field') {
      field = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--value') {
      valueRaw = argv[index + 1];
      index += 1;

      continue;
    }

    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'automation bump-state',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (tool === undefined) {
      if (!(TOOL_IDS as readonly string[]).includes(token)) {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown tool: ${token}`,
          subcommand: 'automation bump-state',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      tool = token as ToolId;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'automation bump-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (tool === undefined || field === undefined || valueRaw === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'bump-state requires <tool> --field <name> --value <json>',
      subcommand: 'automation bump-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Zod's `.strip()` silently drops unknown keys at parse time, so an
  // unrecognized --field would round-trip as a no-op. Reject early with
  // a structured error so the caller knows the bump did not happen.
  const knownFields = Object.keys(AutomationStateFileSchema.shape);

  if (!knownFields.includes(field)) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown field: ${field}`,
      subcommand: 'automation bump-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation bump-state must run inside a git repository',
      subcommand: 'automation bump-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = readAutomationState(repoRoot, tool);

  if (result.status === 'missing') {
    structuredError({
      code: 'state_missing',
      message: `cannot bump: state file for "${tool}" does not exist`,
      subcommand: 'automation bump-state',
      tool,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (result.status === 'malformed') {
    structuredError({
      code: 'state_malformed',
      message: result.error,
      subcommand: 'automation bump-state',
      tool,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const candidate: Record<string, unknown> = {
    ...(result.state as unknown as Record<string, unknown>),
    [field]: tryParseJson(valueRaw),
  };

  const validation = AutomationStateFileSchema.safeParse(candidate);

  if (!validation.success) {
    structuredError({
      code: 'state_malformed',
      message: validation.error.issues
        .map((i) => `${i.path.join('.') || '<root>'}: ${i.message}`)
        .join('; '),
      subcommand: 'automation bump-state',
      tool,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  writeStateFile(repoRoot, tool, validation.data);

  return EXIT_CODES.OK;
};
