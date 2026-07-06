/**
 * `gaia setup-ci detect-remote [--json]` handler.
 *
 * Shells `git remote get-url origin` and parses the result via
 * `parseRemoteUrl`. Returns the four parsed fields on success; returns
 * `{ found: false, ... }` on missing remote.
 *
 * Exits 0 in every branch where the working directory is a git repo;
 * `detect-remote` is a query. Exits non-zero only for `not_a_git_repo`.
 */
import {execFileSync} from 'node:child_process';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {parseRemoteUrl} from './util/parse-remote-url.js';

const HELP_TEXT = `Usage: gaia setup-ci detect-remote [--json]

  Read \`git remote get-url origin\` and parse it. Returns parsed
  owner/repo/host on success; \`found: false\` on missing remote.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type DetectOutput = {
  found: boolean;
  host: null | string;
  owner: null | string;
  repo: null | string;
  url: null | string;
};

type RunOptions = {
  cwd?: string;
};

const tryGitRemoteUrl = (cwd: string): null | string => {
  try {
    const result = execFileSync('git', ['remote', 'get-url', 'origin'], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });

    return result.toString().trim();
  } catch {
    return null;
  }
};

const printHuman = (output: DetectOutput): void => {
  if (!output.found) {
    process.stdout.write('No origin remote configured.\n');

    return;
  }

  process.stdout.write(
    `url: ${String(output.url)}\n` +
      `host: ${String(output.host)}\n` +
      `owner: ${String(output.owner)}\n` +
      `repo: ${String(output.repo)}\n`
  );
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
      subcommand: 'setup-ci detect-remote',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup-ci detect-remote must run inside a git repository',
      subcommand: 'setup-ci detect-remote',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const url = tryGitRemoteUrl(repoRoot);

  if (url === null) {
    const output: DetectOutput = {
      found: false,
      host: null,
      owner: null,
      repo: null,
      url: null,
    };

    if (json) {
      process.stdout.write(`${JSON.stringify(output)}\n`);
    } else {
      printHuman(output);
    }

    return EXIT_CODES.OK;
  }

  const parsed = parseRemoteUrl(url);

  const output: DetectOutput =
    parsed === null ?
      {found: false, host: null, owner: null, repo: null, url}
    : {
        found: true,
        host: parsed.host,
        owner: parsed.owner,
        repo: parsed.repo,
        url: parsed.url,
      };

  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  return EXIT_CODES.OK;
};
