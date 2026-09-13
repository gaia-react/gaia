/**
 * `gaia residue-record --disposition dismissed|kept|suppressed --token T [--token T ...] --reason-file F`
 *
 * The dismissal store's only writer from the skill (COV-001): every record
 * is produced by `appendRecords`'s JSON serializer, so the SPEC's
 * no-embedded-newline refusal and schema-version obligation are met in one
 * place rather than trusted to a hand-written JSONL line. Mirrors
 * `gaia harden-ledger record`, the precedent this reproduces
 * (`../harden/ledger.ts`).
 *
 * `class` and `cited_line_text` are derived from the token's decoded
 * coordinate plus the attribution cache: a coordinate the cache still holds
 * (an entry the same-session tally attributed) supplies both; a coordinate
 * the cache no longer holds falls back to a live resolve when the cache at
 * least remembers the pull request's head SHA, and to the empty string
 * otherwise. The caller supplies neither field, which is what keeps a forged
 * value out of the record.
 */
import {readFileSync} from 'node:fs';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {readAttributionCache, resolutionCacheKey} from './cache.js';
import type {AttributionCache} from './cache.js';
import {resolveProvider} from './corpus.js';
import type {CorpusProvider} from './corpus.js';
import {resolveCitedLine} from './resolve.js';
import {appendRecords} from './store.js';
import type {StoreDisposition, StoreRecord} from './store.js';
import {decodeToken} from './token.js';

const HELP_TEXT = `Usage: gaia residue-record --disposition <dismissed|kept|suppressed> --token T [--token T ...] --reason-file F

  Appends one dismissal-store record per --token, sharing one disposition,
  date, and reason. Exit 0 means written; any non-zero means nothing was
  recorded.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const KNOWN_DISPOSITIONS = new Set<string>(['dismissed', 'kept', 'suppressed']);

type ParsedArgs = {
  disposition?: string;
  reasonFile?: string;
  tokens: string[];
};

type RunOptions = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  now?: () => Date;
};

const parseArgs = (
  argv: readonly string[]
): {error: string} | {value: ParsedArgs} => {
  let disposition: string | undefined;
  let reasonFile: string | undefined;
  const tokens: string[] = [];

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--disposition') {
      disposition = argv[index + 1];
      index += 1;
    } else if (token === '--token') {
      const value = argv[index + 1];

      if (value !== undefined) tokens.push(value);
      index += 1;
    } else if (token === '--reason-file') {
      reasonFile = argv[index + 1];
      index += 1;
    } else {
      return {error: `unknown argument: ${token}`};
    }
  }

  return {value: {disposition, reasonFile, tokens}};
};

const resolveRoot = (cwd: string): string => {
  try {
    return resolveRepoRoot(cwd);
  } catch {
    return cwd;
  }
};

// A reason file typically ends in the shell's own trailing newline (`echo
// "reason" > file`); stripping exactly one keeps a genuinely single-line
// reason from tripping the store's embedded-newline refusal, while a reason
// that still carries a newline after the strip is a real multi-line refusal.
const stripTrailingNewline = (raw: string): string => {
  if (raw.endsWith('\r\n')) return raw.slice(0, -2);
  if (raw.endsWith('\n')) return raw.slice(0, -1);

  return raw;
};

const deriveFields = (
  cache: AttributionCache,
  provider: CorpusProvider,
  coordinate: {line: number; path: string; pr_number: number}
): {cited_line_text: string; class: string} => {
  const prEntry = cache.prs[String(coordinate.pr_number)];
  const entryClass = prEntry?.attribution.entries.find(
    (entry) =>
      entry.key.path === coordinate.path && entry.key.line === coordinate.line
  )?.key.class;
  const klass = entryClass ?? '';

  if (prEntry === undefined) return {cited_line_text: '', class: klass};

  const key = resolutionCacheKey(
    prEntry.headRefOid,
    coordinate.path,
    coordinate.line
  );
  const cachedResolution = cache.resolutions[key];

  if (cachedResolution !== undefined) {
    return {cited_line_text: cachedResolution.resolved_line_text, class: klass};
  }

  const resolved = resolveCitedLine(provider, {
    headSha: prEntry.headRefOid,
    line: coordinate.line,
    path: coordinate.path,
    prNumber: coordinate.pr_number,
  });

  return {cited_line_text: resolved.resolved_line_text, class: klass};
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [first] = argv;

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'residue-record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {disposition, reasonFile, tokens} = parsed.value;

  if (disposition === undefined || !KNOWN_DISPOSITIONS.has(disposition)) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'residue-record requires --disposition dismissed|kept|suppressed',
      subcommand: 'residue-record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (tokens.length === 0) {
    structuredError({
      code: 'invalid_arguments',
      message: 'residue-record requires at least one --token T',
      subcommand: 'residue-record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (reasonFile === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'residue-record requires --reason-file F',
      subcommand: 'residue-record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let rawReason: string;

  try {
    rawReason = readFileSync(reasonFile, 'utf8');
  } catch {
    structuredError({
      code: 'unreadable_reason_file',
      message: `could not read reason file: ${reasonFile}`,
      subcommand: 'residue-record',
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  const reason = stripTrailingNewline(rawReason);
  const decodedTokens: {line: number; path: string; pr_number: number}[] = [];

  for (const token of tokens) {
    const decoded = decodeToken(token);

    if (!decoded.ok) {
      structuredError({
        code: 'invalid_token',
        message: decoded.reason,
        subcommand: 'residue-record',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    decodedTokens.push(decoded.value);
  }

  const cwd = options.cwd ?? process.cwd();
  const env = options.env ?? process.env;
  const repoRoot = resolveRoot(cwd);
  const cache = readAttributionCache(repoRoot);
  const provider = resolveProvider(cwd, env);
  const date = (options.now ?? (() => new Date()))().toISOString();

  const records: StoreRecord[] = decodedTokens.map((coordinate) => {
    const {cited_line_text: citedLineText, class: klass} = deriveFields(
      cache,
      provider,
      coordinate
    );

    return {
      cited_line_text: citedLineText,
      class: klass,
      date,
      disposition: disposition as StoreDisposition,
      line: coordinate.line,
      path: coordinate.path,
      reason,
      schema: 'v1',
      source_pr: coordinate.pr_number,
    };
  });

  try {
    appendRecords(repoRoot, records);
  } catch (error) {
    structuredError({
      code: 'refused_record',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'residue-record',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  return EXIT_CODES.OK;
};
