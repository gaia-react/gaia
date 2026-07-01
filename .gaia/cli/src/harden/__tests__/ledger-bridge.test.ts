import {describe, expect, it, vi} from 'vitest';
import {EXIT_CODES} from '../../exit.js';
import {
  type LedgerRunner,
  makeLedgerSuppressionPredicate,
  pruneLedger,
} from '../ledger-bridge.js';
import type {ProcessResult} from '../../ci/util/run-process.js';

const ok = (stdout = ''): ProcessResult => ({exitCode: 0, stderr: '', stdout});
const notSuppressed = (): ProcessResult => ({
  exitCode: 1,
  stderr: '',
  stdout: '',
});

describe('makeLedgerSuppressionPredicate', () => {
  it('treats exit 0 as suppressed and passes the class + live count to the ledger', () => {
    const calls: string[][] = [];
    const predicate = makeLedgerSuppressionPredicate({
      cwd: '/repo',
      runLedger: (argv) => {
        calls.push([...argv]);

        return ok();
      },
    });

    expect(predicate('axe/color-contrast', 5)).toBe(true);

    const args = calls.at(-1) ?? [];
    expect(args).toContain('harden-ledger');
    expect(args).toContain('is-suppressed');
    const classIdx = args.indexOf('--finding-class');
    expect(args[classIdx + 1]).toBe('axe/color-contrast');
    const countIdx = args.indexOf('--current-pr-count');
    expect(args[countIdx + 1]).toBe('5');
  });

  it('treats exit 1 (the legitimate not-suppressed code) as not suppressed', () => {
    const predicate = makeLedgerSuppressionPredicate({
      cwd: '/repo',
      runLedger: notSuppressed,
    });

    expect(predicate('axe/color-contrast', 5)).toBe(false);
  });

  it('fails closed on CONFIG_INVALID (a corrupt / version-skewed ledger)', () => {
    const predicate = makeLedgerSuppressionPredicate({
      cwd: '/repo',
      runLedger: () => ({
        exitCode: EXIT_CODES.CONFIG_INVALID,
        stderr: '',
        stdout: '',
      }),
    });

    // Fail-closed: an error exit stays suppressed so a corrupt ledger never
    // silently re-surfaces a declined candidate.
    expect(predicate('axe/color-contrast', 5)).toBe(true);
  });

  it('fails closed on STORAGE_INACCESSIBLE', () => {
    const predicate = makeLedgerSuppressionPredicate({
      cwd: '/repo',
      runLedger: () => ({
        exitCode: EXIT_CODES.STORAGE_INACCESSIBLE,
        stderr: '',
        stdout: '',
      }),
    });

    expect(predicate('axe/color-contrast', 5)).toBe(true);
  });
});

describe('pruneLedger', () => {
  it('invokes prune with the comma-joined window classes', () => {
    const runLedger = vi.fn<LedgerRunner>(() => ok());

    pruneLedger({
      cwd: '/repo',
      runLedger,
      windowClasses: ['axe/color-contrast', 'knip/exports'],
    });

    const args = runLedger.mock.calls[0]?.[0] ?? [];
    expect(args).toContain('harden-ledger');
    expect(args).toContain('prune');
    const idx = args.indexOf('--window-classes');
    expect(args[idx + 1]).toBe('axe/color-contrast,knip/exports');
  });

  it('invokes prune with an empty value when no classes remain in the window', () => {
    const runLedger = vi.fn<LedgerRunner>(() => ok());

    pruneLedger({cwd: '/repo', runLedger, windowClasses: []});

    const args = runLedger.mock.calls[0]?.[0] ?? [];
    const idx = args.indexOf('--window-classes');
    expect(args[idx + 1]).toBe('');
  });
});
