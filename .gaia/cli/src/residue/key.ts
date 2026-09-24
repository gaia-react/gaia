/**
 * Dedup-key grammar and field validation for audit residue.
 *
 * Pure: no filesystem, no network, no process spawning. Two grammars live
 * here and they are not interchangeable, because they serve two different
 * consumers and agreeing with the wrong one is a defect in each direction.
 *
 * `KEY_PATTERN` is the recognized dedup-key grammar. `attributeBody` uses it
 * to find every key in a pull-request body, and `parseKey` serves that side
 * and keeps the mandatory `v1` token.
 *
 * `LENIENT_KEY_PATTERN` reproduces the tech-debt filer's grammar
 * (`.gaia/scripts/debt-count-refresh.sh`). Suppression matching against
 * tech-debt issue bodies uses it, because the thing suppression must agree
 * with is the filer. It anchors on the wrapped comment opener and it does not
 * require `v1`. Both grammars terminate the path on the key comment's own
 * closer rather than on a space; this side also stops at a newline because
 * its subject is a whole body and a key never spans one. `parseWrappedKeys`
 * serves that side.
 *
 * A caller may not substitute one for the other. Reading FEWER issue keys
 * than the filer matches is a livelock: the drain keeps offering a residual
 * the filer then refuses to file as a duplicate, forever. Reading a key out
 * of a pull-request body with the lenient grammar is the mirror defect: the
 * tally would attribute entries the strict grammar never counted.
 */

/**
 * The gate's frozen wrapped key grammar; group 1 is the inner key.
 *
 * Spelled `[0-9]` rather than `\d` because a parity test compares this source
 * text against the gate's own POSIX ERE, which has no `\d` to compare to.
 */
export const KEY_PATTERN =
  // eslint-disable-next-line sonarjs/concise-regex -- byte parity with the gate's ERE
  /<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->/;

/** The filer's grammar, applied to a whole issue body; group 1 is the path. */
export const LENIENT_KEY_PATTERN =
  /<!-- gaia-debt-key:[^>]*?path=([^>\n]+) line=/;

/**
 * Upper bound on a cited line number. Well above any file this repo or an
 * adopter's carries, and low enough that a key claiming a line beyond it is
 * evidence of a corrupt or hand-forged key rather than a real coordinate.
 */
export const MAX_LINE = 10_000_000;

export type ResidueKey = {
  class: string;
  line: number;
  path: string;
  version: 'v1';
};

export type Validated<T> = {ok: false; reason: string} | {ok: true; value: T};

// Named individually rather than as one class, so a refusal names the
// character that was actually found: the three arrive from different places
// (a NUL from a binary splice, a newline or carriage return from a wrapped or
// CRLF body) and a reader repairing one should not be told about the others.
const CONTROL_CHARACTERS: readonly (readonly [string, string])[] = [
  ['\0', 'NUL'],
  ['\n', 'newline'],
  ['\r', 'carriage return'],
];

/**
 * Validates a repo-relative POSIX path and returns its normalized form.
 *
 * Normalization collapses repeated separators, drops `./` segments, and
 * strips a trailing separator, so those spelling variants of one path cannot
 * bypass the shared coordinate identity `sameCoordinate` compares on.
 *
 * Whitespace is NOT among them. Now that the path field terminates on the
 * comment's closer rather than on a space, one space separates the path from
 * ` line=` and any further space stays inside the path, so `path=app/a.ts
 * line=1` written with two spaces parses `ok` with a trailing space and reads
 * as a different coordinate from the same file filed without it. Under the
 * old space-terminated grammar the comment matched no key at all, so the unit
 * was keyless; `malformed[]` is reached only once the pattern matches and
 * field validation then fails, which it never did here. The regression is
 * therefore keyless becoming silently accepted as a distinct coordinate, not
 * reported becoming accepted. It is
 * still disposable through the normal drain rather than a livelock: it
 * resolves `unresolvable` and is dismissible.
 */
export const normalizeRepoRelativePath = (raw: string): Validated<string> => {
  if (raw === '') {
    return {ok: false, reason: 'path is empty'};
  }

  const control = CONTROL_CHARACTERS.find(([character]) =>
    raw.includes(character)
  );

  if (control !== undefined) {
    return {
      ok: false,
      reason: `path contains an embedded ${control[1]} character`,
    };
  }

  if (
    raw.startsWith('/') ||
    raw.startsWith('\\\\') ||
    /^[A-Za-z]:[\\/]/.test(raw)
  ) {
    return {
      ok: false,
      reason:
        'path has an absolute prefix; a residual key cites a repo-relative path',
    };
  }

  if (raw.startsWith('-')) {
    return {
      ok: false,
      reason: 'path has a leading dash, which reads as an option flag in argv',
    };
  }

  const segments = raw
    .split('/')
    .filter((segment) => segment !== '' && segment !== '.');

  if (segments.includes('..')) {
    return {
      ok: false,
      reason: 'path contains a .. traversal segment',
    };
  }

  const normalized = segments.join('/');

  if (normalized === '') {
    return {ok: false, reason: 'path normalizes to empty'};
  }

  return {ok: true, value: normalized};
};

/** Validates a cited line number: a plain positive integer within MAX_LINE. */
export const parseKeyLine = (raw: string): Validated<number> => {
  if (raw === '') {
    return {ok: false, reason: 'line is empty'};
  }

  if (raw.startsWith('+') || raw.startsWith('-')) {
    return {
      ok: false,
      reason: 'line carries a sign; the grammar takes a bare digit run',
    };
  }

  if (!/^\d+$/.test(raw)) {
    return {
      ok: false,
      reason:
        'line is not a bare digit run (no exponent, decimal point, separator, or whitespace)',
    };
  }

  if (raw.length > 1 && raw.startsWith('0')) {
    return {ok: false, reason: 'line has a leading zero'};
  }

  const value = Number(raw);

  if (value < 1) {
    return {
      ok: false,
      reason: 'line is below 1; the first line of a file is 1',
    };
  }

  if (value > MAX_LINE) {
    return {ok: false, reason: `line exceeds the maximum of ${MAX_LINE}`};
  }

  return {ok: true, value};
};

// Keyed by grammar name so the caller's choice of grammar is a value rather
// than a comment. There is deliberately no 'lenient' member: the lenient side
// reads a whole issue body, not a pre-extracted inner key, so it cannot be
// reached by swapping a pattern here. `parseWrappedKeys` is its only door.
const KEY_FIELD_PATTERNS = {
  gate: /^v1 class=([^ ]+) path=([^>]+) line=(\d+)$/,
} as const;

/** Parses and validates an inner key (`v1 class=… path=… line=…`). */
export const parseKey = (
  innerKey: string,
  grammar: 'gate'
): Validated<ResidueKey> => {
  const fields = KEY_FIELD_PATTERNS[grammar].exec(innerKey);

  if (fields === null) {
    if (!innerKey.startsWith('v1 ')) {
      return {
        ok: false,
        reason: 'key is missing the mandatory v1 version token',
      };
    }

    return {
      ok: false,
      reason:
        'key does not match the gate grammar `v1 class=<class> path=<path> line=<line>`; a missing or malformed field is the usual cause',
    };
  }

  const [, rawClass = '', rawPath = '', rawLine = ''] = fields;
  const path = normalizeRepoRelativePath(rawPath);

  if (!path.ok) {
    return path;
  }

  const line = parseKeyLine(rawLine);

  if (!line.ok) {
    return line;
  }

  return {
    ok: true,
    value: {class: rawClass, line: line.value, path: path.value, version: 'v1'},
  };
};

/**
 * Every wrapped key an issue body carries, in body order, as coordinates.
 *
 * A key whose path or line the validators refuse is dropped rather than
 * surfaced: on the suppression side a key that cannot be compared cannot
 * suppress, and a malformed key in someone's issue body is not this command's
 * to report.
 */
export const parseWrappedKeys = (
  text: string
): {line: number; path: string}[] => {
  const scanner = new RegExp(LENIENT_KEY_PATTERN.source, 'g');
  const found: {line: number; path: string}[] = [];

  for (const match of text.matchAll(scanner)) {
    const rawPath = match[1];
    // The filer's pattern ends at ` line=` and captures only the path, so the
    // line is the digit run immediately following the match.
    const digits = /^\d+/.exec(text.slice(match.index + match[0].length));

    if (rawPath !== undefined && digits !== null) {
      const path = normalizeRepoRelativePath(rawPath);
      const line = parseKeyLine(digits[0]);

      if (path.ok && line.ok) {
        found.push({line: line.value, path: path.value});
      }
    }
  }

  return found;
};

/**
 * Whether two residual coordinates name the same place: path and line only,
 * on the normalized path form. Class never participates, and an unvalidatable
 * path on either side compares as different.
 */
export const sameCoordinate = (
  a: {line: number; path: string},
  b: {line: number; path: string}
): boolean => {
  const left = normalizeRepoRelativePath(a.path);
  const right = normalizeRepoRelativePath(b.path);

  return left.ok && right.ok && left.value === right.value && a.line === b.line;
};
