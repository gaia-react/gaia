/**
 * `gaia labels sync` reconciles a repository's labels against
 * `.gaia/labels.json`.
 *
 * `planSync` holds the whole decision table and is pure; `run` does exactly
 * three impure things, one `gh label list`, the `gh` mutations the plan names,
 * and printing the report.
 *
 * # Two contracts other files key on
 *
 * **Exit codes.** `0` on success AND on the degraded path, `1` on a real `gh`
 * failure, `2` on a usage or environment error. A caller cannot tell "sync did
 * the job" from "sync could not" by exit code alone, because degrading is a
 * success: `sync || gh label create` would never reach its fallback in exactly
 * the situation the fallback exists for. The degraded path therefore prints
 * the literal line `labels-sync: degraded, manual commands follow` on stdout
 * (on stderr under `--json`, which owns stdout), and a fallback keys on that
 * line rather than on the exit code.
 *
 * **Report versus write.** Several rows of the decision table report by
 * default and write only when the operator opts in. The action is planned
 * either way so the report names it, and `mutationFor` is the single place
 * that turns an action into a `gh` invocation. `drift-color` (operator wins,
 * `--adopt` overrides) and `prune` (never delete without `--prune-deprecated`)
 * both work this way, so "planned" never means "will be written".
 */
import type {ProcessResult} from '../ci/util/run-process.js';
import {runGh} from '../ci/util/run-process.js';
import {EXIT_CODES} from '../exit.js';
import type {
  LabelAudience,
  LabelEntry,
  LabelFeature,
  LabelRegistry,
} from '../schemas/labels.js';
import {
  audienceCovers,
  isCreatable,
  LABEL_AUDIENCES,
  LABEL_FEATURES,
} from '../schemas/labels.js';
import {structuredError} from '../stderr.js';
import {lookupOwn, takeNonFlagValue} from '../util/argv.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {
  readRegistry,
  resolveAudience,
  resolveFeatures,
  suggestedColorFor,
} from './registry.js';

const HELP_TEXT = `Usage: gaia labels sync [--repo <owner/name>] [--repo-root <path>] [--dry-run]
                        [--adopt] [--adopt-palette] [--prune-deprecated]
                        [--enforce-blocked] [--json]
                        [--audience adopter|maintainer] [--feature <key>]...

  Reconciles the target repository's labels against .gaia/labels.json.
  --repo defaults to the current repository (gh resolves it).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/** Printed verbatim when a scopeless token turns the plan into manual work. */
export const DEGRADED_LINE = 'labels-sync: degraded, manual commands follow';

const EXIT_GH_FAILED = 1;
const EXIT_USAGE = 2;

/** Issue-count query cap; only the zero / non-zero split gates a deletion. */
const ISSUE_COUNT_LIMIT = 200;

export type LiveLabel = {color: string; description: string; name: string};

export type SyncAction =
  | {command: string; kind: 'manual-command'; why: string}
  | {entry: LabelEntry; kind: 'create'}
  | {from: string; kind: 'rename'; to: string}
  | {
      issueCount: null | number;
      kind: 'blocked-present';
      name: string;
      reason: string;
    }
  | {kind: 'blocked-removed'; name: string}
  | {kind: 'drift-color'; live: LiveLabel; name: string; registryColor: string}
  | {
      kind: 'drift-description';
      live: LiveLabel;
      name: string;
      registryDescription: string;
    }
  | {kind: 'prune'; name: string}
  | {kind: 'unknown'; name: string; suggestedColor: null | string};

/** The plan-affecting flags. `--dry-run` and `--json` are execution-only. */
export type SyncFlags = {
  adopt: boolean;
  adoptPalette: boolean;
  enforceBlocked: boolean;
  pruneDeprecated: boolean;
};

export type SyncPlan = {actions: readonly SyncAction[]; repo: null | string};

type BlockedPresentAction = Extract<SyncAction, {kind: 'blocked-present'}>;

/** Actions for a registry entry the repository does not carry. */
const plannedForAbsent = (
  entry: LabelEntry,
  options: {
    audience: LabelAudience;
    enabledFeatures: readonly LabelFeature[];
    liveNames: ReadonlySet<string>;
  }
): {actions: SyncAction[]; claimed: null | string} => {
  const previous = entry.renamedFrom.find((old) => options.liveNames.has(old));

  // Rename, never delete-and-recreate: a delete strips the label from every
  // issue carrying it and destroys the association permanently.
  if (
    previous !== undefined &&
    audienceCovers(options.audience, entry.audience)
  ) {
    return {
      actions: [{from: previous, kind: 'rename', to: entry.name}],
      claimed: previous,
    };
  }

  const creatable = isCreatable(
    entry,
    options.audience,
    options.enabledFeatures
  );

  return {actions: creatable ? [{entry, kind: 'create'}] : [], claimed: null};
};

/** Actions for a registry entry the repository already carries. */
const plannedForPresent = (
  entry: LabelEntry,
  present: LiveLabel
): SyncAction[] => {
  const actions: SyncAction[] = [];

  if (entry.deprecated) actions.push({kind: 'prune', name: entry.name});

  // An unmanaged entry is documented only: its description still reconciles,
  // its color never does.
  if (
    entry.managed &&
    entry.color !== null &&
    present.color.toLowerCase() !== entry.color
  ) {
    actions.push({
      kind: 'drift-color',
      live: present,
      name: entry.name,
      registryColor: entry.color,
    });
  }

  if (present.description !== entry.description) {
    actions.push({
      kind: 'drift-description',
      live: present,
      name: entry.name,
      registryDescription: entry.description,
    });
  }

  return actions;
};

/**
 * Pure: the whole decision table, live labels in, planned actions out.
 *
 * `flags` is part of the call shape but the plan never reads it: what to
 * plan is flag-invariant, and which planned actions become writes is
 * `mutationFor`'s decision, taken later. The suites pin that invariance by
 * planning across every flag combination.
 */
export const planSync = (options: {
  audience: LabelAudience;
  enabledFeatures: readonly LabelFeature[];
  flags: SyncFlags;
  live: readonly LiveLabel[];
  registry: LabelRegistry;
}): SyncPlan => {
  const {audience, enabledFeatures, live, registry} = options;
  const liveByName = new Map(live.map((label) => [label.name, label]));
  const liveNames = new Set(liveByName.keys());
  const claimed = new Set<string>();
  const actions: SyncAction[] = [];

  for (const entry of registry.labels) {
    const present = liveByName.get(entry.name);

    if (entry.blocked) {
      if (present !== undefined) {
        claimed.add(entry.name);
        actions.push({
          issueCount: null,
          kind: 'blocked-present',
          name: entry.name,
          reason: entry.reason ?? '',
        });
      }
    } else if (present === undefined) {
      const planned = plannedForAbsent(entry, {
        audience,
        enabledFeatures,
        liveNames,
      });

      if (planned.claimed !== null) claimed.add(planned.claimed);
      actions.push(...planned.actions);
    } else {
      claimed.add(entry.name);
      actions.push(...plannedForPresent(entry, present));
    }
  }

  const registryNames = new Set(registry.labels.map((entry) => entry.name));
  const unknown = live
    .filter(
      (label) => !claimed.has(label.name) && !registryNames.has(label.name)
    )
    .toSorted((a, b) => a.name.localeCompare(b.name))
    .map((label): SyncAction => ({
      kind: 'unknown',
      name: label.name,
      suggestedColor: suggestedColorFor(registry, label.name),
    }));

  return {actions: [...actions, ...unknown], repo: null};
};

/**
 * Refines a planned `blocked-present` once its issue count is known.
 *
 * `planSync` is pure and cannot count issues, so the enforcement decision
 * lands here instead of inside the plan. On an adopter repository this is
 * always the identity: an adopter's labels are the adopter's business, so a
 * blocked entry is advisory there whatever the flags say.
 */
const enforcesBlocked = (audience: LabelAudience, flags: SyncFlags): boolean =>
  audience === 'maintainer' && flags.enforceBlocked;

export const resolveBlocked = (
  action: BlockedPresentAction,
  options: {audience: LabelAudience; flags: SyncFlags; issueCount: number}
): SyncAction => {
  if (!enforcesBlocked(options.audience, options.flags)) {
    return action;
  }

  return options.issueCount === 0 ?
      {kind: 'blocked-removed', name: action.name}
    : {...action, issueCount: options.issueCount};
};

/** The `gh` argv an action owes under `flags`, or null when report-only. */
export const mutationFor = (
  action: SyncAction,
  flags: SyncFlags
): null | readonly string[] => {
  if (action.kind === 'create') {
    return [
      'label',
      'create',
      action.entry.name,
      '--color',
      action.entry.color ?? '',
      '--description',
      action.entry.description,
    ];
  }

  if (action.kind === 'rename') {
    return ['label', 'edit', action.from, '--name', action.to];
  }

  if (action.kind === 'drift-description') {
    return [
      'label',
      'edit',
      action.name,
      '--description',
      action.registryDescription,
    ];
  }

  if (action.kind === 'drift-color') {
    return flags.adopt ?
        ['label', 'edit', action.name, '--color', action.registryColor]
      : null;
  }

  if (action.kind === 'unknown') {
    return flags.adoptPalette && action.suggestedColor !== null ?
        ['label', 'edit', action.name, '--color', action.suggestedColor]
      : null;
  }

  if (action.kind === 'prune') {
    return flags.pruneDeprecated ?
        ['label', 'delete', action.name, '--yes']
      : null;
  }

  if (action.kind === 'blocked-removed') {
    return ['label', 'delete', action.name, '--yes'];
  }

  return null;
};

/**
 * A missing label-write scope reaches us as a non-zero exit with an HTTP 403
 * in stderr. Every other non-zero exit is a real failure and stays one.
 */
export const classifyGhResult = (
  result: ProcessResult
): 'degraded' | 'failed' | 'ok' => {
  if (result.exitCode === 0) return 'ok';

  return /403|Resource not accessible/u.test(result.stderr) ? 'degraded' : (
      'failed'
    );
};

const SAFE_ARGUMENT = /^[\w./:=@-]+$/u;
const QUOTE_ESCAPE = String.raw`'\''`;

const shellQuote = (value: string): string =>
  SAFE_ARGUMENT.test(value) ? value : (
    `'${value.replaceAll("'", QUOTE_ESCAPE)}'`
  );

const commandLine = (argv: readonly string[]): string =>
  ['gh', ...argv].map(shellQuote).join(' ');

const describeBlockedPresent = (action: BlockedPresentAction): string => {
  const carried =
    action.issueCount === null ? '' : ` (${action.issueCount} issues carry it)`;

  return `blocked but present: ${action.name}${carried}. ${action.reason}`;
};

/** One report line per planned action. */
export const describeAction = (action: SyncAction): string => {
  if (action.kind === 'create') return `create ${action.entry.name}`;
  if (action.kind === 'rename') return `rename ${action.from} to ${action.to}`;
  if (action.kind === 'prune') return `deprecated and present: ${action.name}`;
  if (action.kind === 'manual-command') return `manual: ${action.command}`;
  if (action.kind === 'blocked-present') return describeBlockedPresent(action);

  if (action.kind === 'blocked-removed') {
    return `blocked removed: ${action.name}`;
  }

  if (action.kind === 'drift-color') {
    return `color drift on ${action.name}: live ${action.live.color}, registry ${action.registryColor}`;
  }

  if (action.kind === 'drift-description') {
    return `description drift on ${action.name}`;
  }

  const suggestion =
    action.suggestedColor === null ?
      'no namespace match'
    : `suggested color ${action.suggestedColor}`;

  return `unknown label ${action.name}: ${suggestion}`;
};

type ParsedArgs = {
  audience: LabelAudience | undefined;
  dryRun: boolean;
  features: LabelFeature[];
  flags: SyncFlags;
  json: boolean;
  repo: string | undefined;
  repoRoot: string | undefined;
};

const BOOLEAN_SETTERS: Readonly<
  Partial<Record<string, (parsed: ParsedArgs) => void>>
> = {
  '--adopt': (parsed) => {
    parsed.flags.adopt = true;
  },
  '--adopt-palette': (parsed) => {
    parsed.flags.adoptPalette = true;
  },
  '--dry-run': (parsed) => {
    parsed.dryRun = true;
  },
  '--enforce-blocked': (parsed) => {
    parsed.flags.enforceBlocked = true;
  },
  '--json': (parsed) => {
    parsed.json = true;
  },
  '--prune-deprecated': (parsed) => {
    parsed.flags.pruneDeprecated = true;
  },
};

const VALUED_FLAGS = new Set([
  '--audience',
  '--feature',
  '--repo',
  '--repo-root',
]);

const isAudience = (value: string): value is LabelAudience =>
  (LABEL_AUDIENCES as readonly string[]).includes(value);

const isFeature = (value: string): value is LabelFeature =>
  (LABEL_FEATURES as readonly string[]).includes(value);

/** Applies a `--flag value` pair, returning a usage message when invalid. */
const applyValued = (
  parsed: ParsedArgs,
  token: string,
  value: string
): null | string => {
  if (token === '--repo') {
    parsed.repo = value;
  } else if (token === '--repo-root') {
    parsed.repoRoot = value;
  } else if (token === '--audience') {
    if (!isAudience(value)) {
      return `--audience must be one of: ${LABEL_AUDIENCES.join(', ')}`;
    }
    parsed.audience = value;
  } else {
    if (!isFeature(value)) {
      return `--feature must be one of: ${LABEL_FEATURES.join(', ')}`;
    }
    parsed.features.push(value);
  }

  return null;
};

const usageError = (message: string): {code: number} => {
  structuredError({
    code: 'invalid_arguments',
    message,
    subcommand: 'labels sync',
  });

  return {code: EXIT_USAGE};
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {code: number} => {
  const parsed: ParsedArgs = {
    audience: undefined,
    dryRun: false,
    features: [],
    flags: {
      adopt: false,
      adoptPalette: false,
      enforceBlocked: false,
      pruneDeprecated: false,
    },
    json: false,
    repo: undefined,
    repoRoot: undefined,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] ?? '';
    const setter = lookupOwn(BOOLEAN_SETTERS, token);

    if (setter !== undefined) {
      setter(parsed);
    } else if (VALUED_FLAGS.has(token)) {
      const taken = takeNonFlagValue(argv, index + 1, token);

      if (!taken.ok) return usageError(taken.message);
      index += 1;

      const problem = applyValued(parsed, token, taken.value);

      if (problem !== null) return usageError(problem);
    } else {
      return usageError(`unknown argument: ${token}`);
    }
  }

  return parsed;
};

const parseLiveLabels = (stdout: string): LiveLabel[] => {
  const parsed: unknown = JSON.parse(stdout);

  if (!Array.isArray(parsed)) {
    throw new TypeError('gh label list did not return a JSON array');
  }

  return parsed.flatMap((value: unknown) => {
    if (typeof value !== 'object' || value === null) return [];
    const record = value as Record<string, unknown>;

    if (typeof record.name !== 'string') return [];

    return [
      {
        color: typeof record.color === 'string' ? record.color : '',
        description:
          typeof record.description === 'string' ? record.description : '',
        name: record.name,
      },
    ];
  });
};

const countIssues = (
  name: string,
  repoArgs: readonly string[]
): null | number => {
  const result = runGh([
    'issue',
    'list',
    ...repoArgs,
    '--label',
    name,
    '--state',
    'all',
    '--limit',
    String(ISSUE_COUNT_LIMIT),
    '--json',
    'number',
  ]);

  if (result.exitCode !== 0) return null;

  try {
    const parsed: unknown = JSON.parse(result.stdout);

    return Array.isArray(parsed) ? parsed.length : null;
  } catch {
    return null;
  }
};

const enforceBlockedActions = (
  actions: readonly SyncAction[],
  options: {
    audience: LabelAudience;
    flags: SyncFlags;
    repoArgs: readonly string[];
  }
): readonly SyncAction[] => {
  if (!enforcesBlocked(options.audience, options.flags)) {
    return actions;
  }

  return actions.map((action) => {
    if (action.kind !== 'blocked-present') return action;

    const issueCount = countIssues(action.name, options.repoArgs);

    // An uncountable label is never deleted: refusing is the safe direction.
    if (issueCount === null) return action;

    return resolveBlocked(action, {
      audience: options.audience,
      flags: options.flags,
      issueCount,
    });
  });
};

type LiveFetch = {code: number} | {degraded: boolean; live: LiveLabel[]};

const fetchLive = (repoArgs: readonly string[]): LiveFetch => {
  const listed = runGh([
    'label',
    'list',
    ...repoArgs,
    '--limit',
    '200',
    '--json',
    'name,color,description',
  ]);
  const outcome = classifyGhResult(listed);

  if (outcome === 'failed') {
    structuredError({
      code: 'gh_invocation_failed',
      exit_code: listed.exitCode,
      message:
        listed.stderr.trim() || `gh label list exited ${listed.exitCode}`,
      subcommand: 'labels sync',
    });

    return {code: EXIT_GH_FAILED};
  }

  // A token that cannot read labels cannot write them either, so the plan is
  // computed against an empty repository and every owed mutation becomes a
  // manual command. That is the useful answer on a fresh repo, and it keeps
  // setup from failing on a scope it cannot grant itself.
  if (outcome === 'degraded') return {degraded: true, live: []};

  try {
    return {degraded: false, live: parseLiveLabels(listed.stdout)};
  } catch (error) {
    structuredError({
      code: 'gh_response_unparseable',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'labels sync',
    });

    return {code: EXIT_GH_FAILED};
  }
};

type Execution = {code: number} | {degraded: boolean; manual: SyncAction[]};

const executePlan = (
  actions: readonly SyncAction[],
  options: {
    degraded: boolean;
    flags: SyncFlags;
    repoArgs: readonly string[];
  }
): Execution => {
  const owed = actions.flatMap((action) => {
    const mutation = mutationFor(action, options.flags);

    return mutation === null ?
        []
      : [{action, argv: [...mutation, ...options.repoArgs]}];
  });

  const manual: SyncAction[] = [];
  let {degraded} = options;

  for (const {action, argv} of owed) {
    if (!degraded) {
      const result = runGh(argv);
      const outcome = classifyGhResult(result);

      if (outcome === 'failed') {
        structuredError({
          code: 'gh_invocation_failed',
          exit_code: result.exitCode,
          message: result.stderr.trim() || `gh ${commandLine(argv)} failed`,
          subcommand: 'labels sync',
        });

        return {code: EXIT_GH_FAILED};
      }

      degraded = outcome === 'degraded';
    }

    if (degraded) {
      manual.push({
        command: commandLine(argv),
        kind: 'manual-command',
        why: describeAction(action),
      });
    }
  }

  return {degraded, manual};
};

const report = (options: {
  degraded: boolean;
  json: boolean;
  manual: readonly SyncAction[];
  plan: SyncPlan;
}): void => {
  if (options.json) {
    process.stdout.write(`${JSON.stringify(options.plan)}\n`);
    if (options.degraded) process.stderr.write(`${DEGRADED_LINE}\n`);

    return;
  }

  for (const action of options.plan.actions) {
    if (action.kind !== 'manual-command') {
      process.stdout.write(`${describeAction(action)}\n`);
    }
  }

  if (!options.degraded) return;

  process.stdout.write(`${DEGRADED_LINE}\n`);

  for (const action of options.manual) {
    if (action.kind === 'manual-command') {
      process.stdout.write(`${action.command}\n`);
    }
  }
};

export const run = (argv: readonly string[]): number => {
  const first = argv[0];

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if ('code' in parsed) return parsed.code;

  const {dryRun, features, flags, json, repo} = parsed;
  const repoArgs = repo === undefined ? [] : ['--repo', repo];

  let registry: LabelRegistry;
  let audience: LabelAudience;
  let enabledFeatures: readonly LabelFeature[];

  try {
    const repoRoot = parsed.repoRoot ?? resolveRepoRoot();

    registry = readRegistry(repoRoot);
    audience = parsed.audience ?? resolveAudience(repoRoot);
    enabledFeatures =
      features.length > 0 ? features : resolveFeatures(repoRoot);
  } catch (error) {
    structuredError({
      code: 'labels_sync_environment',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'labels sync',
    });

    return EXIT_USAGE;
  }

  const fetched = fetchLive(repoArgs);

  if ('code' in fetched) return fetched.code;

  const planned = planSync({
    audience,
    enabledFeatures,
    flags,
    live: fetched.live,
    registry,
  });
  const actions = enforceBlockedActions(planned.actions, {
    audience,
    flags,
    repoArgs,
  });

  const executed =
    dryRun ?
      {degraded: fetched.degraded, manual: []}
    : executePlan(actions, {degraded: fetched.degraded, flags, repoArgs});

  if ('code' in executed) return executed.code;

  report({
    degraded: executed.degraded,
    json,
    manual: executed.manual,
    plan: {actions: [...actions, ...executed.manual], repo: repo ?? null},
  });

  return EXIT_CODES.OK;
};
