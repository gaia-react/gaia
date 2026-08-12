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
