import {describe, expect, test, vi} from 'vitest';
import type {ProcessResult} from '../../ci/util/run-process.js';
import {EXIT_CODES} from '../../exit.js';
import {makeLedgerSuppressionPredicate, pruneLedger} from '../ledger-bridge.js';
import type {LedgerRunner} from '../ledger-bridge.js';

const ok = (stdout = ''): ProcessResult => ({exitCode: 0, stderr: '', stdout});
const notSuppressed = (): ProcessResult => ({
  exitCode: 1,
  stderr: '',
  stdout: '',
});

describe('makeLedgerSuppressionPredicate', () => {
  test('treats exit 0 as suppressed and passes the class + live count to the ledger', () => {
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
    const classIndex = args.indexOf('--finding-class');
    expect(args[classIndex + 1]).toBe('axe/color-contrast');
    const countIndex = args.indexOf('--current-pr-count');
    expect(args[countIndex + 1]).toBe('5');
  });

  test('treats exit 1 (the legitimate not-suppressed code) as not suppressed', () => {
    const predicate = makeLedgerSuppressionPredicate({
      cwd: '/repo',
      runLedger: notSuppressed,
    });

    expect(predicate('axe/color-contrast', 5)).toBe(false);
  });

  test('fails closed on CONFIG_INVALID (a corrupt / version-skewed ledger)', () => {
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

  test('fails closed on STORAGE_INACCESSIBLE', () => {
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
  test('invokes prune with the comma-joined window classes', () => {
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

  test('invokes prune with an empty value when no classes remain in the window', () => {
    const runLedger = vi.fn<LedgerRunner>(() => ok());

    pruneLedger({cwd: '/repo', runLedger, windowClasses: []});

    const args = runLedger.mock.calls[0]?.[0] ?? [];
    const idx = args.indexOf('--window-classes');
    expect(args[idx + 1]).toBe('');
  });
});
