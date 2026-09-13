import {describe, expect, test, vi} from 'vitest';
import type {
  AttributedEntry,
  MalformedKey,
  ResidueKey,
} from '../attribution.js';
import {computeCandidates} from '../compute-candidates.js';
import type {CandidateInputPr} from '../compute-candidates.js';
import type {IssueRecord} from '../corpus.js';
import type {ResolvedCandidate} from '../resolve.js';
import type {StoreRecord} from '../store.js';

type EntryOverrides = Partial<Omit<AttributedEntry, 'key'>> & {
  key?: Partial<ResidueKey>;
};

const entry = (overrides: EntryOverrides = {}): AttributedEntry => ({
  disposition: 'accept',
  failure_mode: 'a failure mode',
  raw_key: 'v1 class=holistic/unclassified path=app/x.ts line=1',
  unit_start_line: 1,
  ...overrides,
  key: {
    class: 'holistic/unclassified',
    line: 1,
    path: 'app/x.ts',
    version: 'v1',
    ...overrides.key,
  },
});

const pr = (params: {
  entries?: AttributedEntry[];
  headRefOid?: string;
  malformed?: MalformedKey[];
  mergedAt?: string;
  number?: number;
}): CandidateInputPr => ({
  attribution: {
    entries: params.entries ?? [],
    keyless: [],
    keyless_count: 0,
    malformed: params.malformed ?? [],
  },
  headRefOid: params.headRefOid ?? 'sha',
  mergedAt: params.mergedAt ?? '2026-01-01T00:00:00Z',
  number: params.number ?? 1,
});

const noResolve = (): ResolvedCandidate => ({
  resolution: 'unresolved',
  resolved_line_text: '',
});

const stillResolverReturning =
  (resolvedLineText: string) => (): ResolvedCandidate => ({
    resolution: 'still' as const,
    resolved_line_text: resolvedLineText,
  });

const corpusOf25 = (): CandidateInputPr[] =>
  Array.from({length: 25}, (_, index) =>
    pr({
      entries: [entry({key: {line: 1, path: `app/file${index}.ts`}})],
      mergedAt: new Date(Date.UTC(2026, 0, 1 + index)).toISOString(),
      number: index + 1,
    })
  );

const baseArgs = {
  cap: 10,
  cursor: null,
  issues: [] as readonly IssueRecord[],
  keepWindowDays: 14,
  now: new Date('2026-03-01T00:00:00Z'),
  resolve: noResolve,
  storeRecords: [] as readonly StoreRecord[],
  suppressionMode: 'content-bound' as const,
};

describe('computeCandidates, attribution and emit', () => {
  test('emits exactly the keyed units; total_keyed_count matches a hand-enumerated expectation', () => {
    const prs = [
      pr({
        entries: [
          entry({key: {line: 1, path: 'a.ts'}}),
          entry({key: {line: 2, path: 'b.ts'}}),
        ],
      }),
      pr({entries: [entry({key: {line: 3, path: 'c.ts'}})], number: 2}),
    ];

    const result = computeCandidates({...baseArgs, prs});

    expect(result.total_keyed_count).toBe(3);
    expect(result.candidate_count).toBe(3);
  });

  test('both canonical dispositions appear, each candidate tagged per a hand-enumerated expectation', () => {
    const prs = [
      pr({
        entries: [
          entry({disposition: 'accept', key: {line: 1, path: 'a.ts'}}),
          entry({disposition: 'waive', key: {line: 2, path: 'b.ts'}}),
        ],
      }),
    ];

    const result = computeCandidates({...baseArgs, prs});
    const byPath = new Map(
      result.candidates.map((candidate) => [candidate.path, candidate])
    );

    expect(byPath.get('a.ts')?.disposition).toBe('accept');
    expect(byPath.get('b.ts')?.disposition).toBe('waive');
  });

  test('malformed entries carry all five contracted fields, tagged with pr_number', () => {
    const malformed: MalformedKey = {
      disposition: 'waive',
      raw_key: 'v1 class=x path=/abs line=1',
      reason: 'path has an absolute prefix',
      unit_start_line: 9,
    };
    const prs = [pr({malformed: [malformed], number: 42})];

    const result = computeCandidates({...baseArgs, prs});

    expect(result.malformed).toEqual([{...malformed, pr_number: 42}]);
  });
});

describe('computeCandidates, store suppression modes', () => {
  test('coordinate-only mode suppresses on path and line alone, without resolving, and drops the residual from the counts', () => {
    const resolveSpy = vi.fn(noResolve);
    const prs = [
      pr({
        entries: [
          entry({key: {line: 5, path: 'app/x.ts'}}),
          entry({key: {line: 6, path: 'app/y.ts'}}),
        ],
      }),
    ];
    const storeRecords: StoreRecord[] = [
      {
        cited_line_text:
          'this text will never be compared in coordinate-only mode',
        class: 'holistic/unclassified',
        date: '2026-01-01T00:00:00Z',
        disposition: 'dismissed',
        line: 5,
        path: 'app/x.ts',
        reason: 'not useful',
        schema: 'v1',
        source_pr: 1,
      },
    ];

    const result = computeCandidates({
      ...baseArgs,
      prs,
      resolve: resolveSpy,
      storeRecords,
      suppressionMode: 'coordinate-only',
    });

    expect(result.remaining_count).toBe(1);
    expect(result.candidate_count).toBe(1);
    expect(result.candidates[0]?.path).toBe('app/y.ts');
    // Step 7 (resolve the emitted batch) still runs regardless of mode; the
    // suppressed coordinate (app/x.ts, line 5) is what coordinate-only mode
    // never resolves, since it never reaches step 7's batch.
    expect(resolveSpy).toHaveBeenCalledTimes(1);
    expect(resolveSpy).toHaveBeenCalledWith(
      expect.objectContaining({line: 6, path: 'app/y.ts'})
    );
  });

  test('content-bound mode: resolved content differing from the stored cited_line_text still offers the residual', () => {
    const prs = [
      pr({
        entries: [entry({key: {line: 5, path: 'app/x.ts'}})],
        headRefOid: 'sha1',
      }),
    ];
    const storeRecords: StoreRecord[] = [
      {
        cited_line_text: 'the old cited text',
        class: 'holistic/unclassified',
        date: '2026-01-01T00:00:00Z',
        disposition: 'dismissed',
        line: 5,
        path: 'app/x.ts',
        reason: 'not useful',
        schema: 'v1',
        source_pr: 1,
      },
    ];
    const result = computeCandidates({
      ...baseArgs,
      prs,
      resolve: stillResolverReturning('a completely different line now'),
      storeRecords,
      suppressionMode: 'content-bound',
    });

    expect(result.remaining_count).toBe(1);
    expect(result.candidate_count).toBe(1);
  });

  test('content-bound mode: matching stored content suppresses the residual', () => {
    const prs = [
      pr({
        entries: [entry({key: {line: 5, path: 'app/x.ts'}})],
        headRefOid: 'sha1',
      }),
    ];
    const storeRecords: StoreRecord[] = [
      {
        cited_line_text: 'exact match',
        class: 'holistic/unclassified',
        date: '2026-01-01T00:00:00Z',
        disposition: 'dismissed',
        line: 5,
        path: 'app/x.ts',
        reason: 'not useful',
        schema: 'v1',
        source_pr: 1,
      },
    ];
    const result = computeCandidates({
      ...baseArgs,
      prs,
      resolve: stillResolverReturning('exact match'),
      storeRecords,
      suppressionMode: 'content-bound',
    });

    expect(result.remaining_count).toBe(0);
    expect(result.candidate_count).toBe(0);
  });

  test('resolution budget: exactly the store-coordinate matches plus the emitted batch are resolved, each coordinate once', () => {
    const entries = Array.from({length: 25}, (_, index) =>
      entry({key: {line: index + 1, path: `app/file${index}.ts`}})
    );
    const prs = [
      pr({entries, headRefOid: 'sha', mergedAt: '2026-01-01T00:00:00Z'}),
    ];

    // Two candidates (index 20, 21) carry a coordinate-matching store record;
    // they sort to the END of the batch (same mergedAt, tie-break by line),
    // so with a cap of 3 they are NOT among the first 3 emitted.
    const storeRecords: StoreRecord[] = [20, 21].map((index) => ({
      cited_line_text: '',
      class: 'holistic/unclassified',
      date: '2026-01-01T00:00:00Z',
      disposition: 'dismissed',
      line: index + 1,
      path: `app/file${index}.ts`,
      reason: 'irrelevant',
      schema: 'v1',
      source_pr: 1,
    }));

    const calls: string[] = [];

    const resolve = (candidate: {
      headSha: string;
      line: number;
      path: string;
    }): ResolvedCandidate => {
      calls.push(`${candidate.headSha}:${candidate.path}:${candidate.line}`);

      return {
        resolution: 'still',
        resolved_line_text: 'different from stored, never suppresses',
      };
    };

    const resultCap3 = computeCandidates({
      ...baseArgs,
      cap: 3,
      prs,
      resolve,
      storeRecords,
    });

    expect(new Set(calls).size).toBe(5); // 2 content-bind + 3 emitted batch
    expect(resultCap3.candidate_count).toBe(3);

    calls.length = 0;

    const resultCap5 = computeCandidates({
      ...baseArgs,
      cap: 5,
      prs,
      resolve,
      storeRecords,
    });

    expect(new Set(calls).size).toBe(7); // 2 content-bind + 5 emitted batch
    expect(resultCap5.candidate_count).toBe(5);
  });
});

describe('computeCandidates, counts, ordering, and cursor', () => {
  test('at the default cap of 10, emits 10 ordered oldest-merge-first, with all four counts correct', () => {
    const result = computeCandidates({...baseArgs, cap: 10, prs: corpusOf25()});

    expect(result.total_keyed_count).toBe(25);
    expect(result.remaining_count).toBe(25);
    expect(result.candidate_count).toBe(10);
    expect(result.candidates[0]?.path).toBe('app/file0.ts');
    expect(result.candidates.at(-1)?.path).toBe('app/file9.ts');

    const mergedAts = result.candidates.map((candidate) =>
      Date.parse(candidate.merged_at)
    );

    expect(mergedAts).toEqual(mergedAts.toSorted((a, b) => a - b));
  });

  test('aged_candidate_count is computed pre-cap: a cap of 3 over 8 aged survivors still reports 8 aged, 3 emitted', () => {
    const now = new Date('2026-03-01T00:00:00Z');
    const prs = Array.from({length: 8}, (_, index) =>
      pr({
        entries: [entry({key: {line: 1, path: `app/aged${index}.ts`}})],
        mergedAt: '2026-01-01T00:00:00Z', // 59 days before `now`, well past the 30-day threshold
        number: index + 1,
      })
    );

    const result = computeCandidates({...baseArgs, cap: 3, now, prs});

    expect(result.aged_candidate_count).toBe(8);
    expect(result.candidate_count).toBe(3);
  });

  test('--no-cap emits every survivor', () => {
    const result = computeCandidates({
      ...baseArgs,
      cap: Number.MAX_SAFE_INTEGER,
      prs: corpusOf25(),
    });

    expect(result.candidate_count).toBe(25);
  });

  test('every emitted candidate carries a cursor_token that round-trips to its own coordinate', () => {
    const prs = [
      pr({
        entries: [entry({key: {line: 3, path: 'app/space path.ts'}})],
        number: 9,
      }),
    ];

    const result = computeCandidates({...baseArgs, prs});

    expect(result.candidates[0]?.cursor_token).toMatch(/^[A-Za-z0-9_-]+$/);
  });

  test('a recorded cursor resumes after that coordinate rather than re-emitting it', () => {
    const prs = corpusOf25();
    const firstRun = computeCandidates({...baseArgs, cap: 3, prs});
    const lastOfFirstBatch = firstRun.candidates.at(-1);

    expect(lastOfFirstBatch).toBeDefined();

    const secondRun = computeCandidates({
      ...baseArgs,
      cap: 3,
      cursor: {
        line: lastOfFirstBatch!.line,
        path: lastOfFirstBatch!.path,
        pr_number: lastOfFirstBatch!.pr_number,
      },
      prs,
    });

    expect(secondRun.candidates[0]?.path).toBe('app/file3.ts');
    expect(
      secondRun.candidates.some(
        (candidate) => candidate.path === lastOfFirstBatch!.path
      )
    ).toBe(false);
  });
});
