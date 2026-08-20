/**
 * Reader and resolvers for `.gaia/labels.json`, shared by every `gaia labels`
 * subcommand.
 *
 * Feature resolution answers "which labels does a tree owe", and `gaia-ci`
 * resolves OFF in the GAIA repository itself because `.gaia/automation.json`
 * is not part of it. That is the correct answer rather than a gap to repair:
 * the `gaia-ci` and `security` labels serve the workflows GAIA renders into
 * adopter repositories, not GAIA's own CI. A tree that has never run
 * `/gaia-setup`'s automation step owes neither label.
 *
 * Every helper takes an explicit `repoRoot` and none calls `process.cwd()`,
 * matching `ci/paths.ts`. Each `run(argv)` handler resolves its own default
 * once with `resolveRepoRoot()` and passes the result down.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {automationConfigPath} from '../automation/paths.js';
import type {
  LabelAudience,
  LabelEntry,
  LabelFeature,
  LabelRegistry,
} from '../schemas/labels.js';
import {isCreatable, LabelRegistrySchema} from '../schemas/labels.js';
import {summarizeZodError} from '../schemas/zod-error.js';

/** Repo-relative registry path, joined onto an explicit `repoRoot`. */
export const labelsRegistryPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'labels.json');

const forensicsWorkflowPath = (repoRoot: string): string =>
  path.join(repoRoot, '.github', 'workflows', 'forensics-triage.yml');

/** Reads and validates `.gaia/labels.json`; throws naming the file on failure. */
export const readRegistry = (repoRoot: string): LabelRegistry => {
  const filePath = labelsRegistryPath(repoRoot);
  let raw: string;

  try {
    raw = readFileSync(filePath, 'utf8');
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);

    throw new Error(`${filePath}: unreadable: ${detail}`);
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);

    throw new Error(`${filePath}: invalid JSON: ${detail}`);
  }

  const result = LabelRegistrySchema.safeParse(parsed);

  if (!result.success) {
    throw new Error(summarizeZodError(filePath, result.error));
  }

  return result.data;
};

/** Entries sync creates on a repo of `audience` with `enabledFeatures` on. */
export const creatableEntries = (
  registry: LabelRegistry,
  audience: LabelAudience,
  enabledFeatures: readonly LabelFeature[]
): readonly LabelEntry[] =>
  registry.labels.filter((entry) =>
    isCreatable(entry, audience, enabledFeatures)
  );

/** Entries the registry marks `blocked`. */
export const blockedEntries = (
  registry: LabelRegistry
): readonly LabelEntry[] => registry.labels.filter((entry) => entry.blocked);

/** GAIA namespace prefixes an unknown live label may be recognized by. */
export const NAMESPACE_PREFIXES: readonly string[] = [
  'severity:',
  'difficulty:',
  'handler:',
  'debt:',
  'surface:',
  'fold:',
];

/**
 * The family color to suggest for an unknown live label, or `null`.
 *
 * Derived from the registry rather than a second hand-kept palette table: the
 * suggestion is the color of the lowest-sorting entry sharing the name's
 * namespace, so a family that gains or loses a member needs no edit here.
 */
export const suggestedColorFor = (
  registry: LabelRegistry,
  name: string
): null | string => {
  const prefix = NAMESPACE_PREFIXES.find((candidate) =>
    name.startsWith(candidate)
  );

  if (prefix === undefined) return null;

  const family = registry.labels
    .filter((entry) => entry.color !== null && entry.name.startsWith(prefix))
    .toSorted((a, b) => a.name.localeCompare(b.name));

  return family[0]?.color ?? null;
};

/** `maintainer` when `repoRoot` carries `.gaia/cli/src`, else `adopter`. */
export const resolveAudience = (repoRoot: string): LabelAudience =>
  existsSync(path.join(repoRoot, '.gaia', 'cli', 'src')) ? 'maintainer' : (
    'adopter'
  );

/** Features the tree at `repoRoot` has enabled. */
export const resolveFeatures = (repoRoot: string): readonly LabelFeature[] => {
  // `tech-debt` is unconditional: the debt tooling ships with every copy of
  // GAIA, so its labels are owed by every tree.
  const features: LabelFeature[] = ['tech-debt'];

  if (existsSync(automationConfigPath(repoRoot))) features.push('gaia-ci');
  if (existsSync(forensicsWorkflowPath(repoRoot))) features.push('forensics');

  return features;
};
