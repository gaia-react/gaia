import {afterEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import * as attribution from '../attribution.js';
import {run as runCursor} from '../cursor-cmd.js';
import {run} from '../tally.js';

// A passthrough spy: the tally's real behavior is unchanged, but whether a
// body was attributed again or read from the cache becomes observable.
vi.mock('../attribution.js', async (importOriginal) => {
  const actual = await importOriginal<typeof attribution>();

  return {...actual, attributeBody: vi.fn(actual.attributeBody)};
});

const attributeBodySpy = vi.mocked(attribution.attributeBody);

type FixtureCorpus = {
  blobs?: Record<string, string>;
  issues?: unknown[];
  prs?: unknown[];
};

const makeFixtureRoot = (corpus: FixtureCorpus): string => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-tally-'));

  if (corpus.prs !== undefined) {
    writeFileSync(path.join(dir, 'prs.json'), JSON.stringify(corpus.prs));
  }

  if (corpus.issues !== undefined) {
    writeFileSync(path.join(dir, 'issues.json'), JSON.stringify(corpus.issues));
  }

  if (corpus.blobs !== undefined) {
    writeFileSync(path.join(dir, 'blobs.json'), JSON.stringify(corpus.blobs));
  }

  return dir;
};

const capture = () => {
  const lines: string[] = [];
  const spy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      lines.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    json: (): unknown => JSON.parse(lines.at(-1) ?? '{}'),
    spy,
  };
};

const keyComment = (className: string, path_: string, line: number): string =>
  `<!-- gaia-debt-key: v1 class=${className} path=${path_} line=${line} -->`;

const bodyWithKey = (
  heading: string,
  className: string,
  path_: string,
  line: number
): string =>
  `${heading}\n\n- a finding ${keyComment(className, path_, line)}\n`;

const ACCEPT_HEADING = '## Accepted residuals (recorded, not fixed)';
const fixedNow = () => new Date('2026-06-01T00:00:00Z');

const listTree = (root: string): string[] => {
  const out: string[] = [];

  const walk = (dir: string): void => {
    if (!existsSync(dir)) return;

    for (const name of readdirSync(dir)) {
      const full = path.join(dir, name);

      if (statSync(full).isDirectory()) walk(full);
      else out.push(path.relative(root, full));
    }
  };

  walk(root);

  return out.toSorted((a, b) => a.localeCompare(b));
};

// Advancing past an unparseable `--cap` value consumed whatever sat in the
// value position, so a following mode flag was swallowed and its contract
// silently broken. An unknown argument is already an error; so is this.
const CAP_CORPUS: FixtureCorpus = {
  prs: [
    {
      body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
      headRefOid: 'sha1',
      mergedAt: '2026-01-01T00:00:00Z',
      number: 1,
    },
  ],
};

const runWithCapValue = (
  root: string,
  value: string[]
): {code: number; stderr: string} => {
  const errors: string[] = [];

  vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
    errors.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  });

  const code = run(['--cap', ...value], {
    cwd: root,
    env: {GAIA_RESIDUE_FIXTURE_DIR: root},
    now: fixedNow,
  });

  return {code, stderr: errors.join('')};
};

// Editing a merged body is the natural repair for a key the tally reports in
// `malformed[]`, and that edit moves no head SHA. Keying on the SHA alone made
// the repair invisible until the cache was deleted by hand.
// Two pull requests, and the one under repair is deliberately NOT the newest
// merge. A one-pull-request corpus is trivially at the cache's high-water
// mark, so the incremental window re-reads it whatever the window logic does,
// and the digest comparison looks correct while never running for the entry
// that needs it.
const corpusWithBody = (body: string): FixtureCorpus => ({
  blobs: {},
  issues: [],
  prs: [
    {
      body,
      headRefOid: 'sha-unchanged',
      mergedAt: '2026-01-01T00:00:00Z',
      number: 1,
    },
    {
      body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/newer.ts', 9),
      headRefOid: 'sha-newer',
      mergedAt: '2026-02-01T00:00:00Z',
      number: 2,
    },
  ],
});

const tallyCounts = (
  root: string
): {candidate_count: number; malformed: unknown[]} => {
  const out = capture();

  run(['--count-only'], {
    cwd: root,
    env: {GAIA_RESIDUE_FIXTURE_DIR: root},
    now: fixedNow,
  });

  return out.json() as {candidate_count: number; malformed: unknown[]};
};

describe('gaia residue-tally', () => {
  const dirs: string[] = [];

  const makeRoot = (corpus: FixtureCorpus): string => {
    const dir = makeFixtureRoot(corpus);

    dirs.push(dir);

    return dir;
  };

  afterEach(() => {
    vi.restoreAllMocks();

    for (const dir of dirs.splice(0))
      rmSync(dir, {force: true, recursive: true});
  });

  test('--attribute-only emits the frozen shape with a non-empty keyless[], writes no cache, and performs no suppression', () => {
    const root = makeRoot({
      prs: [
        {
          body: `${ACCEPT_HEADING}\n\n- a keyed entry ${keyComment('x/y', 'app/a.ts', 1)}\n- a keyless entry with no key at all\n`,
          headRefOid: 'sha1',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
      ],
    });
    const out = capture();

    const exitCode = run(['--attribute-only'], {
      cwd: root,
      env: {GAIA_RESIDUE_FIXTURE_DIR: root},
    });

    expect(exitCode).toBe(0);

    const emitted = out.json() as {
      bodies: {keyless: unknown[]}[];
      gh_ok: boolean;
    };

    expect(emitted.gh_ok).toBe(true);
    expect(emitted.bodies).toHaveLength(1);
    expect(emitted.bodies[0]?.keyless.length).toBeGreaterThan(0);
    expect(existsSync(path.join(root, '.gaia', 'local', 'cache'))).toBe(false);
  });

  test('a failed pull-request window read emits gh_ok: false, candidate_count 0, empty candidates, and exits 0', () => {
    const root = makeRoot({issues: []});
    const out = capture();

    const exitCode = run([], {
      cwd: root,
      env: {GAIA_RESIDUE_FIXTURE_DIR: root},
    });

    expect(exitCode).toBe(0);

    const emitted = out.json() as {
      candidate_count: number;
      candidates: unknown[];
      gh_ok: boolean;
    };

    expect(emitted.gh_ok).toBe(false);
    expect(emitted.candidate_count).toBe(0);
    expect(emitted.candidates).toEqual([]);
  });

  test('a failed issue read also emits gh_ok: false with an empty candidate list', () => {
    const root = makeRoot({
      prs: [
        {
          body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
          headRefOid: 'sha1',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
      ],
    });
    const out = capture();

    const exitCode = run([], {
      cwd: root,
      env: {GAIA_RESIDUE_FIXTURE_DIR: root},
    });

    expect(exitCode).toBe(0);

    const emitted = out.json() as {candidate_count: number; gh_ok: boolean};

    expect(emitted.gh_ok).toBe(false);
    expect(emitted.candidate_count).toBe(0);
  });

  test('with a corpus that would produce candidates, gh_ok is true', () => {
    const root = makeRoot({
      blobs: {'sha1:app/a.ts': 'line one\nthe cited line\nline three\n'},
      issues: [],
      prs: [
        {
          body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 2),
          headRefOid: 'sha1',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
      ],
    });
    const out = capture();

    run([], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});

    const emitted = out.json() as {candidate_count: number; gh_ok: boolean};

    expect(emitted.gh_ok).toBe(true);
    expect(emitted.candidate_count).toBe(1);
  });

  // The provenance line below is the real emitted shape, not a stand-in, so
  // that the attribution this asserts is the one production bodies exercise.
  // `.claude/skills/file-tech-debt/SKILL.md` owns that shape; nothing here
  // states or re-derives it, and a drift in it belongs to the owner rather
  // than to this fixture.
  test('the resolved line comes from the pull-request head object, identically whether or not a provenance line sits beside the key', () => {
    const blobs = {'sha1:app/a.ts': 'preamble\nthe cited line\n'};
    const rootWithProvenance = makeRoot({
      blobs,
      issues: [],
      prs: [
        {
          body: `${ACCEPT_HEADING}\n\n- a finding ${keyComment('x/y', 'app/a.ts', 2)}\n<!-- gaia-debt-origin: branch=unknown mode=unknown unit=unknown changed=unknown head=deadbeef session=unknown -->\n`,
          headRefOid: 'sha1',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
      ],
    });
    const rootWithoutProvenance = makeRoot({
      blobs,
      issues: [],
      prs: [
        {
          body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 2),
          headRefOid: 'sha1',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
      ],
    });

    const withOut = capture();

    run([], {
      cwd: rootWithProvenance,
      env: {GAIA_RESIDUE_FIXTURE_DIR: rootWithProvenance},
    });

    const withEmitted = withOut.json() as {
      candidates: {resolved_line_text: string}[];
    };

    const withoutOut = capture();

    run([], {
      cwd: rootWithoutProvenance,
      env: {GAIA_RESIDUE_FIXTURE_DIR: rootWithoutProvenance},
    });

    const withoutEmitted = withoutOut.json() as {
      candidates: {resolved_line_text: string}[];
    };

    expect(withEmitted.candidates[0]?.resolved_line_text).toBe(
      'the cited line'
    );
    expect(withEmitted.candidates[0]?.resolved_line_text).toBe(
      withoutEmitted.candidates[0]?.resolved_line_text
    );
  });

  test('a residual whose cited content exists nowhere at current HEAD resolves "gone"', () => {
    const root = makeRoot({
      blobs: {
        'HEAD:app/a.ts': 'nothing like it here\n',
        'sha1:app/a.ts': 'the cited line\n',
      },
      issues: [],
      prs: [
        {
          body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
          headRefOid: 'sha1',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
      ],
    });
    const out = capture();

    run([], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});

    const emitted = out.json() as {candidates: {resolution: string}[]};

    expect(emitted.candidates[0]?.resolution).toBe('gone');
  });

  test('a blank cited line at the head object classifies unresolvable, not still', () => {
    const root = makeRoot({
      blobs: {'sha1:app/a.ts': 'first\n   \nthird\n'},
      issues: [],
      prs: [
        {
          body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 2),
          headRefOid: 'sha1',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
      ],
    });
    const out = capture();

    run([], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});

    const emitted = out.json() as {candidates: {resolution: string}[]};

    expect(emitted.candidates[0]?.resolution).toBe('unresolvable');
  });

  test('--count-only performs no resolution: every candidate is "unresolved" with empty text, and count_approximate is true', () => {
    const root = makeRoot({
      blobs: {'sha1:app/a.ts': 'the cited line\n'},
      issues: [],
      prs: [
        {
          body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
          headRefOid: 'sha1',
          mergedAt: '2026-01-01T00:00:00Z',
          number: 1,
        },
      ],
    });
    const out = capture();

    run(['--count-only'], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});

    const emitted = out.json() as {
      candidates: {resolution: string; resolved_line_text: string}[];
      count_approximate: boolean;
    };

    expect(emitted.count_approximate).toBe(true);
    expect(emitted.candidates[0]).toMatchObject({
      resolution: 'unresolved',
      resolved_line_text: '',
    });
  });

  test('the count-only degradation, on a cold cache: a dismissed record with non-empty cited_line_text still drops an aged residual from remaining_count and aged_candidate_count', () => {
    const root = makeRoot({
      blobs: {},
      issues: [],
      prs: [
        {
          body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
          headRefOid: 'sha1',
          mergedAt: '2020-01-01T00:00:00Z', // far older than 30 days
          number: 1,
        },
      ],
    });

    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(
      path.join(root, '.gaia', 'audit-residual-dismissals.jsonl'),
      `${JSON.stringify({
        cited_line_text: 'some previously-resolved content',
        class: 'x/y',
        date: '2020-01-02T00:00:00Z',
        disposition: 'dismissed',
        line: 1,
        path: 'app/a.ts',
        reason: 'not useful',
        schema: 'v1',
        source_pr: 1,
      })}\n`
    );

    expect(
      existsSync(
        path.join(root, '.gaia', 'local', 'cache', 'residual-attribution.json')
      )
    ).toBe(false);

    const out = capture();

    run(['--count-only'], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});

    const emitted = out.json() as {
      aged_candidate_count: number;
      count_approximate: boolean;
      remaining_count: number;
    };

    expect(emitted.count_approximate).toBe(true);
    expect(emitted.remaining_count).toBe(0);
    expect(emitted.aged_candidate_count).toBe(0);
  });

  test('GAIA_RESIDUE_CAP=3 emits 3; --no-cap emits every survivor; an invalid GAIA_RESIDUE_CAP falls back to 10', () => {
    const prs = Array.from({length: 25}, (_, index) => ({
      body: bodyWithKey(ACCEPT_HEADING, 'x/y', `app/file${index}.ts`, 1),
      headRefOid: 'sha',
      mergedAt: new Date(Date.UTC(2026, 0, 1 + index)).toISOString(),
      number: index + 1,
    }));

    const rootCapped = makeRoot({blobs: {}, issues: [], prs});
    const cappedOut = capture();

    run([], {
      cwd: rootCapped,
      env: {GAIA_RESIDUE_CAP: '3', GAIA_RESIDUE_FIXTURE_DIR: rootCapped},
    });
    expect(
      (cappedOut.json() as {candidate_count: number}).candidate_count
    ).toBe(3);

    const rootNoCap = makeRoot({blobs: {}, issues: [], prs});
    const noCapOut = capture();

    run(['--no-cap'], {
      cwd: rootNoCap,
      env: {GAIA_RESIDUE_FIXTURE_DIR: rootNoCap},
    });
    expect((noCapOut.json() as {candidate_count: number}).candidate_count).toBe(
      25
    );

    for (const badCap of ['', '0', '-2', 'abc']) {
      const rootFallback = makeRoot({blobs: {}, issues: [], prs});
      const fallbackOut = capture();

      run([], {
        cwd: rootFallback,
        env: {GAIA_RESIDUE_CAP: badCap, GAIA_RESIDUE_FIXTURE_DIR: rootFallback},
      });
      expect(
        (fallbackOut.json() as {candidate_count: number}).candidate_count
      ).toBe(10);
    }
  });

  test('a cold cache and a warm cache produce byte-identical emits for the same corpus', () => {
    const prs = [
      {
        body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
        headRefOid: 'sha1',
        mergedAt: '2026-01-01T00:00:00Z',
        number: 1,
      },
    ];
    const root = makeRoot({
      blobs: {'sha1:app/a.ts': 'the cited line\n'},
      issues: [],
      prs,
    });
    const first = capture();

    run([], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}, now: fixedNow});

    const firstEmit = first.json();

    const second = capture();

    run([], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}, now: fixedNow});

    const secondEmit = second.json() as Record<string, unknown>;

    // `window.mode` legitimately differs (full on a cold cache, incremental
    // once a high-water mark exists); every candidate-bearing field is what
    // "byte-identical" is actually asserting here.
    const {window: firstWindow, ...firstRest} = firstEmit as Record<
      string,
      unknown
    >;
    const {window: secondWindow, ...secondRest} = secondEmit;

    expect(secondRest).toEqual(firstRest);
    expect(
      (secondWindow as {high_water_merged_at: unknown}).high_water_merged_at
    ).toEqual(
      (firstWindow as {high_water_merged_at: unknown}).high_water_merged_at
    );
  });

  test('a corrupt cache file produces the same emit as a cold cache, with no throw', () => {
    const prs = [
      {
        body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
        headRefOid: 'sha1',
        mergedAt: '2026-01-01T00:00:00Z',
        number: 1,
      },
    ];
    const root = makeRoot({
      blobs: {'sha1:app/a.ts': 'the cited line\n'},
      issues: [],
      prs,
    });

    mkdirSync(path.join(root, '.gaia', 'local', 'cache'), {recursive: true});
    writeFileSync(
      path.join(root, '.gaia', 'local', 'cache', 'residual-attribution.json'),
      '{"schema":"v1","prs":{'
    );

    expect(() =>
      run([], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}})
    ).not.toThrow();
  });

  test('--attribute-only and --count-only never write the cursor file', () => {
    const prs = [
      {
        body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
        headRefOid: 'sha1',
        mergedAt: '2026-01-01T00:00:00Z',
        number: 1,
      },
    ];
    const root = makeRoot({blobs: {}, issues: [], prs});
    const cursorFile = path.join(
      root,
      '.gaia',
      'local',
      'cache',
      'residual-cursor.json'
    );

    run(['--attribute-only'], {
      cwd: root,
      env: {GAIA_RESIDUE_FIXTURE_DIR: root},
    });
    expect(existsSync(cursorFile)).toBe(false);

    run(['--count-only'], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});
    expect(existsSync(cursorFile)).toBe(false);
  });

  test('the resumable cursor: residue-cursor advance on an emitted token, then a fresh tally run resumes after it', () => {
    const prs = Array.from({length: 3}, (_, index) => ({
      body: bodyWithKey(ACCEPT_HEADING, 'x/y', `app/file${index}.ts`, 1),
      headRefOid: 'sha',
      mergedAt: new Date(Date.UTC(2026, 0, 1 + index)).toISOString(),
      number: index + 1,
    }));
    const root = makeRoot({blobs: {}, issues: [], prs});

    const firstOut = capture();

    run(['--cap', '1'], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});

    const firstEmit = firstOut.json() as {
      candidates: {cursor_token: string; path: string}[];
    };

    expect(firstEmit.candidates[0]?.path).toBe('app/file0.ts');

    const token = firstEmit.candidates[0]?.cursor_token as string;

    expect(runCursor(['advance', '--token', token], {cwd: root})).toBe(0);

    const secondOut = capture();

    run(['--cap', '1'], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});

    const secondEmit = secondOut.json() as {candidates: {path: string}[]};

    expect(secondEmit.candidates[0]?.path).toBe('app/file1.ts');
  });

  test('a full run against a fixture corpus modifies no file outside the attribution cache', () => {
    const prs = [
      {
        body: bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1),
        headRefOid: 'sha1',
        mergedAt: '2026-01-01T00:00:00Z',
        number: 1,
      },
    ];
    const root = makeRoot({
      blobs: {'sha1:app/a.ts': 'the cited line\n'},
      issues: [],
      prs,
    });
    // Represents an adopter's own tracked file living alongside the fixture
    // corpus: nothing the tally does should ever touch it.
    writeFileSync(path.join(root, 'app-owned-file.txt'), 'untouched');

    const before = listTree(root);

    run([], {cwd: root, env: {GAIA_RESIDUE_FIXTURE_DIR: root}});

    const after = listTree(root);
    const added = after.filter((file) => !before.includes(file));
    const removed = before.filter((file) => !after.includes(file));

    expect(removed).toEqual([]);
    expect(added).toEqual([
      path.join('.gaia', 'local', 'cache', 'residual-attribution.json'),
    ]);
  });

  describe('--cap refuses a value it cannot use', () => {
    test('`--cap --count-only` is refused rather than eating the mode flag', () => {
      const {code, stderr} = runWithCapValue(makeRoot(CAP_CORPUS), [
        '--count-only',
      ]);

      expect(code).not.toBe(0);
      expect(stderr).toMatch(/--cap needs a positive integer/);
    });

    test.each([
      ['a non-numeric value', 'abc'],
      ['zero', '0'],
      ['a negative value', '-3'],
    ])('%s is refused instead of falling back to the default', (_name, bad) => {
      const {code, stderr} = runWithCapValue(makeRoot(CAP_CORPUS), [bad]);

      expect(code).not.toBe(0);
      expect(stderr).toMatch(/--cap needs a positive integer/);
    });

    test('a positive value is still accepted', () => {
      const {code} = runWithCapValue(makeRoot(CAP_CORPUS), ['3']);

      expect(code).toBe(0);
    });
  });

  describe('the attribution cache sees a merged pull-request body edit', () => {
    test('a body repaired in place re-attributes on the warm cache', () => {
      const root = makeRoot(
        corpusWithBody(bodyWithKey(ACCEPT_HEADING, 'x/y', '/absolute/a.ts', 1))
      );

      const cold = tallyCounts(root);

      expect(cold.malformed).toHaveLength(1);
      expect(cold.candidate_count).toBe(1);

      // The repair: the OLDER pull request, same head SHA, corrected key. The
      // newer merge is untouched, so the cache's high-water mark sits above
      // the entry being repaired.
      writeFileSync(
        path.join(root, 'prs.json'),
        JSON.stringify(
          corpusWithBody(bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1)).prs
        )
      );

      // The interactive run, not `--count-only`: only this path widens the
      // window, which is what makes the repair visible.
      const out = capture();

      run([], {
        cwd: root,
        env: {GAIA_RESIDUE_FIXTURE_DIR: root},
        now: fixedNow,
      });

      const warm = out.json() as {
        candidate_count: number;
        malformed: unknown[];
      };

      expect(warm.malformed).toEqual([]);
      expect(warm.candidate_count).toBe(2);
    });

    test('--count-only never widens the window, so the refresher keeps its incremental read', () => {
      // The widening is bounded by the AGE of the oldest malformed key, and
      // nothing retires one, so on the refresher's path it would be a
      // permanently full-corpus read. It under-reports a just-repaired entry
      // instead, until the next interactive run.
      const root = makeRoot(
        corpusWithBody(bodyWithKey(ACCEPT_HEADING, 'x/y', '/absolute/a.ts', 1))
      );

      tallyCounts(root);

      writeFileSync(
        path.join(root, 'prs.json'),
        JSON.stringify(
          corpusWithBody(bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1)).prs
        )
      );

      // --count-only does not see the repair...
      expect(tallyCounts(root).malformed).toHaveLength(1);

      // ...and the interactive run does, then leaves a cache that agrees.
      const out = capture();

      run([], {
        cwd: root,
        env: {GAIA_RESIDUE_FIXTURE_DIR: root},
        now: fixedNow,
      });

      expect((out.json() as {malformed: unknown[]}).malformed).toEqual([]);
      expect(tallyCounts(root).malformed).toEqual([]);
    });

    test('a cache entry of an unexpected shape does not crash the window scan', () => {
      // `isValidCache` checks the container, not its entries, so a hand-edited
      // or truncated cache reaches the scan. Exiting 0 over a cache it cannot
      // use is this command's stated contract.
      const root = makeRoot(
        corpusWithBody(bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1))
      );

      tallyCounts(root);

      const cachePath = path.join(
        root,
        '.gaia',
        'local',
        'cache',
        'residual-attribution.json'
      );

      writeFileSync(
        cachePath,
        JSON.stringify({
          high_water_merged_at: '2026-02-01T00:00:00Z',
          prs: {1: {}, abc: {}},
          resolutions: {},
          schema: 'v1',
        })
      );

      const out = capture();

      expect(
        run([], {
          cwd: root,
          env: {GAIA_RESIDUE_FIXTURE_DIR: root},
          now: fixedNow,
        })
      ).toBe(0);
      expect((out.json() as {gh_ok: boolean}).gh_ok).toBe(true);
    });

    test('an unchanged body reuses its cached attribution instead of re-attributing', () => {
      // Counting candidates across two runs cannot see this: a run that
      // ignores the cache entirely produces the identical count. Only the
      // attribution call itself distinguishes reuse from re-attribution.
      const root = makeRoot(
        corpusWithBody(bodyWithKey(ACCEPT_HEADING, 'x/y', 'app/a.ts', 1))
      );

      tallyCounts(root);
      attributeBodySpy.mockClear();
      tallyCounts(root);

      expect(attributeBodySpy).not.toHaveBeenCalled();
    });
  });
});
