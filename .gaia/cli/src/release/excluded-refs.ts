/**
 * The `excluded-refs` derived leak check: references in shipped files to
 * paths, slash commands, agents, and code files that `.gaia/release-exclude`
 * withholds from adopters. The token set is derived from the exclude list at
 * scan time, so a newly excluded file is covered with no config edit; the
 * hand-kept `maintainer-paths` alternation this replaces had drifted to miss
 * most of the excluded set while naming three paths that no longer existed.
 *
 * Pure: the caller supplies the exclude lines, the tracked file list, the
 * shipped basenames, and an executable-bit probe, so the derivation is
 * testable without a git repository.
 */
import path from 'node:path';
import {escapeRegExp} from '../util/escape-regexp.js';

export type ExcludedRefInputs = {
  excludeLines: readonly string[];
  isExecutable: (relativePath: string) => boolean;
  optOut: readonly string[];
  shippedBasenames: ReadonlySet<string>;
  tracked: readonly string[];
};

export type ExcludedRefTokens = {
  agents: readonly string[];
  basenames: readonly string[];
  commands: readonly string[];
  paths: readonly string[];
  unusedOptOut: readonly string[];
};

// `excluded-workflow-ref` owns excluded workflows, because some of them are
// installed on adopters from a render template and that check knows which.
const WORKFLOWS_PREFIX = '.github/workflows/';
const COMMAND_PATTERN =
  /^\.claude\/(?:commands\/(?<command>[\w-]+)\.md|skills\/(?<skill>[\w-]+))$/;
const AGENT_PATTERN = /^\.claude\/agents\/(?<agent>[\w-]+)\.md$/;
// Code file names are distinctive enough to stand alone in prose. Data and
// fixture names (`cost.jsonl`) are not: adopters generate files of the same
// name at runtime, so a bare mention of one is not a pointer to GAIA's copy.
const CODE_EXTENSIONS = new Set(['.mjs', '.sh', '.ts']);

// A token must not continue a longer identifier on its right.
const RIGHT_BOUNDARY = String.raw`(?![\w-])`;
// A path must not sit inside a longer path on its left. `./` is allowed in
// front of it, `foo/` and `x.` are not.
const PATH_LEFT_BOUNDARY = String.raw`(?<![\w.-])(?<![\w-]/)`;
// A name (command, agent, basename) must not be a path segment or a suffix.
const NAME_LEFT_BOUNDARY = String.raw`(?<![\w/.-])`;

const isUnder = (file: string, entry: string): boolean =>
  file === entry || file.startsWith(`${entry}/`);

// Local state (`.serena`, `.gaia/local`) and root governance files
// (`README.md`) are excluded too, but adopters have their own, so naming them
// is not a pointer to something missing.
const isReferenceableEntry = (
  entry: string,
  tracked: readonly string[]
): boolean =>
  entry.includes('/') &&
  !entry.startsWith(WORKFLOWS_PREFIX) &&
  tracked.some((file) => isUnder(file, entry));

const isCodeFile = (
  file: string,
  isExecutable: (relativePath: string) => boolean
): boolean => {
  const extension = path.extname(file);

  return extension === '' ? isExecutable(file) : CODE_EXTENSIONS.has(extension);
};

const sortTokens = (tokens: ReadonlySet<string>): string[] => {
  const list: string[] = [...tokens];

  return list.toSorted((left, right) => left.localeCompare(right));
};

export const deriveExcludedRefTokens = ({
  excludeLines,
  isExecutable,
  optOut,
  shippedBasenames,
  tracked,
}: ExcludedRefInputs): ExcludedRefTokens => {
  const entries = excludeLines.filter((entry) =>
    isReferenceableEntry(entry, tracked)
  );
  const paths = new Set(entries);
  const commands = new Set<string>();
  const agents = new Set<string>();
  const basenames = new Set<string>();

  for (const entry of entries) {
    const commandGroups = COMMAND_PATTERN.exec(entry)?.groups;
    const command = commandGroups?.command ?? commandGroups?.skill;
    const agent = AGENT_PATTERN.exec(entry)?.groups?.agent;

    if (command !== undefined) commands.add(command);
    if (agent !== undefined) agents.add(agent);

    for (const file of tracked) {
      if (
        isUnder(file, entry) &&
        !shippedBasenames.has(path.basename(file)) &&
        isCodeFile(file, isExecutable)
      ) {
        basenames.add(path.basename(file));
      }
    }
  }

  const unusedOptOut: string[] = [];

  for (const token of optOut) {
    const removed = [paths, commands, agents, basenames].some((set) =>
      set.delete(token)
    );

    if (!removed) unusedOptOut.push(token);
  }

  return {
    agents: sortTokens(agents),
    basenames: sortTokens(basenames),
    commands: sortTokens(commands),
    paths: sortTokens(paths),
    unusedOptOut,
  };
};

// Longest first, so a token is never shadowed by a shorter one it extends.
// Undefined when there is nothing to match, so the caller can drop it.
const compileKind = (
  tokens: readonly string[],
  leftBoundary: string,
  prefix = ''
): RegExp | undefined => {
  if (tokens.length === 0) return undefined;

  const alternatives = tokens
    .toSorted((left, right) => right.length - left.length)
    .map((token) => escapeRegExp(token))
    .join('|');

  return new RegExp(
    `${leftBoundary}${prefix}(?:${alternatives})${RIGHT_BOUNDARY}`,
    'g'
  );
};

const isRegExp = (value: RegExp | undefined): value is RegExp =>
  value !== undefined;

export type ExcludedRefMatcher = (
  line: string,
  options: {markdown: boolean}
) => string[];

/**
 * Every distinct excluded reference on one line, in match order. Basenames
 * are matched in Markdown only: elsewhere (shell comments, the CLI bundle) a
 * bare file name is too often a local of the same name.
 */
export const compileExcludedRefMatcher = (
  tokens: ExcludedRefTokens
): ExcludedRefMatcher => {
  const general = [
    compileKind(tokens.paths, PATH_LEFT_BOUNDARY),
    compileKind(tokens.commands, NAME_LEFT_BOUNDARY, '/'),
    compileKind(tokens.agents, NAME_LEFT_BOUNDARY),
  ].filter(isRegExp);
  const markdown = [
    ...general,
    compileKind(tokens.basenames, NAME_LEFT_BOUNDARY),
  ].filter(isRegExp);

  return (line, options) => {
    const found: {index: number; token: string}[] = [];

    for (const pattern of options.markdown ? markdown : general) {
      for (const match of line.matchAll(pattern)) {
        found.push({index: match.index, token: match[0]});
      }
    }

    if (found.length === 0) return [];

    return [
      ...new Set(
        found
          .toSorted((left, right) => left.index - right.index)
          .map(({token}) => token)
      ),
    ];
  };
};
