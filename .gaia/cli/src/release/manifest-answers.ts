/**
 * Answer machinery for `gaia-maintainer release manifest`.
 *
 * The distribution boundary is asymmetric. Withholding a file leaves
 * evidence (a line in `.gaia/release-exclude`); shipping one leaves nothing
 * at all, because shipping is what happens when nobody does anything. So at
 * regeneration time "the maintainer considered this and chose to ship it"
 * and "the maintainer never saw it" are byte-identical states.
 *
 * These pure functions break the tie: every file that would newly ship must
 * carry an explicit answer (`--ship` or `--withhold`) before the CLI will
 * produce a manifest in any output mode. `--allow-undecided` waives the
 * exact-cover requirement, and nothing else.
 *
 * Nothing here touches the filesystem, and nothing here imports from
 * `manifest.ts` (no cycle).
 */

export type AnswerError = {
  code: AnswerErrorCode;
  message: string;
  paths: readonly string[];
};

export type AnswerErrorCode =
  | 'answer_not_missing'
  | 'duplicate_answer'
  | 'unanswered_paths'
  | 'unknown_category'
  | 'withhold_metacharacter'
  | 'withhold_reason_invalid';

export type AnswerSet = {
  allowUndecided: boolean;
  ships: readonly string[];
  withholds: readonly WithholdAnswer[];
};

export type ExcludeCategory = {
  /** 0-based index of the `# --- N. title ---` line within the split text. */
  headerLineIndex: number;
  number: number;
  title: string;
};

export type WithholdAnswer = {
  category: number;
  path: string;
  reason: string;
};

const CATEGORY_HEADER = /^# --- (\d+)\. (.+?) ---\s*$/;

/**
 * Characters rejected in a withhold path. Every exclude line compiles to an
 * anchored regex, so a metacharacter in a path silently changes which files
 * the line masks.
 *
 * `.`, `+`, `-`, `_`, `~`, `@`, `,`, `!`, and `=` are deliberately allowed:
 * all three release-exclude parsers (the regex compiler in `manifest.ts`,
 * `release.yml`'s sed, and the distribution harness's literal test) escape
 * `.` and `+` identically, and GAIA's own `app/routes/_public+/` paths carry
 * a `+`. Over-rejecting them would make a legitimate file unwithholdable.
 */
const REJECTED_PATH_CHARACTERS = [
  '(',
  ')',
  '*',
  '?',
  '[',
  '\\',
  ']',
  '^',
  '{',
  '|',
  '}',
  '$',
];

/**
 * A line break is the one whitespace character a withhold path may never
 * carry. The CLI renders the path as its own line in `.gaia/release-exclude`,
 * so an embedded newline emits a SECOND, uncommented line that membership
 * never inspected: the same hazard `isRejectedReason` guards on the reason
 * text. Interior spaces and tabs are safe by contrast, and are allowed, see
 * `isRejectedWithholdPath`.
 */
const LINE_BREAK = /[\n\r]/;

/**
 * True when `value` carries a character from `REJECTED_PATH_CHARACTERS`. The
 * single source of truth for "unsafe exclude-line character", shared by the
 * withhold-answer gate here and by `manifest.ts`'s raw-exclude-text validator
 * (`validateExcludeText`), so a metacharacter is rejected identically whether
 * it arrives via `--withhold` or already sits in the committed boundary file.
 */
export const hasRejectedExcludeMetacharacter = (value: string): boolean =>
  REJECTED_PATH_CHARACTERS.some((character) => value.includes(character));

const uniqueSorted = (paths: readonly string[]): string[] => {
  const unique: string[] = [...new Set(paths)];

  return unique.toSorted((a, b) => a.localeCompare(b));
};

const findDuplicates = (paths: readonly string[]): string[] => {
  const seen = new Set<string>();
  const duplicates = new Set<string>();

  for (const candidate of paths) {
    if (seen.has(candidate)) duplicates.add(candidate);
    seen.add(candidate);
  }

  return uniqueSorted([...duplicates]);
};

/**
 * A withhold value that is empty, comment-shaped, slash-anchored, line-break-
 * bearing, surrounded by whitespace, or metacharacter-bearing. A bracketed
 * path is the narrow case this guards: it does NOT crash the exclude compiler
 * (`escapeRegExp` leaves `[` and `]` alone, so `docs/notes[1].md` compiles to a
 * valid `^docs/notes[1]\.md(/|$)`), it silently masks `docs/notes1.md` and
 * never masks the file actually withheld, while `build-staging.sh` DOES
 * escape brackets, so the manifest and the staging pipeline disagree about
 * which file was excluded.
 *
 * Interior whitespace is deliberately allowed, and the leading/trailing test
 * is written as a trim comparison to mirror `validateExcludeText`'s
 * `normalized !== trimmed` exactly. The two validators are one boundary read
 * from two directions, so a path this gate refuses to WRITE that the committed
 * file would happily be READ with is a defect: `wiki/` titles carry spaces, and
 * the boundary file already holds such lines. Every consumer treats an exclude
 * line as a literal path, `release exclude-regex` escaping it into an anchored
 * regex that `grep -vE -f` and `rsync --files-from` then apply, and a space is
 * literal in all three.
 */
const isRejectedWithholdPath = (withholdPath: string): boolean =>
  withholdPath.length === 0 ||
  withholdPath.startsWith('#') ||
  withholdPath.startsWith('/') ||
  withholdPath.endsWith('/') ||
  withholdPath !== withholdPath.trim() ||
  LINE_BREAK.test(withholdPath) ||
  hasRejectedExcludeMetacharacter(withholdPath);

/**
 * The reason is untrusted input the CLI renders into the boundary file as a
 * comment. A newline would make it emit a second, UNCOMMENTED line — a bare
 * subtree-masking entry that membership never inspected, because membership
 * only ever looks at the withhold value.
 */
const isRejectedReason = (reason: string): boolean =>
  reason.trim().length === 0 || reason.includes('\n') || reason.includes('\r');

const parseCategoryLines = (lines: readonly string[]): ExcludeCategory[] =>
  lines.flatMap((line, headerLineIndex) => {
    const match = CATEGORY_HEADER.exec(line);

    if (match === null) return [];

    const [, numberText, title] = match;

    if (numberText === undefined || title === undefined) return [];

    return [{headerLineIndex, number: Number(numberText), title}];
  });

/** Parse `# --- <N>. <title> ---` headers out of a release-exclude body. */
export const parseExcludeCategories = (text: string): ExcludeCategory[] =>
  parseCategoryLines(text.split('\n'));

/**
 * Validate the WHOLE answer set against a `missing` snapshot. An empty array
 * means the set is valid. Returns every error found, not just the first: a
 * caller who answered three paths wrongly should see all three.
 *
 * Order: membership → duplicates → metacharacter → reason → category →
 * exact-cover.
 */
export const validateAnswers = (
  answers: AnswerSet,
  missing: readonly string[],
  categories: readonly ExcludeCategory[]
): AnswerError[] => {
  const errors: AnswerError[] = [];
  const withholdPaths = answers.withholds.map((withhold) => withhold.path);
  const answered = [...answers.ships, ...withholdPaths];
  const missingSet = new Set(missing);

  // Membership is what stops a bare directory (`wiki/decisions`) from standing
  // in for its whole subtree: a directory carries no metacharacter, but
  // `missing` holds files, so a directory is never a member of it.
  const notMissing = uniqueSorted(
    answered.filter((candidate) => !missingSet.has(candidate))
  );

  if (notMissing.length > 0) {
    errors.push({
      code: 'answer_not_missing',
      message: `answered path is not awaiting an answer: ${notMissing.join(', ')}`,
      paths: notMissing,
    });
  }

  const duplicates = findDuplicates(answered);

  if (duplicates.length > 0) {
    errors.push({
      code: 'duplicate_answer',
      message: `path answered more than once: ${duplicates.join(', ')}`,
      paths: duplicates,
    });
  }

  const rejectedPaths = uniqueSorted(
    withholdPaths.filter((candidate) => isRejectedWithholdPath(candidate))
  );

  // Six distinct conditions reach this one branch, and they are not
  // distinguishable from the code alone, so the message names the whole set
  // rather than the metacharacter case the code is spelled for. Naming only
  // that one sends a maintainer hunting for a glob character in a path whose
  // real problem is a leading space.
  if (rejectedPaths.length > 0) {
    errors.push({
      code: 'withhold_metacharacter',
      message: `withhold path is not a bare literal path (empty, comment-shaped, slash-anchored, whitespace-padded, line-break-bearing, or carrying one of ${REJECTED_PATH_CHARACTERS.join('')}): ${rejectedPaths.join(', ')}`,
      paths: rejectedPaths,
    });
  }

  const badReasonPaths = uniqueSorted(
    answers.withholds
      .filter((withhold) => isRejectedReason(withhold.reason))
      .map((withhold) => withhold.path)
  );

  if (badReasonPaths.length > 0) {
    errors.push({
      code: 'withhold_reason_invalid',
      message: `withhold reason must be one non-empty line with no newline or carriage return: ${badReasonPaths.join(', ')}`,
      paths: badReasonPaths,
    });
  }

  const knownCategories = new Set(
    categories.map((category) => category.number)
  );
  const unknownCategoryPaths = uniqueSorted(
    answers.withholds
      .filter((withhold) => !knownCategories.has(withhold.category))
      .map((withhold) => withhold.path)
  );

  if (unknownCategoryPaths.length > 0) {
    errors.push({
      code: 'unknown_category',
      message: `--category names no numbered release-exclude category: ${unknownCategoryPaths.join(', ')}`,
      paths: unknownCategoryPaths,
    });
  }

  if (answers.allowUndecided) return errors;

  const answeredSet = new Set(answered);
  const unanswered = missing.filter((candidate) => !answeredSet.has(candidate));

  if (unanswered.length > 0) {
    errors.push({
      code: 'unanswered_paths',
      message: `${unanswered.length} file(s) would newly ship with no explicit answer: ${unanswered.join(', ')}`,
      paths: unanswered,
    });
  }

  return errors;
};

/**
 * The line index one past the end of a category's block: the next
 * `# --- N. … ---` header, or EOF for the last category.
 */
const findBlockEnd = (
  lines: readonly string[],
  category: ExcludeCategory
): number => {
  for (
    let index = category.headerLineIndex + 1;
    index < lines.length;
    index += 1
  ) {
    const line = lines[index];

    if (line !== undefined && CATEGORY_HEADER.test(line)) return index;
  }

  return lines.length;
};

const findLastNonBlankLine = (
  lines: readonly string[],
  start: number,
  end: number
): number => {
  let last = start;

  for (let index = start; index < end; index += 1) {
    const line = lines[index];

    if (line !== undefined && line.trim().length > 0) last = index;
  }

  return last;
};

/**
 * Pure: returns the new exclude text. Never touches the filesystem.
 *
 * Each withhold appends two lines — `# <reason>` then the verbatim path at
 * column zero — immediately after the last non-blank line of its category's
 * block, which keeps the blank separator before the next category header.
 * Categories are re-parsed per withhold because each splice shifts the line
 * indices of every category below it.
 */
export const applyWithholds = (
  excludeText: string,
  withholds: readonly WithholdAnswer[]
): string => {
  const lines = excludeText.split('\n');

  for (const withhold of withholds) {
    const category = parseCategoryLines(lines).find(
      (candidate) => candidate.number === withhold.category
    );

    // `validateAnswers` has already rejected an unknown category, so this is
    // unreachable through the CLI; a direct caller gets a no-op rather than a
    // withhold silently filed under the wrong heading.
    if (category !== undefined) {
      const insertAt = findLastNonBlankLine(
        lines,
        category.headerLineIndex,
        findBlockEnd(lines, category)
      );
      lines.splice(
        insertAt + 1,
        0,
        `# ${withhold.reason.trim()}`,
        withhold.path
      );
    }
  }

  return lines.join('\n');
};
