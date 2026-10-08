/**
 * `gaia setup warn-existing-tools [--json]` handler.
 *
 * Detects pre-existing dependency-bot configurations that would
 * collide with `/update-deps`. Read-only by design; never auto-disables
 * either tool. The `/setup-gaia` slash command surfaces the warning
 * text and asks the user to confirm before continuing.
 *
 * Detected files:
 *   - .github/dependabot.yml
 *   - .github/dependabot.yaml
 *   - renovate.json
 *   - .renovaterc.json
 *   - .github/renovate.json
 *
 * Dependabot counts only when a config has an `npm` update entry, because
 * a config for other ecosystems (an adopter's own GitHub Actions or Docker
 * updates) does not overlap `/update-deps`. A config that cannot be parsed
 * is reported as Dependabot with `dependabot_unparseable: true`, since its
 * contents are unknown.
 *
 * Output JSON: `{ "found": [...], "dependabot_unparseable": <bool> }`. The
 * `found` array deduplicates by tool name (so `["dependabot"]` even when
 * both `.yml` and `.yaml` exist).
 */
import {load} from 'js-yaml';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';

const HELP_TEXT = `Usage: gaia setup warn-existing-tools [--json]

  Detect Dependabot or Renovate config files in the repo. Read-only.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

type ToolName = 'dependabot' | 'renovate';

const DEPENDABOT_PATHS = [
  ['.github', 'dependabot.yml'],
  ['.github', 'dependabot.yaml'],
] as const;

const RENOVATE_PATHS = [
  ['renovate.json'],
  ['.renovaterc.json'],
  ['.github', 'renovate.json'],
] as const;

type DependabotStatus = 'npm' | 'other' | 'unparseable';

/** Classifies one Dependabot config file by whether it updates npm. */
const classifyDependabotFile = (filePath: string): DependabotStatus => {
  let parsed: unknown;

  try {
    parsed = load(readFileSync(filePath, 'utf8'));
  } catch {
    return 'unparseable';
  }

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return 'unparseable';
  }

  const updates: unknown = (parsed as {updates?: unknown}).updates;

  if (!Array.isArray(updates)) return 'other';

  const hasNpmEntry = updates.some(
    (entry: unknown) =>
      typeof entry === 'object' &&
      entry !== null &&
      (entry as {'package-ecosystem'?: unknown})['package-ecosystem'] === 'npm'
  );

  return hasNpmEntry ? 'npm' : 'other';
};

const printHuman = (found: ToolName[]): void => {
  if (found.length === 0) {
    process.stdout.write('No competing dependency-bot configs detected.\n');

    return;
  }

  process.stdout.write(`detected: ${found.join(', ')}\n`);
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  let json = false;

  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'setup warn-existing-tools',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message:
        'gaia setup warn-existing-tools must run inside a git repository',
      subcommand: 'setup warn-existing-tools',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const found: ToolName[] = [];

  const dependabotStatuses = DEPENDABOT_PATHS.map((segments) =>
    path.join(repoRoot, ...segments)
  )
    .filter((filePath) => existsSync(filePath))
    .map((filePath) => classifyDependabotFile(filePath));
  const dependabotUnparseable = dependabotStatuses.includes('unparseable');

  if (dependabotUnparseable || dependabotStatuses.includes('npm')) {
    found.push('dependabot');
  }

  const hasRenovate = RENOVATE_PATHS.some((segments) =>
    existsSync(path.join(repoRoot, ...segments))
  );

  if (hasRenovate) found.push('renovate');

  if (json) {
    process.stdout.write(
      `${JSON.stringify({
        dependabot_unparseable: dependabotUnparseable,
        found,
      })}\n`
    );
  } else {
    printHuman(found);
  }

  return EXIT_CODES.OK;
};
