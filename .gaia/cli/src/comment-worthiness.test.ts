/**
 * Maintainer guard: the mechanizable floor under the comment-worthiness rule.
 *
 * The rule itself is judgment (the "Comment worthiness" section of the
 * wiki-style rule), and it reduces to one clause: a comment must be about
 * something the file does not contain. Almost none of that is checkable. One
 * part is, and it is the part the audit measured as the only comment class
 * that actually rots: a comment that NAMES something. Across this surface the
 * mechanical detectors found four "restates the line below" instances and nine
 * confirmed drift cases, and every one of the nine was a pointer at a file, a
 * symbol, or a ticket. None of the long causal explanations had drifted.
 *
 * # What is checked
 *
 * Three detectors, ranked by the confidence the audit assigned them:
 *
 * 1. Dead pointers: a backticked path, a ticket id, or a backticked
 *    identifier that resolves to nothing on this surface.
 * 2. The ceremonial docblock opener: a first line assembled out of the
 *    filename's own tokens, which tells a reader nothing the path did not.
 * 3. ASCII section rules: a comment line that is a run of dashes.
 *
 * # Scope boundary, and it is a floor rather than a clean bill of health
 *
 * A backticked token with no internal case boundary is NOT checked. That
 * excludes single-word lowercase tokens, which is where the entire Node, DOM,
 * and npm vocabulary lives, and plain capitalized words, which measured 16
 * distinct ambient globals on this surface (Buffer, Date, Error, Map, Record,
 * Router, Outlet and their siblings) that no declaration or import can
 * resolve. Restricting to the boundary shape (the camelCase and PascalCase
 * shapes, written unbacketed here on purpose so this paragraph does not trip
 * the detector it describes) buys the signal with a small, stable allowlist
 * instead of a large unstable denylist, at the cost of missing a rotted
 * single-word pointer.
 *
 * Two further limits are deliberate. A path pointer whose first segment names
 * no directory in this tree is skipped, because that shape is prose about
 * somewhere else (a sibling repository, an illustrative example) rather than a
 * pointer into this tree, and the cost is that rot inside a directory that was
 * itself deleted goes unseen. And a pointer living in a doc comment on the
 * OTHER side of a rename still resolves whenever some tracked file ends with
 * the named suffix, which is how a partial path like a skill's reference page
 * is written in prose.
 *
 * A third limit is NOT deliberate and is worth knowing before trusting an
 * empty baseline. Backticked spans are paired within a line, so a span that
 * wraps across a line break leaves an odd number of delimiters on each half
 * and shifts every pairing after it. A pointer sitting on such a line is
 * invisible here, and reflowing the paragraph is what exposes it: one dead
 * path survived this file's own baselining that way, and surfaced only when a
 * later sweep rewrapped the sentence around it. Pairing across the whole
 * comment range would close the gap.
 *
 * # Why comments come from the parser
 *
 * Backticked tokens are read out of real comment ranges, not out of raw lines.
 * The scaffold templates on this surface are template literals full of
 * backticked markdown, and a line reader would report every token in generated
 * adopter documentation as a pointer this CLI owns.
 *
 * The ticket and ASCII-rule sub-detectors deliberately do work on raw lines
 * instead, because both are defined against the same comment-shaped-line
 * greps the sweep phases gate on, and matching those greps exactly is what
 * makes this guard and those gates agree.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries neither these sources nor this test, and the corpus
 * assertions skip there. Mirrors `command-reachability.test.ts` and
 * `module-docblock-placement.test.ts`. The fixture tests below carry no skip
 * and run on any clone, because a corpus that happens to be clean would
 * otherwise green a broken detector.
 */
import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';

/** This file's own name, excluded from the walk it drives. */
const GUARD_FILE = 'comment-worthiness.test.ts';

/**
 * File extensions that make a backticked token carrying a `/` a path pointer.
 * Everything else with a slash is prose (a command, a URL, a glob).
 */
const PATH_POINTER_EXTENSIONS: readonly string[] = [
  '.ts',
  '.tsx',
  '.js',
  '.mjs',
  '.cjs',
  '.sh',
  '.bats',
  '.md',
  '.json',
  '.yml',
  '.yaml',
  '.tmpl',
];

/**
 * Paths a comment legitimately names that this tree never contains. Keep this
 * list small and stable: path resolution runs near-zero false positives with
 * it and roughly 90% false positives without one. Every entry states why the
 * path is absent; an unexplained entry is the defect this guard exists to
 * catch. A trailing slash matches a prefix, everything else matches exactly.
 */
const RUNTIME_PATHS: readonly string[] = [
  // Working state (plans, handoffs, per-machine ledgers). Gitignored by design.
  '.gaia/local/',
  // Written by `gaia setup-ci`; absent until an adopter configures CI.
  '.gaia/automation.json',
  // Written by `gaia init` and deleted on finalize.
  '.gaia/init-state.json',
  // Revert ledger a CI run writes; never committed.
  '.gaia/automation.state-revert-attempts.json',
  // Install output.
  'node_modules/',
  // Per-machine settings overlay, gitignored.
  '.claude/settings.local.json',
  // An illustrative example in a docblock about bracket-glob masking, where
  // the whole point is a pair of paths that differ by a metacharacter. Naming
  // a file that exists would destroy the example.
  'docs/notes1.md',
];

/**
 * Basename stems that mark an illustrative example rather than a pointer.
 * A single letter covers the a/b.md shape the same way.
 */
const PLACEHOLDER_STEM = /^(?:foo|bar|baz|qux|[a-z])$/;

/**
 * Characters that make a backticked token a path SHAPE rather than a path:
 * a template slot, a shell fragment, a glob, or a bracketed literal. None of
 * them can be resolved and none of them is a pointer that can rot.
 */
const PATH_SHAPE_CHARACTERS = /[\s<>${}[\]|&*]/;

/**
 * Tokens that carry the case boundary but can never resolve inside
 * `.gaia/cli/src`. Each entry states why, because an unexplained allowlist
 * entry is exactly the defect this guard exists to catch.
 */
const AMBIENT_IDENTIFIERS: readonly string[] = [
  // JavaScript, TypeScript, and Node builtin members. Declared by the runtime.
  'toString',
  'toSorted',
  'indexOf',
  'localeCompare',
  'execSync',
  // Test-framework and test-runner-config vocabulary. Declared by vitest.
  'skipIf',
  'beforeAll',
  'arrayContaining',
  'setupFiles',
  // Compiler, package-manager, and tool config keys. Declared by a config
  // schema this repo consumes, never by a symbol in this workspace.
  'packageManager',
  'allowBuilds',
  'fallbackLng',
  // Third-party symbols and third-party payload keys, named because the
  // comment is about the third party's behavior.
  'safeParse',
  'ZodError',
  'composeStory',
  'expandPackageVersionSpecs',
  'mergePackageVersionSpecs',
  'afterLoad',
  // Symbols owned by the ADOPTER's app rather than by the CLI. This group
  // matters: the CLI's comments legitimately name symbols in another
  // workspace (the app it scaffolds, the language files it rewrites, the
  // framework components it profiles), and by construction none of them can
  // ever resolve here.
  'heroTitle',
  'siteName',
  'runAxe',
  'expectNoA11yViolations',
  'resetTestData',
  'UserSettings',
  'userSettings',
  'UserSetting',
  'userSetting',
  'IndexPage',
  'RenderedRoute',
  'WithComponentProps2',
  'IconBase',
  'ScrollRestoration',
  'HydratedRouter',
  'DataRoutes2',
  'FaGithub',
  'IoDesktopOutline',
  // Placeholder names for a FAMILY of helpers, where the capital X is a
  // wildcard rather than a symbol.
  'tryX',
  'renderXLines',
];

/**
 * Words whose presence in a docblock opener adds nothing the filename already
 * says. An opener built only from these and from the filename's own tokens is
 * ceremony.
 */
const CEREMONY_STOPWORDS: readonly string[] = [
  'a',
  'an',
  'and',
  'as',
  'at',
  'by',
  'for',
  'from',
  'in',
  'into',
  'of',
  'on',
  'or',
  'the',
  'then',
  'to',
  'with',
  'that',
  'this',
  'it',
  'its',
  'is',
  'are',
  'be',
  'gaia',
  'handler',
  'handlers',
  'subcommand',
  'command',
  'router',
  'helper',
  'helpers',
  'util',
  'utils',
  'module',
  'tests',
  'test',
];

/** A ticket id. Working documents get renumbered, superseded, and deleted. */
const TICKET_POINTER = /(?:UAT|SPEC)-\d+/g;

/** A line whose content starts in comment syntax, docblock continuations included. */
const COMMENT_SHAPED_LINE = /^\s*(?:\/\/|\*|\/\*)/;

/**
 * An ASCII section rule.
 *
 * The shell-side equivalent of this pattern must spell the whitespace class
 * as `[[:space:]]`: `git grep -E` does not implement `\s` and returns zero
 * matches rather than erroring, so the shell twin of this check reports a
 * clean corpus while matching nothing at all.
 */
const ASCII_SECTION_RULE = /^\s*\/\/\s*-{20,}/;

type CommentBlock = {readonly line: number; readonly text: string};

type Offense = {readonly line: number; readonly token: string};

type PointerContext = {
  readonly identifiers: ReadonlySet<string>;
  readonly resolvePath: (token: string) => boolean;
};

/**
 * Every comment in a file, as the parser sees them.
 *
 * Each comment is leading trivia of exactly one token, and the end-of-file
 * token carries the trailing ones, so walking every token's leading ranges
 * reaches all of them. Positions are deduplicated because a node and its
 * first token share a full start.
 */
const collectComments = (source: string): readonly CommentBlock[] => {
  const file = ts.createSourceFile(
    'scan.ts',
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS
  );
  const seen = new Set<number>();
  const found: CommentBlock[] = [];

  const visit = (node: ts.Node): void => {
    for (const range of ts.getLeadingCommentRanges(
      source,
      node.getFullStart()
    ) ?? []) {
      if (!seen.has(range.pos)) {
        seen.add(range.pos);
        found.push({
          line: file.getLineAndCharacterOfPosition(range.pos).line + 1,
          text: source.slice(range.pos, range.end),
        });
      }
    }

    for (const child of node.getChildren(file)) visit(child);
  };

  visit(file);

  return found;
};

/**
 * Backticked spans inside one comment, with the line each sits on.
 *
 * A fenced region inside a block comment is skipped: its content is sample
 * code or sample output, so a name in it is quoted material rather than a
 * pointer this file is making.
 */
const backtickedTokens = (comment: CommentBlock): readonly Offense[] => {
  const found: Offense[] = [];
  let fenced = false;

  comment.text.split('\n').forEach((raw, index) => {
    if (
      raw
        .replace(/^\s*\*\s?/, '')
        .trim()
        .startsWith('```')
    ) {
      fenced = !fenced;

      return;
    }

    if (fenced) return;

    for (const match of raw.matchAll(/`([^`\n]+)`/g)) {
      found.push({line: comment.line + index, token: match[1].trim()});
    }
  });

  return found;
};

const isRuntimePath = (token: string): boolean =>
  token === '.env' ||
  token.startsWith('.env.') ||
  RUNTIME_PATHS.some((entry) =>
    entry.endsWith('/') ? token.startsWith(entry) : token === entry
  );

const isPathPointer = (token: string): boolean =>
  token.includes('/') &&
  PATH_POINTER_EXTENSIONS.some((extension) => token.endsWith(extension));

const isIdentifierPointer = (token: string): boolean =>
  /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(token) && /[a-z][A-Z]/.test(token);

/** Whether a path pointer is worth resolving at all. */
const isCheckablePath = (
  token: string,
  knownRoots: ReadonlySet<string>
): boolean => {
  const bare = token.replace(/^\.\//, '');
  const stem = (token.split('/').pop() ?? '').replace(/\.[^.]+$/, '');
  const firstSegment =
    token.replace(/^(?:\.{1,2}\/)+/, '').split('/', 1)[0] ?? '';

  return (
    !PATH_SHAPE_CHARACTERS.test(token) &&
    !PLACEHOLDER_STEM.test(stem) &&
    knownRoots.has(firstSegment) &&
    !isRuntimePath(bare)
  );
};

/**
 * Dead pointers in one file: a path that resolves to nothing, a ticket id on a
 * comment-shaped line, and a backticked identifier that no declaration or
 * import on the scanned surface provides.
 *
 * Ticket ids are matched on raw lines rather than on parsed comments on
 * purpose. This surface holds 25 UAT/SPEC hits that are CODE: test names,
 * fixture literals an assertion reads back, and one shipped help-text
 * template. Reporting those would demand an edit that breaks the suite.
 */
const findDeadPointers = (
  source: string,
  context: PointerContext
): readonly Offense[] => {
  const found: Offense[] = [];

  for (const comment of collectComments(source)) {
    for (const {line, token} of backtickedTokens(comment)) {
      if (isPathPointer(token)) {
        if (!context.resolvePath(token)) found.push({line, token});
      } else if (
        isIdentifierPointer(token) &&
        !context.identifiers.has(token) &&
        !AMBIENT_IDENTIFIERS.includes(token)
      ) {
        found.push({line, token});
      }
    }
  }

  source.split('\n').forEach((raw, index) => {
    if (!COMMENT_SHAPED_LINE.test(raw)) return;

    for (const match of raw.matchAll(TICKET_POINTER)) {
      found.push({line: index + 1, token: match[0]});
    }
  });

  return found;
};

/** Lowercased word tokens of a name, split on separators and case boundaries. */
const wordsOf = (name: string): readonly string[] =>
  name
    .replaceAll(/([a-z0-9])([A-Z])/g, '$1 $2')
    .split(/[^A-Za-z0-9]+/)
    .filter(Boolean)
    .map((word) => word.toLowerCase());

/** The first prose line of a file's leading docblock, or `null` if it has none. */
const leadingDocblockProse = (source: string): null | Offense => {
  const lines = source.split('\n');
  let index = 0;

  while (
    index < lines.length &&
    ((lines[index] ?? '').trim() === '' ||
      (lines[index] ?? '').trim().startsWith('//'))
  ) {
    index += 1;
  }

  const opener = (lines[index] ?? '').trim();

  if (!opener.startsWith('/**')) return null;

  const head = opener.slice(3).replace(/\*\/$/, '').trim();

  if (head !== '') return {line: index + 1, token: head};

  for (let scan = index + 1; scan < lines.length; scan += 1) {
    if ((lines[scan] ?? '').includes('*/')) return null;
    const prose = (lines[scan] ?? '').replace(/^\s*\*\s?/, '').trim();

    if (prose !== '') return {line: scan + 1, token: prose};
  }

  return null;
};

/**
 * A leading docblock whose first line says nothing the path already says.
 *
 * Two shapes qualify: an opener contributing no word outside the filename's
 * own tokens and the stopword set, and the `Tests for` opener, which is the
 * same defect written as a sentence.
 */
const findCeremonialOpener = (
  source: string,
  relative: string
): null | Offense => {
  const opener = leadingDocblockProse(source);

  if (opener === null) return null;

  const prose = opener.token.replaceAll('`', '');

  if (/^Tests for\b/.test(prose)) return {line: opener.line, token: prose};

  const fromName = new Set([
    ...wordsOf(path.basename(relative).replace(/\.ts$/, '')),
    ...wordsOf(path.basename(path.dirname(relative))),
  ]);
  const words = prose
    .toLowerCase()
    .replaceAll(/[^a-z0-9\s]/g, ' ')
    .split(/\s+/)
    .filter(Boolean);
  const novel = words.filter(
    (word) => !fromName.has(word) && !CEREMONY_STOPWORDS.includes(word)
  );

  return words.length > 0 && novel.length === 0 ?
      {line: opener.line, token: prose}
    : null;
};

const findAsciiSectionRules = (source: string): readonly number[] =>
  source
    .split('\n')
    .flatMap((raw, index) => (ASCII_SECTION_RULE.test(raw) ? [index + 1] : []));

/**
 * Names a comment on this surface can legitimately point at: every
 * declaration name, every destructured binding, and every import specifier,
 * plus the member, parameter, and property names a comment names just as
 * often as it names a top-level symbol.
 */
const isDeclarationName = (node: ts.Node): boolean =>
  ts.isVariableDeclaration(node) ||
  ts.isFunctionDeclaration(node) ||
  ts.isClassDeclaration(node) ||
  ts.isTypeAliasDeclaration(node) ||
  ts.isInterfaceDeclaration(node) ||
  ts.isEnumDeclaration(node) ||
  ts.isEnumMember(node) ||
  ts.isBindingElement(node) ||
  ts.isImportSpecifier(node) ||
  ts.isImportClause(node) ||
  ts.isNamespaceImport(node) ||
  ts.isParameter(node) ||
  ts.isPropertySignature(node) ||
  ts.isPropertyDeclaration(node) ||
  ts.isPropertyAssignment(node) ||
  ts.isShorthandPropertyAssignment(node) ||
  ts.isMethodDeclaration(node) ||
  ts.isMethodSignature(node) ||
  ts.isGetAccessor(node) ||
  ts.isSetAccessor(node);

const collectIdentifiers = (source: string, into: Set<string>): void => {
  const file = ts.createSourceFile(
    'scan.ts',
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS
  );

  const visit = (node: ts.Node): void => {
    const named = node as ts.Node & {readonly name?: ts.Node};

    if (
      named.name !== undefined &&
      ts.isIdentifier(named.name) &&
      isDeclarationName(node)
    ) {
      into.add(named.name.text);
    }

    ts.forEachChild(node, visit);
  };

  visit(file);
};

/**
 * The baselines below are the corpus as it stands, seeded by running these
 * detectors. Entries come OUT as the sweep phases remove the offenses and are
 * never added by hand after this file lands: a new key is a new offense and
 * the first assertion reds on it immediately.
 *
 * A key carries no line number, deliberately. A positional key goes stale the
 * moment any earlier comment in the same file is deleted, and the sweep
 * guarantees that: one phase condenses the leading docblock of a file whose
 * inline blocks a later phase rewrites.
 *
 * The cost of file granularity is real and transient. A key does not notice a
 * file dropping from eleven rule lines to three, nor a SECOND dead token in a
 * file already baselined for a different one (a genuinely new token does red,
 * because the token is part of the key). Every baselined file is swept to zero
 * in this same pull request, so the lists empty and the gap closes with them.
 */
const BASELINE_DEAD_POINTERS: readonly string[] = [];

/** Same ratchet, same key discipline. See the note above. */
const BASELINE_CEREMONIAL: readonly string[] = [];

/** Same ratchet, same key discipline. See the note above. */
const BASELINE_ASCII_RULES: readonly string[] = [];

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const sourcesPresent = existsSync(cliSrc);

/**
 * Every tracked `.ts` on the scanned surface, minus two exclusions.
 *
 * A `templates/` directory is excluded as a FORWARD guard: no `.ts` file lives
 * under one today, and those files are rendered verbatim into an adopter's
 * workflows, so a report on one would demand an edit to an adopter artifact.
 *
 * This file excludes itself, and that exclusion is load-bearing rather than
 * tidy. The fixtures below necessarily hold a ticket literal and backticked
 * shape names, so without it the guard reports itself forever and the sweep
 * phases' acceptance gates become unsatisfiable.
 */
const collectSourceFiles = (root: string): readonly string[] =>
  (readdirSync(root, {recursive: true}) as string[])
    .filter(
      (entry) =>
        entry.endsWith('.ts') &&
        !entry.split(path.sep).includes('templates') &&
        entry !== GUARD_FILE
    )
    .toSorted((a, b) => a.localeCompare(b));

/**
 * A resolver over the tracked file set.
 *
 * Three shapes resolve: the path as written, the path relative to the file
 * naming it, and any tracked file ending with the named suffix, which is how
 * prose writes a partial path. A `.js` specifier also resolves against its
 * TypeScript twin, because NodeNext imports name the emitted file.
 */
const makePathResolver = (
  tracked: readonly string[],
  relative: string
): ((token: string) => boolean) => {
  const trackedSet = new Set(tracked);
  const knownRoots = new Set(
    tracked.map((entry) => entry.split('/', 1)[0] ?? '')
  );

  for (const entry of tracked) {
    if (entry.startsWith('.gaia/cli/src/')) {
      knownRoots.add(
        entry.slice('.gaia/cli/src/'.length).split('/', 1)[0] ?? ''
      );
    }
  }

  const directory = path.posix.dirname(
    path.posix.join('.gaia/cli/src', relative)
  );

  return (token) => {
    if (!isCheckablePath(token, knownRoots)) return true;

    const candidates = new Set<string>();

    const add = (candidate: string): void => {
      candidates.add(candidate);

      if (/\.(?:js|mjs|cjs)$/.test(candidate)) {
        candidates.add(candidate.replace(/\.[a-z]+$/, '.ts'));
        candidates.add(candidate.replace(/\.[a-z]+$/, '.tsx'));
      }
    };

    add(path.posix.normalize(token.replace(/^\.\//, '')));
    add(path.posix.normalize(path.posix.join(directory, token)));

    return [...candidates].some(
      (candidate) =>
        trackedSet.has(candidate) ||
        tracked.some((entry) => entry.endsWith(`/${candidate}`))
    );
  };
};

/**
 * The ratchet: two set-membership assertions, and it can only shrink.
 *
 * The failure message carries the `path:line` sites even though the key does
 * not, because the sites are what a human uses to find the offense.
 */
const assertRatchet = (
  baseline: readonly string[],
  detected: ReadonlyMap<string, readonly string[]>
): void => {
  const unexpected = [...detected.entries()]
    .filter(([key]) => !baseline.includes(key))
    .map(([key, sites]) => `${key} (${sites.join(', ')})`);

  expect(unexpected).toEqual([]);

  const stale = baseline.filter((key) => !detected.has(key));

  expect(stale).toEqual([]);
};

const record = (
  into: Map<string, readonly string[]>,
  key: string,
  site: string
): void => {
  into.set(key, [...(into.get(key) ?? []), site]);
};

const trackedFiles = (): readonly string[] =>
  execFileSync('git', ['ls-files', '-z'], {
    cwd: repoRoot,
    maxBuffer: 64 * 1024 * 1024,
  })
    .toString('utf8')
    .split('\0')
    .filter(Boolean);

describe('comment worthiness', () => {
  // Maintainer-only guard: `sourcesPresent` is false on an adopter clone,
  // where `.gaia/cli/src` is release-excluded.
  test.skipIf(!sourcesPresent)('no new dead pointer', () => {
    const sources = collectSourceFiles(cliSrc);

    // A scan that reaches nothing reports nothing, so an empty result would
    // read as a clean corpus. A count this low means the walk broke.
    expect(sources.length).toBeGreaterThan(50);

    const tracked = trackedFiles();
    const identifiers = new Set<string>();
    const texts = new Map<string, string>();

    for (const relative of sources) {
      const source = readFileSync(path.join(cliSrc, relative), 'utf8');

      texts.set(relative, source);
      collectIdentifiers(source, identifiers);
    }

    const detected = new Map<string, readonly string[]>();

    for (const relative of sources) {
      const repoPath = `.gaia/cli/src/${relative}`;
      const offenses = findDeadPointers(texts.get(relative) ?? '', {
        identifiers,
        resolvePath: makePathResolver(tracked, relative),
      });

      for (const {line, token} of offenses) {
        record(detected, `${repoPath}#${token}`, `${repoPath}:${line}`);
      }
    }

    assertRatchet(BASELINE_DEAD_POINTERS, detected);
  });

  test.skipIf(!sourcesPresent)('no new ceremonial docblock opener', () => {
    const sources = collectSourceFiles(cliSrc);

    expect(sources.length).toBeGreaterThan(50);

    const detected = new Map<string, readonly string[]>();

    for (const relative of sources) {
      const repoPath = `.gaia/cli/src/${relative}`;
      const opener = findCeremonialOpener(
        readFileSync(path.join(cliSrc, relative), 'utf8'),
        relative
      );

      if (opener !== null)
        record(detected, repoPath, `${repoPath}:${opener.line}`);
    }

    assertRatchet(BASELINE_CEREMONIAL, detected);
  });

  test.skipIf(!sourcesPresent)('no new ASCII section rule', () => {
    const sources = collectSourceFiles(cliSrc);

    expect(sources.length).toBeGreaterThan(50);

    const detected = new Map<string, readonly string[]>();

    for (const relative of sources) {
      const repoPath = `.gaia/cli/src/${relative}`;
      const lines = findAsciiSectionRules(
        readFileSync(path.join(cliSrc, relative), 'utf8')
      );

      for (const line of lines)
        record(detected, repoPath, `${repoPath}:${line}`);
    }

    assertRatchet(BASELINE_ASCII_RULES, detected);
  });

  // No `skipIf` from here down: the fixtures run against string literals, so
  // they hold on any clone and they are what establish that each detector can
  // report at all.
  const noPointers: PointerContext = {
    identifiers: new Set(['declared', 'realHelper']),
    resolvePath: () => false,
  };
  const allPathsResolve: PointerContext = {
    identifiers: new Set(['declared', 'realHelper']),
    resolvePath: () => true,
  };

  test('reports a backticked path that resolves to nothing', () => {
    const source = [
      '/** Port of `.gaia/scripts/gone.mjs`. */',
      'export const a = 1;',
    ].join('\n');

    expect(findDeadPointers(source, noPointers)).toEqual([
      {line: 1, token: '.gaia/scripts/gone.mjs'},
    ]);
  });

  test('accepts a backticked path that resolves', () => {
    const source = [
      '/** Port of `.gaia/scripts/here.mjs`. */',
      'export const a = 1;',
    ].join('\n');

    expect(findDeadPointers(source, allPathsResolve)).toEqual([]);
  });

  test('reports a ticket id on a comment-shaped line', () => {
    const source = [
      '/**',
      ' * Deep-merge helper for the sandbox verb (UAT-007).',
      ' */',
      'export const a = 1;',
    ].join('\n');

    expect(findDeadPointers(source, allPathsResolve)).toEqual([
      {line: 2, token: 'UAT-007'},
    ]);
  });

  // The near miss that matters most: 25 of this surface's ticket hits are
  // CODE. A test name, a fixture literal an assertion reads back, and one
  // shipped help-text template all carry the same digits, and editing any of
  // them breaks the suite.
  test('ignores a ticket id that is code rather than a comment', () => {
    const source = [
      "test('UAT-007 merges settings', () => {",
      "  expect(id).toBe('SPEC-030');",
      '});',
    ].join('\n');

    expect(findDeadPointers(source, allPathsResolve)).toEqual([]);
  });

  test('reports a backticked identifier that no declaration provides', () => {
    const source = [
      '// Mirrors `deletedHelper` in the other module.',
      'export const a = 1;',
    ].join('\n');

    expect(findDeadPointers(source, allPathsResolve)).toEqual([
      {line: 1, token: 'deletedHelper'},
    ]);
  });

  test('accepts a backticked identifier the surface declares', () => {
    const source = [
      '// Mirrors `realHelper` in the other module.',
      'export const a = 1;',
    ].join('\n');

    expect(findDeadPointers(source, allPathsResolve)).toEqual([]);
  });

  // The scope boundary, pinned so a later widening is deliberate rather than
  // accidental: a token with no internal case boundary is not checked, which
  // is where the whole Node, DOM, and npm vocabulary sits.
  test('does not check a token with no internal case boundary', () => {
    const source = [
      '// Uses `dirname` and `Buffer`, neither declared here.',
      'export const a = 1;',
    ].join('\n');

    expect(findDeadPointers(source, allPathsResolve)).toEqual([]);
  });

  test('does not check a name quoted inside a fenced example', () => {
    const source = [
      '/**',
      ' * Example:',
      ' *',
      ' * ```ts',
      ' * const x = someOtherThing();',
      ' * ```',
      ' */',
      'export const a = 1;',
    ].join('\n');

    expect(findDeadPointers(source, allPathsResolve)).toEqual([]);
  });

  test('reports a Tests for opener', () => {
    const source = ['/**', ' * Tests for `gaia wiki state`.', ' */', ''].join(
      '\n'
    );

    expect(findCeremonialOpener(source, 'wiki/state.test.ts')?.line).toBe(2);
  });

  test('reports an opener assembled from the filename', () => {
    const source = ['/**', ' * `gaia wiki diff-size` handler.', ' */', ''].join(
      '\n'
    );

    expect(findCeremonialOpener(source, 'wiki/diff-size.ts')?.line).toBe(2);
  });

  // The strongest docblocks in the corpus open on something outside the file,
  // and reporting them would invert the standard this guard serves.
  test('accepts an opener naming something outside the file', () => {
    const source = [
      '/**',
      ' * Reads `git status --porcelain -z`, whose NUL framing is the only',
      ' * form that survives a filename containing a newline.',
      ' */',
      '',
    ].join('\n');

    expect(findCeremonialOpener(source, 'util/git-status.ts')).toBeNull();
  });

  test('ignores a file with no leading docblock', () => {
    const source = [
      "import fs from 'node:fs';",
      '',
      'export const a = 1;',
    ].join('\n');

    expect(findCeremonialOpener(source, 'util/thing.ts')).toBeNull();
  });

  // Composed rather than written out, so no line of THIS file begins with a
  // rule: the sweep phases gate on that pattern returning empty, and a
  // literal fixture would make their gates permanently unsatisfiable.
  test('reports an ASCII section rule', () => {
    const source = ['export const a = 1;', `// ${'-'.repeat(24)} Types`].join(
      '\n'
    );

    expect(findAsciiSectionRules(source)).toEqual([2]);
  });

  test('accepts a short dash run that is not a rule', () => {
    const source = [
      'export const a = 1;',
      `// ${'-'.repeat(5)} not a rule`,
    ].join('\n');

    expect(findAsciiSectionRules(source)).toEqual([]);
  });

  // Pins the self-exclusion. The ticket fixture above guarantees this file
  // holds a ticket literal, and the shape fixtures guarantee it holds
  // backticked names; the sweep phases' gates depend on none of it being
  // reported. The path resolver fails every path, so this also asserts the
  // file names no path pointer at all, which keeps the check independent of
  // whatever tree it runs in.
  test('this guard reports no offense against itself', () => {
    const own = readFileSync(fileURLToPath(import.meta.url), 'utf8');
    const identifiers = new Set<string>();

    collectIdentifiers(own, identifiers);

    expect(
      findDeadPointers(own, {identifiers, resolvePath: () => false})
    ).toEqual([]);
    expect(findCeremonialOpener(own, GUARD_FILE)).toBeNull();
    expect(findAsciiSectionRules(own)).toEqual([]);
  });
});
