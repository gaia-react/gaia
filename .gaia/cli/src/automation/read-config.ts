/**
 * `gaia automation read-config [--json]` handler.
 *
 * Thin wrapper around `readAutomationConfig`. JSON output is the
 * schema-typed object verbatim; human output is a few-line key:value
 * summary. Exits non-zero with `config_missing` when the config file
 * does not exist (the CLI is a primitive — callers handle missing
 * configs explicitly).
 */
import {EXIT_CODES} from '../exit.js';
import {readAutomationConfig} from '../schemas/automation-config.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

const HELP_TEXT = `Usage: gaia automation read-config [--json]

  Reads .gaia/automation.json and prints its content. Exits non-zero
  with code "config_missing" when the file does not exist.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
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
      message: `unknown argument: ${token}`,
      subcommand: 'automation read-config',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation read-config must run inside a git repository',
      subcommand: 'automation read-config',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = readAutomationConfig(repoRoot);

  if (result.status === 'missing') {
    structuredError({
      code: 'config_missing',
      message: '.gaia/automation.json does not exist',
      subcommand: 'automation read-config',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (result.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: result.error,
      subcommand: 'automation read-config',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (json) {
    process.stdout.write(`${JSON.stringify(result.config)}\n`);
  } else {
    const c = result.config;
    process.stdout.write(
      `version: ${String(c.version)}\n` +
        `setup_complete: ${String(c.setup_complete)}\n` +
        `setup_opted_out: ${String(c.setup_opted_out)}\n` +
        `wiki: mode=${c.wiki.mode}${c.wiki.schedule ? ` schedule=${c.wiki.schedule}` : ''}\n` +
        `sharpen: mode=${c.sharpen.mode}${c.sharpen.schedule ? ` schedule=${c.sharpen.schedule}` : ''}\n` +
        `pnpm_audit: mode=${c.pnpm_audit.mode}${c.pnpm_audit.schedule ? ` schedule=${c.pnpm_audit.schedule}` : ''}\n` +
        `stale_branches: mode=${c.stale_branches.mode}${c.stale_branches.schedule ? ` schedule=${c.stale_branches.schedule}` : ''}\n` +
        `update_gaia: mode=${c.update_gaia.mode}\n`
    );
  }

  return EXIT_CODES.OK;
};
