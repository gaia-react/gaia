import {describe, expect, test} from 'vitest';
import {renderCard, type FitnessReport} from './render-card.js';

const baseReport = (): FitnessReport => ({
  categories: [
    {grade: 'A+', name: 'Hook integrity'},
    {grade: 'B+', name: 'Skill / command / agent frontmatter'},
    {grade: 'A+', name: 'Rule hygiene'},
    {grade: 'A', name: 'CLAUDE.md hygiene'},
    {grade: 'A+', name: 'Settings hygiene'},
    {grade: 'A', name: 'GAIA-install fitness'},
    {grade: 'A+', name: 'Wiki fitness'},
  ],
  command: '/gaia-fitness',
  findings: [
    {
      category: 'Skill / command / agent frontmatter',
      file: '.claude/commands/deploy.md',
      grade: 'B+',
      remediation:
        'description frontmatter is missing; add a concise description of what this command does.',
      severity: 'warning',
    },
    {
      category: 'CLAUDE.md hygiene',
      file: 'CLAUDE.md',
      grade: 'A',
      remediation:
        '@-import of a path-scoped rule resolves but is always-loaded; consider whether it warrants it.',
      severity: 'info',
    },
  ],
  overall: 'B+',
});

const lineWidths = (card: string): number[] =>
  card.split('\n').map((line) => line.length);

const allEqual = (values: readonly number[]): boolean =>
  values.every((value) => value === values[0]);

describe('renderCard', () => {
  test('every line shares one width so the borders align', () => {
    const widths = lineWidths(renderCard(baseReport(), 80));

    expect(allEqual(widths)).toBe(true);
    expect(widths[0]).toBeGreaterThan(0);
  });

  test('opens and closes with a full border bar', () => {
    const lines = renderCard(baseReport(), 80).split('\n');

    expect(lines[0]).toMatch(/^\+-+\+$/);
    expect(lines[lines.length - 1]).toMatch(/^\+-+\+$/);
  });

  test('renders categories alphabetically', () => {
    const card = renderCard(baseReport(), 80);
    const order = [
      'CLAUDE.md hygiene',
      'GAIA-install fitness',
      'Hook integrity',
      'Rule hygiene',
      'Settings hygiene',
      'Skill / command / agent frontmatter',
      'Wiki fitness',
    ];
    const indices = order.map((name) => card.indexOf(`| ${name}`));

    for (const index of indices) expect(index).toBeGreaterThan(-1);

    expect(indices).toEqual([...indices].sort((a, b) => a - b));
  });

  test('omits the FINDINGS block on a clean run and carries no footer', () => {
    const report = baseReport();
    report.findings = [];
    report.categories = report.categories.map((category) => ({
      ...category,
      grade: 'A+',
    }));
    report.overall = 'A+';

    const card = renderCard(report, 100);

    expect(card).not.toContain('FINDINGS');
    expect(card).not.toContain('git diff');
    expect(allEqual(lineWidths(card))).toBe(true);
  });

  test('caps the box at 120 columns on a very wide terminal', () => {
    const report = baseReport();
    report.findings = [
      {
        category: 'Hook integrity',
        file: '.claude/settings.json',
        grade: 'C',
        remediation: 'x'.repeat(400),
        severity: 'error',
      },
    ];

    expect(Math.max(...lineWidths(renderCard(report, 500)))).toBeLessThanOrEqual(
      WIDTH_CAP_PLUS_BORDER
    );
  });

  test('truncates an over-long file path while keeping borders aligned', () => {
    const report = baseReport();
    report.findings = [
      {
        category: 'Hook integrity',
        file: `.claude/${'nested/'.repeat(40)}hook.sh`,
        grade: 'C',
        remediation: 'fix it',
        severity: 'error',
      },
    ];

    const card = renderCard(report, 80);

    expect(card).toContain('...');
    expect(allEqual(lineWidths(card))).toBe(true);
  });

  test('keeps a mixed-severity note aligned and summarized', () => {
    const report = baseReport();
    report.findings = [
      {
        category: 'Settings hygiene',
        file: '.claude/settings.json:3',
        grade: 'C',
        remediation: 'secret-shaped value in env block',
        severity: 'error',
      },
      {
        category: 'Settings hygiene',
        file: '.claude/settings.json:9',
        grade: 'C',
        remediation: 'redundant permission entry',
        severity: 'info',
      },
    ];

    const card = renderCard(report, 100);

    expect(card).toContain('1 error, 1 info');
    expect(allEqual(lineWidths(card))).toBe(true);
  });
});

const WIDTH_CAP_PLUS_BORDER = 124; // 120-column cap + "| " and " |"
