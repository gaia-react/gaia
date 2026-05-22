/**
 * Tmpdir + git-init sandbox for the slice 2 fixture tests. Mirrors
 * `src/automation/__tests__/sandbox.ts`, but ships the revert-ledger
 * writer instead of automation-state writers.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import type {RevertLedger} from '../../src/schemas/revert-ledger.js';

export type Sandbox = {
  cleanup: () => void;
  ledgerPath: string;
  root: string;
  writeLedger: (ledger: RevertLedger) => void;
};

export const setupSandbox = (prefix = 'gaia-ci-shape-'): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), prefix));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  writeFileSync(path.join(root, 'README.md'), '# test\n', 'utf8');
  execFileSync('git', ['add', 'README.md'], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'initial'], {cwd: root});
  mkdirSync(path.join(root, '.gaia'), {recursive: true});

  const ledgerPath = path.join(
    root,
    '.gaia',
    'automation.state-revert-attempts.json'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    ledgerPath,
    root,
    writeLedger: (ledger) => {
      writeFileSync(ledgerPath, JSON.stringify(ledger), 'utf8');
    },
  };
};

export const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];

  const stdoutSpy = process.stdout.write.bind(process.stdout);
  const stderrSpy = process.stderr.write.bind(process.stderr);

  process.stdout.write = ((chunk: unknown) => {
    out.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  }) as typeof process.stdout.write;

  process.stderr.write = ((chunk: unknown) => {
    err.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  }) as typeof process.stderr.write;

  return {
    err,
    out,
    restore: () => {
      process.stdout.write = stdoutSpy;
      process.stderr.write = stderrSpy;
    },
  };
};
