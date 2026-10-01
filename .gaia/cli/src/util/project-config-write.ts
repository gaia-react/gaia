import {z} from 'zod';
import {mkdirSync} from 'node:fs';
import path from 'node:path';
import {
  DEPENDABOT_SECURITY_UPDATES,
  ISOLATION_POLICIES,
  projectConfigPath,
  readProjectConfig,
} from '../schemas/project-config.js';
import {summarizeZodError} from '../schemas/zod-error.js';
import {atomicWriteFileSync} from './atomic-write.js';

/**
 * Strict counterpart of `ProjectConfigSchema`: the read schema degrades an
 * invalid value to absent, so only this one can refuse a bad value before
 * it lands on disk. Unknown keys pass through untouched.
 */
const ProjectConfigWriteSchema = z.looseObject({
  dependabot_security_updates: z
    .literal(DEPENDABOT_SECURITY_UPDATES)
    .optional(),
  isolation_policy: z.literal(ISOLATION_POLICIES).optional(),
  sandbox_recommended: z.boolean().optional(),
  version: z.literal(1),
});

/** `kind` tells a caller which exit-code contract the failure maps to. */
export class ProjectConfigError extends Error {
  readonly kind: 'invalid_value' | 'malformed';

  constructor(kind: 'invalid_value' | 'malformed', message: string) {
    super(message);
    this.kind = kind;
    this.name = 'ProjectConfigError';
  }
}

/**
 * Shallow-merges `patch` onto the raw `.gaia/project.json` (creating it with
 * `version: 1` when absent) and writes it atomically. Throws
 * a `malformed` `ProjectConfigError` when the existing file cannot be read as a
 * config, and an `invalid_value` one when the merged result carries
 * an invalid known key; neither touches the file.
 */
export const updateProjectConfig = (
  repoRoot: string,
  patch: Record<string, unknown>
): void => {
  const existing = readProjectConfig(repoRoot);

  if (existing.status === 'malformed') {
    throw new ProjectConfigError('malformed', existing.error);
  }

  const base = existing.status === 'ok' ? existing.raw : {};
  const merged: Record<string, unknown> = {
    ...(base.version === undefined ? {version: 1} : {}),
    ...base,
    ...patch,
  };
  const target = projectConfigPath(repoRoot);
  const validation = ProjectConfigWriteSchema.safeParse(merged);

  if (!validation.success) {
    throw new ProjectConfigError(
      'invalid_value',
      summarizeZodError(target, validation.error)
    );
  }

  mkdirSync(path.dirname(target), {recursive: true});
  atomicWriteFileSync(target, `${JSON.stringify(merged, null, 2)}\n`);
};
