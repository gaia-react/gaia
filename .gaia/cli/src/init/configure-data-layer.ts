/**
 * `gaia init configure-data-layer [--casing <c>] [--query <bool>] [--layer <f>]`
 * handler.
 *
 * Codifies the data-layer questions of `/gaia-init` Step 2, and also serves a
 * later rerun after init has finalized (for example `--query true` to add
 * TanStack Query to an existing project), when no orchestrating skill exists.
 *
 *   --query true     Pins TanStack Query in `package.json`, writes the Query
 *                    runtime files, and makes one anchored edit each in
 *                    `app/state/index.tsx`, `.storybook/preview.ts`,
 *                    `vite.config.ts`, and `vitest.config.ts`.
 *   --casing snake   Sets `isSnakeCaseEnabled: true` on the domain layer's
 *                    `create()` call.
 *
 * Additive and idempotent: `--query false` and `--casing camel` change
 * nothing, and each edit is skipped when its result is already in the file.
 * Every edit is planned and anchor-checked in memory before any file is
 * written, so a missing anchor leaves the tree untouched. This step never runs
 * pnpm; it reports what to run next.
 *
 * Stdout: one JSON line, `{changed, next}`. Exit codes: 0 / 1 / 2.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {
  dataLayerTemplatePath,
  declaresTanstackQuery,
  hasQueryGetters,
  TANSTACK_QUERY_PACKAGE,
  TANSTACK_QUERY_VERSION,
} from '../scaffold/data-layer.js';
import {ensureDir} from '../scaffold/fs.js';
import {
  listSubdirectories,
  resolveLayer,
  SNAKE_CASE_FLAG,
} from '../scaffold/layer.js';
import {deriveNames} from '../scaffold/service.js';
import {structuredError} from '../stderr.js';
import {takeValue} from '../util/argv.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {resolvePackageTarget} from '../util/package-target.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init configure-data-layer [--casing <c>] [--query <bool>] [--layer <folder>]

  Configure the data layer from the user's answers. Also runnable after init
  has finalized, for example "--query true" to add TanStack Query later.
  Additive and idempotent: it never removes or reverts anything.

  Flags (at least one of --casing, --query is required):
    --casing <c>         Backend field casing: camel or snake.
                         Only "snake" changes a file (isSnakeCaseEnabled: true).
    --query <bool>       "true" pins TanStack Query and wires its runtime.
    --layer <folder>     Domain-layer folder under app/services/ (needed only
                         for --casing snake when there is not exactly one).

  This is the one init step that writes to stdout: a single JSON line,
  {"changed": [<paths>], "next": [<commands to run>]}. It never runs pnpm.

  Exit codes:
    0  success (one JSON line on stdout)
    1  user-correctable error (bad flags, missing anchor; nothing written)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'configure-data-layer';
const SUBCOMMAND = 'init configure-data-layer';

const CASINGS = ['camel', 'snake'] as const;

type Casing = (typeof CASINGS)[number];

type FlagParseResult = {flags: Flags; ok: true} | {message: string; ok: false};

type Flags = {
  casing: Casing | null;
  layer: null | string;
  query: boolean | null;
};

type FlagStep =
  {message: string; ok: false} | {ok: true; patch: Partial<Flags>};

const isCasing = (value: string): value is Casing =>
  (CASINGS as readonly string[]).includes(value);

const readCasing = (value: string): FlagStep =>
  isCasing(value) ?
    {ok: true, patch: {casing: value}}
  : {
      message: `--casing must be one of ${CASINGS.join(', ')}`,
      ok: false,
    };

const readQuery = (value: string): FlagStep => {
  if (value === 'true') return {ok: true, patch: {query: true}};

  if (value === 'false') return {ok: true, patch: {query: false}};

  return {message: '--query must be "true" or "false"', ok: false};
};

const FLAG_READERS = new Map<string, (value: string) => FlagStep>([
  ['--casing', readCasing],
  ['--layer', (value) => ({ok: true, patch: {layer: value}})],
  ['--query', readQuery],
]);

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  const flags: Flags = {casing: null, layer: null, query: null};

  for (let index = 0; index < argv.length; index += 2) {
    const token = argv[index] ?? '';
    const reader = FLAG_READERS.get(token);

    if (reader === undefined) {
      return {message: `unknown flag: ${token}`, ok: false};
    }

    const taken = takeValue(argv, index + 1, token);

    if (!taken.ok) return taken;
    const step = reader(taken.value);

    if (!step.ok) return step;
    Object.assign(flags, step.patch);
  }

  if (flags.casing === null && flags.query === null) {
    return {
      message: 'at least one of --casing, --query is required',
      ok: false,
    };
  }

  return {flags, ok: true};
};

type AnchorMiss = {file: string; message: string};

type Plan = AnchorMiss | null | PlannedWrite;

/** One planned file write: an absolute path and its full next content. */
type PlannedWrite = {content: string; file: string};

const isAnchorMiss = (plan: Plan): plan is AnchorMiss =>
  plan !== null && 'message' in plan;

const readIfPresent = (file: string): null | string =>
  existsSync(file) ? readFileSync(file, 'utf8') : null;

const missingFile = (relative: string, edit: string): AnchorMiss => ({
  file: relative,
  message: `${relative}: file not found; ${edit}`,
});

/** Adds `import` after the last single-statement import, or at the top. */
const addImport = (source: string, statement: string): string => {
  let lastEnd = 0;

  for (const match of source.matchAll(/^import[^;]*;$/gmu)) {
    lastEnd = match.index + match[0].length;
  }

  if (lastEnd === 0) return `${statement}\n${source}`;

  return `${source.slice(0, lastEnd)}\n${statement}${source.slice(lastEnd)}`;
};

const JSON_INDENT = 2;

/** Index that keeps an already-sorted `names` list sorted once `name` is added. */
const sortedInsertIndex = (names: readonly string[], name: string): number => {
  const at = names.findIndex((existing) => existing > name);

  return at === -1 ? names.length : at;
};

const planPackageJson = (packageDir: string): Plan => {
  const relative = 'package.json';
  const file = path.join(packageDir, relative);
  const source = readIfPresent(file);

  if (source === null) {
    return missingFile(
      relative,
      `add "${TANSTACK_QUERY_PACKAGE}": "${TANSTACK_QUERY_VERSION}" to dependencies`
    );
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(source);
  } catch {
    return {
      file: relative,
      message: `${relative}: not valid JSON; fix it, then rerun`,
    };
  }

  if (declaresTanstackQuery(parsed)) return null;

  const dependencies =
    parsed !== null && typeof parsed === 'object' ?
      (parsed as {dependencies?: unknown}).dependencies
    : undefined;

  if (
    dependencies === null ||
    typeof dependencies !== 'object' ||
    Array.isArray(dependencies)
  ) {
    return {
      file: relative,
      message: `${relative}: no "dependencies" object; add "${TANSTACK_QUERY_PACKAGE}": "${TANSTACK_QUERY_VERSION}" to dependencies by hand`,
    };
  }

  // Insert at the sorted position so the existing key order is left alone.
  const entries = Object.entries(dependencies as Record<string, unknown>);
  entries.splice(
    sortedInsertIndex(
      entries.map(([name]) => name),
      TANSTACK_QUERY_PACKAGE
    ),
    0,
    [TANSTACK_QUERY_PACKAGE, TANSTACK_QUERY_VERSION]
  );
  const next = {
    ...(parsed as Record<string, unknown>),
    dependencies: Object.fromEntries(entries),
  };
  const trailing = source.endsWith('\n') ? '\n' : '';

  return {
    content: `${JSON.stringify(next, null, JSON_INDENT)}${trailing}`,
    file,
  };
};

const planStateIndex = (packageDir: string): Plan => {
  const relative = 'app/state/index.tsx';
  const file = path.join(packageDir, relative);
  const source = readIfPresent(file);
  const handEdit =
    'wrap the JSX child {children} in <QueryProvider> and import it from ./query-provider';

  if (source === null) return missingFile(relative, handEdit);

  if (source.includes('<QueryProvider>')) return null;

  const anchors = [...source.matchAll(/>\s*\{children\}\s*</gu)];

  if (anchors.length !== 1) {
    return {
      file: relative,
      message: `${relative}: expected exactly one JSX child {children} to wrap, found ${anchors.length}; ${handEdit}`,
    };
  }

  const fragment = /<>(\s*)\{children\}(\s*)<\/>/u;
  const wrapped =
    fragment.test(source) ?
      source.replace(fragment, '<QueryProvider>$1{children}$2</QueryProvider>')
    : source.replace(
        /(>\s*)\{children\}(\s*<)/u,
        '$1<QueryProvider>{children}</QueryProvider>$2'
      );

  return {
    content: addImport(
      wrapped,
      "import QueryProvider from './query-provider';"
    ),
    file,
  };
};

const DECORATOR_IMPORT =
  "import QueryClientDecorator from './decorators/QueryClientDecorator';";

const planPreview = (packageDir: string): Plan => {
  const relative = '.storybook/preview.ts';
  const file = path.join(packageDir, relative);
  const source = readIfPresent(file);
  const handEdit =
    'add QueryClientDecorator to the decorators array and import it from ./decorators/QueryClientDecorator';

  if (source === null) return missingFile(relative, handEdit);

  if (source.includes('QueryClientDecorator')) return null;

  const shorthand = [...source.matchAll(/^([ \t]*)decorators,[ \t]*$/gmu)];
  const literal = [...source.matchAll(/decorators:\s*\[([^\]\n]*)\]/gu)];
  let next: null | string = null;

  if (shorthand.length === 1) {
    next = source.replace(
      /^([ \t]*)decorators,[ \t]*$/mu,
      '$1decorators: [...decorators, QueryClientDecorator],'
    );
  } else if (shorthand.length === 0 && literal.length === 1) {
    next = source.replace(
      /decorators:\s*\[([^\]\n]*)\]/u,
      (_whole, inner: string) => {
        const items = inner.trim().replace(/,$/u, '').trim();

        return items === '' ?
            'decorators: [QueryClientDecorator]'
          : `decorators: [${items}, QueryClientDecorator]`;
      }
    );
  }

  if (next === null) {
    return {
      file: relative,
      message: `${relative}: no single "decorators," property or one-line "decorators: [...]" array found; ${handEdit}`,
    };
  }

  return {content: addImport(next, DECORATOR_IMPORT), file};
};

const planOptimizeDeps = (packageDir: string, relative: string): Plan => {
  const file = path.join(packageDir, relative);
  const source = readIfPresent(file);
  const handEdit = `add '${TANSTACK_QUERY_PACKAGE}', to optimizeDeps.include in sorted position`;

  if (source === null) return missingFile(relative, handEdit);

  if (source.includes(`'${TANSTACK_QUERY_PACKAGE}'`)) return null;

  const anchors = [...source.matchAll(/optimizeDeps/gu)];
  const [anchor] = anchors;
  const includeAt =
    anchor === undefined ? -1 : source.indexOf('include:', anchor.index);
  const open = includeAt === -1 ? -1 : source.indexOf('[', includeAt);
  const close = open === -1 ? -1 : source.indexOf(']', open);
  const body = close === -1 ? '' : source.slice(open + 1, close);
  const lines = body.split('\n').filter((line) => line.trim() !== '');
  const quotedEntry = /^\s*'[^'\n]+',?\s*$/u;

  if (
    anchors.length !== 1 ||
    lines.length === 0 ||
    !lines.every((line) => quotedEntry.test(line))
  ) {
    return {
      file: relative,
      message: `${relative}: expected one optimizeDeps.include array with one quoted entry per line; ${handEdit}`,
    };
  }

  const indent = /^\s*/u.exec(lines[0] ?? '')?.[0] ?? '';
  const names = lines.map((line) => /'([^']+)'/u.exec(line)?.[1] ?? '');
  const withComma = lines.map((line) =>
    line.trimEnd().endsWith(',') ? line : `${line.trimEnd()},`
  );
  withComma.splice(
    sortedInsertIndex(names, TANSTACK_QUERY_PACKAGE),
    0,
    `${indent}'${TANSTACK_QUERY_PACKAGE}',`
  );

  return {
    content: `${source.slice(0, open + 1)}\n${withComma.join('\n')}${source.slice(close)}`,
    file,
  };
};

const TEMPLATE_TARGETS: readonly (readonly [string, string])[] = [
  ['query-client.ts.tmpl', 'app/query-client.ts'],
  ['query-provider.tsx.tmpl', 'app/state/query-provider.tsx'],
  [
    'QueryClientDecorator.tsx.tmpl',
    '.storybook/decorators/QueryClientDecorator.tsx',
  ],
];

const planTemplateFiles = (packageDir: string): PlannedWrite[] =>
  TEMPLATE_TARGETS.flatMap(([template, target]) => {
    const file = path.join(packageDir, target);

    if (existsSync(file)) return [];

    return [
      {content: readFileSync(dataLayerTemplatePath(template), 'utf8'), file},
    ];
  });

/** Index of the matching `)` for the `(` at `open`, or -1. */
const closingParen = (source: string, open: number): number => {
  let depth = 0;

  for (let index = open; index < source.length; index += 1) {
    const char = source[index];

    if (char === '(') depth += 1;

    if (char === ')') {
      depth -= 1;

      if (depth === 0) return index;
    }
  }

  return -1;
};

const planSnakeApi = (packageDir: string, layer: string): Plan => {
  const relative = `app/services/${layer}/api.ts`;
  const file = path.join(packageDir, relative);
  const source = readIfPresent(file);
  const handEdit = 'pass {isSnakeCaseEnabled: true} to the create() call';

  if (source === null) return missingFile(relative, handEdit);

  const call = /(?<![.\w])create\(/u.exec(source);
  const open = call === null ? -1 : call.index + call[0].length - 1;
  const close = open === -1 ? -1 : closingParen(source, open);
  const argument = close === -1 ? '' : source.slice(open + 1, close).trim();

  if (close === -1 || !(argument === '' || /^\{[\s\S]*\}$/u.test(argument))) {
    return {
      file: relative,
      message: `${relative}: no create() call with no argument or an object literal found; ${handEdit}`,
    };
  }

  const before = source.slice(0, open + 1);
  const after = source.slice(close);
  const existing = SNAKE_CASE_FLAG.exec(argument);
  const inner = argument.slice(1, -1);
  let nextArgument: string;

  if (argument === '' || (existing === null && inner.trim() === '')) {
    nextArgument = '{isSnakeCaseEnabled: true}';
  } else if (existing === null) {
    const indent = /\n([ \t]*)\S/u.exec(inner)?.[1];

    if (indent === undefined) {
      nextArgument = `{isSnakeCaseEnabled: true, ${inner.trimStart()}}`;
    } else {
      nextArgument = `{\n${indent}isSnakeCaseEnabled: true,${inner}}`;
    }
  } else {
    if (existing[1] === 'true') return null;
    nextArgument = argument.replace(
      SNAKE_CASE_FLAG,
      'isSnakeCaseEnabled: true'
    );
  }

  return {content: `${before}${nextArgument}${after}`, file};
};

/**
 * One `--queries-only` command per existing service that has a `requests.ts`
 * and no `queries.ts`, when `scaffold service --queries-only` would accept it.
 */
const queriesOnlyHints = (packageDir: string): string[] => {
  const servicesDir = path.join(packageDir, 'app', 'services');

  return listSubdirectories(servicesDir)
    .filter((layer) => layer !== 'api')
    .flatMap((layer) =>
      listSubdirectories(path.join(servicesDir, layer)).flatMap((service) => {
        const folder = path.join(servicesDir, layer, service);
        const requests = readIfPresent(path.join(folder, 'requests.ts'));

        if (
          requests === null ||
          existsSync(path.join(folder, 'queries.ts')) ||
          !hasQueryGetters(requests, deriveNames(service))
        ) {
          return [];
        }

        return [
          `./.gaia/cli/gaia scaffold service ${service} --queries-only --layer ${layer}`,
        ];
      })
    );
};

type PlanResult =
  {miss: AnchorMiss; ok: false} | {ok: true; writes: PlannedWrite[]};

const collect = (plans: readonly Plan[]): PlanResult => {
  const writes: PlannedWrite[] = [];

  for (const plan of plans) {
    if (isAnchorMiss(plan)) return {miss: plan, ok: false};

    if (plan !== null) writes.push(plan);
  }

  return {ok: true, writes};
};

const planQueryOn = (packageDir: string): Plan[] => [
  planPackageJson(packageDir),
  planStateIndex(packageDir),
  planPreview(packageDir),
  planOptimizeDeps(packageDir, 'vite.config.ts'),
  planOptimizeDeps(packageDir, 'vitest.config.ts'),
  ...planTemplateFiles(packageDir),
];

type RunOptions = {
  cwd?: string;
};

const fail = (code: string, message: string): number => {
  structuredError({code, message, subcommand: SUBCOMMAND});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

const resolveSnakePlan = (
  packageDir: string,
  layer: null | string
): {error: string} | {plan: Plan} => {
  const resolved = resolveLayer(packageDir, layer ?? undefined);

  if ('error' in resolved) return resolved;

  return {plan: planSnakeApi(packageDir, resolved.layer)};
};

const buildResult = (
  flags: Flags,
  packageDir: string
): {code: string; error: string} | {next: string[]; writes: PlannedWrite[]} => {
  const plans: Plan[] = [];

  if (flags.casing === 'snake') {
    const snake = resolveSnakePlan(packageDir, flags.layer);

    if ('error' in snake) {
      return {code: 'invalid_arguments', error: snake.error};
    }

    plans.push(snake.plan);
  }

  if (flags.query === true) plans.push(...planQueryOn(packageDir));

  const collected = collect(plans);

  if (!collected.ok) {
    return {code: 'data_layer_anchor_missing', error: collected.miss.message};
  }

  const {writes} = collected;
  const packageFile = path.join(packageDir, 'package.json');
  const next: string[] = [];

  if (writes.some((write) => write.file === packageFile)) {
    next.push('pnpm install');
  }

  if (flags.query === true) next.push(...queriesOnlyHints(packageDir));

  return {next, writes};
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [first] = argv;

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) return fail('invalid_arguments', parsed.message);

  const cwd = options.cwd ?? process.cwd();
  const target = resolvePackageTarget(cwd);

  if (!target.ok) {
    structuredError({
      code: 'gaia_packages',
      message: target.message,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const built = buildResult(parsed.flags, target.packageDir);

  if ('error' in built) return fail(built.code, built.error);

  try {
    for (const write of built.writes) {
      ensureDir(path.dirname(write.file));
      atomicWriteFileSync(write.file, write.content);
    }

    markStepCompleted(cwd, STEP_NAME, {
      casing: parsed.flags.casing,
      layer: parsed.flags.layer,
      query: parsed.flags.query,
    });
  } catch (error) {
    structuredError({
      code: 'configure_data_layer_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return UNEXPECTED_EXIT;
  }

  const changed = built.writes
    .map((write) => path.relative(target.repoRoot, write.file))
    .toSorted((a, b) => a.localeCompare(b));

  process.stdout.write(`${JSON.stringify({changed, next: built.next})}\n`);

  return EXIT_CODES.OK;
};
