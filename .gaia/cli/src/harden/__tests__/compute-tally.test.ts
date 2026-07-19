import {describe, expect, test} from 'vitest';
import {isValidFindingClass} from '../../schemas/finding-class.js';
import {computeTally, windowClasses} from '../compute-tally.js';
import type {TallyPrRecord} from '../compute-tally.js';

const pr = (
  prNumber: number,
  findings: TallyPrRecord['findings']
): TallyPrRecord => ({findings, pr_number: prNumber});

const noCover = (): boolean => false;
const noSuppress = (): boolean => false;

describe('computeTally', () => {
  test('surfaces a class seen on 3 distinct PRs at warning severity', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1201, [
          {
            area_tags: ['app/components'],
            finding_class: 'react-doctor/no-generic-handler-names',
            severity: 'warning',
          },
        ]),
        pr(1188, [
          {
            area_tags: ['app/components'],
            finding_class: 'react-doctor/no-generic-handler-names',
            severity: 'warning',
          },
        ]),
        pr(1175, [
          {
            area_tags: ['app/hooks'],
            finding_class: 'react-doctor/no-generic-handler-names',
            severity: 'warning',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(1);
    expect(result.window_days).toBe(90);

    const [candidate] = result.candidates;
    expect(candidate.finding_class).toBe(
      'react-doctor/no-generic-handler-names'
    );
    expect(candidate.distinct_pr_count).toBe(3);
    expect(candidate.severity_max).toBe('warning');
    expect(candidate.pr_numbers).toEqual([1201, 1188, 1175]);
    expect(candidate.area_tags).toEqual(['app/components', 'app/hooks']);
    expect(candidate.is_oracle).toBe(true);
  });

  test('sets is_oracle false for a closed-vocabulary (non-oracle) class', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'warning',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]?.is_oracle).toBe(false);
  });

  test('does not surface a class on only 2 distinct PRs', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(2, [
          {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
        ]),
        pr(1, [
          {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
  });

  test('does not surface a class repeated 3 times within ONE PR', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
          {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
          {area_tags: [], finding_class: 'knip/exports', severity: 'warning'},
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
  });

  test('UAT-001: a suggestion-only recurring class is a candidate with severity_max suggestion', () => {
    const suggestionOnly = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/hardcoded-string',
            severity: 'suggestion',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });
    expect(suggestionOnly.candidate_count).toBe(1);
    expect(suggestionOnly.candidates[0]?.distinct_pr_count).toBe(3);
    expect(suggestionOnly.candidates[0]?.severity_max).toBe('suggestion');
    expect(suggestionOnly.unclassified).toBeNull();

    const atWarning = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/hardcoded-string',
            severity: 'warning',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });
    expect(atWarning.candidate_count).toBe(1);
    expect(atWarning.candidates[0]?.severity_max).toBe('warning');
  });

  test('combines CI-run and local-run findings for the same class across distinct PRs', () => {
    // Each PR contributes one comment block (CI or local); the core only sees a
    // per-PR finding list, so auditor location never changes eligibility.
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(10, [
          {
            area_tags: ['app'],
            finding_class: 'rule/switch-statement',
            severity: 'warning',
          },
        ]),
        pr(11, [
          {
            area_tags: ['app'],
            finding_class: 'rule/switch-statement',
            severity: 'error',
          },
        ]),
        pr(12, [
          {
            area_tags: ['app'],
            finding_class: 'rule/switch-statement',
            severity: 'warning',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(1);
    expect(result.candidates[0]?.severity_max).toBe('error');
  });

  test('collapses two same-class findings in one PR to a single distinct-PR count', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [30, 20, 10].map((n) =>
        pr(n, [
          {
            area_tags: ['app/routes'],
            finding_class: 'holistic/missing-auth-check',
            severity: 'error',
          },
          {
            area_tags: ['app/pages'],
            finding_class: 'holistic/missing-auth-check',
            severity: 'warning',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]?.distinct_pr_count).toBe(3);
    expect(result.candidates[0]?.severity_max).toBe('error');
    expect(result.candidates[0]?.area_tags).toEqual([
      'app/routes',
      'app/pages',
    ]);
  });

  test('ignores class-less / invalid findings entirely', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {area_tags: [], finding_class: '', severity: 'error'},
          {
            area_tags: [],
            finding_class: 'not-a-real-prefix/x',
            severity: 'error',
          },
          {
            area_tags: [],
            finding_class: 'holistic/something-made-up',
            severity: 'error',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
  });

  test('UAT-002: an unseeded holistic slug is dropped, not a candidate nor unclassified', () => {
    expect(isValidFindingClass('holistic/arbitrary-slug')).toBe(false);

    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/arbitrary-slug',
            severity: 'error',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
    expect(result.unclassified).toBeNull();
  });

  test('UAT-003: a classless recurring finding surfaces as the distinct unclassified signal, not a candidate', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {
            area_tags: ['app/routes'],
            finding_class: 'holistic/unclassified',
            severity: 'warning',
          },
          // A second, distinct classless finding in the SAME PR must still
          // collapse to a single distinct-PR increment (cardinality one).
          {
            area_tags: ['app/services'],
            finding_class: 'holistic/unclassified',
            severity: 'error',
          },
        ]),
        pr(2, [
          {
            area_tags: [],
            finding_class: 'holistic/unclassified',
            severity: 'suggestion',
          },
        ]),
        pr(3, [
          {
            area_tags: [],
            finding_class: 'holistic/unclassified',
            severity: 'warning',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
    expect(
      result.candidates.every(
        (c) => c.finding_class !== 'holistic/unclassified'
      )
    ).toBe(true);
    expect(result.unclassified).not.toBeNull();
    expect(result.unclassified?.distinct_pr_count).toBe(3);
    expect(result.unclassified?.severity_max).toBe('error');
    expect(result.unclassified?.area_tags).toEqual([
      'app/routes',
      'app/services',
    ]);
  });

  test('UAT-007: a classless finding on only 2 distinct PRs leaves unclassified null', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/unclassified',
            severity: 'warning',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.unclassified).toBeNull();
  });

  test('windowClasses never includes the classless unclassified bucket (Directive #2)', () => {
    const prs = [3, 2, 1].map((n) =>
      pr(n, [
        {
          area_tags: [],
          finding_class: 'holistic/unclassified',
          severity: 'warning',
        },
      ])
    );

    expect(windowClasses(prs)).toEqual([]);
  });

  test('Directive #1: severity_max is a running max across PRs (suggestion then error -> error)', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'suggestion',
          },
        ]),
        pr(2, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'error',
          },
        ]),
        pr(3, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'suggestion',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]?.severity_max).toBe('error');
  });

  test('Directive #1: severity_max is never downgraded (warning then suggestion -> warning)', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [
        pr(1, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'warning',
          },
        ]),
        pr(2, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'suggestion',
          },
        ]),
        pr(3, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'suggestion',
          },
        ]),
      ],
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]?.severity_max).toBe('warning');
  });

  test('Directive #5: an oracle-prefixed class at suggestion severity is still a candidate', () => {
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'knip/exports',
            severity: 'suggestion',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidates[0]?.is_oracle).toBe(true);
    expect(result.candidates[0]?.severity_max).toBe('suggestion');
  });

  test('Directive #4: a recorded recurring class counts regardless of self-heal (the tally has no self-heal notion)', () => {
    // The tally only sees whatever findings were recorded in the block for
    // each PR; it has no concept of "found-and-healed". A class recorded as
    // recurring produces a candidate even though the tally cannot know (and
    // does not care) whether a later PR fixed the underlying issue.
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'holistic/swallowed-error',
            severity: 'warning',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(1);
    expect(result.candidates[0]?.finding_class).toBe(
      'holistic/swallowed-error'
    );
  });

  test('drops a class a promoted rule already covers', () => {
    const result = computeTally({
      coveredClass: (c) => c === 'rule/switch-statement',
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'rule/switch-statement',
            severity: 'warning',
          },
        ])
      ),
      suppressedClass: noSuppress,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
  });

  test('drops a class the ledger reports suppressed and passes the live PR count', () => {
    const seen: number[] = [];
    const result = computeTally({
      coveredClass: noCover,
      prs: [3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'axe/color-contrast',
            severity: 'error',
          },
        ])
      ),
      suppressedClass: (_c, currentPrCount) => {
        seen.push(currentPrCount);

        return true;
      },
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(0);
    expect(seen).toContain(3);
  });

  test('windowClasses returns classes with >= threshold recurrence regardless of suppression', () => {
    const prs = [
      ...[3, 2, 1].map((n) =>
        pr(n, [
          {
            area_tags: [],
            finding_class: 'axe/color-contrast',
            severity: 'warning',
          },
        ])
      ),
      pr(99, [
        {area_tags: [], finding_class: 'knip/types', severity: 'warning'},
      ]),
    ];

    expect(windowClasses(prs)).toEqual(['axe/color-contrast']);
  });
});
