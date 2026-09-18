import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {reviewSnapshotPath} from '../../schemas/review-snapshot.js';
import type {ReviewSnapshot} from '../../schemas/review-snapshot.js';
import {runSnapshot} from '../snapshot.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  snapshotPath: string;
  tallyPath: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-harden-snapshot-'));
  // runSnapshot calls resolveRepoRoot, so we need a real git repo.
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    snapshotPath: reviewSnapshotPath(root),
    tallyPath: path.join(root, 'review-tally.json'),
  };
};

const writeTally = (sandbox: Sandbox, tally: unknown): void => {
  writeFileSync(sandbox.tallyPath, JSON.stringify(tally), 'utf8');
};

const captureStdio = () => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const readSnapshot = (snapshotPath: string): ReviewSnapshot =>
  JSON.parse(readFileSync(snapshotPath, 'utf8')) as ReviewSnapshot;

const FIXED_NOW = new Date('2026-09-18T10:00:00.000Z');

const FULL_TALLY = {
  audited_pr_count: 400,
  candidate_count: 2,
  candidates: [
    {distinct_pr_count: 40, finding_class: 'holistic/overclaimed-guarantee'},
    {distinct_pr_count: 10, finding_class: 'holistic/drifting-duplicate'},
  ],
  class_inventory: [
    {distinct_pr_count: 40, finding_class: 'holistic/overclaimed-guarantee'},
    {distinct_pr_count: 10, finding_class: 'holistic/drifting-duplicate'},
    {distinct_pr_count: 2, finding_class: 'holistic/swallowed-error'},
  ],
  gh_ok: true,
  snapshot_present: false,
  snapshot_reviewed_at: null,
  tally_schema_version: 1,
  triggers: [],
  unclassified: {distinct_pr_count: 120},
  unclassified_window_count: 120,
  window_days: 90,
};

describe('harden-ledger snapshot', () => {
  let sandbox: Sandbox;
  let io: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox();
    io = captureStdio();
  });

  afterEach(() => {
    io.restore();
    sandbox.cleanup();
  });

  describe('record', () => {
    test('exact shares, full inventory (UAT-002)', () => {
      writeTally(sandbox, FULL_TALLY);

      const recordCode = runSnapshot(
        ['record', '--tally-file', sandbox.tallyPath],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );
      expect(recordCode).toBe(EXIT_CODES.OK);

      const showCode = runSnapshot(['show'], {cwd: sandbox.root});
      expect(showCode).toBe(EXIT_CODES.OK);

      const snapshot = JSON.parse(io.out.join('')) as ReviewSnapshot;
      expect(snapshot.tally_schema_version).toBe(1);
      expect(snapshot.window_days).toBe(90);
      expect(snapshot.audited_pr_count).toBe(400);
      expect(snapshot.reviewed_at).toBe(FIXED_NOW.toISOString());
      expect(snapshot.classes).toEqual({
        'holistic/drifting-duplicate': {distinct_pr_count: 10, share: 0.025},
        'holistic/overclaimed-guarantee': {distinct_pr_count: 40, share: 0.1},
        'holistic/swallowed-error': {distinct_pr_count: 2, share: 0.005},
      });
      expect(snapshot.unclassified).toEqual({
        distinct_pr_count: 120,
        share: 0.3,
      });
    });

    test('zero-candidate tally records', () => {
      writeTally(sandbox, {
        ...FULL_TALLY,
        audited_pr_count: 0,
        candidate_count: 0,
        candidates: [],
        class_inventory: [],
        unclassified: null,
        unclassified_window_count: null,
      });

      const code = runSnapshot(['record', '--tally-file', sandbox.tallyPath], {
        cwd: sandbox.root,
        now: () => FIXED_NOW,
      });
      expect(code).toBe(EXIT_CODES.OK);

      const snapshot = readSnapshot(sandbox.snapshotPath);
      expect(snapshot.classes).toEqual({});
      expect(snapshot.unclassified).toBeNull();
    });

    test('gh_ok false is refused and leaves an existing snapshot untouched', () => {
      writeTally(sandbox, FULL_TALLY);
      runSnapshot(['record', '--tally-file', sandbox.tallyPath], {
        cwd: sandbox.root,
        now: () => FIXED_NOW,
      });
      const before = readFileSync(sandbox.snapshotPath, 'utf8');
      const beforeMtime = statSync(sandbox.snapshotPath).mtimeMs;

      writeTally(sandbox, {...FULL_TALLY, gh_ok: false});
      const code = runSnapshot(['record', '--tally-file', sandbox.tallyPath], {
        cwd: sandbox.root,
        now: () => FIXED_NOW,
      });

      expect(code).toBe(EXIT_CODES.PAYLOAD_VALIDATION_FAILED);
      expect(io.err.join('')).toContain('tally_gh_not_ok');
      expect(readFileSync(sandbox.snapshotPath, 'utf8')).toBe(before);
      expect(statSync(sandbox.snapshotPath).mtimeMs).toBe(beforeMtime);
    });

    test('a pre-SPEC tally is refused as malformed_tally', () => {
      writeTally(sandbox, {
        candidate_count: 1,
        candidates: [],
        gh_ok: true,
        unclassified: null,
        window_days: 90,
      });

      const code = runSnapshot(['record', '--tally-file', sandbox.tallyPath], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.PAYLOAD_VALIDATION_FAILED);
      expect(io.err.join('')).toContain('malformed_tally');
    });

    test('invalid JSON is refused as malformed_tally', () => {
      writeFileSync(sandbox.tallyPath, 'not json', 'utf8');

      const code = runSnapshot(['record', '--tally-file', sandbox.tallyPath], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.PAYLOAD_VALIDATION_FAILED);
      expect(io.err.join('')).toContain('malformed_tally');
    });

    test('a missing tally file is refused as tally_file_unreadable', () => {
      const code = runSnapshot(
        ['record', '--tally-file', 'does-not-exist.json'],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.STORAGE_INACCESSIBLE);
      expect(io.err.join('')).toContain('tally_file_unreadable');
    });

    test('overwrites a malformed snapshot (RT-015)', () => {
      mkdirSync(path.dirname(sandbox.snapshotPath), {recursive: true});
      writeFileSync(sandbox.snapshotPath, '{"broken":', 'utf8');

      writeTally(sandbox, FULL_TALLY);
      const recordCode = runSnapshot(
        ['record', '--tally-file', sandbox.tallyPath],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );
      expect(recordCode).toBe(EXIT_CODES.OK);

      const showCode = runSnapshot(['show'], {cwd: sandbox.root});
      expect(showCode).toBe(EXIT_CODES.OK);
    });
  });

  describe('never reads the prior snapshot', () => {
    test('record output reflects only the new tally', () => {
      writeTally(sandbox, FULL_TALLY);
      runSnapshot(['record', '--tally-file', sandbox.tallyPath], {
        cwd: sandbox.root,
        now: () => new Date('2026-01-01T00:00:00.000Z'),
      });

      writeTally(sandbox, {
        ...FULL_TALLY,
        class_inventory: [
          {distinct_pr_count: 55, finding_class: 'holistic/hardcoded-string'},
        ],
      });
      runSnapshot(['record', '--tally-file', sandbox.tallyPath], {
        cwd: sandbox.root,
        now: () => FIXED_NOW,
      });

      const snapshot = readSnapshot(sandbox.snapshotPath);
      expect(snapshot.reviewed_at).toBe(FIXED_NOW.toISOString());
      expect(Object.keys(snapshot.classes)).toEqual([
        'holistic/hardcoded-string',
      ]);
    });
  });

  describe('show', () => {
    test('exits 1 with no_snapshot when absent', () => {
      const code = runSnapshot(['show'], {cwd: sandbox.root});

      expect(code).not.toBe(EXIT_CODES.OK);
      expect(io.err.join('')).toContain('no_snapshot');
    });

    test('exits 30 code malformed_snapshot when the recorded file fails the schema', () => {
      mkdirSync(path.dirname(sandbox.snapshotPath), {recursive: true});
      writeFileSync(
        sandbox.snapshotPath,
        JSON.stringify({classes: 'nope', version: 1}),
        'utf8'
      );

      const code = runSnapshot(['show'], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.CONFIG_INVALID);
      expect(io.err.join('')).toContain('malformed_snapshot');
    });
  });

  describe('arguments', () => {
    test('record with no flag exits 1 and writes nothing', () => {
      const code = runSnapshot(['record'], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(() => readFileSync(sandbox.snapshotPath, 'utf8')).toThrow(
        /ENOENT/
      );
    });

    test('record --tally-file with no value exits 1', () => {
      const code = runSnapshot(['record', '--tally-file'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    });

    test('record --bogus x exits 1', () => {
      const code = runSnapshot(['record', '--bogus', 'x'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    });

    test('show extra exits 1', () => {
      const code = runSnapshot(['show', 'extra'], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    });

    test('unknown verb exits 1', () => {
      const code = runSnapshot(['frobnicate'], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    });
  });
});
