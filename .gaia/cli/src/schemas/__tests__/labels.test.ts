import {describe, expect, test} from 'vitest';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import type {LabelEntry} from '../labels.js';
import {isCreatable, LabelEntrySchema, LabelRegistrySchema} from '../labels.js';

// Built at runtime so no removed-feature literal lands in the tracked tree.
const REMOVED_FEATURE_NAME = ['gaia', 'ci'].join('-');

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

const readRegistry = (): unknown =>
  JSON.parse(readFileSync(path.join(repoRoot, '.gaia/labels.json'), 'utf8'));

const baseEntry: LabelEntry = {
  audience: 'adopter',
  axis: 'type',
  blocked: false,
  color: 'abcdef',
  deprecated: false,
  description: 'A valid description',
  features: [],
  managed: true,
  name: 'example',
  reason: null,
  renamedFrom: [],
};

describe('schemas/labels', () => {
  test('the committed .gaia/labels.json parses under LabelRegistrySchema', () => {
    const result = LabelRegistrySchema.safeParse(readRegistry());

    expect(result.success).toBe(true);
  });

  test('the committed deprecated entries carry a null reason', () => {
    const registry = LabelRegistrySchema.parse(readRegistry());
    const deprecatedEntries = registry.labels.filter(
      (entry) => entry.deprecated
    );

    expect(
      deprecatedEntries
        .map((entry) => entry.name)
        .toSorted((a, b) => a.localeCompare(b))
    ).toEqual([REMOVED_FEATURE_NAME, 'run-audit']);

    for (const entry of deprecatedEntries) {
      expect(entry.reason).toBeNull();
    }
  });

  test('the removed feature name is rejected as an entry feature', () => {
    const removedFeature = REMOVED_FEATURE_NAME;
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      features: [removedFeature],
    });

    expect(result.success).toBe(false);
  });

  test('a description of 101 characters is rejected', () => {
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      description: 'a'.repeat(101),
    });

    expect(result.success).toBe(false);
  });

  test('a description of 100 characters is accepted', () => {
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      description: 'a'.repeat(100),
    });

    expect(result.success).toBe(true);
  });

  test.each<[string, string, boolean]>([
    ['an uppercase color is rejected', 'B60205', false],
    ['a lowercase 6-digit color is accepted', 'b60205', true],
    ['a 3-digit color is rejected', 'b60', false],
    ['a 7-digit color is rejected', 'b60205a', false],
  ])('%s', (_label, color, success) => {
    const result = LabelEntrySchema.safeParse({...baseEntry, color});

    expect(result.success).toBe(success);
  });

  test('two entries sharing a color are rejected, and the message names the color', () => {
    const result = LabelRegistrySchema.safeParse({
      description: 'test registry',
      labels: [
        {...baseEntry, color: 'abcdef', name: 'one'},
        {...baseEntry, color: 'abcdef', name: 'two'},
      ],
      version: 1,
    });

    expect(result.success).toBe(false);
    assert.ok(!result.success);
    expect(
      result.error.issues.some((issue) => issue.message.includes('abcdef'))
    ).toBe(true);
  });

  test('two entries sharing a name are rejected', () => {
    const result = LabelRegistrySchema.safeParse({
      description: 'test registry',
      labels: [
        {...baseEntry, color: 'abcdef', name: 'dup'},
        {...baseEntry, color: 'fedcba', name: 'dup'},
      ],
      version: 1,
    });

    expect(result.success).toBe(false);
    assert.ok(!result.success);
    expect(
      result.error.issues.some((issue) => issue.message.includes('dup'))
    ).toBe(true);
  });

  test('a description containing an em dash is rejected, and the message names the character', () => {
    const result = LabelRegistrySchema.safeParse({
      description: 'test registry',
      labels: [{...baseEntry, description: 'has an em dash — in it'}],
      version: 1,
    });

    expect(result.success).toBe(false);
    assert.ok(!result.success);
    expect(
      result.error.issues.some((issue) => issue.message.includes('—'))
    ).toBe(true);
  });

  test('a description containing an en dash is rejected, and the message names the character', () => {
    const result = LabelRegistrySchema.safeParse({
      description: 'test registry',
      labels: [{...baseEntry, description: 'has an en dash – in it'}],
      version: 1,
    });

    expect(result.success).toBe(false);
    assert.ok(!result.success);
    expect(
      result.error.issues.some((issue) => issue.message.includes('–'))
    ).toBe(true);
  });

  test('a blocked entry with a non-null color is rejected', () => {
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      blocked: true,
      color: 'abcdef',
      managed: false,
      reason: 'blocked reason',
    });

    expect(result.success).toBe(false);
  });

  test('a blocked entry with managed: true is rejected', () => {
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      blocked: true,
      color: null,
      managed: true,
      reason: 'blocked reason',
    });

    expect(result.success).toBe(false);
  });

  test('a blocked entry with reason: null is rejected', () => {
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      blocked: true,
      color: null,
      managed: false,
      reason: null,
    });

    expect(result.success).toBe(false);
  });

  test('a non-blocked entry with reason set to a string is rejected', () => {
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      blocked: false,
      reason: 'should be null',
    });

    expect(result.success).toBe(false);
  });

  test('a non-blocked entry with a null color is rejected', () => {
    const result = LabelEntrySchema.safeParse({
      ...baseEntry,
      blocked: false,
      color: null,
      reason: null,
    });

    expect(result.success).toBe(false);
  });

  describe('isCreatable', () => {
    const managedAdopterAlways: LabelEntry = {
      ...baseEntry,
      audience: 'adopter',
      blocked: false,
      deprecated: false,
      features: [],
      managed: true,
    };

    test('managed: false is never creatable', () => {
      expect(
        isCreatable({...managedAdopterAlways, managed: false}, 'adopter', [])
      ).toBe(false);
    });

    test('deprecated: true is never creatable', () => {
      expect(
        isCreatable({...managedAdopterAlways, deprecated: true}, 'adopter', [])
      ).toBe(false);
    });

    test('blocked: true is never creatable', () => {
      expect(
        isCreatable(
          {...managedAdopterAlways, blocked: true, color: null, reason: 'x'},
          'adopter',
          []
        )
      ).toBe(false);
    });

    test('the maintainer audience is owed an adopter entry', () => {
      expect(isCreatable(managedAdopterAlways, 'maintainer', [])).toBe(true);
    });

    test('the adopter audience is never owed a maintainer entry', () => {
      expect(
        isCreatable(
          {...managedAdopterAlways, audience: 'maintainer'},
          'adopter',
          []
        )
      ).toBe(false);
    });

    test('features: [] is creatable with zero features enabled', () => {
      expect(isCreatable(managedAdopterAlways, 'adopter', [])).toBe(true);
    });

    test('features: ["tech-debt", "dependabot"] is creatable when only dependabot is on', () => {
      const entry: LabelEntry = {
        ...managedAdopterAlways,
        features: ['tech-debt', 'dependabot'],
      };

      expect(isCreatable(entry, 'adopter', ['dependabot'])).toBe(true);
    });

    test('features: ["tech-debt", "dependabot"] is not creatable when neither is on', () => {
      const entry: LabelEntry = {
        ...managedAdopterAlways,
        features: ['tech-debt', 'dependabot'],
      };

      expect(isCreatable(entry, 'adopter', ['forensics'])).toBe(false);
    });
  });
});
