/**
 * Scans `wiki/**` markdown files for backticked repo-relative paths that
 * reference files no longer present on disk. Detects rot like a wiki page
 * citing a hook script after that hook has been deleted or renamed. Also
 * flags any reference to sibling-monorepo paths
 * (`studio/`, `website/`); those reach outside the GAIA repo and never
 * resolve on a single-repo clone.
 *
 * Output: newline-separated `wiki/path:line  dead-path` entries, followed by
 * any `gaia:hypothetical` marker that exempts nothing. Exit 0 always; finding
 * rot is informational, not a failure.
 */
import {readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  collectWikiMarkdown,
  isGeneratedContentExempt,
  isWikiScanExempt,
} from './util/markdown-corpus.js';

export const HELP_TEXT = `Usage: gaia wiki dead-paths [--json]

  Scan wiki/**/*.md for backticked repo-relative paths under .claude/, .gaia/,
  app/, test/, wiki/ that no longer exist on disk, plus any reference to
  sibling-monorepo paths (studio/, website/) which reach outside the GAIA
  tarball and never resolve on a single-repo clone. Excludes wiki/log.md,
  wiki/hot.md and wiki/meta/** (generated or append-only files that
  legitimately reference historical paths).

  A citation of a path that is an illustration rather than a real file is
  exempted on its own line by a trailing marker naming the same path
  unbackticked, with a reason:

    <!-- gaia:hypothetical .claude/commands/tool.sh: reason it cannot exist -->

  A marker whose line carries no matching dead path is reported alongside the
  dead paths, as is one missing either half of its path-and-reason pair.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const TRACKED_PREFIXES = [
  '.claude/',
  '.gaia/',
  'app/',
  'test/',
  'wiki/',
] as const;

/**
 * Sibling-monorepo segments that the maintainer's working tree contains
 * (`gaia/`, `studio/`, `website/` are siblings) but the GAIA tarball does
 * not. Any wiki citation containing one of these segments is dead on every
 * clone except the maintainer's. The pattern matches both bare prefixes
 * (`studio/foo.md`) and relative escapes (`../../../studio/foo.md`).
 */
const SIBLING_REPO_PATTERN = /(?:^|\/)(studio|website)\//;

/**
 * This scan's own exemption, on top of the two shared tiers it takes from
 * `util/markdown-corpus.js`.
 *
 * `wiki/.state.json` has no counterpart in either shared tier and none in
 * `.claude/rules/wiki-style.md`. It is a defensive non-markdown entry the
 * markdown corpus can never yield, so neither promoting it to the shared
 * vocabulary nor deleting it here follows from anything the shared tiers say.
 * Matched by prefix, as it always has been.
 *
 * Exported for the help-text drift guard in the tests, which reads it beside
 * the two shared tiers to reconstruct what this scan actually skips.
 */
export const LOCAL_EXEMPT_PREFIX = 'wiki/.state.json';

/**
 * Repo-relative prefixes that resolve to gitignored runtime artifacts. Wiki
 * references to these paths describe shapes, not files we expect to exist.
 */
const RUNTIME_PREFIXES = ['.gaia/local/'] as const;

/**
 * Exact repo-relative paths that are real, gitignored, machine-local files:
 * present only on a checkout where a human or `/setup-gaia` wrote one, and so
 * absent on every fresh clone, every CI checkout, and every linked worktree.
 * Their presence is a property of the checkout rather than of the repository,
 * which makes a wiki citation of one correct even where the file is missing.
 *
 * `RUNTIME_PREFIXES` exempts `.gaia/local/` for the same reason and is the
 * closest precedent; these are exact paths rather than a prefix, so they want a
 * sibling set rather than an entry there.
 *
 * Kept distinct from `ADOPTER_OWNED_SENTINELS` rather than folded into it: that
 * set is pinned by equality to the runtime-only entries of
 * `release/runtime-deps.ts`'s same-named set, so an entry added here alone reds
 * that test, and one added on both sides would assert that a machine-local
 * settings file is a release runtime dependency, which it is not.
 */
const GITIGNORED_LOCAL_FILES: ReadonlySet<string> = new Set([
  '.claude/settings.local.json',
]);

/**
 * Exact repo-relative paths that are adopter-owned and legitimately absent
 * on a checkout that hasn't opted in: `.gaia/automation.json` is written by
 * `/setup-gaia`, not shipped by GAIA itself, so it is correctly missing here
 * on the GAIA source repo.
 *
 * `release/runtime-deps.ts` keeps its own `ADOPTER_OWNED_SENTINELS` naming the
 * same file. The two sets intersect on the runtime-created entries only: that
 * one also spreads `manifest.ts`'s git-tracked sentinels, which are present on
 * disk here and so must NOT be exempted from this scan. Kept separate rather
 * than shared because this module ships in the adopter `gaia` bundle and that
 * one is maintainer-only, so importing across would pull release tooling into
 * the adopter binary and reverse the established `release/` → `wiki/` import
 * direction. A new runtime-created sentinel belongs in both; a git-tracked one
 * belongs only in the release-side set.
 */
export const ADOPTER_OWNED_SENTINELS: ReadonlySet<string> = new Set([
  '.gaia/automation.json',
]);

/**
 * The in-prose, line-scoped exemption a wiki author writes when a sentence
 * names a path as an illustration of a file that does not exist and is not
 * meant to. Written on the citation's own line:
 *
 *   `.claude/commands/tool.sh` <!-- gaia:hypothetical .claude/commands/tool.sh: why -->
 *
 * The path inside the marker is written unbackticked. Backticks are kept
 * verbatim in the declared path, so a backticked one matches no token, and the
 * marker then exempts nothing *and* reports itself unused.
 *
 * A central allowlist is the obvious alternative and it cannot self-scope. The
 * bundle-time scrub strips a maintainer-only block from a page an adopter
 * receives, so a list entry covering a line inside one ships in the binary
 * while the line it exempts does not, and that clone is then blind to a
 * genuinely dead future citation of the same path. A marker is stripped by the
 * same scrub that strips its subject, and an adopter writing their own page can
 * reach for it at all: neither property is available to a list held in this
 * file, which adopters receive only as a compiled binary.
 *
 * The mandatory reason and the stale-marker report are `gaia-lint-ignore
 * <guard>: <reason>`'s two safety properties, taken for the reason that pragma
 * has them: without the report, an in-prose marker decays exactly as a list
 * entry does, only less visibly.
 *
 * Comparison is on NFC because an accented path has two legal spellings and
 * string equality compares code points: macOS filesystems and some editors
 * hand back NFD (`e` + U+0301) where prose typed in an editor is NFC (U+00E9).
 * Without it, re-encoding a wiki page silently turns a live marker stale.
 */
const MARKER_PATTERN = /<!--\s*gaia:hypothetical\b([^>]*)-->/g;

const PATH_TOKEN_PATTERN = /`([^`\n]+?)`/g;

/**
 * Placeholder markers in wiki examples: `<name>`, `${VAR}`, `*.ts`, and
 * convention-marker runs like `SPEC-NNN.md` / `XXX-XXX`.
 */
const PLACEHOLDER_PATTERN = /[<>*${}]|N{3,}|X{3,}/;

/**
 * Decision-record bullets explicitly documenting that a path was removed or
 * renamed. Decision pages legitimately reference paths that no longer exist;
 * the bullet itself is the explanation. Match the canonical bullet form:
 *
 *   - **Removed** `path/that/was/removed.ts`
 *   - **Deleted** `...`
 *   - **Renamed** `...`
 *   - **Migrated** `...`
 */
const HISTORICAL_BULLET_PATTERN =
  /^\s*-\s+\*\*(Removed|Deleted|Renamed|Migrated|Replaced)\*\*/i;

type DeadRef = {
  filePath: string;
  line: number;
  path: string;
};

/** The two halves of a well-formed marker, each missing on its own terms. */
type MarkerDefect = 'missing-path' | 'missing-reason';

// Each label names the half the author has to supply, so the report is
// actionable without reading the marker back.
const STALE_MARKER_LABELS = {
  'missing-path': 'malformed gaia:hypothetical marker, no path given',
  'missing-reason': 'malformed gaia:hypothetical marker, no reason given',
  unused: 'unused gaia:hypothetical marker',
} as const;

type RunOptions = {
  cwd?: string;
};

/**
 * A `gaia:hypothetical` marker that exempts nothing. The malformed cases are
 * kept apart rather than folded into one, because each names the part the
 * author has to supply and telling them to add the half they already wrote is
 * worse than saying nothing.
 */
type StaleMarker = {
  filePath: string;
  line: number;
  marker: string;
  problem: 'unused' | MarkerDefect;
};

/** Every finding this scan reports, from one walk of the wiki corpus. */
type WikiPathScan = {
  dead: readonly DeadRef[];
  staleMarkers: readonly StaleMarker[];
};

const isTrackedPath = (token: string): boolean => {
  if (PLACEHOLDER_PATTERN.test(token)) return false;
  if (!token.includes('/')) return false;
  if (!/\.[a-z0-9]{1,8}$/i.test(token)) return false;
  if (ADOPTER_OWNED_SENTINELS.has(token)) return false;
  if (GITIGNORED_LOCAL_FILES.has(token)) return false;
  if (RUNTIME_PREFIXES.some((prefix) => token.startsWith(prefix))) return false;
  if (SIBLING_REPO_PATTERN.test(token)) return true;

  return TRACKED_PREFIXES.some((prefix) => token.startsWith(prefix));
};

// A dead citation is a content finding, so this scan takes the shared
// generated-content tier alongside the base, then its own entry above.
//
// `HELP_TEXT` restates the markdown members of these three in prose. Nothing in
// the language couples the two, so a test asserts it in both directions.
const shouldSkipFile = (relPath: string): boolean =>
  isWikiScanExempt(relPath) ||
  isGeneratedContentExempt(relPath) ||
  relPath.startsWith(LOCAL_EXEMPT_PREFIX);

const pathExists = (root: string, candidate: string): boolean => {
  try {
    statSync(path.join(root, candidate));

    return true;
  } catch {
    return false;
  }
};

// A tracked token is dead when it points outside this repo (sibling-monorepo
// segments never resolve on a single-repo clone) or when it simply doesn't
// exist on disk.
const isDeadToken = (cwd: string, token: string): boolean =>
  SIBLING_REPO_PATTERN.test(token) || !pathExists(cwd, token);

type FileContext = {
  cwd: string;
  filePath: string;
};

type ParsedMarker = {
  defect: MarkerDefect | null;
  path: string;
  raw: string;
};

// The payload is split at its first colon so a reason may itself contain one.
// A path carries no colon, which is what makes that split unambiguous.
//
// With a colon, the two defects are told apart by which side of that split
// came back empty. With none, the split cannot say which half was written, so
// the payload's shape decides: every path this scan can exempt contains a `/`,
// since the token scan refuses any token without one, so a payload lacking one
// is a reason and the path is the missing half. A colonless reason that quotes
// a path still reads as a bare path and reports its reason missing; that names
// the wrong half, but the marker still exempts nothing.
// Whitespace does not discriminate the two: a wiki page name routinely carries
// spaces (`wiki/decisions/Code Audit Team.md`), so reading a spaced payload as
// prose would refuse the marker every spaced path needs.
const parseMarker = (match: RegExpExecArray): ParsedMarker => {
  const payload = match[1] ?? '';
  const separator = payload.indexOf(':');
  const declared = (
    separator === -1 ? payload : payload.slice(0, separator)).trim();
  const reason = separator === -1 ? '' : payload.slice(separator + 1).trim();
  const pathless =
    declared === '' || (separator === -1 && !declared.includes('/'));

  return {
    defect:
      pathless ? 'missing-path'
      : reason === '' ? 'missing-reason'
      : null,
    path: declared.normalize('NFC'),
    raw: payload.trim(),
  };
};

const collectFindingsInLine = (
  ctx: FileContext,
  lineNumber: number,
  line: string
): WikiPathScan => {
  // One marker scan per line, and the strip below runs only on the rare line
  // that carries one; this runs over every line of every wiki page.
  const markers = [...line.matchAll(MARKER_PATTERN)].map(parseMarker);
  const report = (matched: ReadonlySet<string>): readonly StaleMarker[] =>
    markers
      .filter((marker) => marker.defect !== null || !matched.has(marker.path))
      .map((marker) => ({
        filePath: ctx.filePath,
        line: lineNumber,
        marker: marker.raw,
        problem: marker.defect ?? ('unused' as const),
      }));

  // A historical bullet suppresses its own line's citations, so a marker there
  // can never exempt anything and is reported rather than silently kept: the
  // early return skips the dead-path collection, not the marker report.
  if (HISTORICAL_BULLET_PATTERN.test(line))
    return {dead: [], staleMarkers: report(new Set())};

  // A malformed marker exempts nothing, so its citation still reports.
  const exempt = new Set(
    markers.filter((marker) => marker.defect === null).map((m) => m.path)
  );
  // Markers are cut from the line before the token scan so a reason may quote
  // a path without that quotation reading as a citation of its own.
  const scanned =
    markers.length === 0 ? line : line.replaceAll(MARKER_PATTERN, ' ');
  const deadTokens = [...scanned.matchAll(PATH_TOKEN_PATTERN)].flatMap(
    (match) => {
      const token = match[1];

      return (
          token !== undefined &&
            isTrackedPath(token) &&
            isDeadToken(ctx.cwd, token)
        ) ?
          [{normalized: token.normalize('NFC'), token}]
        : [];
    }
  );
  const matched = new Set(
    deadTokens
      .filter((found) => exempt.has(found.normalized))
      .map((found) => found.normalized)
  );
  const dead = deadTokens
    .filter((found) => !exempt.has(found.normalized))
    .map((found) => ({
      filePath: ctx.filePath,
      line: lineNumber,
      path: found.token,
    }));

  const staleMarkers = report(matched);

  return {dead, staleMarkers};
};

const collectFindingsInFile = (ctx: FileContext): WikiPathScan => {
  const content = readFileSync(path.join(ctx.cwd, ctx.filePath), 'utf8');
  const lines = content.split('\n');
  const perLine = lines.map((line, index) =>
    collectFindingsInLine(ctx, index + 1, line)
  );

  return {
    dead: perLine.flatMap((found) => found.dead),
    staleMarkers: perLine.flatMap((found) => found.staleMarkers),
  };
};

export const scanWikiPaths = (cwd: string): WikiPathScan => {
  const perFile = collectWikiMarkdown(cwd)
    .filter((filePath) => !shouldSkipFile(filePath))
    .map((filePath) => collectFindingsInFile({cwd, filePath}));

  return {
    dead: perFile.flatMap((found) => found.dead),
    staleMarkers: perFile.flatMap((found) => found.staleMarkers),
  };
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  let json = false;

  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'wiki dead-paths',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const {dead, staleMarkers} = scanWikiPaths(cwd);

    if (json) {
      process.stdout.write(
        `${JSON.stringify({dead, staleMarkers}, null, 2)}\n`
      );

      return EXIT_CODES.OK;
    }

    const lines = [
      ...dead.map((ref) => `${ref.filePath}:${ref.line}  ${ref.path}`),
      ...staleMarkers.map(
        (stale) =>
          `${stale.filePath}:${stale.line}  ${
            STALE_MARKER_LABELS[stale.problem]
          }: ${stale.marker}`
      ),
    ];

    if (lines.length === 0) return EXIT_CODES.OK;

    process.stdout.write(`${lines.join('\n')}\n`);

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'dead_paths_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki dead-paths',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
