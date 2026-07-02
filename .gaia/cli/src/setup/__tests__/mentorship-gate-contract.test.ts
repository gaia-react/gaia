/**
 * Coupling guard: the `mentorship_decision_missing` code is a cross-artifact
 * contract. `setup finalize` emits it on the mentorship-artifact refusal;
 * gaia-init Step 12 literal-matches it to self-heal. This test fails if either
 * side drifts, so the emitter and the matcher cannot silently diverge.
 */
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run as runFinalize} from '../finalize.js';
import {run as runMarkStep} from '../mark-step.js';
import {SETUP_STEPS} from '../util/state-file.js';

const CODE = 'mentorship_decision_missing';

// Resolve the repo root robustly regardless of the vitest cwd (`pnpm -C .gaia/cli`
// runs with cwd = .gaia/cli, not the repo root).
const repoRoot = execFileSync('git', ['rev-parse', '--show-toplevel'], {
  encoding: 'utf8',
}).trim();

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-coupling-'));
  execFileSync('git', ['init', '-q'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

/**
 * Parse the last non-empty stderr line as JSON and return its `code` field.
 * Asserting the parsed `.code`, never a substring match over the whole buffer,
 * is the [D5] contract the refusal tests share.
 */
const lastErrorCode = (errors: string[]): string => {
  const lines = errors.join('').trim().split('\n');

  return (JSON.parse(lines[lines.length - 1] as string) as {code: string}).code;
};

describe('mentorship_decision_missing coupling guard', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('emitter: `setup finalize` emits the code on the absent-artifact refusal', () => {
    // Mark every step so the pending gate does not fire first, and write NO
    // mentorship.json so the mentorship gate is the refusal we observe. Every
    // handler call passes {cwd: sandbox.root} so both resolve the sandbox, not
    // the real repo (finalize/mark-step otherwise default to process.cwd()).
    for (const step of SETUP_STEPS) {
      runMarkStep([step], {cwd: sandbox.root});
    }

    const exit = runFinalize([], {cwd: sandbox.root});

    expect(exit).toBe(1);
    expect(lastErrorCode(stdio.errors)).toBe(CODE);
  });

  test('matcher: gaia-init.md Step 12 contains the code literal', () => {
    // Free-text prose, so a substring check is the correct form here: the
    // contract is literally "the string appears in the doc" (contrast the
    // emitter assertion, which parses JSON `.code`).
    const initDoc = readFileSync(
      path.join(repoRoot, '.claude', 'commands', 'gaia-init.md'),
      'utf8'
    );

    expect(initDoc).toContain(CODE);
  });
});
