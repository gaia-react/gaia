/**
 * Replicates Phases 1-3 of `.claude/skills/update-deps/SKILL.md` as a
 * deterministic shell primitive so major bumps split into per-group PRs
 * before the LLM-driven flow runs.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from '../util/argv.js';
import {run as runAdvisories} from './advisories.js';
import {run as runAdvisoryLanded} from './advisory-landed.js';
import {run as runCheckSecurityOverride} from './check-security-override.js';
import {run as runDecline} from './decline.js';
import {run as runDismissAlert} from './dismiss-alert.js';
import {run as runGlobalTools} from './global-tools.js';
import {run as runEmit} from './run.js';
import {run as runWriteSecurityCache} from './write-security-cache.js';

const HELP_TEXT = `Usage: gaia update-deps <subcommand> [args]

  run --emit-updates <path>                   Discover outdated packages,
                                              classify into Wave A / Wave B,
                                              and emit a JSON payload at
                                              <path>.
  decline --source <path> --skip <a,b,...>    Snooze update groups so the
                                              statusline stops counting them
                                              (local only). --clear resets.
  global-tools                                Report globally installed tools
                                              (playwright-cli) as JSON rows.
  advisories --emit <path> [--count-only] [--updates <path>] [--no-alerts]
                                              Fetch, validate, and rank open
                                              security advisories (Dependabot
                                              alerts, else pnpm audit) into a
                                              JSON payload at <path>.
  advisory-landed --package <name> --vulnerable-range <range>
                                              Exit 0 when no installed version
                                              of <name> is in <range>.
  dismiss-alert --alert <n> --reason <tolerable_risk|not_used> --comment <text> --confirmed
                                              Dismiss one Dependabot alert
                                              after confirmation (never in
                                              CI).
  write-security-cache --count <n> --source <dependabot|pnpm-audit> [--reason <tokens>]
                                              Rewrite the update-check cache's
                                              security fields.
  check-security-override --key <k> --value <v> --package <name> --first-patched <version>
                                              Validate a security-floor
                                              override entry.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  advisories: runAdvisories,
  'advisory-landed': runAdvisoryLanded,
  'check-security-override': runCheckSecurityOverride,
  decline: runDecline,
  'dismiss-alert': runDismissAlert,
  'global-tools': runGlobalTools,
  run: runEmit,
  'write-security-cache': runWriteSecurityCache,
};

export const run = async (argv: readonly string[]): Promise<number> => {
  const subcommand = argv[0];
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = lookupOwn(SUBCOMMAND_HANDLERS, subcommand);

  if (handler !== undefined) {
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown update-deps subcommand: ${subcommand}`,
    subcommand: `update-deps ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
