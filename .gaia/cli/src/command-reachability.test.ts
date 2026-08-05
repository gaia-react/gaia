import {describe, expect, test} from 'vitest';
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
 * agent, CI workflow (committed or bundled template), or wiki page. A
 * command's own router (its help text) and its own test are never in the
 * haystack, so they cannot vouch for it. Commands that are invoker-less by
 * design or pending triage are listed in `INTERNAL_COMMANDS` with a reason.
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
 * namespace's own router in a different file, and nothing pointed from one to
 * the other: a subcommand added to a router and to that router's own
 * `HELP_TEXT` (both in the file the author already has open) never reached the
 * summary. That produced 21 omissions across 9 lines before this guard, and it
 * had been repaired one line at a time twice without either repair noticing the
 * other eight lines.
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

const extractHandlerKeys = (source: string): string[] => {
  const start = source.indexOf('const SUBCOMMAND_HANDLERS');

  if (start === -1) return [];

  const endOffset = source.slice(start).indexOf('\n};');
  const body =
    endOffset === -1 ?
      source.slice(start)
    : source.slice(start, start + endOffset);

  const keys: string[] = [];

  for (const line of body.split('\n')) {
    const match = HANDLER_KEY_PATTERN.exec(line);

    if (match) keys.push(match[1]);
  }

  return keys;
};

const hasDomainIndex = (cliSrc: string, name: string): boolean =>
  existsSync(path.join(cliSrc, name, 'index.ts'));

// Every domain router (`src/<domain>/index.ts` declaring a
// `SUBCOMMAND_HANDLERS` map), keyed by domain name, with that router's own
// subcommand keys. Both guards in this file dispatch off this one scan.
const collectDomainRouters = (
  cliSrc: string
): ReadonlyMap<string, readonly string[]> => {
  const routers = new Map<string, readonly string[]>();

  for (const entry of readdirSync(cliSrc, {withFileTypes: true})) {
    if (!entry.isDirectory() || !hasDomainIndex(cliSrc, entry.name)) continue;

    const source = readFileSync(
      path.join(cliSrc, entry.name, 'index.ts'),
      'utf8'
    );

    if (!source.includes('const SUBCOMMAND_HANDLERS')) continue;

    routers.set(entry.name, extractHandlerKeys(source));
  }

  return routers;
};

// Full invocation paths for every map-dispatched leaf command. Domain routers
// (`src/<domain>/index.ts` declaring the map) contribute `<domain> <key>`.
// The two entrypoints contribute their keys that have no same-named sub-router
// directory, the genuinely top-level commands (ci-revert, harden-tally, ...).
const enumerateLeafCommands = (cliSrc: string): string[] => {
  const leaves = new Set<string>();

  for (const [domain, keys] of collectDomainRouters(cliSrc)) {
    for (const key of keys) {
      leaves.add(`${domain} ${key}`);
    }
  }

  for (const entrypoint of ['index.ts', 'index.maintainer.ts']) {
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

// A top-level summary line is indented two spaces and opens with the command
// it documents. Prose in a help text (the maintainer binary's "Maintainer-only
// binary." note, the `Usage:` header) sits at column 0 and never matches.
const SUMMARY_COMMAND_PATTERN = /^ {2}([a-z][a-z0-9-]*)(?![\w-])/u;

// The pipe-separated subcommand list is the token immediately after the
// namespace. Everything after that token is free-form flag and argument text
// (`[--cols N]`, `<raw.json>`, the `land` in `wiki … sync land`) and is not
// checked here; each namespace's own `--help` documents it.
const SUMMARY_SUBCOMMANDS_PATTERN =
  /^ {2}[a-z][a-z0-9-]* ([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)*)(?![\w|-])/u;

type SummaryAudit = {
  // `<binary> <namespace>` for every line compared key-for-key. Pinned by its
  // own test so a parser that silently matched nothing cannot green the rest.
  readonly compared: string[];
  // A namespace line whose subcommand list is not exactly its router's keys.
  readonly drifted: string[];
  // A command the binary dispatches with no line in its summary at all.
  readonly unlisted: string[];
  // A summary line for something the binary does not dispatch.
  readonly undispatched: string[];
};

const auditHelpSummaries = (
  cliSrc: string,
  routers: ReadonlyMap<string, readonly string[]>
): SummaryAudit => {
  const audit: SummaryAudit = {
    compared: [],
    drifted: [],
    undispatched: [],
    unlisted: [],
  };

  for (const [entrypoint, binary] of [
    ['index.ts', 'gaia'],
    ['index.maintainer.ts', 'gaia-maintainer'],
  ]) {
    const source = readFileSync(path.join(cliSrc, entrypoint), 'utf8');
    const helpText = extractHelpText(source);
    const dispatched = extractHandlerKeys(source);
    const documented = new Set<string>();

    for (const line of helpText.split('\n')) {
      const command = SUMMARY_COMMAND_PATTERN.exec(line)?.[1];

      if (command === undefined) continue;

      documented.add(command);

      const keys = routers.get(command);

      // Not a `SUBCOMMAND_HANDLERS` domain: a top-level leaf (`harden-tally`),
      // a leaf with its own inner verbs (`ci-revert`, `harden-ledger`), or the
      // `if (subcommand === …)` router (`scaffold`). Same v1 scope boundary
      // the reachability guard declares; their lists are not checked.
      if (keys === undefined) continue;

      audit.compared.push(`${binary} ${command}`);

      const listed =
        SUMMARY_SUBCOMMANDS_PATTERN.exec(line)?.[1]?.split('|') ?? [];
      const missing = keys.filter((key) => !listed.includes(key));
      const unknown = listed.filter((key) => !keys.includes(key));

      if (missing.length > 0 || unknown.length > 0) {
        audit.drifted.push(
          `${binary} ${command}: omits [${missing.join(', ')}], names non-existent [${unknown.join(', ')}]`
        );
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
  }

  return audit;
};

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const routersPresent = existsSync(cliSrc);

const leafCommands = routersPresent ? enumerateLeafCommands(cliSrc) : [];
const summaryAudit =
  routersPresent ?
    auditHelpSummaries(cliSrc, collectDomainRouters(cliSrc))
  : {compared: [], drifted: [], undispatched: [], unlisted: []};
const invokerText =
  routersPresent ?
    INVOKER_SURFACES.map((surface) =>
      collectText(path.join(repoRoot, surface))
    ).join('\n')
  : '';

// A command is reachable when an invocation-shaped string for it exists in the
// invoker text: the binary name, then the space-separated path, bounded so
// `wiki state` never matches inside `wiki state-bump`.
const isReachable = (commandPath: string): boolean => {
  const tokens = commandPath
    .split(' ')
    .map(escapeRegExp)
    .join(String.raw`\s+`);

  return new RegExp(
    String.raw`(?<![\w-])gaia(?:-maintainer)?\s+${tokens}(?![\w-])`
  ).test(invokerText);
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
