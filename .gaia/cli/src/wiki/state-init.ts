/**
 * `gaia wiki state-init <sha>` handler.
 *
 * Creates `wiki/.state.json` from scratch with `{version: 1,
 * last_evaluated_sha, last_evaluated_at}`. Refuses if the file already
 * exists — use `state-bump` to update an existing state file.
 *
 * Replaces the prose bootstrap write in `wiki/sync.md` Step 1: a fresh
 * project has no `wiki/.state.json`, and `state-bump` will not create
 * one for safety reasons (it could mask a typo'd field name on an
 * existing file). `state-init` is the explicit creation primitive.
 */
import {execFileSync} from 'node:child_process';
import {existsSync, mkdirSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {resolveRepoRoot} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki state-init <sha>

  Create wiki/.state.json with {version: 1, last_evaluated_sha,
  last_evaluated_at}. Refuses if the file already exists.

  <sha> may be any ref (full sha, short sha, branch, tag) — it is
  resolved to a full 40-char sha via \`git rev-parse\`.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
  /** Override the timestamp used in `last_evaluated_at`. Tests only. */
  now?: () => Date;
};

const resolveFullSha = (ref: string, cwd: string): string | null => {
  try {
    const out = execFileSync('git', ['rev-parse', '--verify', `${ref}^{commit}`], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });

    return out.trim();
  } catch {
    return null;
  }
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const positional: string[] = [];

  for (const token of argv) {
    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'wiki state-init',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    positional.push(token);
  }

  if (positional.length !== 1) {
    structuredError({
      code: 'invalid_arguments',
      message: 'state-init requires exactly <sha>',
      subcommand: 'wiki state-init',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const ref = positional[0] as string;

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki state-init must run inside a git repository',
      subcommand: 'wiki state-init',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const fullSha = resolveFullSha(ref, repoRoot);

  if (fullSha === null) {
    structuredError({
      code: 'sha_unresolvable',
      message: `could not resolve <sha> via git rev-parse: "${ref}"`,
      subcommand: 'wiki state-init',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const wikiDir = path.join(repoRoot, 'wiki');
  const statePath = path.join(wikiDir, '.state.json');

  if (existsSync(statePath)) {
    structuredError({
      code: 'state_already_exists',
      message:
        'wiki/.state.json already exists — use `gaia wiki state-bump` to update fields',
      subcommand: 'wiki state-init',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  mkdirSync(wikiDir, {recursive: true});

  const nowDate = (options.now ?? (() => new Date()))();
  const isoNow = nowDate.toISOString();

  const payload = {
    version: 1,
    last_evaluated_sha: fullSha,
    last_evaluated_at: isoNow,
  };

  const serialized = `${JSON.stringify(payload, null, 2)}\n`;
  atomicWriteFileSync(statePath, serialized);

  return EXIT_CODES.OK;
};
