/**
 * Minimal YAML frontmatter parser for wiki pages.
 *
 * Handles the subset actually used by `wiki/**` pages:
 *   - Top-of-file `---` fenced block.
 *   - Scalar `key: value` lines (string, number, boolean).
 *   - Inline list `tags: [a, b, c]`.
 *   - ISO date / string values are returned verbatim as strings.
 *
 * Out of scope: nested mappings, multi-line block scalars, anchors. If a
 * future page needs richer YAML, swap in a real parser at that point —
 * this module covers the shapes wiki pages emit today.
 */
const FRONTMATTER_FENCE = '---';
const SCALAR_PATTERN = /^([\w-]+)\s*:\s*(.*)$/u;

export type FrontmatterValue = boolean | number | string | string[] | null;

export type Frontmatter = Record<string, FrontmatterValue>;

const stripQuotes = (raw: string): string => {
  if (raw.length < 2) return raw;
  const first = raw.charAt(0);
  const last = raw.charAt(raw.length - 1);

  if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
    return raw.slice(1, -1);
  }

  return raw;
};

const parseScalar = (raw: string): FrontmatterValue => {
  const trimmed = raw.trim();

  if (trimmed === '' || trimmed === 'null' || trimmed === '~') return null;
  if (trimmed === 'true') return true;
  if (trimmed === 'false') return false;

  if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
    const inner = trimmed.slice(1, -1).trim();

    if (inner === '') return [];

    return inner
      .split(',')
      .map((entry) => stripQuotes(entry.trim()))
      .filter((entry) => entry.length > 0);
  }

  if (/^-?\d+(\.\d+)?$/u.test(trimmed)) {
    return Number(trimmed);
  }

  return stripQuotes(trimmed);
};

export type FrontmatterParseResult = {
  body: string;
  frontmatter: Frontmatter;
  hasFrontmatter: boolean;
};

/**
 * Parse a markdown file's leading YAML frontmatter block. Returns the parsed
 * mapping plus the body (everything after the closing `---`).
 *
 * If no frontmatter is present, `frontmatter` is `{}` and `body` equals the
 * input. If the opening fence is present but the closing fence is missing,
 * the function still returns: callers that care about that case can check
 * `hasFrontmatter` before reading.
 */
export const parseFrontmatter = (raw: string): FrontmatterParseResult => {
  const lines = raw.split('\n');

  if ((lines[0] ?? '').trim() !== FRONTMATTER_FENCE) {
    return {body: raw, frontmatter: {}, hasFrontmatter: false};
  }

  let closingIndex = -1;

  for (let index = 1; index < lines.length; index += 1) {
    if ((lines[index] ?? '').trim() === FRONTMATTER_FENCE) {
      closingIndex = index;
      break;
    }
  }

  if (closingIndex === -1) {
    // Malformed: opening fence without a closing fence. Treat as no
    // frontmatter so callers don't blow up.
    return {body: raw, frontmatter: {}, hasFrontmatter: false};
  }

  const yamlLines = lines.slice(1, closingIndex);
  const frontmatter: Frontmatter = {};

  for (const line of yamlLines) {
    if (line.trim() === '' || line.trim().startsWith('#')) continue;
    const match = SCALAR_PATTERN.exec(line);

    if (match === null) continue;
    const key = match[1] as string;
    const value = (match[2] as string).trim();
    frontmatter[key] = parseScalar(value);
  }

  const body = lines.slice(closingIndex + 1).join('\n');

  return {body, frontmatter, hasFrontmatter: true};
};
