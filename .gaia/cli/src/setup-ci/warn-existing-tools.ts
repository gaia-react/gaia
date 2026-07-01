/**
 * `gaia setup-ci warn-existing-tools [--json]` handler.
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
 * Output JSON: `{ "found": [...] }`. The `found` array deduplicates by
 * tool name (so `["dependabot"]` even when both `.yml` and `.yaml`
 * exist).
 */
import {existsSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

const HELP_TEXT = `Usage: gaia setup-ci warn-existing-tools [--json]

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

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${token}`,
      subcommand: 'setup-ci warn-existing-tools',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message:
        'gaia setup-ci warn-existing-tools must run inside a git repository',
      subcommand: 'setup-ci warn-existing-tools',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const found: ToolName[] = [];

  const hasDependabot = DEPENDABOT_PATHS.some((segments) =>
    existsSync(path.join(repoRoot, ...segments))
  );

  if (hasDependabot) found.push('dependabot');

  const hasRenovate = RENOVATE_PATHS.some((segments) =>
    existsSync(path.join(repoRoot, ...segments))
  );

  if (hasRenovate) found.push('renovate');

  if (json) {
    process.stdout.write(`${JSON.stringify({found})}\n`);
  } else {
    printHuman(found);
  }

  return EXIT_CODES.OK;
};
