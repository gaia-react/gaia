import {describe, expect, test} from 'vitest';
import assert from 'node:assert/strict';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  readReviewSnapshot,
  reviewSnapshotPath,
  ReviewTallyInputSchema,
  snapshotFromTally,
  writeReviewSnapshot,
} from '../review-snapshot.js';
import type {ReviewSnapshot, ReviewTallyInput} from '../review-snapshot.js';

const FIXED_NOW = new Date('2026-09-18T10:00:00.000Z');

const FULL_TALLY: ReviewTallyInput = {
  audited_pr_count: 400,
  class_inventory: [
    {distinct_pr_count: 40, finding_class: 'holistic/overclaimed-guarantee'},
    {distinct_pr_count: 10, finding_class: 'holistic/drifting-duplicate'},
    {distinct_pr_count: 2, finding_class: 'holistic/swallowed-error'},
  ],
  gh_ok: true,
  tally_schema_version: 1,
  unclassified_window_count: 120,
  window_days: 90,
};

describe('schemas/review-snapshot', () => {
  describe('snapshotFromTally', () => {
    test('returns exact shares and full inventory', () => {
      const snapshot = snapshotFromTally(FULL_TALLY, FIXED_NOW);

      expect(snapshot).toEqual({
        audited_pr_count: 400,
        classes: {
          'holistic/drifting-duplicate': {distinct_pr_count: 10, share: 0.025},
          'holistic/overclaimed-guarantee': {distinct_pr_count: 40, share: 0.1},
          'holistic/swallowed-error': {distinct_pr_count: 2, share: 0.005},
        },
        reviewed_at: FIXED_NOW.toISOString(),
        tally_schema_version: 1,
        unclassified: {distinct_pr_count: 120, share: 0.3},
        version: 1,
        window_days: 90,
      });
    });

    test('returns empty classes and null unclassified for a zero-candidate tally', () => {
      const snapshot = snapshotFromTally(
        {
          audited_pr_count: 0,
          class_inventory: [],
          gh_ok: true,
          tally_schema_version: 1,
          unclassified_window_count: null,
          window_days: 90,
        },
        FIXED_NOW
      );

      expect(snapshot.classes).toEqual({});
      expect(snapshot.unclassified).toBeNull();
      expect(snapshot.audited_pr_count).toBe(0);
    });
  });

  describe('ReviewTallyInputSchema', () => {
    test('refuses a tally missing audited_pr_count', () => {
      const rest: Partial<ReviewTallyInput> = {...FULL_TALLY};
      delete rest.audited_pr_count;
      expect(ReviewTallyInputSchema.safeParse(rest).success).toBe(false);
    });

    test('refuses a tally missing class_inventory', () => {
      const rest: Partial<ReviewTallyInput> = {...FULL_TALLY};
      delete rest.class_inventory;
      expect(ReviewTallyInputSchema.safeParse(rest).success).toBe(false);
    });

    test('refuses unclassified_window_count: 0', () => {
      expect(
        ReviewTallyInputSchema.safeParse({
          ...FULL_TALLY,
          unclassified_window_count: 0,
        }).success
      ).toBe(false);
    });

    test('refuses a pre-SPEC tally shape', () => {
      expect(
        ReviewTallyInputSchema.safeParse({
          candidate_count: 1,
          candidates: [],
          gh_ok: true,
          unclassified: null,
          window_days: 90,
        }).success
      ).toBe(false);
    });

    test('accepts a tally carrying extra keys', () => {
      expect(
        ReviewTallyInputSchema.safeParse({
          ...FULL_TALLY,
          candidates: [],
          triggers: [],
        }).success
      ).toBe(true);
    });
  });

  describe('read/write round trip', () => {
    let root: string;

    const setup = (): void => {
      root = mkdtempSync(path.join(tmpdir(), 'gaia-review-snapshot-'));
    };

    const cleanup = (): void => {
      rmSync(root, {force: true, recursive: true});
    };

    test('round-trips to status ok with deep-equal content', () => {
      setup();

      try {
        const snapshot = snapshotFromTally(FULL_TALLY, FIXED_NOW);
        writeReviewSnapshot(root, snapshot);

        const result = readReviewSnapshot(root);
        expect(result.status).toBe('ok');
        assert.ok(result.status === 'ok');
        expect(result.snapshot).toEqual(snapshot);
      } finally {
        cleanup();
      }
    });

    test('returns missing when the file does not exist', () => {
      setup();

      try {
        expect(readReviewSnapshot(root).status).toBe('missing');
      } finally {
        cleanup();
      }
    });

    test('returns malformed for invalid JSON', () => {
      setup();

      try {
        mkdirSync(path.dirname(reviewSnapshotPath(root)), {recursive: true});
        writeFileSync(reviewSnapshotPath(root), '{ not json', 'utf8');
        expect(readReviewSnapshot(root).status).toBe('malformed');
      } finally {
        cleanup();
      }
    });

    test('returns malformed for valid JSON failing the schema', () => {
      setup();

      try {
        const snapshot = snapshotFromTally(FULL_TALLY, FIXED_NOW);
        mkdirSync(path.dirname(reviewSnapshotPath(root)), {recursive: true});
        writeFileSync(
          reviewSnapshotPath(root),
          JSON.stringify({...snapshot, classes: 'nope'}),
          'utf8'
        );
        expect(readReviewSnapshot(root).status).toBe('malformed');
      } finally {
        cleanup();
      }
    });

    test('writeReviewSnapshot overwrites a pre-existing malformed file unconditionally', () => {
      setup();

      try {
        mkdirSync(path.dirname(reviewSnapshotPath(root)), {recursive: true});
        writeFileSync(reviewSnapshotPath(root), '{"broken":', 'utf8');

        const snapshot: ReviewSnapshot = snapshotFromTally(
          FULL_TALLY,
          FIXED_NOW
        );
        writeReviewSnapshot(root, snapshot);

        const result = readReviewSnapshot(root);
        expect(result.status).toBe('ok');
      } finally {
        cleanup();
      }
    });
  });
});
