/**
 * `gaia wiki state [--json]` handler.
 *
 * Reports drift between `wiki/.state.json` `last_evaluated_sha` and `git
 * HEAD`. Replaces the prose-form drift checks scattered across
 * `wiki-drift-check.sh`, `wiki/lint.md`, and `wiki/sync.md`.
 *
 * Severity thresholds mirror `wiki-drift-check.sh`:
 *   - none:   commits_ahead === 0
 *   - low:    1–5
 *   - medium: 6–20
 *   - high:   21+
 *
 * Per-domain page counts walk `wiki/<domain>/*.md`. The map is convenient
 * for callers that want a one-shot snapshot without an extra `page-index`
 * call.
 */
import {existsSync, readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  ancestorBefore,
  commitsAhead,
  headSha,
  isReachable,
  recentCommits,
  resolveRepoRoot,
  shortSha,
} from './util/git.js';
import type {RecentCommit} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki state [--json]
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type DriftSeverity = 'high' | 'low' | 'medium' | 'none';

export type WikiState = {
  commits_ahead: number;
  drift_severity: DriftSeverity;
  head_short: string;
  per_domain_page_counts: Record<string, number>;
  reachable: boolean;
  recent_commits: RecentCommit[];
  state_sha: string;
  /**
   * When `reachable` is false, the short SHA of a reachable baseline to resume
   * evaluation from: the newest ancestor of HEAD at or older than
   * `last_evaluated_at`. Empty string when reachable, when the state file has
   * no `last_evaluated_at`, or when the timestamp predates all history. The
   * sync playbook uses it to recover the un-evaluated window after a squash- or
   * rebase-merge orphans `last_evaluated_sha`, rather than discarding it.
   */
  suggested_base: string;
};

const classifySeverity = (commitCount: number): DriftSeverity => {
  if (commitCount <= 0) return 'none';
  if (commitCount <= 5) return 'low';
  if (commitCount <= 20) return 'medium';

  return 'high';
};

const DOMAIN_DIRS = [
  'components',
  'concepts',
  'decisions',
  'dependencies',
  'entities',
  'flows',
  'meta',
  'modules',
];

const countDomainPages = (wikiRoot: string): Record<string, number> => {
  const counts: Record<string, number> = {};

  for (const domain of DOMAIN_DIRS) {
    const domainDir = path.join(wikiRoot, domain);

    if (!existsSync(domainDir) || !statSync(domainDir).isDirectory()) {
      counts[domain] = 0;
      continue;
    }

    const entries = readdirSync(domainDir, {withFileTypes: true});
    let count = 0;

    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.endsWith('.md')) continue;
      // Skip per-domain index pages so the count reflects content pages.
      if (entry.name === '_index.md') continue;
      count += 1;
    }
    counts[domain] = count;
  }

  return counts;
};

type StateFileShape = {
  last_evaluated_at?: string;
  last_evaluated_sha?: string;
};

const readStateFile = (statePath: string): null | StateFileShape => {
  if (!existsSync(statePath)) return null;
  const raw = readFileSync(statePath, 'utf8');

  try {
    return JSON.parse(raw) as StateFileShape;
  } catch {
    return null;
  }
};

const printHuman = (state: WikiState, write: (chunk: string) => void): void => {
  const lines = [
    'Wiki state',
    `  HEAD:           ${state.head_short}`,
    `  Last evaluated: ${state.state_sha}`,
    `  Reachable:      ${state.reachable ? 'yes' : 'no'}`,
    `  Drift:          ${state.commits_ahead} commits (${state.drift_severity})`,
  ];

  if (state.suggested_base !== '') {
    lines.push(`  Recovery base:  ${state.suggested_base}`);
  }

  if (state.recent_commits.length > 0) {
    lines.push('  Recent unsynced:');

    for (const commit of state.recent_commits) {
      lines.push(`    - ${commit.sha} ${commit.subject}`);
    }
  }

  lines.push('  Per-domain pages:');

  for (const [domain, count] of Object.entries(state.per_domain_page_counts)) {
    lines.push(`    ${domain}: ${count}`);
  }
  write(`${lines.join('\n')}\n`);
};

type RunOptions = {
  cwd?: string;
  /**
   * Sink for the handler's stdout. Defaults to `process.stdout.write`.
   * Callers that need to capture the output (e.g. `release preflight`
   * parsing the `--json` payload) pass a collector instead of patching
   * the global stream.
   */
  write?: (chunk: string) => void;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const write =
    options.write ??
    ((chunk: string) => {
      process.stdout.write(chunk);
    });
  let json = false;

  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;
      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${token}`,
      subcommand: 'wiki state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki state must run inside a git repository',
      subcommand: 'wiki state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const wikiRoot = path.join(repoRoot, 'wiki');
  const statePath = path.join(wikiRoot, '.state.json');
  const stateFile = readStateFile(statePath);
  const stateSha = stateFile?.last_evaluated_sha ?? '';
  const stateAt = stateFile?.last_evaluated_at ?? '';
  const head = headSha(repoRoot);
  const headShort = shortSha(head, repoRoot);
  const stateShort = stateSha === '' ? '' : shortSha(stateSha, repoRoot);
  const reachable = stateSha !== '' && isReachable(stateSha, repoRoot);
  const ahead =
    stateSha === '' || !reachable ? 0 : commitsAhead(stateSha, repoRoot);
  const recent =
    stateSha === '' || !reachable ? [] : recentCommits(stateSha, repoRoot, 5);
  const severity = classifySeverity(ahead);
  const counts = countDomainPages(wikiRoot);
  // Only the unreachable path needs a recovery baseline. When the recorded SHA
  // is still in HEAD's history, the normal `last_evaluated_sha..HEAD` range is
  // correct; suggested_base stays empty so consumers ignore it.
  const suggestedFull =
    !reachable && stateAt !== '' ? ancestorBefore(stateAt, repoRoot) : '';
  const suggestedBase =
    suggestedFull === '' ? '' : shortSha(suggestedFull, repoRoot);

  const state: WikiState = {
    commits_ahead: ahead,
    drift_severity: severity,
    head_short: headShort,
    per_domain_page_counts: counts,
    reachable,
    recent_commits: recent,
    state_sha: stateShort,
    suggested_base: suggestedBase,
  };

  if (json) {
    write(`${JSON.stringify(state)}\n`);
  } else {
    printHuman(state, write);
  }

  return EXIT_CODES.OK;
};
