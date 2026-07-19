import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import * as runProcess from '../../ci/util/run-process.js';
import type {ProcessResult} from '../../ci/util/run-process.js';
import {markerComment} from '../marker.js';
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
    });

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
  });

  test('does not surface a suggestion-only class', () => {
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
    });

    expect(parseStdout(stdout.out).candidate_count).toBe(0);
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
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
      runLedger: () => ({exitCode: 0, stderr: '', stdout: ''}),
    });
    expect(parseStdout(stdout.out).candidate_count).toBe(0);

    // Fresh evidence: ledger now says NOT suppressed (exit 1): re-surfaces.
    stdout.out.length = 0;
    run([], {
      cwd: sandbox.root,
      runLedger: (argv) =>
        argv.includes('is-suppressed') ?
          {exitCode: 1, stderr: '', stdout: ''}
        : {exitCode: 0, stderr: '', stdout: ''},
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

    const ledgerCalls: string[][] = [];
    run([], {
      cwd: sandbox.root,
      runLedger: (argv) => {
        ledgerCalls.push([...argv]);

        return {exitCode: 1, stderr: '', stdout: ''};
      },
    });

    const pruneCall = ledgerCalls.find((c) => c.includes('prune'));
    expect(pruneCall).toBeDefined();
    const idx = (pruneCall ?? []).indexOf('--window-classes');
    expect((pruneCall ?? [])[idx + 1]).toBe('axe/color-contrast');
  });

  test('falls back to candidate_count 0 and gh_ok false when gh fails (non-fatal)', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 4,
      stderr: 'gh: not authenticated',
      stdout: '',
    });

    const exit = run([], {
      cwd: sandbox.root,
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
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
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
    });
    expect(exit).toBe(0);

    const printed = parseStdout(stdout.out);
    expect(printed.gh_ok).toBe(true);
    expect(printed.candidate_count).toBe(0);
  });

  test('queries the 90-day merged-PR window via gh', () => {
    const ghSpy = vi.spyOn(runProcess, 'runGh').mockReturnValue(stubGh([]));

    run([], {
      cwd: sandbox.root,
      runLedger: () => ({exitCode: 1, stderr: '', stdout: ''}),
    });

    const args = ghSpy.mock.calls[0]?.[0] ?? [];
    expect(args).toContain('pr');
    expect(args).toContain('list');
    expect(args).toContain('merged');
    const searchIndex = args.indexOf('--search');
    expect(args[searchIndex + 1]).toMatch(/^merged:>=\d{4}-\d{2}-\d{2}$/);
  });
});
