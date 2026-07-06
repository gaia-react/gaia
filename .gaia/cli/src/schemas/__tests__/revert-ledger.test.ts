import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {z} from 'zod';
import assert from 'node:assert/strict';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  emptyRevertLedger,
  readRevertLedger,
  RevertLedgerSchema,
  writeRevertLedger,
} from '../revert-ledger.js';
import type {RevertLedger} from '../revert-ledger.js';

const VALID_LEDGER: RevertLedger = {
  attempts: {
    '99': {
      opened_at: '2026-05-09T04:00:00Z',
      original_pr: 99,
      revert_pr: 137,
      status: 'open',
    },
  },
  version: 1,
};

type Sandbox = {
  cleanup: () => void;
  ledgerPath: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-revert-ledger-'));
  mkdirSync(path.join(root, '.gaia'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    ledgerPath: path.join(
      root,
      '.gaia',
      'automation.state-revert-attempts.json'
    ),
    root,
  };
};

describe('schemas/revert-ledger', () => {
  describe('RevertLedgerSchema', () => {
    test('parses a valid ledger', () => {
      expect(() => RevertLedgerSchema.parse(VALID_LEDGER)).not.toThrow();
    });

    test('rejects version: 2', () => {
      expect(() =>
        RevertLedgerSchema.parse({...VALID_LEDGER, version: 2})
      ).toThrow(z.ZodError);
    });

    test('rejects attempts: null', () => {
      expect(() =>
        RevertLedgerSchema.parse({...VALID_LEDGER, attempts: null})
      ).toThrow(z.ZodError);
    });

    test('rejects unknown status', () => {
      expect(() =>
        RevertLedgerSchema.parse({
          ...VALID_LEDGER,
          attempts: {
            '99': {...VALID_LEDGER.attempts['99'], status: 'wat'},
          },
        })
      ).toThrow(z.ZodError);
    });

    test('rejects negative original_pr', () => {
      expect(() =>
        RevertLedgerSchema.parse({
          ...VALID_LEDGER,
          attempts: {
            '99': {...VALID_LEDGER.attempts['99'], original_pr: -1},
          },
        })
      ).toThrow(z.ZodError);
    });

    test('rejects unparseable opened_at', () => {
      expect(() =>
        RevertLedgerSchema.parse({
          ...VALID_LEDGER,
          attempts: {
            '99': {...VALID_LEDGER.attempts['99'], opened_at: 'tomorrow'},
          },
        })
      ).toThrow(z.ZodError);
    });

    test('accepts merged status', () => {
      expect(() =>
        RevertLedgerSchema.parse({
          ...VALID_LEDGER,
          attempts: {
            '99': {...VALID_LEDGER.attempts['99'], status: 'merged'},
          },
        })
      ).not.toThrow();
    });

    test('accepts failed status', () => {
      expect(() =>
        RevertLedgerSchema.parse({
          ...VALID_LEDGER,
          attempts: {
            '99': {...VALID_LEDGER.attempts['99'], status: 'failed'},
          },
        })
      ).not.toThrow();
    });
  });

  describe('emptyRevertLedger', () => {
    test('returns a fresh empty ledger each call', () => {
      const a = emptyRevertLedger();
      const b = emptyRevertLedger();
      a.attempts['1'] = {
        opened_at: '2026-05-09T04:00:00Z',
        original_pr: 1,
        revert_pr: 2,
        status: 'open',
      };
      expect(b.attempts).toEqual({});
    });
  });

  describe('readRevertLedger', () => {
    let sandbox: Sandbox;

    beforeEach(() => {
      sandbox = setupSandbox();
    });

    afterEach(() => {
      sandbox.cleanup();
    });

    test('returns {status: "missing"} when the file does not exist', () => {
      const result = readRevertLedger(sandbox.root);
      expect(result.status).toBe('missing');
    });

    test('returns {status: "ok"} for a valid ledger', () => {
      writeFileSync(sandbox.ledgerPath, JSON.stringify(VALID_LEDGER), 'utf8');
      const result = readRevertLedger(sandbox.root);
      expect(result.status).toBe('ok');
      assert.ok(result.status === 'ok');
      expect(result.ledger.attempts['99'].revert_pr).toBe(137);
    });

    test('returns {status: "malformed"} for invalid JSON', () => {
      writeFileSync(sandbox.ledgerPath, '{nope', 'utf8');
      const result = readRevertLedger(sandbox.root);
      expect(result.status).toBe('malformed');
    });

    test('returns {status: "malformed"} for schema mismatch', () => {
      writeFileSync(
        sandbox.ledgerPath,
        JSON.stringify({...VALID_LEDGER, version: 99}),
        'utf8'
      );
      const result = readRevertLedger(sandbox.root);
      expect(result.status).toBe('malformed');
    });
  });

  describe('writeRevertLedger', () => {
    let sandbox: Sandbox;

    beforeEach(() => {
      sandbox = setupSandbox();
    });

    afterEach(() => {
      sandbox.cleanup();
    });

    test('writes a 2-space-indented file with trailing newline', () => {
      writeRevertLedger(sandbox.root, VALID_LEDGER);
      const text = readFileSync(sandbox.ledgerPath, 'utf8');
      expect(text.endsWith('\n')).toBe(true);
      expect(text).toContain('  "version": 1');
    });

    test('round-trips through readRevertLedger', () => {
      writeRevertLedger(sandbox.root, VALID_LEDGER);
      const result = readRevertLedger(sandbox.root);
      expect(result.status).toBe('ok');
      assert.ok(result.status === 'ok');
      expect(result.ledger).toEqual(VALID_LEDGER);
    });
  });
});
