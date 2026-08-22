/**
 * Maintainer guards for the CLI subcommand surface. Two of them, sharing one
 * router scan: a reachability guard (is each command invoked from anywhere?)
 * and a help-summary completeness guard (is each command documented in its
 * binary's top-level summary?).
 *
 * # Reachability
 *
 * `knip` cannot see this class of deadness. A subcommand is statically
 * reachable through its router's `SUBCOMMAND_HANDLERS` object map, so
 * import-graph analysis always marks it live. The deadness lives one layer
 * lower, at runtime string dispatch: nothing ever passes the argv that
 * selects the command. `gaia update merge` sat dead ~18 days exactly this
 * way, the `/update-gaia` skill stopped routing it but the handler, its
 * help line, and its own test kept it import-reachable.
 *
 * This guard enumerates every `SUBCOMMAND_HANDLERS` leaf command across the
 * two binary entrypoints and the domain routers, then asserts each one is
 * reachable from at least one EXTERNAL invoker: an invocation-shaped string
 * (`gaia <path>` / `gaia-maintainer <path>`) in a skill, command, hook,
 * agent, CI workflow (committed or bundled template), or wiki page. The
 * binary may carry a path prefix and may be quoted, so a release-resolved
 * `"$LATEST_DIR/.gaia/cli/gaia" <path>` counts on its own; see
 * `matchesInvocation`. A command's own router (its help text) and its own
 * test are never in the haystack, so they cannot vouch for it. Commands that
 * are invoker-less by design or pending triage are listed in
 * `INTERNAL_COMMANDS` with a reason.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so
 * adopters carry neither these routers nor this test. On any clone where the
 * routers are absent the suite skips, mirroring the audit-template dogfood
 * guard.
 *
 * Scope boundary (v1): only `SUBCOMMAND_HANDLERS`-dispatched commands. The
 * `if (subcommand === '...')` routers (`scaffold`) use a different dispatch
 * shape and are out of scope. The oracle is a
 * substring match, so an invocation-shaped string in operator-facing prose
 * (e.g. a recovery hint in a CI PR body) counts as reachable; that is the
 * intended floor, the target is the command referenced by nothing at all.
 *
 * # Help-summary completeness
 *
 * Each binary prints a top-level summary with one line per command. A
 * namespace line's subcommands are also declared, separately, in that
 * namespace's own router in a different file, and nothing points from one to
 * the other: a subcommand added to a router and to that router's own
 * `HELP_TEXT`, both in the file the author already has open, does not reach the
 * summary. The class recurs on its own and is invisible to a reader who
 * consults only one of the two surfaces, so it needs a guard rather than a
 * sweep.
 *
 * The convention this asserts is **exhaustive enumeration with no allowlist**:
 * a namespace line names every key its router dispatches and nothing else.
 * `sandbox seed` is listed even though the reachability guard above records it
 * as invoker-less by design, which is the existing text's own answer to whether
 * a summary is a curated view (it is not). Should a command ever genuinely need
 * to be unlisted, design the allowlist then; speculating one now costs a second
 * hand-maintained list to keep honest.
 *
 * Scope boundary, narrower than the reachability guard's: only lines whose
 * first token is a `SUBCOMMAND_HANDLERS` domain router are compared key-for-key.
 * A top-level leaf that carries its own inner verbs (`ci-revert open|…`,
 * `harden-ledger list|…`) declares them inside a single handler rather than in
 * a router map, and `scaffold` dispatches with `if (subcommand === '...')`, so
 * for those lines this guard checks only that the command is documented and
 * dispatched, never that the verbs after it are complete.
 */
import {load} from 'js-yaml';
import {describe, expect, test} from 'vitest';
import {existsSync, readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';

// Subcommands reachable only through their router with no external invoker,
// allowed on purpose. Each entry needs a reason. Wiring or retiring a command
// here makes the "no stale entries" test fail until the entry is removed.
const INTERNAL_COMMANDS: ReadonlyMap<string, string> = new Map([
  [
    'sandbox seed',
    'Inspection/debug verb: prints the seed settings fragment as JSON. The setup flow calls `gaia sandbox apply`, which computes and writes the seed internally, so `seed` has no external invoker by design.',
  ],
]);

// Directories under the repo root scanned for invocation strings. None of
// these contain a router or a test file, so a command can never vouch for
// itself. `.gaia/cli/src/automation/templates` holds the bundled CI workflow
// templates that render into an adopter's `.github/`, the real home of the
// `automation` and `wiki diff-size` invocations.
//
// Completeness of this list is the guard's single point of rot. If the
// "every leaf has an external invoker" test goes red on a command you know
// is live, the fix is almost always a missing surface here (a new invoker
// location, a new binary, a new invocation prefix), NOT an INTERNAL_COMMANDS
// entry. Allowlisting a live command silently stops the guard watching it.
const INVOKER_SURFACES: readonly string[] = [
  '.claude/skills',
  '.claude/commands',
  '.claude/hooks',
  '.claude/agents',
  '.github',
  'wiki',
  '.gaia/cli/src/automation/templates',
];

const TEXT_EXTENSIONS = new Set([
  '.cjs',
  '.js',
  '.json',
  '.markdown',
  '.md',
  '.mjs',
  '.sh',
  '.tmpl',
  '.ts',
  '.tsx',
  '.txt',
  '.yaml',
  '.yml',
]);

const escapeRegExp = (value: string): string =>
  value.replaceAll(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);

// The keys of a router's `SUBCOMMAND_HANDLERS` map. Every handler value is a
// `run<Pascal>` symbol, so anchoring on `: run[A-Z]` selects exactly the
// command keys and skips the `code:` / `message:` / `subcommand:` lines of the
// router's `structuredError` fallback.
// Anchored per-line (not multiline/global on the whole body): sonarjs's
// regex-complexity check flags the combined `m`/`g` form as super-linear.
// Testing one line at a time is equivalent (each map entry is one line) and
// keeps each match a single bounded-length attempt.
const HANDLER_KEY_PATTERN = /^\s*'?([a-z][a-z0-9-]*)'?\s*:\s*run[A-Z]/u;

// The lines between a `SUBCOMMAND_HANDLERS` map's `= {` and its closing
// `\n};`. Starting after the brace rather than at the declaration keeps the
// multi-line generic in the two entrypoints (`Readonly<Partial<Record<…>>>`)
// out of the body, so a type line is never mistaken for an unparsed entry.
const handlerMapBody = (source: string): string => {
  const start = source.indexOf('const SUBCOMMAND_HANDLERS');

  if (start === -1) return '';

  const openOffset = source.slice(start).indexOf('= {');

  if (openOffset === -1) return '';

  const bodyStart = start + openOffset + '= {'.length;
  const endOffset = source.slice(bodyStart).indexOf('\n};');

  return endOffset === -1 ?
      source.slice(bodyStart)
    : source.slice(bodyStart, bodyStart + endOffset);
};

const extractHandlerKeys = (source: string): string[] => {
  const keys: string[] = [];

  for (const line of handlerMapBody(source).split('\n')) {
    const match = HANDLER_KEY_PATTERN.exec(line);
    const key = match?.[1];

    if (key !== undefined) keys.push(key);
  }

  return keys;
};

const COMMENT_OR_BLANK_PATTERN = /^\s*(?:\/\/|\/\*|\*|$)/u;

// Map-body lines the key pattern does not recognize.
//
// `HANDLER_KEY_PATTERN` matches only a `run<Pascal>` value, which is the
// convention every router follows today. An entry written any other way is
// dropped from the key set **silently**, and that silence is worse than a
// parse error: a subcommand missing from both its router's keys and its
// summary line leaves `missing` and `unknown` both empty, so the drift guard
// reads agreement and passes green on precisely the undocumented-subcommand
// case it exists to catch. The reachability guard goes quiet on the same
// command for the same reason.
//
// Widening the pattern is the wrong repair: it would have to anticipate every
// value shape, and the next unanticipated one fails the same silent way.
// Refusing to leave a line unaccounted for does not.
const unparsedHandlerLines = (source: string): string[] =>
  handlerMapBody(source)
    .split('\n')
    .filter(
      (line) =>
        !COMMENT_OR_BLANK_PATTERN.test(line) && !HANDLER_KEY_PATTERN.test(line)
    );

const hasDomainIndex = (cliSrc: string, name: string): boolean =>
  existsSync(path.join(cliSrc, name, 'index.ts'));

// The binary entrypoints, as `[source file, binary name]`. Both guards read
// this one list, so a third entrypoint is wired in one place.
const ENTRYPOINTS: readonly (readonly [string, string])[] = [
  ['index.ts', 'gaia'],
  ['index.maintainer.ts', 'gaia-maintainer'],
];

type RouterScan = {
  // Domain name → that router's own subcommand keys.
  readonly keys: ReadonlyMap<string, readonly string[]>;
  // `<file>: <line>` for every map-body line the key pattern did not parse,
  // across the domain routers and both entrypoints.
  readonly unparsed: readonly string[];
};

// One pass over every `SUBCOMMAND_HANDLERS` map in the tree, feeding both
// guards and the extractor's own blind-spot check.
const scanRouters = (cliSrc: string): RouterScan => {
  const domains = readdirSync(cliSrc, {withFileTypes: true})
    .filter(
      (entry) => entry.isDirectory() && hasDomainIndex(cliSrc, entry.name)
    )
    .map((entry) => entry.name);

  const keys = new Map<string, readonly string[]>();
  const unparsed: string[] = [];

  const record = (file: string, source: string): void => {
    for (const line of unparsedHandlerLines(source)) {
      unparsed.push(`${file}: ${line.trim()}`);
    }
  };

  for (const domain of domains) {
    const file = path.join(domain, 'index.ts');
    const source = readFileSync(path.join(cliSrc, file), 'utf8');

    if (source.includes('const SUBCOMMAND_HANDLERS')) {
      keys.set(domain, extractHandlerKeys(source));
      record(file, source);
    }
  }

  for (const [entrypoint] of ENTRYPOINTS) {
    record(entrypoint, readFileSync(path.join(cliSrc, entrypoint), 'utf8'));
  }

  return {keys, unparsed};
};

// Full invocation paths for every map-dispatched leaf command. Domain routers
// (`src/<domain>/index.ts` declaring the map) contribute `<domain> <key>`.
// The two entrypoints contribute their keys that have no same-named sub-router
// directory, the genuinely top-level commands (ci-revert, harden-tally, ...).
const enumerateLeafCommands = (
  cliSrc: string,
  routers: ReadonlyMap<string, readonly string[]>
): string[] => {
  const leaves = new Set<string>();

  for (const [domain, keys] of routers) {
    for (const key of keys) {
      leaves.add(`${domain} ${key}`);
    }
  }

  for (const [entrypoint] of ENTRYPOINTS) {
    const source = readFileSync(path.join(cliSrc, entrypoint), 'utf8');

    for (const key of extractHandlerKeys(source)) {
      if (!hasDomainIndex(cliSrc, key)) leaves.add(key);
    }
  }

  // Bound to a variable before sorting: canonical/no-use-extend-native's
  // proto-method database predates ES2023 and does not recognize
  // `toSorted` on an inline array-spread expression.
  const leafArray = [...leaves];

  return leafArray.toSorted((a, b) => a.localeCompare(b));
};

const collectText = (absDir: string): string => {
  if (!existsSync(absDir)) return '';

  let entries: string[];

  try {
    entries = readdirSync(absDir, {recursive: true}) as string[];
  } catch {
    return '';
  }

  const parts: string[] = [];

  for (const rel of entries) {
    if (TEXT_EXTENSIONS.has(path.extname(rel).toLowerCase())) {
      const abs = path.join(absDir, rel);

      try {
        if (statSync(abs).isFile()) parts.push(readFileSync(abs, 'utf8'));
      } catch {
        // Unreadable entry (e.g. a dangling symlink); skip it.
      }
    }
  }

  return parts.join('\n');
};

// The body of a `HELP_TEXT` template literal. Neither entrypoint's help text
// contains a backtick, so the first `\`;` after the opening delimiter closes it.
const extractHelpText = (source: string): string => {
  const opener = 'const HELP_TEXT = `';
  const start = source.indexOf(opener);

  if (start === -1) return '';

  const bodyStart = start + opener.length;
  const end = source.indexOf('`;', bodyStart);

  return end === -1 ? '' : source.slice(bodyStart, end);
};

// A top-level summary line: two-space indent, the command it documents, then
// optionally that command's pipe-separated subcommand list. Prose in a help
// text (the maintainer binary's "Maintainer-only binary." note, the `Usage:`
// header) sits at column 0 and never matches.
//
// Anything after the subcommand list is free-form flag and argument text
// (`[--cols N]`, `<raw.json>`, the `land` in `wiki … sync land`) and is not
// checked here; each namespace's own `--help` documents it. A line whose
// second token opens with `-` or `<` has no list at all, so group 2 captures
// the empty string; the optionality sits inside the group rather than on it so
// that the group always participates and never types as `undefined`.
const SUMMARY_LINE_PATTERN =
  /^ {2}([a-z][a-z0-9-]*)((?: [a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)*)?)(?![\w|-])/u;

type SummaryAudit = {
  // `<binary> <namespace>` for every line compared key-for-key. Pinned by its
  // own test so a parser that silently matched nothing cannot green the rest.
  readonly compared: string[];
  // A namespace line whose subcommand list is not exactly its router's keys.
  readonly drifted: string[];
  // A summary line for something the binary does not dispatch.
  readonly undispatched: string[];
  // A command the binary dispatches with no line in its summary at all.
  readonly unlisted: string[];
};

type SummaryLine = {
  readonly command: string;
  readonly listed: readonly string[];
};

const parseSummaryLines = (helpText: string): SummaryLine[] => {
  const parsed: SummaryLine[] = [];

  for (const line of helpText.split('\n')) {
    const match = SUMMARY_LINE_PATTERN.exec(line);

    if (match !== null) {
      const [, command, rawSubcommands] = match;

      if (command !== undefined && rawSubcommands !== undefined) {
        const subcommands = rawSubcommands.trim();

        parsed.push({
          command,
          listed: subcommands === '' ? [] : subcommands.split('|'),
        });
      }
    }
  }

  return parsed;
};

const auditBinary = (
  source: string,
  binary: string,
  routers: ReadonlyMap<string, readonly string[]>
): SummaryAudit => {
  const audit: SummaryAudit = {
    compared: [],
    drifted: [],
    undispatched: [],
    unlisted: [],
  };

  const dispatched = extractHandlerKeys(source);
  const summary = parseSummaryLines(extractHelpText(source));
  const documented = new Set(summary.map(({command}) => command));

  for (const {command, listed} of summary) {
    const keys = routers.get(command);

    // A `keys` of undefined is not a `SUBCOMMAND_HANDLERS` domain: a top-level
    // leaf (`harden-tally`), a leaf with its own inner verbs (`ci-revert`,
    // `harden-ledger`), or the `if (subcommand === …)` router (`scaffold`).
    // Same v1 scope boundary the reachability guard declares, so their lists
    // are not checked.
    if (keys !== undefined) {
      audit.compared.push(`${binary} ${command}`);

      const missing = keys.filter((key) => !listed.includes(key));
      const unknown = listed.filter((key) => !keys.includes(key));

      if (missing.length > 0 || unknown.length > 0) {
        audit.drifted.push(
          `${binary} ${command}: omits [${missing.join(', ')}], names non-existent [${unknown.join(', ')}]`
        );
      }
    }
  }

  for (const key of dispatched) {
    if (!documented.has(key)) audit.unlisted.push(`${binary} ${key}`);
  }

  for (const command of documented) {
    if (!dispatched.includes(command)) {
      audit.undispatched.push(`${binary} ${command}`);
    }
  }

  return audit;
};

const auditHelpSummaries = (
  cliSrc: string,
  routers: ReadonlyMap<string, readonly string[]>
): SummaryAudit => {
  const audits = ENTRYPOINTS.map(([entrypoint, binary]) =>
    auditBinary(
      readFileSync(path.join(cliSrc, entrypoint), 'utf8'),
      binary,
      routers
    )
  );

  return {
    compared: audits.flatMap(({compared}) => compared),
    drifted: audits.flatMap(({drifted}) => drifted),
    undispatched: audits.flatMap(({undispatched}) => undispatched),
    unlisted: audits.flatMap(({unlisted}) => unlisted),
  };
};

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const routersPresent = existsSync(cliSrc);

const routerScan: RouterScan =
  routersPresent ?
    scanRouters(cliSrc)
  : {keys: new Map<string, readonly string[]>(), unparsed: []};

const domainRouters = routerScan.keys;

const leafCommands =
  routersPresent ? enumerateLeafCommands(cliSrc, domainRouters) : [];
const summaryAudit =
  routersPresent ?
    auditHelpSummaries(cliSrc, domainRouters)
  : {compared: [], drifted: [], undispatched: [], unlisted: []};
const invokerText =
  routersPresent ?
    INVOKER_SURFACES.map((surface) =>
      collectText(path.join(repoRoot, surface))
    ).join('\n')
  : '';

// An invocation-shaped string for `commandPath` in `text`: the binary name,
// optionally closed by a quote, then the space-separated path, bounded so
// `wiki state` never matches inside `wiki state-bump`.
//
// The quote class is what lets a **release-resolved** invocation count. A
// subcommand invoked only as `"$LATEST_DIR/.gaia/cli/gaia" update merge-region`
// puts a closing quote exactly where the separator is required, so without the
// class the guard reads a live command as dead and the author has to mention
// its bare form somewhere else to clear a red. Note the narrower fix does not
// exist: an *unquoted* path prefix already matched, because `/` is neither
// `\w` nor `-`, so the quote is the whole of the blind spot.
//
// This is not a loosening. The docstring's stated floor already counts an
// invocation-shaped string in operator-facing prose, and an invocation that is
// actually executed is stronger evidence than one that is merely written down.
// What stays excluded is a bare path with no separator at all, so the quote is
// admitted beside the separator and never instead of it.
// `.gaia/tests/distribution/17-gaia-update-merge-region.sh` reached the same
// `gaia"?` shape for the same reason.
//
// Takes its haystack as an argument rather than closing over `invokerText`, so
// the pattern itself can be exercised against fixture strings. Reading the
// oracle only through the whole repository's text cannot show the difference
// between "this form is unmatchable" and "no such invocation exists here".
// `quoteClass` is a parameter for exactly one reason: the skills-surface test
// needs the pre-widening shape as a control, and a hand-copied second regex
// would drift from this one silently. Only two callers exist, both below, and
// both pin the value.
const invocationPattern = (commandPath: string, quoteClass: string): RegExp => {
  const tokens = commandPath
    .split(' ')
    .map(escapeRegExp)
    .join(String.raw`\s+`);

  return new RegExp(
    String.raw`(?<![\w-])gaia(?:-maintainer)?${quoteClass}\s+${tokens}(?![\w-])`
  );
};

const matchesInvocation = (commandPath: string, text: string): boolean =>
  invocationPattern(commandPath, '["\']?').test(text);

// The same matcher without the quote class, i.e. the shape that could not see
// a release-resolved invocation. Used only as the control described in the
// skills-surface test below; never as a reachability oracle.
const matchesUnquotedInvocation = (
  commandPath: string,
  text: string
): boolean => invocationPattern(commandPath, '').test(text);

// A command is reachable when an invocation-shaped string for it exists in the
// invoker text.
const isReachable = (commandPath: string): boolean =>
  matchesInvocation(commandPath, invokerText);

// The CI job that runs this suite, and the second paths-filter output that
// arms it on the surfaces `INVOKER_SURFACES` names.
//
// `cli-tests.yml`'s `code:` filter is the job's ordinary gate, and it lists the
// paths whose edits need the FULL job (typecheck, cold eslint, bats,
// bundle-freshness). It cannot also carry these surfaces: they are prose and
// configuration directories, so arming `code:` on them would run all of that on
// roughly two pull requests in five, on a declared-required context, to
// re-derive nothing but this guard. `reach:` exists to arm only the two steps
// this guard actually needs -- the workspace install and the Vitest run -- and
// leave the rest on `code:`.
//
// The list below is the whole point of the split, and it is the half that rots.
// A surface added to `INVOKER_SURFACES` without a mirror here leaves the guard
// running on every edit EXCEPT the one that breaks it: the removal of a
// command's sole invocation from the new surface resolves both filter outputs
// false, the Vitest step skips, and `Vitest (.gaia/cli)` reports green having
// run this file zero times. That is the exact shape of #1524, one surface
// later, and no other check in the repository can see it --
// `.gaia/scripts/tests/workflow-filter-coverage.bats` reads the literal paths a
// gated step's `run:` body names, and this step's body is
// `pnpm -C .gaia/cli test --run`, which names none.
//
// Both halves of the mirror are reachable, which is what makes the binding
// enforceable rather than advisory: an edit to `INVOKER_SURFACES` touches
// `.gaia/cli/**` and an edit to the filter touches
// `.github/workflows/cli-tests.yml`, and `code:` arms on both.
const cliTestsWorkflow = path.join(
  repoRoot,
  '.github',
  'workflows',
  'cli-tests.yml'
);

// Steps whose gate must name `reach`. The Vitest step is the one that runs this
// guard; the install step is what leaves `pnpm -C .gaia/cli test` a runnable
// command, so arming the second without the first buys a red on a missing
// `node_modules` rather than a run.
const REACH_GATED_STEPS: readonly string[] = [
  'Setup Node and install the CLI workspace',
  'Run Vitest tests',
];

type WorkflowStep = {
  readonly id?: string;
  readonly if?: string;
  readonly name?: string;
  readonly with?: {readonly filters?: string};
};

const alphabetically = (a: string, b: string): number => a.localeCompare(b);

// The `cli-tests` job's steps, and the glob list its `reach:` output declares.
// `filters:` is a YAML document embedded in a YAML string, so it parses twice.
const readCliTestsJob = (): {
  reachGlobs: readonly string[];
  steps: readonly WorkflowStep[];
} => {
  const workflow = load(readFileSync(cliTestsWorkflow, 'utf8')) as {
    jobs?: Record<string, {steps?: readonly WorkflowStep[]}>;
  };
  const steps = workflow.jobs?.['cli-tests']?.steps ?? [];
  const filters = steps.find((step) => step.id === 'filter')?.with?.filters;
  const parsed =
    filters === undefined ?
      {}
    : (load(filters) as Record<string, readonly string[] | undefined>);

  return {reachGlobs: parsed.reach ?? [], steps};
};

describe('CLI subcommand reachability guard', () => {
  // Maintainer-only guard: `routersPresent` is false on an adopter clone
  // (`.gaia/cli` release-excluded), so the whole suite skips there rather
  // than pretending to have passed a check it could not run.
  test.skipIf(!routersPresent)(
    'enumerates the command surface (guards against parser rot)',
    () => {
      // A silent enumerator would make the reachability test pass vacuously.
      // Pin a few known leaves and a floor count so parser drift fails loudly.
      expect(leafCommands).toContain('update merge-workspace');
      expect(leafCommands).toContain('wiki orphans');
      expect(leafCommands).toContain('release bump');
      expect(leafCommands).toContain('harden-tally');
      expect(leafCommands.length).toBeGreaterThanOrEqual(40);

      // The oracle must be able to return false, else everything looks
      // reachable.
      expect(isReachable('zzz fabricated-command')).toBe(false);
    }
  );

  // No `skipIf`: this exercises the pattern against fixture strings only, and
  // the pattern travels in this file, so it is runnable wherever the file is.
  test('the invocation pattern reads a quoted binary path', () => {
    // A release-resolved invocation is frozen in quoted form. Why that counts
    // is argued once, in `matchesInvocation`'s comment.
    expect(
      matchesInvocation(
        'update merge-region',
        '"$LATEST_DIR/.gaia/cli/gaia" update merge-region'
      )
    ).toBe(true);
    expect(
      matchesInvocation(
        'release scrub',
        "'/opt/g/.gaia/cli/gaia-maintainer' release scrub"
      )
    ).toBe(true);

    // Regression controls for the two forms that already worked: a bare name,
    // and an unquoted path prefix.
    expect(
      matchesInvocation('update merge-region', 'gaia update merge-region')
    ).toBe(true);
    expect(
      matchesInvocation(
        'update merge-region',
        '$LATEST_DIR/.gaia/cli/gaia update merge-region'
      )
    ).toBe(true);

    // The quote is permitted beside the separator, never instead of it.
    expect(
      matchesInvocation('update merge-region', 'gaia"update merge-region')
    ).toBe(false);
    // Both boundaries survive: a longer command name is not a prefix match,
    // and a longer binary name is not the binary.
    expect(
      matchesInvocation('wiki state', '"$D/.gaia/cli/gaia" wiki state-bump')
    ).toBe(false);
    expect(
      matchesInvocation('update merge-region', 'notgaia update merge-region')
    ).toBe(false);
  });

  test.skipIf(!routersPresent)(
    'the release-resolved invocations in the update skill are reachability evidence',
    () => {
      // `/update-gaia` invokes these two through a quoted `$LATEST_DIR` path,
      // which is their frozen invocation contract (an adopter whose installed
      // binary predates the subcommand cannot reach it any other way), and
      // `.gaia/tests/distribution/17-gaia-update-merge-region.sh` pins that
      // form. Asserting against the skills surface **alone** is the point: the
      // whole-repo `invokerText` also carries these commands' bare forms in
      // `wiki/`, so it greens whether or not the quoted call site is legible.
      const skillsText = collectText(path.join(repoRoot, '.claude', 'skills'));

      expect(matchesInvocation('update merge-region', skillsText)).toBe(true);
      expect(matchesInvocation('update regen-regions', skillsText)).toBe(true);

      // The control is what makes the two assertions above evidence about the
      // *quoted* call site rather than about whatever a skill happens to
      // mention. `matchesInvocation` accepts bare and quoted alike, so without
      // this they would also pass on a bare mention, and reverting the quote
      // class would leave them green with the property they exist to protect
      // silently gone.
      //
      // A red here is not necessarily a regression: it means some skill now
      // carries a bare form too, so this haystack no longer isolates the quoted
      // one. Narrow the haystack to the skill under test rather than deleting
      // the control.
      expect(matchesUnquotedInvocation('update merge-region', skillsText)).toBe(
        false
      );
      expect(
        matchesUnquotedInvocation('update regen-regions', skillsText)
      ).toBe(false);
    }
  );

  test.skipIf(!routersPresent)(
    'every router map entry parses, so no command is dropped silently',
    () => {
      // See `unparsedHandlerLines`. Both guards in this file read their command
      // set through `HANDLER_KEY_PATTERN`, and a router entry it does not match
      // vanishes from that set without a word: the reachability guard stops
      // watching the command, and the help-summary guard reads its absence from
      // both the router and the summary as agreement.
      //
      // To resolve a failure, write the entry as `key: run<Pascal>` like every
      // other router, rather than widening the pattern to admit a new shape.
      expect(routerScan.unparsed).toEqual([]);
    }
  );

  test.skipIf(!routersPresent)(
    'every map-dispatched leaf command has an external invoker',
    () => {
      const dead = leafCommands.filter(
        (command) => !INTERNAL_COMMANDS.has(command) && !isReachable(command)
      );

      // See the file docstring for how to resolve a dead command (wire an
      // invoker, retire it, or allowlist it in INTERNAL_COMMANDS).
      expect(dead).toEqual([]);
    }
  );

  test.skipIf(!routersPresent)(
    "the CI filter's reach globs mirror INVOKER_SURFACES",
    () => {
      // No second `skipIf` on the workflow's presence: a skip would disarm
      // the mirror silently, which is the failure this binding exists to
      // prevent, so an absent workflow throws out of the read below instead.
      const {reachGlobs} = readCliTestsJob();

      // Set equality, not containment. `reach:` has one job -- name the
      // surfaces this guard reads -- so a glob here that no surface asks for
      // is drift in the other direction and reds too.
      expect(reachGlobs.toSorted(alphabetically)).toEqual(
        INVOKER_SURFACES.map((surface) => `${surface}/**`).toSorted(
          alphabetically
        )
      );
    }
  );

  test.skipIf(!routersPresent)(
    'the CI steps that run this guard are gated on the reach filter',
    () => {
      const {steps} = readCliTestsJob();

      // A perfect mirror that nothing consumes arms nothing. Named steps
      // rather than a scan: these two are the pair that has to move together,
      // and every other step in the job stays on `code:` on purpose.
      const ungated = REACH_GATED_STEPS.filter((name) => {
        const step = steps.find((candidate) => candidate.name === name);

        return !step?.if?.includes("steps.filter.outputs.reach == 'true'");
      });

      expect(ungated).toEqual([]);
    }
  );

  test.skipIf(!routersPresent)(
    'the internal-command allowlist has no stale entries',
    () => {
      const leafSet = new Set(leafCommands);

      // An allowlisted command that was retired (no longer a leaf) or that
      // has since gained an invoker must drop out of the allowlist.
      const stale = [...INTERNAL_COMMANDS.keys()].filter(
        (command) => !leafSet.has(command) || isReachable(command)
      );

      // See the file docstring: remove any stale INTERNAL_COMMANDS entry
      // (command retired or now has an external invoker).
      expect(stale).toEqual([]);
    }
  );
});

describe('CLI help-summary completeness guard', () => {
  test.skipIf(!routersPresent)(
    'compares the summary lines it claims to (guards against parser rot)',
    () => {
      // Every assertion below is a set difference, and an empty set difference
      // is what "passing" looks like. A help-text extractor or a line pattern
      // that silently matched nothing would therefore green all three. Pin one
      // namespace per binary and a floor count so that failure is loud.
      expect(summaryAudit.compared).toContain('gaia wiki');
      expect(summaryAudit.compared).toContain('gaia setup-ci');
      expect(summaryAudit.compared).toContain('gaia-maintainer release');
      expect(summaryAudit.compared).toContain('gaia-maintainer init');
      expect(summaryAudit.compared.length).toBeGreaterThanOrEqual(15);
    }
  );

  test.skipIf(!routersPresent)(
    'every namespace line enumerates exactly its router subcommands',
    () => {
      // The convention is exhaustive enumeration, with no allowlist: a
      // namespace line names every key its router dispatches and nothing else.
      // To resolve a failure, add the omitted subcommand to that line in
      // `index.ts` / `index.maintainer.ts` (both, when both dispatch the
      // namespace), or drop the name the router no longer has. Do not silence
      // this by widening the parser.
      expect(summaryAudit.drifted).toEqual([]);
    }
  );

  test.skipIf(!routersPresent)(
    'every dispatched command has a summary line, and every line is dispatched',
    () => {
      // The line-by-line comparison above can only check namespaces that
      // appear in the help text at all, so a whole namespace added to
      // `SUBCOMMAND_HANDLERS` and never documented would slip past it. These
      // two close that gap from both directions.
      expect(summaryAudit.unlisted).toEqual([]);
      expect(summaryAudit.undispatched).toEqual([]);
    }
  );
});
