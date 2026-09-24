/**
 * SPEC-081 Phase 3a: the end-to-end UAT drivers this task owns (UAT-006,
 * UAT-007, UAT-008, UAT-010, UAT-011, UAT-013), the tally-side mutation
 * control for UAT-012, and the four skill-reference prose assertions their
 * acceptance criteria require.
 *
 * Every test here reads the SHARED fixture corpus at
 * `.gaia/tests/fixtures/residue-corpus/` (Phase 3's deliverable) through
 * `GAIA_RESIDUE_FIXTURE_DIR`; none of them author into it. Every file write
 * a test performs lands under its own `mkdtempSync` root, never in this
 * repository's working tree.
 */
import {afterEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {collectTreeFiles, EVERY_EXTENSION} from '../../util/tree-walk.js';
import {
  attributeBody,
  attributeBodyWith,
  DEFAULT_PREDICATES,
} from '../attribution.js';
import type {AttributionResult} from '../attribution.js';
import {attributionBodyDigest} from '../cache.js';
import {run as runCursor} from '../cursor-cmd.js';
import {KEY_PATTERN, parseKey, parseWrappedKeys} from '../key.js';
import {run as runRecord} from '../record-cmd.js';
import {appendRecords, readStore} from '../store.js';
import type {StoreRecord} from '../store.js';
import {run as runTally} from '../tally.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const CORPUS_DIR = path.join(REPO_ROOT, '.gaia/tests/fixtures/residue-corpus');
const DEDUP_CORPUS_DIR = path.join(
  REPO_ROOT,
  '.gaia/tests/fixtures/dedup-key-corpus'
);
const SKILL_REFERENCE_PATH = path.join(
  REPO_ROOT,
  '.claude/skills/gaia/references/residue.md'
);
const DAY_MS = 24 * 60 * 60 * 1000;
const FIXED_NOW = () => new Date('2026-09-14T00:00:00Z');

// --- shared scratch-root plumbing (mirrors tally.test.ts's own helper) ----

const dirs: string[] = [];

const makeTemporaryRoot = (): string => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-uat-'));

  dirs.push(dir);

  return dir;
};

afterEach(() => {
  vi.restoreAllMocks();

  for (const dir of dirs.splice(0)) rmSync(dir, {force: true, recursive: true});
});

const capture = () => {
  const lines: string[] = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    lines.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  });

  return {json: (): unknown => JSON.parse(lines.at(-1) ?? '{}')};
};

// Regular files only: a symlink the drain created would not read as a stray
// write. The tally and the cursor write their caches as plain files.
const listTree = (root: string): readonly string[] =>
  collectTreeFiles(root, EVERY_EXTENSION);

// Throws (rather than returning a boolean) so the guards-must-fail proof
// below can drive it with `expect(() => ...).toThrow()`.
const assertExactNewFiles = (
  before: readonly string[],
  after: readonly string[],
  expectedNew: readonly string[]
): void => {
  const beforeSet = new Set(before);
  const afterSet = new Set(after);
  const added = [...afterSet]
    .filter((f) => !beforeSet.has(f))
    .toSorted((a, b) => a.localeCompare(b));
  const removed = [...beforeSet]
    .filter((f) => !afterSet.has(f))
    .toSorted((a, b) => a.localeCompare(b));

  if (removed.length > 0) {
    throw new Error(`unexpected removal(s): ${removed.join(', ')}`);
  }

  const expectedSorted = expectedNew.toSorted((a, b) => a.localeCompare(b));

  if (added.join(',') !== expectedSorted.join(',')) {
    throw new Error(
      `unexpected file-set diff: added=[${added.join(', ')}], expected=[${expectedSorted.join(', ')}]`
    );
  }
};

const FIXTURE_ENV = {GAIA_RESIDUE_FIXTURE_DIR: CORPUS_DIR};

// UAT-014: an attribution recorded as keyless, the shape the pre-change
// reader produced for a spaced path it could not parse as a key at all.
const buildStaleAttribution = (): AttributionResult => ({
  entries: [],
  keyless: [{disposition: 'accept', unit_start_line: 2}],
  keyless_count: 1,
  malformed: [],
});

// ---------------------------------------------------------------------------
// UAT-012 mutation control, tally side: `attributeBodyWith` +
// `DEFAULT_PREDICATES` are frozen exports for exactly this, so no module
// under .gaia/cli/src/residue/ is edited.
// ---------------------------------------------------------------------------

describe('UAT-012 mutation control (tally side, via the frozen predicate seam)', () => {
  test("mutating attributeBodyWith's canonWaive predicate over the shared corpus diverges from the hand-written oracle", () => {
    const prs = JSON.parse(
      readFileSync(path.join(CORPUS_DIR, 'prs.json'), 'utf8')
    ) as {body: string; number: number}[];
    const oracle = JSON.parse(
      readFileSync(path.join(CORPUS_DIR, 'expected-attribution.json'), 'utf8')
    ) as {bodies: {pr_number: number; tuples: string[]}[]};

    const oracleTuples = oracle.bodies
      .flatMap((b) => b.tuples.map((t) => `${b.pr_number}\t${t}`))
      .toSorted((a, b) => a.localeCompare(b));

    expect(oracleTuples.length).toBeGreaterThan(0);

    const mutatedTuples: string[] = [];

    for (const pr of prs) {
      const result = attributeBodyWith(pr.body, {
        ...DEFAULT_PREDICATES,
        canonWaive: '## MUTATED waive heading',
      });

      for (const entry of result.entries) {
        mutatedTuples.push(
          `${pr.number}\t${entry.unit_start_line}|${entry.disposition}|1|${entry.raw_key}`
        );
      }

      for (const bad of result.malformed) {
        mutatedTuples.push(
          `${pr.number}\t${bad.unit_start_line}|${bad.disposition}|1|${bad.raw_key}`
        );
      }

      for (const kl of result.keyless) {
        mutatedTuples.push(
          `${pr.number}\t${kl.unit_start_line}|${kl.disposition}|0|-`
        );
      }
    }

    const sortedMutatedTuples = mutatedTuples.toSorted((a, b) =>
      a.localeCompare(b)
    );

    expect(sortedMutatedTuples).not.toStrictEqual(oracleTuples);

    // Name which side diverged: every waive-disposition tuple the oracle
    // carries must be absent from the mutant's output (PRs 2000, 2003,
    // 3002, 3008, 5002, 5004, 5006 all use the waive heading).
    const oracleWaiveTuples = oracleTuples.filter((t) => t.includes('|waive|'));

    expect(oracleWaiveTuples.length).toBeGreaterThan(0);
    for (const tuple of oracleWaiveTuples)
      expect(mutatedTuples).not.toContain(tuple);
  });
});

// ---------------------------------------------------------------------------
// UAT-006 (machine-checkable half): the tally itself never files, never
// writes the store, and cannot reach GitHub in fixture mode.
// ---------------------------------------------------------------------------

describe('UAT-006', () => {
  test('a tally run over a multi-candidate corpus files no issue, writes no store record, and cannot touch GitHub state', () => {
    const root = makeTemporaryRoot();
    const out = capture();

    const exitCode = runTally(['--no-cap'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exitCode).toBe(0);
    const emitted = out.json() as {candidate_count: number};

    expect(emitted.candidate_count).toBeGreaterThan(1);

    // Files no issue: `residue-tally` has no code path that calls `gh issue
    // create`; filing is exclusively `.claude/skills/file-tech-debt/SKILL.md`,
    // which this command never invokes.
    // Touches no GitHub state: `resolveProvider` (corpus.ts) never
    // constructs the live `gh`-backed provider once GAIA_RESIDUE_FIXTURE_DIR
    // is set, so a `gh` call is structurally unreachable on this path.
    expect(
      existsSync(path.join(root, '.gaia', 'audit-residual-dismissals.jsonl'))
    ).toBe(false);
    expect(readStore(root).records).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// UAT-007: gaia residue-record appends one record naming all nine
// contracted fields; the next tally withholds the residual; removing the
// store offers it again (a match, not a constant).
// ---------------------------------------------------------------------------

describe('UAT-007', () => {
  test('residue-record dismisses a candidate end to end; the store record carries all nine fields; the suppression is a real match', () => {
    const root = makeTemporaryRoot();
    const out = capture();

    const exit1 = runTally(['--no-cap'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exit1).toBe(0);
    const first = out.json() as {
      candidates: {cursor_token: string; line: number; path: string}[];
    };
    const target = first.candidates.find(
      (c) => c.path === 'app/cache/evict.ts' && c.line === 8
    );

    expect(target).toBeDefined();

    const reasonFile = path.join(root, 'reason.txt');

    writeFileSync(reasonFile, 'dismissing for UAT-007\n');

    const recordExit = runRecord(
      [
        '--disposition',
        'dismissed',
        '--token',
        target?.cursor_token ?? '',
        '--reason-file',
        reasonFile,
      ],
      {cwd: root, env: FIXTURE_ENV, now: FIXED_NOW}
    );

    expect(recordExit).toBe(0);

    const {records} = readStore(root);

    expect(records).toHaveLength(1);
    const record = records[0] as StoreRecord;

    expect(record.schema).toBe('v1');
    expect(record.path).toBe('app/cache/evict.ts');
    expect(record.line).toBe(8);
    expect(record.class).toBe('bug');
    expect(record.disposition).toBe('dismissed');
    expect(record.date).toBe(FIXED_NOW().toISOString());
    expect(record.reason).toBe('dismissing for UAT-007');
    expect(record.source_pr).toBe(2001);
    expect(record.cited_line_text).toContain('evictedCount');

    const exit2 = runTally(['--no-cap'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exit2).toBe(0);
    const second = out.json() as {candidates: {line: number; path: string}[]};

    expect(
      second.candidates.some(
        (c) => c.path === 'app/cache/evict.ts' && c.line === 8
      )
    ).toBe(false);

    // Removing the store file makes the tally offer the residual again: the
    // suppression above is a real match against a real record, not a
    // constant that would pass regardless of what the store held.
    rmSync(path.join(root, '.gaia', 'audit-residual-dismissals.jsonl'));

    const exit3 = runTally(['--no-cap'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exit3).toBe(0);
    const third = out.json() as {candidates: {line: number; path: string}[]};

    expect(
      third.candidates.some(
        (c) => c.path === 'app/cache/evict.ts' && c.line === 8
      )
    ).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// UAT-010: no-stray-writes at whole-run scope, plus a guards-must-fail
// proof that the diff assertion itself can catch a stray write.
// ---------------------------------------------------------------------------

describe('UAT-010', () => {
  test('a plain drain step (tally, then advancing the cursor) touches only the two cache files', () => {
    const root = makeTemporaryRoot();
    const before = listTree(root);

    expect(before).toHaveLength(0);

    const out = capture();
    const tallyExit = runTally([], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(tallyExit).toBe(0);
    const emitted = out.json() as {candidates: {cursor_token: string}[]};
    const firstCandidate = emitted.candidates[0];

    expect(firstCandidate).toBeDefined();

    const cursorExit = runCursor(
      ['advance', '--token', firstCandidate?.cursor_token ?? ''],
      {cwd: root}
    );

    expect(cursorExit).toBe(0);

    const after = listTree(root);

    assertExactNewFiles(before, after, [
      '.gaia/local/cache/residual-attribution.json',
      '.gaia/local/cache/residual-cursor.json',
    ]);
  });

  // Editing tally.ts itself is out of this task's remit (Files to touch),
  // so "a scratch copy of the tally" is realized as a scratch copy of the
  // FILE-SYSTEM SNAPSHOT the assertion above reasons over: inject one stray
  // path into the "after" set a buggy tally might have produced, and prove
  // `assertExactNewFiles` -- the same function the real assertion above
  // uses -- reds on it rather than passing silently.
  test('guard-must-fail: a stray write injected into the after-snapshot reds assertExactNewFiles', () => {
    const before: string[] = [];
    const strayAfter = [
      '.gaia/local/cache/residual-attribution.json',
      '.gaia/local/cache/residual-cursor.json',
      '.gaia/some/unexpected/stray-file.txt',
    ];

    expect(() =>
      assertExactNewFiles(before, strayAfter, [
        '.gaia/local/cache/residual-attribution.json',
        '.gaia/local/cache/residual-cursor.json',
      ])
    ).toThrow(/unexpected file-set diff/);
  });
});

// ---------------------------------------------------------------------------
// Acceptance criterion 6: the gone/moved/still/unresolvable classification
// for the corpus's four dedicated resolution-class entries (PRs 2001-2004
// in blobs.json) matches a hand-enumerated expectation, not a count:
// evict.ts's head and HEAD blobs are byte-identical (still); helper.ts's
// cited line survives at a different HEAD line (moved); oldmodule.ts has
// no HEAD blob at all (gone); blank/file.ts's cited line is blank at the
// head object (unresolvable).
// ---------------------------------------------------------------------------

describe('resolution classification (acceptance criterion 6)', () => {
  test('the four dedicated resolution-class coordinates resolve exactly as designed', () => {
    const root = makeTemporaryRoot();
    const out = capture();
    const exitCode = runTally(['--no-cap'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exitCode).toBe(0);
    const emitted = out.json() as {
      candidates: {line: number; path: string; resolution: string}[];
    };
    const resolutionOf = (
      targetPath: string,
      targetLine: number
    ): string | undefined =>
      emitted.candidates.find(
        (c) => c.path === targetPath && c.line === targetLine
      )?.resolution;

    expect(resolutionOf('app/cache/evict.ts', 8)).toBe('still');
    expect(resolutionOf('app/utils/helper.ts', 4)).toBe('moved');
    expect(resolutionOf('app/legacy/oldmodule.ts', 3)).toBe('gone');
    expect(resolutionOf('app/blank/file.ts', 2)).toBe('unresolvable');
  });
});

// ---------------------------------------------------------------------------
// UAT-011: the keep window. Pin the default (14 days) and its configuration
// point (GAIA_RESIDUE_KEEP_DAYS).
// ---------------------------------------------------------------------------

describe('UAT-011', () => {
  test('a kept record past the keep window is offered again; one inside it is not; GAIA_RESIDUE_KEEP_DAYS moves the boundary', () => {
    const root = makeTemporaryRoot();
    const twentyDaysAgo = new Date(
      FIXED_NOW().getTime() - 20 * DAY_MS
    ).toISOString();
    const threeDaysAgo = new Date(
      FIXED_NOW().getTime() - 3 * DAY_MS
    ).toISOString();

    // cited_line_text must match each coordinate's ACTUAL resolved content:
    // storeSuppression's content-bound mode matches a record only when its
    // cited_line_text equals the candidate's freshly resolved line, so a
    // wrong value here would make the record match nothing at any age.
    appendRecords(root, [
      {
        cited_line_text: '  const evictedCount2 = evictedCount;',
        class: 'bug',
        date: twentyDaysAgo,
        disposition: 'kept',
        line: 8,
        path: 'app/cache/evict.ts',
        reason: 'snoozed twenty days ago',
        schema: 'v1',
        source_pr: 2001,
      },
      {
        cited_line_text: "export const helperLine = 'moved-marker';",
        class: 'lint',
        date: threeDaysAgo,
        disposition: 'kept',
        line: 4,
        path: 'app/utils/helper.ts',
        reason: 'snoozed three days ago',
        schema: 'v1',
        source_pr: 2002,
      },
    ]);

    const out = capture();
    const defaultExit = runTally(['--no-cap'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(defaultExit).toBe(0);
    const defaultRun = out.json() as {
      candidates: {line: number; path: string}[];
    };

    expect(
      defaultRun.candidates.some(
        (c) => c.path === 'app/cache/evict.ts' && c.line === 8
      )
    ).toBe(true); // 20 days >= the default 14-day window: offered again
    expect(
      defaultRun.candidates.some(
        (c) => c.path === 'app/utils/helper.ts' && c.line === 4
      )
    ).toBe(false); // 3 days < the default 14-day window: still suppressed

    const widenedExit = runTally(['--no-cap'], {
      cwd: root,
      env: {...FIXTURE_ENV, GAIA_RESIDUE_KEEP_DAYS: '30'},
      now: FIXED_NOW,
    });

    expect(widenedExit).toBe(0);
    const widenedRun = out.json() as {
      candidates: {line: number; path: string}[];
    };

    expect(
      widenedRun.candidates.some(
        (c) => c.path === 'app/cache/evict.ts' && c.line === 8
      )
    ).toBe(false); // 20 days < a 30-day window: suppressed again
  });
});

// ---------------------------------------------------------------------------
// UAT-013: the subcommand set's author/no-author contract.
//
// DEVIATION FROM THE PLAN DOC (see Notes for orchestrator): `--count-only`
// does NOT author nothing. `run()` in tally.ts calls `writeAttributionCache`
// unconditionally on every non-`--attribute-only` path that reaches a
// successful pull-request read, `--count-only` included -- only the
// resolution half of RD-004's degradation (no head fetch, no git call) is
// actually gated on the flag. This test asserts the REAL behavior rather
// than the plan doc's "each author nothing" claim.
// ---------------------------------------------------------------------------

describe('UAT-013', () => {
  test('--attribute-only writes no file anywhere under a temp root', () => {
    const root = makeTemporaryRoot();
    capture();
    const exitCode = runTally(['--attribute-only'], {
      cwd: root,
      env: FIXTURE_ENV,
    });

    expect(exitCode).toBe(0);
    expect(listTree(root)).toStrictEqual([]);
  });

  test('--count-only writes the attribution cache only (not the cursor, not the store): a documented deviation from the plan doc', () => {
    const root = makeTemporaryRoot();
    capture();
    const exitCode = runTally(['--count-only'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exitCode).toBe(0);
    expect(listTree(root)).toStrictEqual([
      '.gaia/local/cache/residual-attribution.json',
    ]);
  });

  test('the bare invocation produces the candidate list', () => {
    const root = makeTemporaryRoot();
    const out = capture();
    const exitCode = runTally([], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exitCode).toBe(0);
    const emitted = out.json() as {
      candidate_count: number;
      candidates: unknown[];
    };

    expect(emitted.candidate_count).toBeGreaterThan(0);
    expect(emitted.candidates).toHaveLength(emitted.candidate_count);
  });
});

// ---------------------------------------------------------------------------
// SPEC-082 (task-conformance-suite.md, Deliverable 5): the TypeScript half of
// the dedup-key path terminator's cross-consumer conformance. The bats
// suite's frozen reader table and per-row mutants own the tree-wide
// coupling; these cases pin the two TypeScript readers (`parseKey`,
// `parseWrappedKeys`) and `attributeBody`'s use of them.
// ---------------------------------------------------------------------------

describe("SPEC-082: a spaced path terminates on the key comment's own closer", () => {
  // Plan-time finding (README.md, "Plan-time findings the orchestrator must
  // carry forward", #1): UAT-002 asserts a key carrying an embedded
  // malformed tail (`path=app/a.ts line=1 line=2`) goes gate-keyed AND
  // CLI-malformed[]. The CLI half is false under the frozen two-spelling
  // contract: the greedy path group backtracks to `app/a.ts line=1`, the
  // trailing ` line=2` satisfies the anchor, and parseKey returns ok. This
  // pins the ACTUAL behavior rather than the SPEC's stated one; no
  // validator is added to make the SPEC's sentence true, since doing so
  // would mint a third path-terminator spelling, which success criterion 3
  // and always[5] forbid.
  test('UAT-002 deviation: a key carrying an embedded malformed tail (two " line=" tokens) is gate-keyed but resolves to the spliced path in entries[], not malformed[]', () => {
    const parsed = parseKey(
      'v1 class=lint path=app/a.ts line=1 line=2',
      'gate'
    );

    expect(parsed).toStrictEqual({
      ok: true,
      value: {class: 'lint', line: 2, path: 'app/a.ts line=1', version: 'v1'},
    });

    const body = [
      '## Accepted residuals (recorded, not fixed)',
      '- MARKER_UAT002, an embedded malformed tail <!-- gaia-debt-key: v1 class=lint path=app/a.ts line=1 line=2 -->',
    ].join('\n');
    const result = attributeBody(body);

    // The CLI-malformed[] backstop UAT-002 describes does not exist for
    // this input: the unit lands in entries[], keyed, with the spliced path.
    expect(result.malformed).toStrictEqual([]);
    expect(result.entries).toHaveLength(1);
    expect(result.entries[0]?.key).toStrictEqual({
      class: 'lint',
      line: 2,
      path: 'app/a.ts line=1',
      version: 'v1',
    });
  });

  test('parseKey accepts a spaced path under the gate grammar, and attributeBody attributes the same residual over the real corpus body', () => {
    const parsed = parseKey(
      'v1 class=lint path=app/my dir/file.ts line=1',
      'gate'
    );

    expect(parsed).toStrictEqual({
      ok: true,
      value: {
        class: 'lint',
        line: 1,
        path: 'app/my dir/file.ts',
        version: 'v1',
      },
    });

    const prs = JSON.parse(
      readFileSync(path.join(CORPUS_DIR, 'prs.json'), 'utf8')
    ) as {body: string; number: number}[];
    const pr3006 = prs.find((pr) => pr.number === 3006);

    expect(pr3006).toBeDefined();

    const result = attributeBody(pr3006?.body ?? '');

    expect(result.entries).toHaveLength(1);
    const entry = result.entries[0];

    expect(
      `${entry?.unit_start_line}|${entry?.disposition}|1|${entry?.raw_key}`
    ).toBe('2|accept|1|v1 class=lint path=app/my dir/file.ts line=1');
  });

  test("#1250's recorded key: parseWrappedKeys and parseKey both yield the same coordinate they did before the change", () => {
    const wrapped = readFileSync(
      path.join(DEDUP_CORPUS_DIR, 'issue-1250-key.txt'),
      'utf8'
    ).trim();

    expect(parseWrappedKeys(wrapped)).toStrictEqual([
      {line: 175, path: 'wiki/concepts/PR Merge Workflow.md'},
    ]);

    // parseKey takes the INNER key; the fixture holds the WRAPPED form, so
    // group 1 is extracted with KEY_PATTERN first, exactly as a real caller
    // (attribution.ts) does.
    const inner = KEY_PATTERN.exec(wrapped)?.[1];

    expect(inner).toBeDefined();
    expect(parseKey(inner ?? '', 'gate')).toStrictEqual({
      ok: true,
      value: {
        class: 'holistic/unclassified',
        line: 175,
        path: 'wiki/concepts/PR Merge Workflow.md',
        version: 'v1',
      },
    });
  });

  test('parseWrappedKeys does not cross the decoy newline; a path group with no newline exclusion splices across it and loses the real key', () => {
    const body = readFileSync(
      path.join(DEDUP_CORPUS_DIR, 'multiline-decoy-body.txt'),
      'utf8'
    );

    expect(parseWrappedKeys(body)).toStrictEqual([
      {line: 42, path: 'app/real.ts'},
    ]);

    // The livelock this module's docblock names: a path group excluding only
    // '>' (never '\n') crosses the decoy's newline and swallows the real key.
    const noNewlineExclusion = /path=([^>]+) line=/g;
    const spliced = [...body.matchAll(noNewlineExclusion)];

    expect(spliced).toHaveLength(1);
    expect(spliced[0]?.[1]).toContain('\n');
    expect(spliced.some((match) => match[1] === 'app/real.ts')).toBe(false);
  });

  test('attributeBody pins raw_key to the FIRST of two wrapped keys sharing a continuation line (UAT-003 arm a, TypeScript mirror)', () => {
    const body = readFileSync(
      path.join(DEDUP_CORPUS_DIR, 'two-keys-one-line.md'),
      'utf8'
    );
    const result = attributeBody(body);

    expect(result.entries).toHaveLength(1);
    // Neither a path nor a line is asserted here: the gate itself yields
    // neither for this shape (Deliverable 4a, the bats-side driver of the
    // gate's own emitted key=), and this is the mirror of that answer, not a
    // richer reading of it.
    expect(result.entries[0]?.raw_key).toBe(
      'v1 class=a path=wiki/concepts/PR Merge Workflow.md line=7'
    );
  });
});

describe('UAT-014: the attribution cache schema bump is the discriminator, not the digest', () => {
  test('a cache stamped with the pre-change schema is discarded wholesale, and the spaced-path residual re-attributes keyed', () => {
    const root = makeTemporaryRoot();
    const prs = JSON.parse(
      readFileSync(path.join(CORPUS_DIR, 'prs.json'), 'utf8')
    ) as {body: string; headRefOid: string; mergedAt: string; number: number}[];
    const pr3006 = prs.find((pr) => pr.number === 3006);

    expect(pr3006).toBeDefined();

    const preChangeCache = {
      high_water_merged_at: pr3006?.mergedAt ?? null,
      prs: {
        '3006': {
          attribution: buildStaleAttribution(),
          bodyDigest: attributionBodyDigest(pr3006?.body ?? ''),
          headRefOid: pr3006?.headRefOid ?? '',
          mergedAt: pr3006?.mergedAt ?? '',
        },
      },
      resolutions: {},
      schema: 'v1',
    };
    const cacheDir = path.join(root, '.gaia', 'local', 'cache');

    mkdirSync(cacheDir, {recursive: true});
    writeFileSync(
      path.join(cacheDir, 'residual-attribution.json'),
      `${JSON.stringify(preChangeCache)}\n`
    );

    const out = capture();
    const exitCode = runTally(['--no-cap'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exitCode).toBe(0);
    const emitted = out.json() as {candidates: {line: number; path: string}[]};

    expect(
      emitted.candidates.some(
        (c) => c.path === 'app/my dir/file.ts' && c.line === 1
      )
    ).toBe(true);
  });

  test('the same scenario under the CURRENT schema stamp is served straight from the cache, not re-attributed', () => {
    const root = makeTemporaryRoot();
    const prs = JSON.parse(
      readFileSync(path.join(CORPUS_DIR, 'prs.json'), 'utf8')
    ) as {body: string; headRefOid: string; mergedAt: string; number: number}[];
    const pr3006 = prs.find((pr) => pr.number === 3006);

    expect(pr3006).toBeDefined();

    const dayBeforeMerge = new Date(
      Date.parse(pr3006?.mergedAt ?? '') - DAY_MS
    ).toISOString();
    const currentSchemaCache = {
      high_water_merged_at: dayBeforeMerge,
      prs: {
        '3006': {
          attribution: buildStaleAttribution(),
          // The digest matches the real body byte for byte: reuse happens
          // here anyway, which is what proves the schema bump is the
          // discriminator rather than the digest.
          bodyDigest: attributionBodyDigest(pr3006?.body ?? ''),
          headRefOid: pr3006?.headRefOid ?? '',
          mergedAt: pr3006?.mergedAt ?? '',
        },
      },
      resolutions: {},
      schema: 'v3',
    };
    const cacheDir = path.join(root, '.gaia', 'local', 'cache');

    mkdirSync(cacheDir, {recursive: true});
    writeFileSync(
      path.join(cacheDir, 'residual-attribution.json'),
      `${JSON.stringify(currentSchemaCache)}\n`
    );

    const out = capture();
    const exitCode = runTally(['--no-cap'], {
      cwd: root,
      env: FIXTURE_ENV,
      now: FIXED_NOW,
    });

    expect(exitCode).toBe(0);
    const emitted = out.json() as {candidates: {line: number; path: string}[]};

    expect(
      emitted.candidates.some(
        (c) => c.path === 'app/my dir/file.ts' && c.line === 1
      )
    ).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Skill-reference prose assertions: four literals, each present verbatim
// and each provably able to red when one word changes in a scratch copy.
// ---------------------------------------------------------------------------

const skillText = readFileSync(SKILL_REFERENCE_PATH, 'utf8');

const SKILL_LITERALS: {name: string; text: string}[] = [
  {
    name: 'UAT-008: the failed-read literal, verbatim',
    text: 'could not complete the GitHub reads; this is not an all-clear, re-run when \\`gh\\` is available',
  },
  {
    name: 'UAT-013: the review subcommand definition',
    text: '`review` (or empty `$ARGUMENTS`) → the full interactive flow.',
  },
  {
    name: 'UAT-013: the list subcommand definition',
    text: '`list` → print the live candidates. No authoring, no prompts.',
  },
  {
    name: 'UAT-013: the why subcommand definition',
    text: '`why <path>:<line>` → explain the one candidate at that coordinate. No authoring, no prompts.',
  },
  {
    name: 'UAT-013: the list-subcommand authors-nothing claim',
    text: 'Author nothing, prompt for nothing, resolve nothing beyond what the tally already emitted.',
  },
  {
    name: 'UAT-013: the why-subcommand authors-nothing claim',
    text: 'Author nothing, prompt for nothing. Match the coordinate against the tally',
  },
  {
    name: 'COV-004: the publish section, present by name',
    text: '## Publish approved changes (end of run)',
  },
  {
    name: 'COV-004: the publish section names the branch step',
    text: 'git checkout -b "$BRANCH"',
  },
  {
    name: 'COV-004: the publish section names the pull-request step',
    text: 'gh pr create --title',
  },
  {
    name: 'COV-011: the write-allowlist heading',
    text: '**The complete set of files a run may write:**',
  },
  {
    name: 'COV-011: the write-allowlist names the dismissal store',
    text: '`.gaia/audit-residual-dismissals.jsonl`, the dismissal store;',
  },
  {
    name: 'COV-011: the write-allowlist names the attribution cache',
    text: '`.gaia/local/cache/residual-attribution.json`, the derived read cache;',
  },
  {
    name: 'COV-011: the write-allowlist names the cursor cache',
    text: '`.gaia/local/cache/residual-cursor.json`, the resumable cursor;',
  },
  {
    name: 'COV-011: the write-allowlist names the transient reason file',
    text: 'the transient reason file under `.gaia/local/audit/`, deleted in its own tool call;',
  },
  {
    name: 'COV-011: the write-allowlist names the filing recipe files',
    text: "the filing recipe's own transient issue-body file under `.gaia/local/audit/`, and the debt-count staleness sentinel",
  },
];

// Corrupts the first alphabetic word found, guaranteeing the mutated text
// differs from the original (every literal above carries at least one).
const mutateOneWord = (text: string): string => {
  const mutated = text.replace(/[A-Za-z]+/, (word) => `${word}MUTATED`);

  if (mutated === text) {
    throw new Error(`mutateOneWord found no word to mutate in: ${text}`);
  }

  return mutated;
};

describe('skill-reference prose assertions (residue.md)', () => {
  test.each(SKILL_LITERALS)('$name is present verbatim', ({text}) => {
    expect(skillText).toContain(text);
  });

  test.each(SKILL_LITERALS)(
    '$name reds when one word is changed in a scratch copy',
    ({text}) => {
      const mutatedLiteral = mutateOneWord(text);
      const mutatedContent = skillText.replace(text, mutatedLiteral);

      expect(mutatedContent).not.toBe(skillText);

      const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-skill-'));
      const scratchPath = path.join(dir, 'residue.md');

      writeFileSync(scratchPath, mutatedContent);
      const scratchText = readFileSync(scratchPath, 'utf8');

      expect(scratchText).not.toContain(text);
      rmSync(dir, {force: true, recursive: true});
    }
  );
});
