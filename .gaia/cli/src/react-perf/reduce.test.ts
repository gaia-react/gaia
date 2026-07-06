import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the `gaia react-perf reduce` Reduce layer.
 *
 * `reduceDump` (the pure algorithm) is asserted directly against the committed
 * fixtures; `run` (the CLI handler) is asserted by capturing stdout/stderr to
 * cover file reading, alien-shape rejection, determinism, and the frame-budget
 * flag. Fixtures live in `test-fixtures/react-perf/`.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {
  RawDumpSchema,
  ReducedSummarySchema,
} from '../schemas/react-perf-summary.js';
import type {RawDump} from '../schemas/react-perf-summary.js';
import {reduceDump, run} from './reduce.js';

const FIXTURES = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../test-fixtures/react-perf'
);

const fixturePath = (name: string): string => path.join(FIXTURES, name);

const loadDump = (name: string): RawDump =>
  RawDumpSchema.parse(JSON.parse(readFileSync(fixturePath(name), 'utf8')));

describe('reduceDump (pure algorithm)', () => {
  describe('legacy bippy-renders-dump.json (no planted bug)', () => {
    const summary = reduceDump(loadDump('bippy-renders-dump.json'), {
      frameBudgetMs: 16,
    });

    test('validates against the Contract-B output schema', () => {
      expect(() => ReducedSummarySchema.parse(summary)).not.toThrow();
    });

    test('counts all 248 records', () => {
      expect(summary.totals.records).toBe(248);
      expect(summary.totals.mounts + summary.totals.updates).toBe(248);
    });

    test('filters the known framework cohort out of findings', () => {
      const names = summary.findings.map((finding) => finding.componentName);
      expect(names).not.toContain('RenderedRoute');
      expect(names).not.toContain('Router');
      expect(names).not.toContain('Links');
      expect(summary.totals.frameworkFiltered).toBeGreaterThan(0);
    });

    test('reports zero memoDefeated and the matching stop signal', () => {
      expect(summary.totals.memoDefeated).toBe(0);
      expect(summary.stopSignal.zeroAppMemoDefeated).toBe(true);
    });

    test('has no app component over the default 16ms budget', () => {
      expect(summary.stopSignal.noAppFrameBudgetBreach).toBe(true);
      expect(summary.findings).toHaveLength(0);
    });

    test('defaults the strictMode caveat to true and meta fields from defaults', () => {
      // Legacy meta is {installed, commits, errors} only.
      expect(summary.strictModeTimingCaveat).toBe(true);
      expect(summary.rendererVersion).toBeNull();
      expect(summary.profilingAvailable).toBe(false);
    });

    test('buckets null-name renders into unknownNameCount (zero here)', () => {
      expect(summary.unknownNameCount).toBe(0);
    });
  });

  describe('memo-defeat.json (one planted culprit)', () => {
    const summary = reduceDump(loadDump('memo-defeat.json'), {
      frameBudgetMs: 16,
    });

    test('produces exactly one memoDefeated finding for StatusBadge, ranked #1', () => {
      expect(summary.findings).toHaveLength(1);
      const [finding] = summary.findings;
      expect(finding.componentName).toBe('StatusBadge');
      expect(finding.rank).toBe(1);
      expect(finding.isMemo).toBe(true);
      expect(finding.memoDefeatedCount).toBe(2);
      expect(finding.reactDoctorRule).toBe('jsx-no-new-object-as-prop');
      expect(finding.unstableInputs).toEqual(['prop:status']);
    });

    test('does NOT flag the legitimate parent state change (SpikePanel)', () => {
      const names = summary.findings.map((finding) => finding.componentName);
      expect(names).not.toContain('SpikePanel');
    });

    test('flips zeroAppMemoDefeated to false', () => {
      expect(summary.totals.memoDefeated).toBe(2);
      expect(summary.stopSignal.zeroAppMemoDefeated).toBe(false);
    });
  });

  describe('--frame-budget-ms gate', () => {
    test('flips exceedsFrameBudget / noAppFrameBudgetBreach under a low budget', () => {
      const dump = loadDump('bippy-renders-dump.json');
      const tight = reduceDump(dump, {frameBudgetMs: 1});

      expect(tight.stopSignal.noAppFrameBudgetBreach).toBe(false);
      expect(tight.findings.length).toBeGreaterThan(0);
      expect(
        tight.findings.every((finding) => finding.exceedsFrameBudget)
      ).toBe(true);
    });
  });
});

describe('run (CLI handler)', () => {
  let stdout: string;
  let stderr: string;

  beforeEach(() => {
    stdout = '';
    stderr = '';
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
      stdout += String(chunk);

      return true;
    });
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      stderr += String(chunk);

      return true;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  test('prints a schema-valid summary and exits 0', () => {
    const code = run([fixturePath('bippy-renders-dump.json')]);

    expect(code).toBe(EXIT_CODES.OK);
    expect(stderr).toBe('');
    const parsed = ReducedSummarySchema.parse(JSON.parse(stdout));
    expect(parsed.totals.records).toBe(248);
  });

  test('is deterministic: same input yields byte-identical stdout', () => {
    run([fixturePath('bippy-renders-dump.json')]);
    const first = stdout;
    stdout = '';
    run([fixturePath('bippy-renders-dump.json')]);

    expect(stdout).toBe(first);
  });

  test('rejects the alien react-scan dump with a clear error', () => {
    const code = run([fixturePath('renders-dump.json')]);

    expect(code).toBe(EXIT_CODES.PAYLOAD_VALIDATION_FAILED);
    expect(stdout).toBe('');
    const payload = JSON.parse(stderr) as {code: string};
    expect(payload.code).toBe('invalid_dump');
  });

  test('errors on a missing input file', () => {
    const code = run([fixturePath('does-not-exist.json')]);

    expect(code).toBe(EXIT_CODES.STORAGE_INACCESSIBLE);
    expect(stdout).toBe('');
    const payload = JSON.parse(stderr) as {code: string};
    expect(payload.code).toBe('input_unreadable');
  });

  test('errors on a missing path argument', () => {
    const code = run([]);

    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    const payload = JSON.parse(stderr) as {code: string};
    expect(payload.code).toBe('invalid_arguments');
  });

  test('errors on a non-numeric --frame-budget-ms', () => {
    const code = run([
      fixturePath('bippy-renders-dump.json'),
      '--frame-budget-ms',
      'nope',
    ]);

    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    const payload = JSON.parse(stderr) as {code: string};
    expect(payload.code).toBe('invalid_arguments');
  });

  test('honors --frame-budget-ms when reducing', () => {
    run([fixturePath('bippy-renders-dump.json'), '--frame-budget-ms', '1']);
    const parsed = ReducedSummarySchema.parse(JSON.parse(stdout));

    expect(parsed.stopSignal.noAppFrameBudgetBreach).toBe(false);
  });
});
