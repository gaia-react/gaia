import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  ReviewTallyInputSchema,
  snapshotFromTally,
  writeReviewSnapshot,
} from '../../schemas/review-snapshot.js';
import type {ReviewSnapshot} from '../../schemas/review-snapshot.js';
import {MERGED_PR_PAGE_CEILING} from '../../util/merged-pr-window.js';
import * as runProcess from '../../util/run-process.js';
import type {ProcessResult} from '../../util/run-process.js';
import {markerComment} from '../marker.js';
import {isMaterialRise, TALLY_SCHEMA_VERSION} from '../material-rise.js';
import {run} from '../tally.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  rulesDir: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-tally-'));
  const rulesDir = path.join(root, '.claude', 'rules');

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    rulesDir,
  };
};

const captureStdout = () => {
  const out: string[] = [];
  const spy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    out,
    restore: () => {
      spy.mockRestore();
    },
  };
};

type BlockFinding = {
  area_tags: string[];
  finding_class: string;
  severity: string;
};

const findingsComment = (
  prNumber: number,
  auditor: string,
  findings: BlockFinding[]
): {body: string} => ({
  body: [
    'Audit summary.',
    '<!-- gaia-harden:findings:start -->',
    '<!--',
    JSON.stringify({auditor, findings, pr_number: prNumber, schema: 1}),
    '-->',
    '<!-- gaia-harden:findings:end -->',
  ].join('\n'),
});

// Same shape as `findingsComment` but omits the `auditor` key entirely, for
// exercising the parser's missing-auditor normalization to the `''` bucket.
const anonymousFindingsComment = (
  prNumber: number,
  findings: BlockFinding[]
): {body: string} => ({
  body: [
    'Audit summary.',
    '<!-- gaia-harden:findings:start -->',
    '<!--',
    JSON.stringify({findings, pr_number: prNumber, schema: 1}),
    '-->',
    '<!-- gaia-harden:findings:end -->',
  ].join('\n'),
});

const ghPr = (prNumber: number, comments: {body: string}[]) => ({
  comments,
  number: prNumber,
});

const stubGh = (prs: unknown[]): ProcessResult => ({
  exitCode: 0,
  stderr: '',
  stdout: JSON.stringify(prs),
});

const parseStdout = (out: string[]): Record<string, unknown> =>
  JSON.parse(out.join('').trim()) as Record<string, unknown>;

const REFERENCE_NOW = new Date('2026-09-18T10:00:00.000Z');

const snapshotPath = (root: string): string =>
  path.join(root, '.gaia', 'local', 'harden', 'reviewed.json');

const writeRawSnapshot = (root: string, contents: string): void => {
  mkdirSync(path.dirname(snapshotPath(root)), {recursive: true});
  writeFileSync(snapshotPath(root), contents);
};

// Stubs a window of `recurring` PRs carrying `findingClass` plus `bystanders`
// audited PRs carrying an unrelated seeded class, so a test can drive both
// the numerator (the class under test) and the denominator
// (`audited_pr_count`) independently.
const stubClassWindow = (args: {
  bystanders: number;
  findingClass: string;
  recurring: number;
}): void => {
  const recurringPrs = Array.from({length: args.recurring}, (_u, index) =>
    ghPr(index + 1, [
      findingsComment(index + 1, 'ci', [
        {area_tags: [], finding_class: args.findingClass, severity: 'warning'},
      ]),
    ])
  );
  const bystanderPrs = Array.from({length: args.bystanders}, (_u, index) =>
    ghPr(args.recurring + index + 1, [
      findingsComment(args.recurring + index + 1, 'ci', [
        {
          area_tags: [],
          finding_class: 'holistic/stale-figure',
          severity: 'warning',
        },
      ]),
    ])
  );

  vi.spyOn(runProcess, 'runGh').mockReturnValue(
    stubGh([...recurringPrs, ...bystanderPrs])
  );
};

// Stubs the window read as one classless finding per named PR, so a test can
// drive the fallback bucket's distinct-PR count directly.
const stubClasslessWindow = (prNumbers: readonly number[]): void => {
  vi.spyOn(runProcess, 'runGh').mockReturnValue(
    stubGh(
      prNumbers.map((n) =>
        ghPr(n, [
          findingsComment(n, 'ci', [
            {
              area_tags: [],
              finding_class: 'holistic/unclassified',
              severity: 'warning',
            },
          ]),
        ])
      )
    )
  );
};

// One full search page of finding-less PRs, created a minute apart, so the
// window walk has an oldest `createdAt` to narrow its next query on.
const fullSearchPage = (topNumber: number) =>
  Array.from({length: MERGED_PR_PAGE_CEILING}, (_, index) => ({
    comments: [] as {body: string}[],
    createdAt: new Date(Date.UTC(2026, 8, 2) - index * 60_000).toISOString(),
    number: topNumber - index,
  }));

const recurringFinding = (prNumber: number) =>
  findingsComment(prNumber, 'ci', [
    {
      area_tags: ['app'],
      finding_class: 'rule/switch-statement',
      severity: 'warning',
    },
  ]);

type FakeLedger = {
  calls: {prune: (readonly string[])[]};
  has: (findingClass: string) => boolean;
  ledger: LedgerAccess;
  record: (
    findingClass: string,
    prCount: number,
    auditedPrCount: number
  ) => void;
};

type LedgerAccess = NonNullable<
  NonNullable<Parameters<typeof run>[1]>['ledger']
>;

// A ledger with no decline entries: every class re-surfaces.
const noDeclines: LedgerAccess = {
  check: () => ({reason: 'no_decline_entry', status: 'resurface'}),
  prune: () => undefined,
};

// A ledger whose file cannot be read: the tally must keep every class
// suppressed rather than re-surface a declined candidate.
const unreadableLedger: LedgerAccess = {
  check: () => ({error: 'corrupt', status: 'unreadable'}),
  prune: () => undefined,
};

// A fake, stateful ledger over an in-memory store keyed on `finding_class`,
// deciding through the same `isMaterialRise` the real ledger uses, so a test
// can drive the composed suppress-then-prune call site in `run()` without a
// ledger file. `ledger.test.ts` owns the proof of the real filter.
const makeFakeLedger = (): FakeLedger => {
  const store = new Map<
    string,
    {declined_at_audited_pr_count: number; declined_at_pr_count: number}
  >();
  const calls: FakeLedger['calls'] = {prune: []};

  return {
    calls,
    has: (findingClass) => store.has(findingClass),
    ledger: {
      check: (findingClass, currentPrCount, currentAuditedPrCount) => {
        const entry = store.get(findingClass);

        if (entry === undefined) {
          return {reason: 'no_decline_entry', status: 'resurface'};
        }

        return (
            isMaterialRise({
              baseAuditedPrCount: entry.declined_at_audited_pr_count,
              baseCount: entry.declined_at_pr_count,
              liveAuditedPrCount: currentAuditedPrCount,
              liveCount: currentPrCount,
            })
          ) ?
            {reason: 'material_rise', status: 'resurface'}
          : {status: 'suppressed'};
      },
      // Every key the window-classes set does not name is dropped, the
      // classless fallback included.
      prune: (windowClasses) => {
        calls.prune.push(windowClasses);

        for (const findingClass of [...store.keys()].filter(
          (key) => !windowClasses.includes(key)
        )) {
          store.delete(findingClass);
        }
      },
    },
    record: (findingClass, prCount, auditedPrCount) => {
      store.set(findingClass, {
        declined_at_audited_pr_count: auditedPrCount,
        declined_at_pr_count: prCount,
      });
    },
  };
};

describe('harden-tally run', () => {
  let sandbox: Sandbox;
  let stdout: ReturnType<typeof captureStdout>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdout = captureStdout();
  });

  afterEach(() => {
    stdout.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('emits a candidate for a class on 3 distinct merged PRs at warning', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1201, [
          findingsComment(1201, 'ci', [
            {
              area_tags: ['app/components'],
              finding_class: 'react-doctor/no-generic-handler-names',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(1188, [
          findingsComment(1188, 'local', [
            {
              area_tags: ['app/hooks'],
              finding_class: 'react-doctor/no-generic-handler-names',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(1175, [
          findingsComment(1175, 'ci', [
            {
              area_tags: ['app/components'],
              finding_class: 'react-doctor/no-generic-handler-names',
              severity: 'warning',
            },
          ]),
        ]),
      ])
    );

    const exit = run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(1);
    expect(printed.window_days).toBe(90);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe(
      'react-doctor/no-generic-handler-names'
    );
    expect(candidates[0]?.distinct_pr_count).toBe(3);
    expect(candidates[0]?.is_oracle).toBe(true);
  });

  test('CI+local findings for the same class across distinct PRs combine into one candidate', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(2, [
          findingsComment(2, 'local', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'error',
            },
          ]),
        ]),
        ghPr(3, [
          findingsComment(3, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.severity_max).toBe('error');
    expect(candidates[0]?.is_oracle).toBe(false);
  });

  test('two different auditors posting on the same PR both count (#731 regression)', () => {
    // PR 1201 carries a 'ci' block for classA and a 'local' block for classB
    // in the SAME comment list. Under the old last-block-on-the-PR-wins bug,
    // only the local/classB block would survive, so classA would be short one
    // PR and fall below the recurrence threshold.
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1201, [
          findingsComment(1201, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
          findingsComment(1201, 'local', [
            {
              area_tags: ['app'],
              finding_class: 'axe/color-contrast',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(1188, [
          findingsComment(1188, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(1175, [
          findingsComment(1175, 'ci', [
            {
              area_tags: ['app'],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    const candidates = printed.candidates as Record<string, unknown>[];
    const switchCandidate = candidates.find(
      (c) => c.finding_class === 'rule/switch-statement'
    );
    expect(switchCandidate?.distinct_pr_count).toBe(3);
    expect(switchCandidate?.pr_numbers).toContain(1201);
  });

  test('same auditor re-running on a PR supersedes its own earlier block, not merges', () => {
    // PR 1 carries two 'ci' blocks: the second (classB) must fully replace
    // the first (classA) for that auditor, so classA gets no credit from PR 1.
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {
              area_tags: [],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
          findingsComment(1, 'ci', [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(2, [
          findingsComment(2, 'ci', [
            {
              area_tags: [],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(3, [
          findingsComment(3, 'ci', [
            {
              area_tags: [],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(4, [
          findingsComment(4, 'ci', [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(5, [
          findingsComment(5, 'ci', [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'warning',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    // classA (rule/switch-statement) only reaches PRs 2 and 3 (2 distinct):
    // PR 1's ci/classA block was superseded by ci/classB on the same PR, so
    // it must not qualify. classB (axe/color-contrast) reaches PRs 1, 4, 5.
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe('axe/color-contrast');
    expect(candidates[0]?.pr_numbers).toEqual(
      expect.arrayContaining([1, 4, 5])
    );
  });

  test('two anonymous (missing-auditor) blocks on the same PR collapse, latest wins', () => {
    // Both blocks omit `auditor`, so the parser normalizes each to the same
    // '' bucket: the second (classB) must supersede the first (classA), the
    // same as a same-auditor re-run, not merge as if from different auditors.
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          anonymousFindingsComment(1, [
            {
              area_tags: [],
              finding_class: 'rule/switch-statement',
              severity: 'warning',
            },
          ]),
          anonymousFindingsComment(1, [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(2, [
          anonymousFindingsComment(2, [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(3, [
          anonymousFindingsComment(3, [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'warning',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe('axe/color-contrast');
    expect(candidates[0]?.distinct_pr_count).toBe(3);
  });

  test('does not surface a class on only 2 distinct PRs', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
          ]),
        ]),
        ghPr(2, [
          findingsComment(2, 'ci', [
            {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('does not surface a class found 3 times in a single PR', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
            {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
            {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('surfaces a suggestion-only recurring class as a candidate (severity-independent)', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'holistic/hardcoded-string',
                severity: 'suggestion',
              },
            ]),
          ])
        )
      )
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(1);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.severity_max).toBe('suggestion');
  });

  test('emits a populated unclassified field for a classless recurring finding, excluded from candidates', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: ['app/routes'],
                finding_class: 'holistic/unclassified',
                severity: 'warning',
              },
            ]),
          ])
        )
      )
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(0);
    const unclassified = printed.unclassified as Record<string, unknown>;
    expect(unclassified).not.toBeNull();
    expect(unclassified.distinct_pr_count).toBe(3);
    expect(unclassified.severity_max).toBe('warning');
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(
      candidates.every((c) => c.finding_class !== 'holistic/unclassified')
    ).toBe(true);
  });

  test('emits a null unclassified field when the classless bucket is below threshold', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {
              area_tags: [],
              finding_class: 'holistic/unclassified',
              severity: 'warning',
            },
          ]),
        ]),
      ])
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    expect(parseStdout(stdout.out).unclassified).toBeNull();
  });

  test('drops a class a promoted rule already covers', () => {
    mkdirSync(sandbox.rulesDir, {recursive: true});
    writeFileSync(
      path.join(sandbox.rulesDir, 'switch.md'),
      markerComment('rule/switch-statement')
    );

    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'rule/switch-statement',
                severity: 'warning',
              },
            ]),
          ])
        )
      )
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('drops a ledger-suppressed class, then re-surfaces once it crosses the threshold again', () => {
    const gh = stubGh(
      [3, 2, 1].map((n) =>
        ghPr(n, [
          findingsComment(n, 'ci', [
            {
              area_tags: [],
              finding_class: 'axe/color-contrast',
              severity: 'error',
            },
          ]),
        ])
      )
    );
    vi.spyOn(runProcess, 'runGh').mockReturnValue(gh);

    // Ledger says suppressed (exit 0): no candidate.
    run([], {
      cwd: sandbox.root,
      ledger: {
        check: () => ({status: 'suppressed'}),
        prune: () => undefined,
      },
    });
    expect(parseStdout(stdout.out).candidate_count).toBe(0);

    // Fresh evidence: ledger now says NOT suppressed (exit 1): re-surfaces.
    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      ledger: {
        check: () => ({reason: 'material_rise', status: 'resurface'}),
        prune: () => undefined,
      },
    });
    expect(parseStdout(stdout.out).candidate_count).toBe(1);
  });

  test('prunes the ledger with the classes still recurring in the window', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'axe/color-contrast',
                severity: 'warning',
              },
            ]),
          ])
        )
      )
    );

    const fake = makeFakeLedger();
    run([], {cwd: sandbox.root, ledger: fake.ledger});

    expect(fake.calls.prune).toEqual([['axe/color-contrast']]);
  });

  test('keeps an at-threshold class suppressed when the ledger is unreadable', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'axe/color-contrast',
                severity: 'warning',
              },
            ]),
          ])
        )
      )
    );

    run([], {cwd: sandbox.root, ledger: unreadableLedger});
    expect(parseStdout(stdout.out).candidate_count).toBe(0);

    // The same window with a readable, empty ledger surfaces the class, so the
    // zero above is the guard refusing and not an empty window.
    stdout.out.length = 0;
    run([], {cwd: sandbox.root, ledger: noDeclines});
    expect(parseStdout(stdout.out).candidate_count).toBe(1);
  });

  test('suppresses every class and skips the prune when no repository root resolves', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'axe/color-contrast',
                severity: 'warning',
              },
            ]),
          ])
        )
      )
    );

    // The sandbox is a bare directory, not a git repository.
    run([], {cwd: sandbox.root});

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('reads a real ledger in process and writes nothing to stderr when a class re-surfaces', () => {
    execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: sandbox.root});
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'axe/color-contrast',
                severity: 'warning',
              },
            ]),
          ])
        )
      )
    );
    const stderr = vi
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);

    // No decline entry for the class: the ledger answers `no_decline_entry`
    // and the prune finds nothing to drop. Neither may print.
    run([], {cwd: sandbox.root});

    expect(parseStdout(stdout.out).candidate_count).toBe(1);
    expect(stderr).not.toHaveBeenCalled();
  });

  test('leaves the ledger unpruned when the window read failed', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 4,
      stderr: 'gh: not authenticated',
      stdout: '',
    });

    const fake = makeFakeLedger();
    fake.record('knip/exports', 4, 4);

    run([], {cwd: sandbox.root, ledger: fake.ledger});

    expect(fake.calls.prune).toEqual([]);
    expect(fake.has('knip/exports')).toBe(true);
  });

  test('falls back to candidate_count 0 and gh_ok false when gh fails (non-fatal)', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 4,
      stderr: 'gh: not authenticated',
      stdout: '',
    });

    const exit = run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.candidate_count).toBe(0);
    expect(printed.candidates).toEqual([]);
    expect(printed.gh_ok).toBe(false);
  });

  test('sets gh_ok true on a successful read of a genuinely empty window', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));

    const exit = run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.gh_ok).toBe(true);
    expect(printed.candidate_count).toBe(0);
  });

  test('a fallback suppression recorded between two run() calls survives the intervening prune and silences unclassified', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh(
        [3, 2, 1].map((n) =>
          ghPr(n, [
            findingsComment(n, 'ci', [
              {
                area_tags: [],
                finding_class: 'holistic/unclassified',
                severity: 'warning',
              },
            ]),
          ])
        )
      )
    );

    const fake = makeFakeLedger();

    run([], {cwd: sandbox.root, ledger: fake.ledger});
    expect(parseStdout(stdout.out).unclassified).not.toBeNull();

    fake.record('holistic/unclassified', 3, 3);

    stdout.out.length = 0;
    run([], {cwd: sandbox.root, ledger: fake.ledger});

    expect(parseStdout(stdout.out).unclassified).toBeNull();
    expect(fake.has('holistic/unclassified')).toBe(true);
  });

  test('a fallback baseline is released once its cluster drains, so a later unrelated cluster surfaces at the threshold', () => {
    const fake = makeFakeLedger();

    // Suppress a classless cluster at a high-water count of 8.
    stubClasslessWindow([8, 7, 6, 5, 4, 3, 2, 1]);
    run([], {cwd: sandbox.root, ledger: fake.ledger});
    fake.record('holistic/unclassified', 8, 8);

    // The cluster ages out of the window, taking its baseline with it.
    stubClasslessWindow([9]);
    stdout.out.length = 0;
    run([], {cwd: sandbox.root, ledger: fake.ledger});
    expect(fake.has('holistic/unclassified')).toBe(false);

    // A genuinely different classless cluster now surfaces at 3, not at 11.
    stubClasslessWindow([12, 11, 10]);
    stdout.out.length = 0;
    run([], {cwd: sandbox.root, ledger: fake.ledger});

    const unclassified = parseStdout(stdout.out).unclassified as Record<
      string,
      unknown
    >;
    expect(unclassified).not.toBeNull();
    expect(unclassified.distinct_pr_count).toBe(3);
  });

  test('counts PRs past the first search page, so the 1000-result cap is not the window', () => {
    const first = fullSearchPage(5000).map((pr, index) =>
      index === 0 ? {...pr, comments: [recurringFinding(5000)]} : pr
    );
    vi.spyOn(runProcess, 'runGh')
      .mockReturnValueOnce(stubGh(first))
      .mockReturnValueOnce(
        stubGh([
          {
            ...ghPr(3001, [recurringFinding(3001)]),
            createdAt: '2026-08-01T00:00:00Z',
          },
          {
            ...ghPr(3000, [recurringFinding(3000)]),
            createdAt: '2026-07-31T00:00:00Z',
          },
        ])
      );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.gh_ok).toBe(true);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(candidates[0]?.finding_class).toBe('rule/switch-statement');
    expect(candidates[0]?.distinct_pr_count).toBe(3);
  });

  test('reads a window the walk cannot finish as unread: gh_ok false, ledger unpruned, window_truncated', () => {
    vi.spyOn(runProcess, 'runGh').mockImplementation(() =>
      stubGh(fullSearchPage(90_000))
    );

    const fake = makeFakeLedger();
    fake.record('knip/exports', 4, 4);

    const stderr = vi
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);

    const exit = run([], {cwd: sandbox.root, ledger: fake.ledger});
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.gh_ok).toBe(false);
    expect(printed.candidate_count).toBe(0);
    expect(fake.has('knip/exports')).toBe(true);
    const diagnostic = JSON.parse(String(stderr.mock.calls[0]?.[0])) as Record<
      string,
      unknown
    >;
    expect(diagnostic.code).toBe('window_truncated');
  });

  test('queries the 90-day merged-PR window via gh', () => {
    const ghSpy = vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const args = ghSpy.mock.calls[0]?.[0] ?? [];
    expect(args).toContain('pr');
    expect(args).toContain('list');
    expect(args).toContain('merged');
    const searchIndex = args.indexOf('--search');
    expect(args[searchIndex + 1]).toMatch(
      /^merged:>=\d{4}-\d{2}-\d{2} sort:created-desc$/
    );
  });

  test('UAT-002/UAT-003: audited_pr_count, tally_schema_version, and no-snapshot triggers', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(
      stubGh([
        ghPr(1, [
          findingsComment(1, 'ci', [
            {
              area_tags: [],
              finding_class: 'holistic/stale-figure',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(2, [findingsComment(2, 'ci', [])]),
        ghPr(3, [
          findingsComment(3, 'ci', [
            {
              area_tags: [],
              finding_class: 'holistic/stale-figure',
              severity: 'warning',
            },
          ]),
        ]),
        ghPr(4, []),
        ghPr(5, []),
      ])
    );

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.audited_pr_count).toBe(3);
    expect(printed.tally_schema_version).toBe(TALLY_SCHEMA_VERSION);
    expect(printed.snapshot_present).toBe(false);
    expect(printed.snapshot_reviewed_at).toBeNull();
    expect(printed.triggers).toEqual([]);
    expect(ReviewTallyInputSchema.safeParse(printed).success).toBe(true);
  });

  test('a snapshot written from a first run reads back unchanged on an identical re-run, candidates included', () => {
    stubClassWindow({
      bystanders: 0,
      findingClass: 'holistic/overclaimed-guarantee',
      recurring: 3,
    });

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });
    const firstEmitted = ReviewTallyInputSchema.parse(parseStdout(stdout.out));

    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(firstEmitted, REFERENCE_NOW)
    );

    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.snapshot_present).toBe(true);
    expect(printed.snapshot_reviewed_at).toBe(REFERENCE_NOW.toISOString());
    expect(printed.triggers).toEqual([]);
    const candidates = printed.candidates as Record<string, unknown>[];
    expect(
      candidates.some(
        (c) => c.finding_class === 'holistic/overclaimed-guarantee'
      )
    ).toBe(true);
    expect(ReviewTallyInputSchema.safeParse(printed).success).toBe(true);
  });

  test('a schema-version mismatch refuses every other trigger, clearing after a fresh snapshot; repeated on an all-clear window', () => {
    stubClassWindow({
      bystanders: 0,
      findingClass: 'holistic/n-plus-one',
      recurring: 3,
    });

    const mismatchedSnapshot: ReviewSnapshot = {
      audited_pr_count: 3,
      classes: {},
      reviewed_at: REFERENCE_NOW.toISOString(),
      tally_schema_version: TALLY_SCHEMA_VERSION + 1,
      unclassified: null,
      version: 1,
      window_days: 90,
    };
    writeReviewSnapshot(sandbox.root, mismatchedSnapshot);

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });
    expect(parseStdout(stdout.out).triggers).toEqual([{type: 'schema_change'}]);

    const firstEmitted = ReviewTallyInputSchema.parse(parseStdout(stdout.out));
    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(firstEmitted, REFERENCE_NOW)
    );

    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });
    expect(parseStdout(stdout.out).triggers).toEqual([]);

    // Repeat on an all-clear window (candidate_count 0, unclassified null).
    vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));
    writeReviewSnapshot(sandbox.root, mismatchedSnapshot);

    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });
    expect(parseStdout(stdout.out).triggers).toEqual([{type: 'schema_change'}]);

    const allClearEmitted = ReviewTallyInputSchema.parse(
      parseStdout(stdout.out)
    );
    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(allClearEmitted, REFERENCE_NOW)
    );

    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });
    expect(parseStdout(stdout.out).triggers).toEqual([]);
  });

  test('a malformed snapshot (invalid JSON, and valid JSON failing the schema) is ignored, not trusted', () => {
    stubClassWindow({
      bystanders: 0,
      findingClass: 'holistic/swallowed-error',
      recurring: 3,
    });

    for (const contents of ['{"broken":', '{"version":2}']) {
      writeRawSnapshot(sandbox.root, contents);
      stdout.out.length = 0;
      const stderr = vi
        .spyOn(process.stderr, 'write')
        .mockImplementation(() => true);

      run([], {
        cwd: sandbox.root,
        ledger: noDeclines,
      });

      const printed = parseStdout(stdout.out);
      expect(printed.snapshot_present).toBe(false);
      expect(printed.triggers).toEqual([]);
      const candidates = printed.candidates as Record<string, unknown>[];
      expect(candidates.length).toBeGreaterThan(0);
      expect(ReviewTallyInputSchema.safeParse(printed).success).toBe(true);

      const diagnostic = JSON.parse(
        String(stderr.mock.calls[0]?.[0])
      ) as Record<string, unknown>;
      expect(diagnostic.code).toBe('malformed_snapshot');
      stderr.mockRestore();
    }
  });

  test('gh_ok false with a valid snapshot present: triggers empty, audited_pr_count 0, snapshot_present true', () => {
    writeReviewSnapshot(sandbox.root, {
      audited_pr_count: 10,
      classes: {},
      reviewed_at: REFERENCE_NOW.toISOString(),
      tally_schema_version: TALLY_SCHEMA_VERSION,
      unclassified: null,
      version: 1,
      window_days: 90,
    });

    vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 4,
      stderr: 'gh: not authenticated',
      stdout: '',
    });

    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    const printed = parseStdout(stdout.out);
    expect(printed.triggers).toEqual([]);
    expect(printed.audited_pr_count).toBe(0);
    expect(printed.snapshot_present).toBe(true);
  });

  test('20a: a class suppressed at review start is absent from that snapshot, so its later re-surfacing reads as new_class, not rising_class (accepted behavior, never reviewed under that snapshot)', () => {
    stubClassWindow({
      bystanders: 2,
      findingClass: 'holistic/n-plus-one',
      recurring: 3,
    });

    // First run: the ledger fake reports the class suppressed, so it is
    // absent from both candidates and class_inventory in this run's emitted
    // JSON, and therefore absent from the snapshot built from it.
    run([], {
      cwd: sandbox.root,
      ledger: {
        check: () => ({status: 'suppressed'}),
        prune: () => undefined,
      },
    });
    const suppressedEmitted = ReviewTallyInputSchema.parse(
      parseStdout(stdout.out)
    );
    expect(
      suppressedEmitted.class_inventory.some(
        (entry) => entry.finding_class === 'holistic/n-plus-one'
      )
    ).toBe(false);

    writeReviewSnapshot(
      sandbox.root,
      snapshotFromTally(suppressedEmitted, REFERENCE_NOW)
    );

    // Second run, same window: an empty fake store stands in for a decline
    // that re-surfaced, so the ledger no longer reports it suppressed.
    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      ledger: noDeclines,
    });

    expect(parseStdout(stdout.out).triggers).toEqual([
      {finding_class: 'holistic/n-plus-one', type: 'new_class'},
    ]);
  });
});
