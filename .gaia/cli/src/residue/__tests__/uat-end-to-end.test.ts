/**
 * SPEC-081 Phase 3a: the end-to-end UAT drivers this task owns (UAT-006,
 * UAT-007, UAT-008, UAT-010, UAT-011, UAT-013), the tally-side mutation
 * control for UAT-012 (the gate-side control lives in the sibling bats
 * suite, `.gaia/tests/hooks/residue-attribution-conformance.bats`), and the
 * four skill-reference prose assertions their acceptance criteria require.
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
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {attributeBodyWith, DEFAULT_PREDICATES} from '../attribution.js';
import {run as runCursor} from '../cursor-cmd.js';
import {run as runRecord} from '../record-cmd.js';
import {appendRecords, readStore} from '../store.js';
import type {StoreRecord} from '../store.js';
import {run as runTally} from '../tally.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const CORPUS_DIR = path.join(REPO_ROOT, '.gaia/tests/fixtures/residue-corpus');
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

const listTree = (root: string): string[] => {
  const out: string[] = [];

  const walk = (dir: string): void => {
    if (!existsSync(dir)) return;

    for (const name of readdirSync(dir)) {
      const full = path.join(dir, name);

      if (statSync(full).isDirectory()) walk(full);
      else out.push(path.relative(root, full).split(path.sep).join('/'));
    }
  };

  walk(root);

  return out;
};

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

// ---------------------------------------------------------------------------
// UAT-012 mutation control, tally side. The gate-side control lives in
// residue-attribution-conformance.bats; this is the other half named by the
// task: `attributeBodyWith` + `DEFAULT_PREDICATES` are frozen exports for
// exactly this, so no module under .gaia/cli/src/residue/ is edited.
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
// Skill-reference prose assertions: four literals, each present verbatim
// and each provably able to red when one word changes in a scratch copy.
// ---------------------------------------------------------------------------

const skillText = readFileSync(SKILL_REFERENCE_PATH, 'utf8');

const SKILL_LITERALS: {name: string; text: string}[] = [
  {
    name: 'UAT-008: the failed-window literal, verbatim',
    text: 'could not read the merged-PR window; this is not an all-clear, re-run when \\`gh\\` is available',
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
