/**
 * `gaia wiki orphans` handler.
 *
 * Newline-separated list of repo-relative paths of pages with
 * `inbound_links === 0` per the page-index walk. No `--json` flag — the
 * output is a list intended for piping to `wc -l` or similar.
 *
 * Replaces the prose subject-orphan pass in `wiki/consolidate.md` Step 2d.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {computePageIndex} from './page-index.js';

const HELP_TEXT = `Usage: gaia wiki orphans

  Newline-separated list of wiki pages with zero inbound wikilinks.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

// Maintainer-only domains. `wiki/meta/` is dated audit artifacts (lint
// reports, dashboards) that exist as standalone documents without inbound
// links by design. `wiki/entities/` is the maintainer's project-specific
// people / org pages. Both are release-excluded — adopters never see them
// — and flagging them as orphans is noise the maintainer can't act on.
// `page-index.ts` deliberately emits these domains and leaves filtering
// to the consumer; this is the orphans consumer's filter.
const isMaintainerOnly = (path: string): boolean =>
  path.startsWith('wiki/meta/') || path.startsWith('wiki/entities/');

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }
    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${token}`,
      subcommand: 'wiki orphans',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let cwd: string;

  try {
    cwd = options.cwd ?? process.cwd();
    const index = computePageIndex(cwd);
    const orphans = index.pages
      .filter((page) => page.inbound_links === 0)
      .filter((page) => !isMaintainerOnly(page.path))
      .map((page) => page.path);

    if (orphans.length > 0) {
      process.stdout.write(`${orphans.join('\n')}\n`);
    }

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'orphans_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki orphans',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
