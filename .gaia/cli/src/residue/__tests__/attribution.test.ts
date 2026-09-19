import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {
  attributeBody,
  attributeBodyWith,
  CANON_ACCEPT,
  CANON_WAIVE,
  DEFAULT_PREDICATES,
} from '../attribution.js';
import {KEY_PATTERN} from '../key.js';

// Fixtures are arrays of lines, and every expected line number is computed
// from the array rather than hand-counted, so reordering a fixture cannot
// silently desync an assertion from its content.
const bodyOf = (lines: readonly string[]): string => lines.join('\n');

const lineOf = (lines: readonly string[], needle: string): number => {
  const index = lines.findIndex((line) => line.includes(needle));

  if (index === -1) {
    throw new Error(`fixture carries no line containing "${needle}"`);
  }

  return index + 1;
};

const key = (className: string, keyPath: string, line: number): string =>
  `<!-- gaia-debt-key: v1 class=${className} path=${keyPath} line=${line} -->`;

// Both sides of the key-grammar parity check capture the inner key for their
// own emit, and neither uses a group for anything else, so the parentheses are
// the one difference the comparison is allowed to ignore. Stripping them on
// BOTH sides keeps the assertion stable whichever side carries a group.
const withoutGroups = (source: string): string =>
  source.replaceAll(/[()]/g, '');

// UAT-004 named mutant helper: reverts a key-grammar source's path
// terminator from the closer-scoped spelling back to the pre-change
// space-scoped one.
const revertPathTerminatorToSpace = (source: string): string =>
  source.replace('path=[^>]+', 'path=[^ ]+');

const MIXED_LINES = [
  '# Summary',
  `Prose outside any canonical section, carrying ${key('x/prose', 'app/prose.ts', 1)}.`,
  '',
  CANON_ACCEPT,
  '',
  `Intro prose beneath the canonical heading, carrying ${key('x/intro', 'app/intro.ts', 2)} outside any unit.`,
  '',
  `- Accepted one ${key('a/one', 'app/one.ts', 11)}`,
  '- Accepted two, whose key sits on a continuation line',
  `  continued here ${key('a/two', 'app/two.ts', 22)}`,
  '',
  CANON_WAIVE,
  '',
  `- Waived one ${key('w/one', '.gaia/scripts/w.sh', 33)}`,
  '',
  '## Documentation example',
  '',
  `Write the dedup key as ${key('doc/example', 'app/doc.ts', 44)}.`,
];

const FIRST_MATCH_LINES = [
  CANON_ACCEPT,
  `- First unit ${key('a/first', 'app/first.ts', 1)}`,
  '  more text',
  '  and more',
  `  a second key ${key('a/second', 'app/second.ts', 2)}`,
  `- Two keys on one line ${key('b/left', 'app/left.ts', 3)} ${key('b/right', 'app/right.ts', 4)}`,
];

const KEYLESS_LINES = [
  CANON_ACCEPT,
  `- A keyed entry ${key('a/keyed', 'app/keyed.ts', 7)}`,
  '- An entry nobody keyed',
  '  with a continuation line and still no key',
  CANON_WAIVE,
  '- A waived entry nobody keyed either',
];

const INTERRUPTED_LINES = [
  CANON_ACCEPT,
  '- An entry whose key arrives too late',
  '#### An interrupting heading',
  `Now a key ${key('a/late', 'app/late.ts', 9)}`,
];

const MALFORMED_LINES = [
  CANON_ACCEPT,
  `- Absolute path ${key('m/abs', '/etc/passwd', 5)}`,
  `- Traversal path ${key('m/traverse', 'app/../../etc/passwd', 5)}`,
  `- Traversal after normalization ${key('m/normalized', 'app/./../../x', 5)}`,
  `- Leading dash ${key('m/dash', '--upload-pack=x', 5)}`,
  `- Line zero ${key('m/zero', 'app/zero.ts', 0)}`,
];

const NO_V1_LINES = [
  CANON_ACCEPT,
  '- An entry whose key omits the version token <!-- gaia-debt-key: class=n/one path=app/n.ts line=5 -->',
];

const ALL_FIXTURES = [
  MIXED_LINES,
  FIRST_MATCH_LINES,
  KEYLESS_LINES,
  INTERRUPTED_LINES,
  MALFORMED_LINES,
  NO_V1_LINES,
];

describe('attributeBody, entry attribution', () => {
  test('attributes only keyed units, never a key sitting outside one', () => {
    const result = attributeBody(bodyOf(MIXED_LINES));

    expect(result.entries.map((entry) => entry.key.path)).toStrictEqual([
      'app/one.ts',
      'app/two.ts',
      '.gaia/scripts/w.sh',
    ]);
    expect(result.keyless_count).toBe(0);
    expect(result.malformed).toStrictEqual([]);
  });

  test('tags each entry with the disposition of the heading it sat beneath', () => {
    const result = attributeBody(bodyOf(MIXED_LINES));

    // Hand-enumerated per entry, not merely "both values occur".
    expect(
      result.entries.map((entry) => [entry.key.path, entry.disposition])
    ).toStrictEqual([
      ['app/one.ts', 'accept'],
      ['app/two.ts', 'accept'],
      ['.gaia/scripts/w.sh', 'waive'],
    ]);
  });

  test('records each entry at its opening bullet line, key on the bullet or on a continuation', () => {
    const result = attributeBody(bodyOf(MIXED_LINES));

    expect(result.entries.map((entry) => entry.unit_start_line)).toStrictEqual([
      lineOf(MIXED_LINES, '- Accepted one'),
      lineOf(MIXED_LINES, '- Accepted two'),
      lineOf(MIXED_LINES, '- Waived one'),
    ]);
  });

  test('latches the first key in a unit and emits exactly one entry for it', () => {
    const result = attributeBody(bodyOf(FIRST_MATCH_LINES));

    expect(result.entries).toHaveLength(2);
    expect(result.entries[0]?.raw_key).toBe(
      'v1 class=a/first path=app/first.ts line=1'
    );
    expect(result.entries[1]?.raw_key).toBe(
      'v1 class=b/left path=app/left.ts line=3'
    );
  });

  test('records a keyless unit with its disposition and opening bullet line', () => {
    const result = attributeBody(bodyOf(KEYLESS_LINES));

    expect(result.entries).toHaveLength(1);
    expect(result.keyless).toStrictEqual([
      {
        disposition: 'accept',
        unit_start_line: lineOf(KEYLESS_LINES, '- An entry nobody keyed'),
      },
      {
        disposition: 'waive',
        unit_start_line: lineOf(KEYLESS_LINES, '- A waived entry'),
      },
    ]);
    expect(result.keyless_count).toBe(result.keyless.length);
  });

  test('attributes beneath a canonical heading spelled at any level, not only at level two', () => {
    const accept = CANON_ACCEPT.replace('## ', '');
    const waive = CANON_WAIVE.replace('## ', '');

    for (const marker of ['#', '###', '######']) {
      const lines = [
        `${marker} ${accept}`,
        `- An accepted entry ${key('a/one', 'app/one.ts', 1)}`,
        `${marker} ${waive}`,
        `- A waived entry ${key('w/one', 'app/two.ts', 2)}`,
      ];
      const result = attributeBody(bodyOf(lines));

      expect(
        result.entries.map((entry) => [entry.disposition, entry.key.path])
      ).toStrictEqual([
        ['accept', 'app/one.ts'],
        ['waive', 'app/two.ts'],
      ]);
      expect(result.keyless).toStrictEqual([]);
    }
  });

  test('the separator widens to any one whitespace character, so a tab-separated canonical heading is canonical', () => {
    const result = attributeBody(
      bodyOf([
        `##\t${CANON_ACCEPT.replace('## ', '')}`,
        `- An entry ${key('a/one', 'app/one.ts', 1)}`,
      ])
    );

    expect(result.entries.map((entry) => entry.key.path)).toStrictEqual([
      'app/one.ts',
    ]);
    expect(result.keyless).toStrictEqual([]);
  });

  test('the separator never widens to a run of whitespace, so a two-space canonical heading is not canonical', () => {
    const result = attributeBody(
      bodyOf([
        `###  ${CANON_ACCEPT.replace('## ', '')}`,
        `- An entry ${key('a/one', 'app/one.ts', 1)}`,
      ])
    );

    expect(result.entries).toStrictEqual([]);
    expect(result.keyless).toStrictEqual([]);
  });

  test('attributes nothing in a body carrying no canonical heading', () => {
    const result = attributeBody(
      bodyOf([
        '## Summary',
        `- An entry ${key('a/one', 'app/one.ts', 1)}`,
        '## Accepted residuals',
        `- A near-miss heading ${key('a/two', 'app/two.ts', 2)}`,
      ])
    );

    expect(result.entries).toStrictEqual([]);
    expect(result.keyless).toStrictEqual([]);
  });

  test('closes an open unit on a heading of any level', () => {
    const result = attributeBody(bodyOf(INTERRUPTED_LINES));

    expect(result.entries).toStrictEqual([]);
    expect(result.keyless).toStrictEqual([
      {
        disposition: 'accept',
        unit_start_line: lineOf(INTERRUPTED_LINES, '- An entry whose key'),
      },
    ]);
  });

  test('derives a failure_mode carrying no newline and no HTML comment', () => {
    const failureModes = ALL_FIXTURES.flatMap((lines) =>
      attributeBody(bodyOf(lines)).entries.map((entry) => entry.failure_mode)
    );

    expect(failureModes.length).toBeGreaterThan(0);

    for (const failureMode of failureModes) {
      expect(failureMode).not.toMatch(/[\n\r]/);
      expect(failureMode).not.toContain('<!--');
      expect(failureMode).not.toContain('-->');
    }

    expect(attributeBody(bodyOf(MIXED_LINES)).entries[0]?.failure_mode).toBe(
      'Accepted one'
    );
  });

  // PR #1160's shape: the entry wraps, its key sits on a continuation line,
  // and unrelated prose follows a blank line while still inside the unit.
  test('keeps a wrapped entry whole and stops at the end of its list item', () => {
    const lines = [
      CANON_WAIVE,
      '',
      '- **`changelog.ts:4`**: the docblock opens `Step 7 of the',
      '  runbook`, but `release changelog` is `### 5. Graduate`.',
      '',
      '  An indented paragraph still belongs to the item.',
      `  ${key('holistic/unclassified', '.gaia/cli/src/release/changelog.ts', 4)}`,
      '',
      'Unindented prose after a blank line is not part of the entry.',
    ];

    expect(attributeBody(bodyOf(lines)).entries[0]?.failure_mode).toBe(
      '**`changelog.ts:4`**: the docblock opens `Step 7 of the runbook`, but `release changelog` is `### 5. Graduate`. An indented paragraph still belongs to the item.'
    );
  });

  // PR #1145's shape: a code span quotes a bare `<!--` opener before the real
  // key comment, which is itself wrapped in a code span.
  test('does not let a quoted comment opener swallow the text before the real key', () => {
    const lines = [
      CANON_WAIVE,
      `- quotes the \`<!-- gaia-debt-key: v1 \` prefix, never parse behavior. \`${key('holistic/unclassified', '.gaia/tests/lib/doc-debt-query.bats', 101)}\``,
    ];

    expect(attributeBody(bodyOf(lines)).entries[0]?.failure_mode).toBe(
      'quotes the `<!-- gaia-debt-key: v1 ` prefix, never parse behavior.'
    );
  });

  test('leaves the code spans on either side of a bare comment intact', () => {
    const lines = [
      CANON_WAIVE,
      `- spans \`a\`${key('holistic/unclassified', 'app/a.ts', 1)}\`b\` stay apart`,
    ];

    expect(attributeBody(bodyOf(lines)).entries[0]?.failure_mode).toBe(
      'spans `a` `b` stay apart'
    );
  });
});

describe('attributeBody, malformed keys', () => {
  test('withholds a gate-matching key whose fields fail validation and names why', () => {
    const result = attributeBody(bodyOf(MALFORMED_LINES));

    expect(result.entries).toStrictEqual([]);
    expect(result.keyless).toStrictEqual([]);
    expect(
      result.malformed.map((entry) => [entry.unit_start_line, entry.reason])
    ).toStrictEqual([
      [
        lineOf(MALFORMED_LINES, '- Absolute path'),
        expect.stringContaining('absolute prefix'),
      ],
      [
        lineOf(MALFORMED_LINES, '- Traversal path'),
        expect.stringContaining('traversal segment'),
      ],
      [
        lineOf(MALFORMED_LINES, '- Traversal after normalization'),
        expect.stringContaining('traversal segment'),
      ],
      [
        lineOf(MALFORMED_LINES, '- Leading dash'),
        expect.stringContaining('leading dash'),
      ],
      [
        lineOf(MALFORMED_LINES, '- Line zero'),
        expect.stringContaining('below 1'),
      ],
    ]);
    expect(result.malformed[0]?.disposition).toBe('accept');
    expect(result.malformed[0]?.raw_key).toBe(
      'v1 class=m/abs path=/etc/passwd line=5'
    );
  });

  test('a unit whose only key omits v1 is keyless, exactly as the gate reads it', () => {
    const result = attributeBody(bodyOf(NO_V1_LINES));

    // The gate's grammar requires the v1 token, so it never sees this as a
    // key at all and denies the merge over a keyless unit. Attributing it as
    // malformed here would give the unit two tuples in the conformance
    // comparison against the gate's one.
    expect(result.entries).toStrictEqual([]);
    expect(result.malformed).toStrictEqual([]);
    expect(result.keyless).toHaveLength(1);
  });

  test('a valid path carrying a dot segment collapses and attributes', () => {
    const result = attributeBody(
      bodyOf([
        CANON_ACCEPT,
        `- Dotted ${key('a/dot', 'app/./services//foo.ts', 1)}`,
      ])
    );

    expect(result.malformed).toStrictEqual([]);
    expect(result.entries[0]?.key.path).toBe('app/services/foo.ts');
  });
});

describe('attributeBodyWith, the predicate seam', () => {
  test('a mutated canonWaive stops attributing beneath the real waive heading', () => {
    const body = bodyOf(MIXED_LINES);
    const mutated = attributeBodyWith(body, {
      ...DEFAULT_PREDICATES,
      canonWaive: '## Out-of-scope machinery findings (recorded, not FILED)',
    });

    expect(mutated.entries.map((entry) => entry.key.path)).toStrictEqual([
      'app/one.ts',
      'app/two.ts',
    ]);
    expect(attributeBody(body).entries).toHaveLength(3);
  });

  test('a mutated keyPattern stops attributing keys the default recognizes', () => {
    const body = bodyOf(FIRST_MATCH_LINES);
    const mutated = attributeBodyWith(body, {
      ...DEFAULT_PREDICATES,
      keyPattern: /<!-- gaia-residue-key: (v\d+ [^>]*?) -->/,
    });

    expect(mutated.entries).toStrictEqual([]);
    expect(mutated.keyless_count).toBe(2);
    expect(attributeBody(body).entries).toHaveLength(2);
  });
});

describe('recognizer parity with the merge gate', () => {
  const HOOK_RELATIVE_PATH = '.claude/hooks/audit-residual-shape-check.sh';

  const hookAssignment = (name: string): string => {
    const hookPath = path.join(
      resolveRepoRootFromImportMeta(import.meta.url),
      HOOK_RELATIVE_PATH
    );
    const source = readFileSync(hookPath, 'utf8');
    const match = new RegExp(`^${name}='(.*)'$`, 'm').exec(source);

    if (match?.[1] === undefined) {
      throw new Error(
        `${HOOK_RELATIVE_PATH} carries no single-quoted ${name} assignment; the extraction this parity test rests on is broken, not the constant`
      );
    }

    return match[1];
  };

  test('CANON_ACCEPT and CANON_WAIVE are byte-identical to the gate literals', () => {
    expect(CANON_ACCEPT).toBe(hookAssignment('CANON_ACCEPT'));
    expect(CANON_WAIVE).toBe(hookAssignment('CANON_WAIVE'));
  });

  test('KEY_PATTERN matches the gate key regex up to capture parentheses', () => {
    expect(withoutGroups(KEY_PATTERN.source)).toBe(
      withoutGroups(hookAssignment('key_re'))
    );
  });

  // UAT-004 named mutant (SPEC-082). The test above is green at HEAD and
  // green after this SPEC's grammar move, so on its own it discriminates
  // nothing: forgetting to move one side would pass it just as cleanly.
  // This drives the actual partial-edit failure mode by reverting each
  // side's path terminator from the closer-scoped spelling back to the
  // pre-change space-scoped one and asserting the parity comparison fails.
  //
  // `withoutGroups` strips capture parentheses from BOTH sides (see its own
  // comment above `withoutGroups`'s definition), so a mutant differing only
  // in parentheses is a deliberate equivalence class this test does not
  // catch; the conformance table in
  // `.gaia/tests/hooks/residue-attribution-conformance.bats` is what covers
  // that class instead.
  //
  // `path=[^ ]+` below is the one sanctioned occurrence of the pre-change
  // terminator under `.gaia/cli/src/`: the acceptance criterion that
  // `git grep -n 'path=\[\^ \]' -- .gaia/cli/src .gaia/cli/gaia ':!*__tests__*'`
  // returns nothing excludes `__tests__` precisely so this mutant can live
  // here. A later sweep repairing this occurrence would be a mistake.
  test("UAT-004 named mutant: reverting either side's path terminator to a space fails the parity comparison", () => {
    const tsSide = KEY_PATTERN.source;
    const gateSide = hookAssignment('key_re');

    // Sanity: the real (unmutated) comparison this parity test makes.
    expect(withoutGroups(tsSide)).toBe(withoutGroups(gateSide));

    const mutatedTsSide = revertPathTerminatorToSpace(tsSide);

    expect(mutatedTsSide).not.toBe(tsSide);
    expect(withoutGroups(mutatedTsSide)).not.toBe(withoutGroups(gateSide));

    const mutatedGateSide = revertPathTerminatorToSpace(gateSide);

    expect(mutatedGateSide).not.toBe(gateSide);
    expect(withoutGroups(tsSide)).not.toBe(withoutGroups(mutatedGateSide));
  });
});
