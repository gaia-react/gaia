/**
 * `gaia wiki orphans [--json]` handler.
 *
 * Default output: newline-separated list of repo-relative paths of pages
 * with `inbound_links === 0` per the page-index walk, intended for piping
 * to `wc -l` or similar. With `--json`, each orphan is enriched with its
 * `title` and `domain` (both already derived by the page-index walk).
 *
 * Replaces the prose subject-orphan pass in `wiki/consolidate.md` Step 2d.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {computePageIndex} from './page-index.js';

const HELP_TEXT = `Usage: gaia wiki orphans [--json]

  List wiki pages with zero inbound wikilinks. Without --json, prints one
  repo-relative path per line. With --json, emits { "orphans": [ { path,
  title, domain } ] }.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

// Maintainer-only domains. `wiki/meta/` is dated audit artifacts (lint
// reports, dashboards) that exist as standalone documents without inbound
// links by design. `wiki/entities/` is the maintainer's project-specific
// people / org pages. Both are release-excluded; adopters never see them,
// and flagging them as orphans is noise the maintainer can't act on.
// `page-index.ts` deliberately emits these domains and leaves filtering
// to the consumer; this is the orphans consumer's filter.
const isMaintainerOnly = (path: string): boolean =>
  path.startsWith('wiki/meta/') || path.startsWith('wiki/entities/');

type Orphan = {
  domain: string;
  path: string;
  title: string;
};

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
      message: `unknown flag: ${token}`,
      subcommand: 'wiki orphans',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let cwd: string;

  try {
    cwd = options.cwd ?? process.cwd();
    const index = computePageIndex(cwd);
    const orphans: Orphan[] = [];

    for (const page of index.pages) {
      if (page.inbound_links === 0 && !isMaintainerOnly(page.path)) {
        orphans.push({
          domain: page.domain,
          path: page.path,
          title: page.title,
        });
      }
    }

    if (json) {
      process.stdout.write(`${JSON.stringify({orphans}, null, 2)}\n`);

      return EXIT_CODES.OK;
    }

    if (orphans.length > 0) {
      process.stdout.write(
        `${orphans.map((orphan) => orphan.path).join('\n')}\n`
      );
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
