/**
 * Pins the title-handling carve-outs of the RED-ledger signal helper
 * (`.gaia/scripts/red-ledger/extract-test-signals.mjs`): a `.each`, `.for`, or
 * dynamic-title `describe`/`test` has no source title vitest preserves
 * verbatim at runtime, so the helper must emit nothing for one rather than
 * recording an identity the RED ledger could never match back up.
 */
import {describe, expect, test} from 'vitest';
import {execFileSync, spawnSync} from 'node:child_process';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const SIGNAL_HELPER = path.join(
  REPO_ROOT,
  '.gaia/scripts/red-ledger/extract-test-signals.mjs'
);

// The helper resolves `typescript` by walking up from its own location to the
// repo-root node_modules. The GAIA: CLI Tests workflow installs deps only in
// `.gaia/cli`, so typescript lives there, not at the (uninstalled) repo root.
// Expose `.gaia/cli/node_modules` via NODE_PATH so the exec'd script resolves
// typescript whether or not the repo root is installed.
const CLI_NODE_MODULES = path.join(REPO_ROOT, '.gaia/cli/node_modules');
const HELPER_ENV = {...process.env, NODE_PATH: CLI_NODE_MODULES};

const TEST_FILE_REL = 'frontend/app/generated/tests/index.test.ts';

/**
 * Pins the `.each` carve-out (gaia-react/gaia#2224): vitest expands an
 * `.each` row into the title at runtime, so a title argument on the call is
 * never the fullName the RED ledger records, whatever kind of literal it is.
 * `red-verify-commit-check.sh`'s own carve-out (lines 19-24) treats a test
 * with NO emitted signal as uncomputable identity and therefore never
 * blocked, so the fix this suite drives is: emit nothing for an `.each` call.
 */
type ExtractedSignal = {
  fullName: string;
  kind: string;
  signal: string;
};

const runOnSource = (source: string): ExtractedSignal[] =>
  execFileSync('node', [SIGNAL_HELPER, TEST_FILE_REL, '--stdin'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
    input: source,
  })
    .split('\n')
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as ExtractedSignal);

describe('extract-test-signals .each title handling', () => {
  test('test.each with a $prop title emits no signal', () => {
    const lines = runOnSource(`
      test.each([{from: '/en', to: '/'}])('301s $from to $to', ({from, to}) => {
        expect(from).not.toBe(to);
      });
    `);

    expect(lines).toEqual([]);
  });

  test('test.each with a printf %s title emits no signal', () => {
    const lines = runOnSource(`
      test.each([['a', 'b']])('converts %s to %s', (a, b) => {
        expect(a).not.toBe(b);
      });
    `);

    expect(lines).toEqual([]);
  });

  test('it.each with a $prop title emits no signal', () => {
    const lines = runOnSource(`
      it.each([{n: 1}])('handles $n', ({n}) => {
        expect(n).toBeGreaterThan(0);
      });
    `);

    expect(lines).toEqual([]);
  });

  test('tagged-template test.each emits no signal', () => {
    const lines = runOnSource(`
      test.each\`
        a    | b
        \${1} | \${2}
      \`('sums $a and $b', ({a, b}) => {
        expect(a + b).toBeGreaterThan(0);
      });
    `);

    expect(lines).toEqual([]);
  });

  test('describe.each with a $prop title emits no signal for a nested static-titled test', () => {
    const lines = runOnSource(`
      describe.each([{group: 'a'}])('group $group', ({group}) => {
        test('does the static thing', () => {
          expect(group).toBeTruthy();
        });
      });
    `);

    expect(lines).toEqual([]);
  });

  test('tagged-template describe.each emits no signal for a nested static-titled test', () => {
    const lines = runOnSource(`
      describe.each\`
        group
        \${'a'}
        \${'b'}
      \`('group $group', ({group}) => {
        test('does the static thing', () => {
          expect(group).toBeTruthy();
        });
      });
    `);

    expect(lines).toEqual([]);
  });

  test('a plain static test still emits a signal (regression guard)', () => {
    const lines = runOnSource(`
      test('adds numbers', () => {
        expect(1 + 1).toBe(2);
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]?.fullName).toBe('adds numbers');
    expect(lines[0]?.kind).toBe('runtime');
  });
});

/**
 * Pins the dynamic-title describe carve-out (gaia-react/gaia#2224, reached
 * through the template-literal trigger rather than `.each`): a describe whose
 * title is a template literal with a substitution is expanded by vitest at
 * runtime, same as `.each`, so the declared source title is never the prefix
 * vitest records. `titleOf` already returns null for it; this suite pins that
 * null propagates to `unmatchable` for every title-null reason, not only
 * `.each`, so descendants stop emitting under a silently shortened prefix.
 */
describe('extract-test-signals dynamic-title describe handling', () => {
  test('a template-literal-titled describe emits no signal for a nested static test', () => {
    const lines = runOnSource(`
      const x = 1;
      describe(\`group \${x}\`, () => {
        test('does the thing', () => {
          expect(1).toBe(1);
        });
      });
    `);

    expect(lines).toEqual([]);
  });

  test('a nested dynamic-title describe suppresses only its own subtree', () => {
    const lines = runOnSource(`
      const x = 1;
      describe('outer', () => {
        test('static sibling', () => {
          expect(1).toBe(1);
        });
        describe(\`inner \${x}\`, () => {
          test('nested', () => {
            expect(1).toBe(1);
          });
        });
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]?.fullName).toBe('outer static sibling');
  });

  test('a static describe with a static test still emits fullName (regression guard)', () => {
    const lines = runOnSource(`
      describe('outer', () => {
        test('inner', () => {
          expect(1).toBe(1);
        });
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]?.fullName).toBe('outer inner');
  });

  test('a dynamic-title test inside a static describe suppresses only itself (regression guard)', () => {
    const lines = runOnSource(`
      const x = 1;
      describe('outer', () => {
        test(\`dynamic \${x}\`, () => {
          expect(1).toBe(1);
        });
        test('static sibling', () => {
          expect(1).toBe(1);
        });
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]?.fullName).toBe('outer static sibling');
  });
});

/**
 * Pins the `.for` carve-out (gaia-react/gaia#2224's `.each` fix, widened):
 * vitest 5.0.0 declares `for` alongside `each` on both the test and suite
 * chainable APIs, and interpolates the same `$prop` / printf tokens into a
 * `.for` title. It is the same unsatisfiable-identity hazard `.each` has, so
 * it gets the same treatment: emit nothing for a `.for` call.
 */
describe('extract-test-signals .for title handling', () => {
  test('test.for with a $prop title emits no signal', () => {
    const lines = runOnSource(`
      test.for([{from: '/en', to: '/'}])('301s $from to $to', ({from, to}) => {
        expect(from).not.toBe(to);
      });
    `);

    expect(lines).toEqual([]);
  });

  test('describe.for with a $prop title emits no signal for a nested static-titled test', () => {
    const lines = runOnSource(`
      describe.for([{group: 'a'}])('group $group', ({group}) => {
        test('does the static thing', () => {
          expect(group).toBeTruthy();
        });
      });
    `);

    expect(lines).toEqual([]);
  });
});

/**
 * Story mode: a `*.stories.tsx` path is read as CSF. Each story with an
 * effective play function is one test addon-vitest runs, so the helper emits
 * one signal per such story, named the way Storybook names the test, and
 * refuses (exit 7, empty stdout) any shape whose play it cannot resolve: a
 * silent empty result would let the worthiness gate pass the file unjudged.
 */
const STORY_FILE_REL = 'frontend/app/generated/tests/index.stories.tsx';

const runStory = (source: string) => {
  const result = spawnSync('node', [SIGNAL_HELPER, STORY_FILE_REL, '--stdin'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
    input: source,
  });

  return {
    lines: result.stdout
      .split('\n')
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line) as ExtractedSignal),
    status: result.status,
    stderr: result.stderr,
    stdout: result.stdout,
  };
};

const storyLines = (source: string): ExtractedSignal[] => {
  const result = runStory(source);

  expect(result.stderr).toBe('');
  expect(result.status).toBe(0);

  return result.lines;
};

const namesOf = (lines: ExtractedSignal[]) =>
  lines.map((line) => line.fullName);

const signalOf = (lines: ExtractedSignal[], fullName: string) =>
  lines.find((line) => line.fullName === fullName)?.signal;

const META = `
  const meta = {component: Widget, args: {size: 'small'}, title: 'Widget'};
  export default meta;
`;

describe('extract-test-signals story mode: play shapes', () => {
  test('an object-property play emits one runtime line named by start-casing the export', () => {
    const lines = storyLines(`${META}
      export const LongStoryName = {
        play: async () => {
          await check();
        },
      };
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({
      fullName: 'Long Story Name',
      kind: 'runtime',
    });
    expect(lines[0]?.signal).toMatch(/^sha256:[0-9a-f]{64}$/);
  });

  test('a digit in the export name is split the way Storybook splits it', () => {
    const lines = storyLines(`${META}
      export const Step2Done = {play: async () => check()};
    `);

    expect(namesOf(lines)).toEqual(['Step 2 Done']);
  });

  test('a string-literal name property overrides the export name', () => {
    const lines = storyLines(`${META}
      export const Renamed = {name: 'Custom', play: async () => check()};
    `);

    expect(namesOf(lines)).toEqual(['Custom']);
  });

  test('a storyName assignment overrides the export name', () => {
    const lines = storyLines(`${META}
      export const Renamed = {play: async () => check()};
      Renamed.storyName = 'Assigned Name';
    `);

    expect(namesOf(lines)).toEqual(['Assigned Name']);
  });

  test('a play assigned after a function story emits that story', () => {
    const lines = storyLines(`${META}
      export const Invalid = () => <Widget />;
      Invalid.play = async () => {
        await check();
      };
    `);

    expect(namesOf(lines)).toEqual(['Invalid']);
  });

  test('a play shared by identifier emits every story that uses it', () => {
    const lines = storyLines(`${META}
      const showError = async () => {
        await check();
      };
      export const Default = () => <Widget />;
      Default.play = showError;
      export const Hidden = () => <Widget hidden />;
      Hidden.play = showError;
    `);

    expect(namesOf(lines)).toEqual(['Default', 'Hidden']);
  });

  test('a story built by a same-file factory inherits the play the factory returns', () => {
    const lines = storyLines(`${META}
      const createArrowStory = (type) => ({play: async () => check(type)});
      function createBlockStory(type) {
        const label = type + ' story';
        return {play: async () => check(label)};
      }
      export const ErrorType = createArrowStory('error');
      export const Info = createBlockStory('info');
    `);

    expect(namesOf(lines)).toEqual(['Error Type', 'Info']);
  });

  test('a meta-level play makes every story without its own play a test', () => {
    const lines = storyLines(`
      const meta = {component: Widget, play: async () => check(), title: 'Widget'};
      export default meta;
      export const Plain = {};
      export const Rendered = () => <Widget />;
    `);

    expect(namesOf(lines)).toEqual(['Plain', 'Rendered']);
  });

  test('a story spreading another story inherits its play', () => {
    const lines = storyLines(`${META}
      export const Base = {play: async () => check()};
      export const Variant = {...Base, args: {size: 'large'}};
    `);

    expect(namesOf(lines)).toEqual(['Base', 'Variant']);
  });

  test('a render-only story emits nothing', () => {
    expect(
      storyLines(`${META}
        export const Default = {args: {size: 'large'}};
        export const Rendered = () => <Widget />;
      `)
    ).toEqual([]);
  });

  test('a play overridden to undefined falls through to the meta, here absent', () => {
    expect(
      storyLines(`${META}
        export const Base = {play: async () => check()};
        Base.play = undefined;
        export const Variant = {...Base};
        export const Cleared = {play: async () => check(), ...{play: undefined}};
      `)
    ).toEqual([]);
  });
});

describe('extract-test-signals story mode: test tags', () => {
  test('a story tagged !test emits nothing', () => {
    const lines = storyLines(`${META}
      export const Kept = {play: async () => check()};
      export const Dropped = {play: async () => check(), tags: ['!test']};
    `);

    expect(namesOf(lines)).toEqual(['Kept']);
  });

  test('a meta tagged !test suppresses every story that does not re-add test', () => {
    const lines = storyLines(`
      const meta = {component: Widget, tags: ['!test'], title: 'Widget'};
      export default meta;
      export const Suppressed = {play: async () => check()};
      export const Restored = {play: async () => check(), tags: ['test']};
    `);

    expect(namesOf(lines)).toEqual(['Restored']);
  });
});

const sharedPlaySource = (body: string, metaArgs: string) => `
  const meta = {component: Widget, args: ${metaArgs}, title: 'Widget'};
  export default meta;
  const showError = async () => {
    ${body}
  };
  export const Default = () => <Widget />;
  Default.play = showError;
  export const Hidden = () => <Widget hidden />;
  Hidden.play = showError;
  export const Own = {play: async () => check()};
`;

const baseLines = () =>
  storyLines(sharedPlaySource('await check();', "{size: 'small'}"));

describe('extract-test-signals story mode: signal rotation', () => {
  test('editing the shared play body rotates both stories that use it, and only them', () => {
    const base = baseLines();
    const edited = storyLines(
      sharedPlaySource('await check(); await again();', "{size: 'small'}")
    );

    expect(namesOf(edited)).toEqual(['Default', 'Hidden', 'Own']);
    expect(signalOf(edited, 'Default')).not.toBe(signalOf(base, 'Default'));
    expect(signalOf(edited, 'Hidden')).not.toBe(signalOf(base, 'Hidden'));
    expect(signalOf(edited, 'Own')).toBe(signalOf(base, 'Own'));
  });

  test("editing the meta's args rotates every story in the file", () => {
    const base = baseLines();
    const edited = storyLines(
      sharedPlaySource('await check();', "{size: 'large'}")
    );

    for (const name of ['Default', 'Hidden', 'Own']) {
      expect(signalOf(edited, name)).not.toBe(signalOf(base, name));
    }
  });

  test('reformatting whitespace or rewording a comment rotates no signal', () => {
    const reworded = storyLines(
      sharedPlaySource(
        '// a reworded comment\n\n      await   check();',
        "{size:\n        'small'}"
      )
    );
    const original = storyLines(
      sharedPlaySource(
        '// the first comment\n      await check();',
        "{size: 'small'}"
      )
    );

    expect(reworded).toEqual(original);
    expect(namesOf(original)).toEqual(['Default', 'Hidden', 'Own']);
  });
});

const expectRefusal = (source: string, exportName: string, reason: RegExp) => {
  const result = runStory(source);

  expect(result.status).toBe(7);
  expect(result.stdout).toBe('');
  expect(
    result.stderr.startsWith(
      `extract-test-signals: unsupported story shape in ${STORY_FILE_REL}: ${exportName}: `
    )
  ).toBe(true);
  expect(result.stderr.split('\n')).toHaveLength(2);
  expect(result.stderr).toMatch(reason);
};

describe('extract-test-signals story mode: refusal', () => {
  test('a play bound to an imported identifier is refused', () => {
    expectRefusal(
      `import {sharedPlay} from './plays';
      ${META}
      export const Default = () => <Widget />;
      Default.play = sharedPlay;
    `,
      'Default',
      /imported identifier sharedPlay/
    );
  });

  test('a CSF4 meta.story() export is refused', () => {
    expectRefusal(
      `${META}
      export const Primary = meta.story({args: {size: 'large'}});
    `,
      'Primary',
      /CSF4 factory story/
    );
  });

  test('a spread cycle is refused', () => {
    expectRefusal(
      `${META}
      export const First = {...Second};
      export const Second = {...First};
    `,
      'First',
      /cycle/
    );
  });

  test('a story built by an imported function is refused', () => {
    expectRefusal(
      `import {makeStory} from './factory';
      ${META}
      export const Built = makeStory('x');
    `,
      'Built',
      /imported function makeStory/
    );
  });

  test('a .test() call on a story is refused', () => {
    expectRefusal(
      `${META}
      export const Primary = {};
      Primary.test('does a thing', async () => check());
    `,
      'Primary',
      /test story/
    );
  });

  test('a meta excludeStories is refused before any story', () => {
    expectRefusal(
      `const meta = {component: Widget, excludeStories: /.*Data$/, title: 'Widget'};
      export default meta;
      export const Primary = {play: async () => check()};
    `,
      'default',
      /excludeStories/
    );
  });

  test('an export clause is refused', () => {
    expectRefusal(
      `${META}
      const Hidden = {play: async () => check()};
      export {Hidden as Shown};
    `,
      'Shown',
      /`export \{…\}` clause/
    );
  });

  test('a play body that calls imported helpers is not refused', () => {
    const lines = storyLines(`import {expectToast} from './expect-toast';
      ${META}
      export const Toasted = {play: async ({canvasElement}) => expectToast(canvasElement, 'Saved')};
    `);

    expect(namesOf(lines)).toEqual(['Toasted']);
  });
});
