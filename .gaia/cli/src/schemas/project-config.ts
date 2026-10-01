/**
 * Zod schema + read helper for `.gaia/project.json`, the committed,
 * team-shared file carrying GAIA project preferences. A missing file means
 * "no preferences recorded"; `readProjectConfig` never throws, callers
 * branch on the discriminated `status` field.
 */
import {z} from 'zod';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {summarizeZodError} from './zod-error.js';

export const ISOLATION_POLICIES = [
  'always-worktree',
  'prefer-branch',
  'prefer-worktree',
] as const;

export type IsolationPolicy = (typeof ISOLATION_POLICIES)[number];

export const isIsolationPolicy = (value: string): value is IsolationPolicy =>
  (ISOLATION_POLICIES as readonly string[]).includes(value);

export const DEPENDABOT_SECURITY_UPDATES = ['on', 'off'] as const;

export type DependabotSecurityUpdates =
  (typeof DEPENDABOT_SECURITY_UPDATES)[number];

export const isDependabotSecurityUpdates = (
  value: string
): value is DependabotSecurityUpdates =>
  (DEPENDABOT_SECURITY_UPDATES as readonly string[]).includes(value);

/**
 * Every field is read permissively: an absent key, an unrecognized string,
 * and a wrong-typed value all leave the config parsing `ok` with the field
 * `undefined`, so a typo or a value a newer binary wrote never malforms the
 * whole file. The known values are enforced at the WRITE boundary
 * (`updateProjectConfig` and the CLI writers) and narrowed here so a
 * consumer can compare against a literal without re-validating.
 */
export const ProjectConfigSchema = z.object({
  dependabot_security_updates: z
    .literal(DEPENDABOT_SECURITY_UPDATES)
    .optional()
    .catch(undefined),
  isolation_policy: z.literal(ISOLATION_POLICIES).optional().catch(undefined),
  sandbox_recommended: z.boolean().optional().catch(undefined),
  // An unrecognized or absent version degrades to 1 rather than malforming
  // the config.
  version: z.literal(1).catch(1),
});

export type ProjectConfig = z.infer<typeof ProjectConfigSchema>;

export const projectConfigPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'project.json');

/**
 * `raw` is the unstripped `JSON.parse` output, so a key this binary does not
 * know survives a read-merge-write cycle instead of being dropped by Zod's
 * default stripping.
 */
export type ReadProjectConfigResult =
  | {config: ProjectConfig; raw: Record<string, unknown>; status: 'ok'}
  | {error: string; status: 'malformed'}
  | {status: 'missing'};

export const readProjectConfig = (
  repoRoot: string
): ReadProjectConfigResult => {
  const filePath = projectConfigPath(repoRoot);

  if (!existsSync(filePath)) return {status: 'missing'};

  let text: string;

  try {
    text = readFileSync(filePath, 'utf8');
  } catch (error) {
    return {
      error: `${filePath}: ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(text);
  } catch (error) {
    return {
      error: `${filePath}: invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  const result = ProjectConfigSchema.safeParse(parsed);

  if (!result.success) {
    return {
      error: summarizeZodError(filePath, result.error),
      status: 'malformed',
    };
  }

  // A successful object parse implies `parsed` was itself an object.
  return {
    config: result.data,
    raw: parsed as Record<string, unknown>,
    status: 'ok',
  };
};
