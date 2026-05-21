/**
 * Shared git helpers for the `gaia wiki` subcommand family.
 *
 * Every function shells out to git via `child_process` synchronously and
 * returns trimmed stdout. Errors are surfaced as thrown `Error`s — the
 * subcommand handler is responsible for translating to exit codes.
 */
import {execFileSync} from 'node:child_process';

type RunOptions = {
  cwd?: string;
};

const runGit = (args: readonly string[], options: RunOptions = {}): string => {
  const cwd = options.cwd ?? process.cwd();
  const result = execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    // `git log` over a large history easily exceeds the 1 MiB default and
    // throws ENOBUFS; 64 MiB covers any realistic sync window.
    maxBuffer: 64 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  return result.toString();
};

const tryRunGit = (
  args: readonly string[],
  options: RunOptions = {}
): string | null => {
  try {
    return runGit(args, options);
  } catch {
    return null;
  }
};

/** Resolve the repository root (`git rev-parse --show-toplevel`). */
export const resolveRepoRoot = (cwd: string = process.cwd()): string =>
  runGit(['rev-parse', '--show-toplevel'], {cwd}).trim();

/** Return the full 40-char SHA for HEAD. */
export const headSha = (cwd: string): string =>
  runGit(['rev-parse', 'HEAD'], {cwd}).trim();

/** Return the 7-char short SHA for an arbitrary ref. */
export const shortSha = (sha: string, cwd: string): string => {
  const result = tryRunGit(['rev-parse', '--short=7', sha], {cwd});

  if (result === null) return sha.slice(0, 7);

  return result.trim();
};

/** Test whether `sha` is reachable from HEAD (i.e. an ancestor). */
export const isReachable = (sha: string, cwd: string): boolean => {
  try {
    execFileSync('git', ['merge-base', '--is-ancestor', sha, 'HEAD'], {
      cwd,
      stdio: ['ignore', 'ignore', 'ignore'],
    });

    return true;
  } catch {
    return false;
  }
};

/** Count commits in `<sha>..HEAD`. Returns 0 if `sha` is unreachable. */
export const commitsAhead = (sha: string, cwd: string): number => {
  const result = tryRunGit(['rev-list', '--count', `${sha}..HEAD`], {cwd});

  if (result === null) return 0;
  const parsed = Number.parseInt(result.trim(), 10);

  return Number.isNaN(parsed) ? 0 : parsed;
};

export type RecentCommit = {
  sha: string;
  subject: string;
};

/**
 * Return up to `limit` commits from `<sinceSha>..HEAD` in oldest-first order.
 * Each entry is `{sha (7-char), subject}`. Empty array if `sinceSha` is
 * unreachable or there are no commits.
 */
export const recentCommits = (
  sinceSha: string,
  cwd: string,
  limit = 5
): RecentCommit[] => {
  const result = tryRunGit(
    [
      'log',
      '--no-merges',
      '--reverse',
      '--format=%h%x09%s',
      `${sinceSha}..HEAD`,
    ],
    {cwd}
  );

  if (result === null) return [];

  const lines = result.split('\n').flatMap((line) => {
    const trimmed = line.trim();

    return trimmed.length > 0 ? [trimmed] : [];
  });

  return lines.slice(-limit).map((line) => {
    const tabIndex = line.indexOf('\t');
    const sha = tabIndex === -1 ? line : line.slice(0, tabIndex);
    const subject = tabIndex === -1 ? '' : line.slice(tabIndex + 1);

    return {sha, subject};
  });
};

export type CommitDetail = {
  body: string;
  deletions: number;
  files: string[];
  files_changed: number;
  insertions: number;
  sha: string;
  subject: string;
};

const parseShortStat = (stat: string): {
  deletions: number;
  files_changed: number;
  insertions: number;
} => {
  // Examples:
  //   " 1 file changed, 5 insertions(+)"
  //   " 2 files changed, 3 insertions(+), 1 deletion(-)"
  //   " 1 file changed, 1 deletion(-)"
  let filesChanged = 0;
  let insertions = 0;
  let deletions = 0;

  const filesMatch = /(\d+)\s+files?\s+changed/u.exec(stat);

  if (filesMatch !== null) filesChanged = Number.parseInt(filesMatch[1] as string, 10);

  const insertMatch = /(\d+)\s+insertions?\(\+\)/u.exec(stat);

  if (insertMatch !== null) insertions = Number.parseInt(insertMatch[1] as string, 10);

  const deleteMatch = /(\d+)\s+deletions?\(-\)/u.exec(stat);

  if (deleteMatch !== null) deletions = Number.parseInt(deleteMatch[1] as string, 10);

  return {deletions, files_changed: filesChanged, insertions};
};

const fileListForCommit = (sha: string, cwd: string): string[] => {
  // `git diff-tree --no-commit-id --name-only -r <sha>` emits one path per
  // line touched by `<sha>`. We prefer this to `git show --name-only`
  // because newer git versions reject the `--no-patch --name-only` combo
  // older docs recommended.
  const result = tryRunGit(
    ['diff-tree', '--no-commit-id', '--name-only', '-r', sha],
    {cwd}
  );

  if (result === null) return [];

  return result.split('\n').flatMap((line) => {
    const trimmed = line.trim();

    return trimmed.length > 0 ? [trimmed] : [];
  });
};

type RawRecord = {
  body: string;
  sha: string;
  subject: string;
};

type ChunkParse = {
  precedingStat: string;
  record: RawRecord | null;
};

const parseChunk = (chunk: string): ChunkParse => {
  const trimmed = chunk.replace(/^[\s\n]+/u, '').replace(/[\s\n]+$/u, '');

  if (trimmed === '') return {precedingStat: '', record: null};

  // Find the COMMIT line. Anything before it is the preceding commit's
  // shortstat block; anything from there on is this chunk's commit.
  const lines = trimmed.split('\n');
  const commitLineIndex = lines.findIndex((line) => line.startsWith('COMMIT '));

  if (commitLineIndex === -1) {
    // No COMMIT line in this chunk — the chunk is the trailing-stat-only
    // tail produced after the final commit's separator.
    return {precedingStat: trimmed, record: null};
  }

  const statLines = lines.slice(0, commitLineIndex);
  const precedingStat = statLines.find(
    (line) => /\d+\s+files?\s+changed/u.test(line)
  ) ?? '';

  const commitBlock = lines.slice(commitLineIndex);
  const sha = (commitBlock[0] ?? '').replace(/^COMMIT\s+/u, '').trim();
  const subject = commitBlock[1] ?? '';
  const bodyLines = commitBlock.slice(2);

  while (bodyLines.length > 0 && (bodyLines.at(-1) ?? '').trim() === '') {
    bodyLines.pop();
  }

  return {
    precedingStat,
    record: {body: bodyLines.join('\n'), sha, subject},
  };
};

/**
 * Return commit details for every commit in `<sinceSha>..HEAD` in oldest-first
 * order. Returns full SHA, subject, body, and stat counters per commit.
 *
 * Implementation: a single `git log` call with `--shortstat` plus a unique
 * record separator (`---END-COMMIT---`). `git log` emits the shortstat
 * line AFTER the separator (i.e. at the start of the next commit's
 * record), so each chunk after the first carries the previous commit's
 * stat block AND the current commit's record. File paths are fetched
 * per commit via `git diff-tree --name-only` (one extra call per commit;
 * acceptable because the caller is bounded to a single sync window —
 * typically < 50 commits).
 */
export const commitDetails = (
  sinceSha: string,
  cwd: string
): CommitDetail[] => {
  const recordSeparator = '---END-COMMIT---';
  const raw = tryRunGit(
    [
      'log',
      '--no-merges',
      '--reverse',
      '--shortstat',
      `--format=COMMIT %H%n%s%n%b%n${recordSeparator}`,
      `${sinceSha}..HEAD`,
    ],
    {cwd}
  );

  if (raw === null) return [];

  const chunks = raw.split(recordSeparator);
  const records: RawRecord[] = [];
  const stats: string[] = [];
  let pendingStat: string | null = null;

  for (const chunk of chunks) {
    const {precedingStat, record} = parseChunk(chunk);

    if (record !== null) {
      records.push(record);
      // Resolve the previous record's stat (if any).
      if (records.length > 1) stats.push(precedingStat);
      pendingStat = null;
    } else {
      // Trailing-stat tail belonging to the LAST emitted record.
      pendingStat = precedingStat;
    }
  }

  // Push the final record's stat if a trailing tail was found.
  if (records.length > 0) {
    stats.push(pendingStat ?? '');
  }

  return records.map((record, index) => {
    const stat = stats[index] ?? '';
    const parsed = parseShortStat(stat);
    const files = fileListForCommit(record.sha, cwd);

    return {
      body: record.body,
      deletions: parsed.deletions,
      files,
      files_changed: parsed.files_changed,
      insertions: parsed.insertions,
      sha: record.sha,
      subject: record.subject,
    };
  });
};
