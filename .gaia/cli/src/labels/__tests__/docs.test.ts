import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import type {LabelRegistry} from '../../schemas/labels.js';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {
  GENERATED_END_MARKER,
  GENERATED_START_MARKER,
  renderGeneratedSpan,
  spliceGeneratedSpan,
} from '../docs.js';
import {readRegistry} from '../registry.js';

const MAINTAINER_START = '<!-- gaia:maintainer-only:start -->';
const MAINTAINER_END = '<!-- gaia:maintainer-only:end -->';

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const registry = readRegistry(repoRoot);

const adopterRegistry: LabelRegistry = {
  ...registry,
  labels: registry.labels.filter((entry) => entry.audience !== 'maintainer'),
};

const maintainerNames = registry.labels
  .filter((entry) => entry.audience === 'maintainer')
  .map((entry) => entry.name);

/** What `release-scrub.yml`'s marker strip does to the rendered span. */
const stripMaintainerBlock = (span: string): string => {
  const lines = span.split('\n');
  const start = lines.indexOf(MAINTAINER_START);
  const end = lines.indexOf(MAINTAINER_END);

  return [...lines.slice(0, start), ...lines.slice(end + 1)].join('\n');
};

const SEPARATOR_ROW = /^\|(?: --- \|)+$/u;

/** Table headers left with no body row: the defect the marker strip risks. */
const headerOnlyTables = (markdown: string): string[] => {
  const lines = markdown.split('\n');

  return lines.flatMap((line, index) => {
    const separator = lines[index + 1] ?? '';
    const body = lines[index + 2] ?? '';

    if (!line.startsWith('|') || !SEPARATOR_ROW.test(separator)) return [];

    return body.startsWith('|') ? [] : [line];
  });
};

const buildPage = (span: string): string =>
  ['# Header', '', GENERATED_START_MARKER, span, GENERATED_END_MARKER, ''].join(
    '\n'
  );

describe('labels/docs renderGeneratedSpan', () => {
  test('two renders of the same registry are byte-identical', () => {
    expect(renderGeneratedSpan(registry)).toBe(renderGeneratedSpan(registry));
  });

  test('the module never imports the process runner', () => {
    const source = readFileSync(
      path.join(repoRoot, '.gaia', 'cli', 'src', 'labels', 'docs.ts'),
      'utf8'
    );

    expect(source).not.toContain('run-process');
  });

  test('the adopter tables carry no maintainer row', () => {
    const span = renderGeneratedSpan(registry);
    const adopterSection = span.slice(0, span.indexOf(MAINTAINER_START));

    expect(maintainerNames).toHaveLength(6);

    for (const name of maintainerNames) {
      expect(adopterSection).not.toContain(`\`${name}\``);
    }
  });

  test('the mixed-axis maintainer entries are the ones that need row filtering', () => {
    // Four of the six sit in axes that also carry adopter rows, so an
    // axis-level filter would leave them inside an adopter table.
    const mixed = [
      'non-issue',
      'gaia-forensics',
      'gaia-triaged',
      'auto-fixable',
    ];
    const span = renderGeneratedSpan(registry);
    const adopterSection = span.slice(0, span.indexOf(MAINTAINER_START));

    for (const name of mixed) {
      expect(maintainerNames).toContain(name);
      expect(adopterSection).not.toContain(`\`${name}\``);
    }
  });

  test('the maintainer section emits one table per axis it carries', () => {
    const span = renderGeneratedSpan(registry);
    const block = span.slice(
      span.indexOf(MAINTAINER_START),
      span.indexOf(MAINTAINER_END)
    );
    const headings = block
      .split('\n')
      .filter((line) => line.startsWith('### '));

    expect(headings).toEqual([
      '### Disposition',
      '### Origin and trigger',
      '### Attention gate',
      '### Audience',
    ]);
  });

  test('stripping the maintainer block equals the adopter-registry render', () => {
    expect(stripMaintainerBlock(renderGeneratedSpan(registry))).toBe(
      renderGeneratedSpan(adopterRegistry)
    );
  });

  test('the adopter-registry render carries no maintainer markers', () => {
    const span = renderGeneratedSpan(adopterRegistry);

    expect(span).not.toContain(MAINTAINER_START);
    expect(span).not.toContain(MAINTAINER_END);
  });

  test('neither the full nor the stripped render leaves a header-only table', () => {
    const span = renderGeneratedSpan(registry);

    expect(headerOnlyTables(span)).toEqual([]);
    expect(headerOnlyTables(stripMaintainerBlock(span))).toEqual([]);
  });

  test('the header-only-table detector can report', () => {
    const broken = ['| Label | Reason |', '| --- | --- |', '', '## Next'].join(
      '\n'
    );

    expect(headerOnlyTables(broken)).toEqual(['| Label | Reason |']);
  });

  test('the render carries no em dash and no en dash', () => {
    const span = renderGeneratedSpan(registry);

    // Escapes, not the characters themselves: the house rule bans both from
    // every file in the tree, and a repo-wide grep for them has to stay clean.
    expect(span).not.toContain('\u2014');
    expect(span).not.toContain('\u2013');
  });

  test('every rendered description is at most 100 characters', () => {
    const descriptions = renderGeneratedSpan(registry)
      .split('\n')
      .filter((line) => line.startsWith('| `') && !SEPARATOR_ROW.test(line))
      .map((line) => line.split(' | ', 3)[2] ?? '');

    expect(descriptions.length).toBeGreaterThan(20);

    for (const description of descriptions) {
      expect(description.length).toBeLessThanOrEqual(100);
    }
  });

  test('the blocked entries render with their reasons', () => {
    const span = renderGeneratedSpan(registry);

    expect(span).toContain('## Deliberately absent');
    expect(span).toContain('| `good first issue` | Solicits drive-by');
    expect(span).toContain('| `help wanted` | Same solicitation problem');
  });
});

describe('labels/docs spliceGeneratedSpan', () => {
  test('every byte outside the marker pair survives', () => {
    const original = buildPage('\nold body\n');
    const next = spliceGeneratedSpan(original, '\nnew body\n');

    expect(next.startsWith(`# Header\n\n${GENERATED_START_MARKER}\n`)).toBe(
      true
    );
    expect(next.endsWith(`\n${GENERATED_END_MARKER}\n`)).toBe(true);
    expect(next).toContain('new body');
    expect(next).not.toContain('old body');
  });

  test('a hand-maintained appendix below the end marker is untouched', () => {
    const original = [
      GENERATED_START_MARKER,
      'generated',
      GENERATED_END_MARKER,
      '',
      '## Project labels',
      'mine',
    ].join('\n');

    expect(spliceGeneratedSpan(original, 'fresh')).toBe(
      [
        GENERATED_START_MARKER,
        'fresh',
        GENERATED_END_MARKER,
        '',
        '## Project labels',
        'mine',
      ].join('\n')
    );
  });

  test('a page with no markers throws', () => {
    expect(() => spliceGeneratedSpan('# Header\n', 'x')).toThrow(
      GENERATED_START_MARKER
    );
  });

  test('a page with only a start marker throws', () => {
    expect(() =>
      spliceGeneratedSpan(`${GENERATED_START_MARKER}\n`, 'x')
    ).toThrow(GENERATED_START_MARKER);
  });

  test('a page with three markers throws', () => {
    const page = [
      GENERATED_START_MARKER,
      GENERATED_START_MARKER,
      GENERATED_START_MARKER,
      GENERATED_END_MARKER,
    ].join('\n');

    expect(() => spliceGeneratedSpan(page, 'x')).toThrow(
      GENERATED_START_MARKER
    );
  });

  test('an end marker above its start throws', () => {
    const page = [GENERATED_END_MARKER, GENERATED_START_MARKER].join('\n');

    expect(() => spliceGeneratedSpan(page, 'x')).toThrow('at or above');
  });

  test('a marker that is not a whole line does not count', () => {
    const page = [
      `prose ${GENERATED_START_MARKER} prose`,
      GENERATED_END_MARKER,
    ].join('\n');

    expect(() => spliceGeneratedSpan(page, 'x')).toThrow(
      GENERATED_START_MARKER
    );
  });
});
