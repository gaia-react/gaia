/**
 * Zod schema for `.gaia/labels.json`, the single source of truth for every
 * GitHub label GAIA creates, syncs, and documents.
 *
 * This module is the validator the CLI runs. `.gaia/labels.schema.json` is
 * the editor-facing copy: it restates the per-entry blocked/color/reason
 * invariant, and the two are kept in step by hand, so a change to either
 * belongs in both. The three enumerations below are the exception: a parity
 * test in `__tests__/labels.test.ts` reads the schema and fails on drift in
 * either direction. Uniqueness of names and colors, and the
 * no-em-dash/no-en-dash house rule on every description, live only here,
 * because a JSON Schema cannot express them. `isCreatable` is the one
 * predicate every consumer (sync, `/gaia-setup`, `/gaia-update`) uses to
 * decide whether an entry belongs on a given repository.
 */
import {z} from 'zod';

export const LABEL_AXES = [
  'type',
  'urgency',
  'effort',
  'reach',
  'lifecycle',
  'modifier',
  'disposition',
  'origin',
  'attention',
  'audience',
  'third-party',
  'blocked',
] as const;

export const LABEL_FEATURES = ['tech-debt', 'gaia-ci', 'forensics'] as const;

export const LABEL_AUDIENCES = ['adopter', 'maintainer'] as const;

/** Characters banned from a description by the house rule: em dash and en dash. */
export const BANNED_DESCRIPTION_CHARACTERS: readonly string[] = ['—', '–'];

export const LabelAxisSchema = z.literal(LABEL_AXES);

export type LabelAxis = z.infer<typeof LabelAxisSchema>;

export const LabelFeatureSchema = z.literal(LABEL_FEATURES);

export type LabelFeature = z.infer<typeof LabelFeatureSchema>;

export const LabelAudienceSchema = z.literal(LABEL_AUDIENCES);

export type LabelAudience = z.infer<typeof LabelAudienceSchema>;

export const LabelEntrySchema = z
  .object({
    audience: LabelAudienceSchema,
    axis: LabelAxisSchema,
    blocked: z.boolean(),
    color: z
      .string()
      .regex(/^[0-9a-f]{6}$/)
      .nullable(),
    deprecated: z.boolean(),
    description: z.string().min(1).max(100),
    features: z.array(LabelFeatureSchema),
    managed: z.boolean(),
    name: z.string().min(1),
    reason: z.string().min(1).nullable(),
    renamedFrom: z.array(z.string().min(1)),
  })
  .superRefine((entry, ctx) => {
    if (entry.blocked) {
      if (entry.color !== null) {
        ctx.addIssue({
          code: 'custom',
          message: 'color must be null when blocked is true',
          path: ['color'],
        });
      }

      if (entry.managed) {
        ctx.addIssue({
          code: 'custom',
          message: 'managed must be false when blocked is true',
          path: ['managed'],
        });
      }

      if (typeof entry.reason !== 'string') {
        ctx.addIssue({
          code: 'custom',
          message: 'reason must be a non-empty string when blocked is true',
          path: ['reason'],
        });
      }
    } else {
      if (entry.color === null) {
        ctx.addIssue({
          code: 'custom',
          message: 'color must be a hex string when blocked is false',
          path: ['color'],
        });
      }

      if (entry.reason !== null) {
        ctx.addIssue({
          code: 'custom',
          message: 'reason must be null when blocked is false',
          path: ['reason'],
        });
      }
    }
  });

export type LabelEntry = z.infer<typeof LabelEntrySchema>;

export const LabelRegistrySchema = z
  .object({
    $schema: z.string().min(1),
    description: z.string().min(1),
    labels: z.array(LabelEntrySchema),
    version: z.literal(1),
  })
  .superRefine((registry, ctx) => {
    const firstIndexByName = new Map<string, number>();

    registry.labels.forEach((entry, index) => {
      if (firstIndexByName.has(entry.name)) {
        ctx.addIssue({
          code: 'custom',
          message: `duplicate label name: ${entry.name}`,
          path: ['labels', index, 'name'],
        });
      } else {
        firstIndexByName.set(entry.name, index);
      }
    });

    const firstIndexByColor = new Map<string, number>();

    registry.labels.forEach((entry, index) => {
      if (entry.color === null) return;

      if (firstIndexByColor.has(entry.color)) {
        ctx.addIssue({
          code: 'custom',
          message: `duplicate label color: ${entry.color}`,
          path: ['labels', index, 'color'],
        });
      } else {
        firstIndexByColor.set(entry.color, index);
      }
    });

    registry.labels.forEach((entry, index) => {
      const bannedCharacter = BANNED_DESCRIPTION_CHARACTERS.find((character) =>
        entry.description.includes(character)
      );

      if (bannedCharacter !== undefined) {
        ctx.addIssue({
          code: 'custom',
          message: `description contains a banned character: ${JSON.stringify(bannedCharacter)}`,
          path: ['labels', index, 'description'],
        });
      }
    });
  });

export type LabelRegistry = z.infer<typeof LabelRegistrySchema>;

/**
 * True when a repo of `audience` is owed the entry at all, on audience alone.
 *
 * The maintainer audience is a superset, not a disjoint partition: the GAIA
 * maintainer repository files its own tech debt and runs its own audits, so it
 * is owed every adopter entry as well as its own. A strict equality test left a
 * maintainer tree owed only the maintainer entries, so a fresh fork missing
 * `severity:critical` got zero creates and a clean exit. An adopter tree is
 * unaffected either way: it never resolves the maintainer audience, so it is
 * never owed a maintainer-only entry.
 *
 * Every site that decides coverage by audience calls this rather than spelling
 * the comparison out. Creation and rename are two such sites, and when they
 * disagree sync plans a create for a live label it should have renamed, which
 * loses the rename-never-delete-and-recreate invariant for that entry.
 *
 * Structured parameter, because both sides are a `LabelAudience`: passed
 * positionally, a swapped call would typecheck and quietly invert the rule,
 * owing an adopter repository every maintainer-only entry.
 */
export const audienceCovers = ({
  audience,
  entryAudience,
}: {
  audience: LabelAudience;
  entryAudience: LabelAudience;
}): boolean => audience === 'maintainer' || entryAudience === audience;

/** True when the entry is one sync creates on a repo of `audience` with `enabledFeatures` on. */
export const isCreatable = (
  entry: LabelEntry,
  audience: LabelAudience,
  enabledFeatures: readonly LabelFeature[]
): boolean => {
  if (!entry.managed || entry.deprecated || entry.blocked) return false;
  if (!audienceCovers({audience, entryAudience: entry.audience})) return false;

  return (
    entry.features.length === 0 ||
    entry.features.some((feature) => enabledFeatures.includes(feature))
  );
};
