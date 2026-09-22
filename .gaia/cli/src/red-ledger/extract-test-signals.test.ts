/**
 * Pins the stdout-exit contract of the RED-ledger signal helper
 * (`.gaia/scripts/red-ledger/extract-test-signals.mjs`): a reader that stops
 * before EOF must leave the helper exiting 0 with a silent stderr.
 *
 * The helper emits one record per test, so a few thousand tests out-write the
 * pipe buffer and the reader's close lands mid-write. Without an EPIPE
 * listener on `process.stdout` node raises `Unhandled 'error' event`, prints a
 * stack trace, and exits 1. No in-repo consumer stops early (each reads to EOF
 * through a command substitution or `execFileSync`), so this guards the manual
 * invocation the helper's README documents.
 *
 * `.gaia/tests/hooks/red-ledger-lib.bats` carries the same assertion, but its
 * `setup()` skips wherever `node_modules/typescript` is absent, which is the
 * lean box `audit-ci-tests.yml` runs the hook suites on. This suite runs in the
 * CLI Tests job, where the dependency exists, so it is the copy that reds a
 * required check if the listener is removed.
 *
 * Maintainer-only by construction: `.gaia/scripts` is release-excluded, so the
 * helper and this test never ship to adopters.
 */
import {describe, expect, test} from 'vitest';
import {execFileSync, spawn} from 'node:child_process';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const SIGNAL_HELPER = path.join(
  REPO_ROOT,
  '.gaia/scripts/red-ledger/extract-test-signals.mjs'
);

// The helper resolves `typescript` by walking up from its own location to the
// repo-root node_modules. The CLI Tests CI job installs deps only in
// `.gaia/cli`, so typescript lives there, not at the (uninstalled) repo root.
// Expose `.gaia/cli/node_modules` via NODE_PATH so the exec'd script resolves
// typescript whether or not the repo root is installed.
const CLI_NODE_MODULES = path.join(REPO_ROOT, '.gaia/cli/node_modules');
const HELPER_ENV = {...process.env, NODE_PATH: CLI_NODE_MODULES};

// A pipe holds 64KB, so the fixture has to out-write that for an early close to
// land mid-write. 3000 tests yields a few hundred KB of records; a fixture that
// fits in one flush would pass this suite even with the listener removed, which
// is what the size assertion below refuses to let happen.
const PIPE_BUFFER_BYTES = 65_536;
const TEST_FILE_REL = 'app/generated/tests/index.test.ts';
const BIG_SOURCE = Array.from(
  {length: 3000},
  (_unused, index) =>
    `test('generated case ${index}', () => {\n  expect(${index}).toBe(${index});\n});`
).join('\n');

const runToCompletion = (): string =>
  execFileSync('node', [SIGNAL_HELPER, TEST_FILE_REL, '--stdin'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
    input: BIG_SOURCE,
    maxBuffer: 64 * 1024 * 1024,
  });

/**
 * Runs the helper and destroys the read end of its stdout after the first
 * chunk, which is what `| head` does to it. Resolves with the exit code and
 * whatever reached stderr.
 */
const runWithEarlyClosingReader = async (): Promise<{
  code: null | number;
  stderr: string;
}> =>
  new Promise((resolve, reject) => {
    const child = spawn('node', [SIGNAL_HELPER, TEST_FILE_REL, '--stdin'], {
      cwd: REPO_ROOT,
      env: HELPER_ENV,
    });
    let stderr = '';

    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk: string) => {
      stderr += chunk;
    });
    child.stdout.once('data', () => {
      child.stdout.destroy();
    });
    // The helper writes far more than stdin's own buffer can absorb while it is
    // still reading, so the write below can outpace it; EPIPE here is the same
    // early-close being tested, not a harness failure.
    child.stdin.on('error', () => {});
    child.on('error', reject);
    child.on('close', (code) => {
      resolve({code, stderr});
    });
    child.stdin.end(BIG_SOURCE);
  });

describe('extract-test-signals stdout-exit contract', () => {
  test('the fixture out-writes the pipe buffer', () => {
    expect(runToCompletion().length).toBeGreaterThan(PIPE_BUFFER_BYTES);
  });

  test('exits 0 with a silent stderr when the reader closes early', async () => {
    const {code, stderr} = await runWithEarlyClosingReader();

    expect(stderr).toBe('');
    expect(code).toBe(0);
  });
});

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
