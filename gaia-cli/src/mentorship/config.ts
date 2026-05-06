import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {MentorshipConfigSchema} from '../schemas/mentorship-config.js';
import type {MentorshipConfig} from '../schemas/mentorship-config.js';
import type {StorageRoots} from '../storage/paths.js';

export const CONFIG_FILENAME = 'mentorship.json';

/**
 * Resolve `<repoRoot>/.gaia/local/mentorship.json`.
 *
 * `StorageRoots` is a frozen Phase 1 contract — extending it for this single
 * sibling-of-`.project-id` path would force a contract change for a path that
 * only the mentorship module reads/writes. `roots.projectIdPath` is
 * `<repoRoot>/.gaia/local/.project-id`, so its parent directory is the
 * mentorship config's parent directory. Derive from there.
 */
const resolveConfigPath = (roots: StorageRoots): string =>
  path.join(path.dirname(roots.projectIdPath), CONFIG_FILENAME);

/**
 * Pre-decision default. `enabled === null` means gaia-init has not yet
 * surfaced the AskUserQuestion. The emit path treats null exactly like false.
 */
const PRE_DECISION_DEFAULT: MentorshipConfig = {
  analytics: {enabled: false},
  decided_at: null,
  decided_via: null,
  enabled: null,
};

/**
 * Read the mentorship config. If the file is absent, return the pre-decision
 * default ({ enabled: null, ... }) without writing anything to disk.
 *
 * Validates against MentorshipConfigSchema. Throws on malformed JSON or a
 * shape that fails validation — a corrupted config should fail loud rather
 * than silently default to "off".
 */
export const readMentorshipConfig = (roots: StorageRoots): MentorshipConfig => {
  const filePath = resolveConfigPath(roots);

  if (!existsSync(filePath)) {
    return {
      ...PRE_DECISION_DEFAULT,
      analytics: {...PRE_DECISION_DEFAULT.analytics},
    };
  }

  const raw = readFileSync(filePath, 'utf8');
  const parsed = JSON.parse(raw) as unknown;

  return MentorshipConfigSchema.parse(parsed);
};

type WriteArguments = {
  analyticsEnabled: boolean;
  decidedVia: NonNullable<MentorshipConfig['decided_via']>;
  enabled: boolean;
  roots: StorageRoots;
};

/**
 * Write the mentorship config atomically (write-temp-and-rename to avoid
 * half-written state visible to a concurrent reader).
 *
 * Mode 644 — the file lives under `.gaia/local/` (gitignored, in-project)
 * and records the user's mentorship choice, not identity.
 *
 * `decided_at` is set to the current ISO-8601 UTC timestamp.
 */
export const writeMentorshipConfig = (arguments_: WriteArguments): void => {
  const {analyticsEnabled, decidedVia, enabled, roots} = arguments_;
  const filePath = resolveConfigPath(roots);

  const config: MentorshipConfig = {
    analytics: {enabled: analyticsEnabled},
    decided_at: new Date().toISOString(),
    decided_via: decidedVia,
    enabled,
  };
  // Validate before write so a programmer error throws loudly here rather
  // than landing a malformed file that the next read would reject.
  MentorshipConfigSchema.parse(config);

  const parent = path.dirname(filePath);

  if (!existsSync(parent)) {
    // `<repoRoot>/.gaia/local/` may not exist yet on a fresh repo (the
    // gaia-init flow writes the config before any other module has had
    // reason to create the directory). Mode 755 matches the in-project
    // convention used by `readOrCreateProjectId`.
    mkdirSync(parent, {mode: 0o755, recursive: true});
  }

  const contents = `${JSON.stringify(config, null, 2)}\n`;
  const temporaryPath = `${filePath}.tmp-${process.pid}`;

  // Atomic write contract: write-temp-and-rename. POSIX rename is atomic
  // on the same filesystem, so a crash mid-write leaves either the old
  // file or the new file — never a half-written one.
  writeFileSync(temporaryPath, contents, {mode: 0o644});
  renameSync(temporaryPath, filePath);
};

/**
 * Convenience for the emit path (UAT-009). Mentorship writes are gated on
 * this; cloud writes are independent.
 *
 * Returns `false` for the absent-file state, `enabled: null`, and
 * `enabled: false`. Returns `true` only when `enabled === true`.
 */
export const isMentorshipEnabled = (roots: StorageRoots): boolean =>
  readMentorshipConfig(roots).enabled === true;
