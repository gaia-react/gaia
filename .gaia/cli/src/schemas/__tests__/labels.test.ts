import {describe, expect, test} from 'vitest';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import type {LabelEntry} from '../labels.js';
import {
  isCreatable,
  LABEL_AUDIENCES,
  LABEL_AXES,
  LABEL_FEATURES,
  LabelEntrySchema,
  LabelRegistrySchema,
} from '../labels.js';

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

const readRegistry = (): unknown =>
  JSON.parse(readFileSync(path.join(repoRoot, '.gaia/labels.json'), 'utf8'));

type SchemaEnumProperty = {
  enum?: readonly string[];
  items?: {enum?: readonly string[]};
};

const readSchemaEntryProperties = (): Record<string, SchemaEnumProperty> => {
  const schema = JSON.parse(
    readFileSync(path.join(repoRoot, '.gaia/labels.schema.json'), 'utf8')
  ) as {$defs: {entry: {properties: Record<string, SchemaEnumProperty>}}};

  return schema.$defs.entry.properties;
};

const sorted = (values: readonly string[]): string[] =>
  values.toSorted((left, right) => left.localeCompare(right));

/** Every `$defs.entry` property whose values are enumerated, and its constant. */
const ENUM_CONSTANTS: Record<string, readonly string[]> = {
  audience: LABEL_AUDIENCES,
  axis: LABEL_AXES,
  features: LABEL_FEATURES,
};

const schemaEnumOf = (
  property: SchemaEnumProperty | undefined
): readonly string[] | undefined => property?.enum ?? property?.items?.enum;

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

  test('the committed registry has exactly 31 entries, split by role and by audience field', () => {
    const registry = LabelRegistrySchema.parse(readRegistry());
    const {labels} = registry;

    expect(labels).toHaveLength(31);

    const blockedRole = labels.filter((entry) => entry.blocked);
    const thirdPartyRole = labels.filter(
      (entry) => !entry.blocked && entry.axis === 'third-party'
    );
    const maintainerOnlyRole = labels.filter(
      (entry) =>
        !entry.blocked &&
        entry.axis !== 'third-party' &&
        entry.audience === 'maintainer'
    );
    const adopterRole = labels.filter(
      (entry) =>
        !entry.blocked &&
        entry.axis !== 'third-party' &&
        entry.audience === 'adopter'
    );

    expect(adopterRole).toHaveLength(20);
    expect(maintainerOnlyRole).toHaveLength(7);
    expect(thirdPartyRole).toHaveLength(2);
    expect(blockedRole).toHaveLength(2);

    const adopterField = labels.filter((entry) => entry.audience === 'adopter');
    const maintainerField = labels.filter(
      (entry) => entry.audience === 'maintainer'
    );

    expect(adopterField).toHaveLength(24);
    expect(maintainerField).toHaveLength(7);
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

  test('an uppercase color is rejected', () => {
    const result = LabelEntrySchema.safeParse({...baseEntry, color: 'B60205'});

    expect(result.success).toBe(false);
  });

  test('a lowercase 6-digit color is accepted', () => {
    const result = LabelEntrySchema.safeParse({...baseEntry, color: 'b60205'});

    expect(result.success).toBe(true);
  });

  test('a 3-digit color is rejected', () => {
    const result = LabelEntrySchema.safeParse({...baseEntry, color: 'b60'});

    expect(result.success).toBe(false);
  });

  test('a 7-digit color is rejected', () => {
    const result = LabelEntrySchema.safeParse({...baseEntry, color: 'b60205a'});

    expect(result.success).toBe(false);
  });

  test('two entries sharing a color are rejected, and the message names the color', () => {
    const result = LabelRegistrySchema.safeParse({
      $schema: './labels.schema.json',
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
      $schema: './labels.schema.json',
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
      $schema: './labels.schema.json',
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
      $schema: './labels.schema.json',
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

    test('features: ["tech-debt", "gaia-ci"] is creatable when only gaia-ci is on', () => {
      const entry: LabelEntry = {
        ...managedAdopterAlways,
        features: ['tech-debt', 'gaia-ci'],
      };

      expect(isCreatable(entry, 'adopter', ['gaia-ci'])).toBe(true);
    });

    test('features: ["tech-debt", "gaia-ci"] is not creatable when neither is on', () => {
      const entry: LabelEntry = {
        ...managedAdopterAlways,
        features: ['tech-debt', 'gaia-ci'],
      };

      expect(isCreatable(entry, 'adopter', ['forensics'])).toBe(false);
    });
  });

  test('the committed .gaia/labels.schema.json parses as JSON, and every required entry key appears on the first entry of .gaia/labels.json', () => {
    const schema = JSON.parse(
      readFileSync(path.join(repoRoot, '.gaia/labels.schema.json'), 'utf8')
    );
    const registry = readRegistry() as {labels: Record<string, unknown>[]};
    const requiredKeys: string[] = schema.$defs.entry.required;
    const firstEntry = registry.labels[0];

    assert.ok(firstEntry);
    requiredKeys.forEach((key) => {
      expect(Object.hasOwn(firstEntry, key)).toBe(true);
    });
  });

  describe('.gaia/labels.schema.json enum parity', () => {
    const entryProperties = readSchemaEntryProperties();

    // Derived, not listed: a fourth enum property added to the schema without a
    // matching ENUM_CONSTANTS row would otherwise drift unguarded, which is the
    // condition the parity rows below are supposed to close.
    test('every enum-bearing schema property has a constant to compare against', () => {
      const enumBearing = Object.keys(entryProperties).filter(
        (property) => schemaEnumOf(entryProperties[property]) !== undefined
      );

      expect(sorted(enumBearing)).toStrictEqual(
        sorted(Object.keys(ENUM_CONSTANTS))
      );
    });

    test.each(Object.keys(ENUM_CONSTANTS))(
      'the schema %s enum holds the same values as its TypeScript constant',
      (property) => {
        const schemaEnum = schemaEnumOf(entryProperties[property]);
        const constant = ENUM_CONSTANTS[property];

        assert.ok(schemaEnum);
        assert.ok(constant);
        expect(sorted(schemaEnum)).toStrictEqual(sorted(constant));
      }
    );
  });
});
