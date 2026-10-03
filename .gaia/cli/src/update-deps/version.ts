/**
 * Strip leading range operators (`^`, `~`, `>=`, `>`, `=`, `v`) so we can
 * compare leading numeric segments. Whitespace is trimmed too.
 */
export const stripRange = (raw: string): string => {
  let value = raw.trim();

  while (value.length > 0) {
    const first = value[0];

    if (first === '^' || first === '~' || first === '=' || first === 'v') {
      value = value.slice(1);
    } else if (first === '>' || first === '<') {
      value = value.slice(1);
      // strip an optional `=` after `>`/`<`
      if (value.startsWith('=')) value = value.slice(1);
    } else {
      break;
    }
  }

  return value.trim();
};

export const parseSegments = (raw: string): readonly number[] => {
  const cleaned = stripRange(raw);
  // Take only the dot-separated leading numeric part. `1.2.3-beta.1` →
  // `[1, 2, 3]`. Non-numeric chunks beyond the first three slots are
  // ignored; the SKILL only needs leading-integer comparison.
  const parts = cleaned.split(/[+-]/u, 1)[0]?.split('.') ?? [];
  const out: number[] = [];

  for (const part of parts) {
    const parsed = Number.parseInt(part, 10);

    out.push(Number.isFinite(parsed) ? parsed : 0);
  }

  while (out.length < 3) out.push(0);

  return out;
};

export const compareSegments = (
  a: readonly number[],
  b: readonly number[]
): number => {
  const maxLength = Math.max(a.length, b.length);

  for (let index = 0; index < maxLength; index += 1) {
    const av = a[index] ?? 0;
    const bv = b[index] ?? 0;

    if (av !== bv) return av < bv ? -1 : 1;
  }

  return 0;
};
