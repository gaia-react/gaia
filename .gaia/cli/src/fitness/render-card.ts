/**
 * `gaia fitness render-card` handler.
 *
 * Reads a /gaia-fitness report JSON document on stdin and writes a
 * width-aware ASCII report card to stdout. The /gaia-fitness skill builds the
 * JSON from its adjudicated findings and computed grades, then pastes the
 * rendered card into its chat reply.
 *
 * The box width self-sizes to the longest content line, clamped to a
 * 120-column ceiling and to the terminal width (`--cols`), so the card grows
 * to one line per finding on a wide terminal and wraps remediation text on a
 * narrow one. Categories render alphabetically; the per-category note column
 * is derived from the findings. The card carries no footer; the skill prints
 * post-heal instructions as prose beneath it.
 *
 * Object-map dispatch and no `switch` per the project's typescript rules.
 */
import {z} from 'zod';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const GRADE_WIDTH = 2; // widest grade glyph: "A+", "B-", "D+"
const GAP = 3; // spaces between the note column and the grade
const TAG_WIDTH = 9; // "[warning]" is the widest severity tag
const INDENT = 2 + TAG_WIDTH + 1; // findings remediation hang indent
const MARGIN = 4; // "| " + " |"
const WIDTH_CAP = 120; // hard ceiling regardless of terminal width
const FALLBACK_COLS = 100; // when neither --cols nor a TTY width is available
const OVERALL_LABEL = 'OVERALL';
const SEVERITY_ORDER = ['error', 'warning', 'info'] as const;

const ReportSchema = z.object({
  categories: z.array(z.object({grade: z.string(), name: z.string()})).min(1),
  command: z.string(),
  findings: z
    .array(
      z.object({
        category: z.string(),
        file: z.string(),
        grade: z.string(),
        remediation: z.string(),
        severity: z.literal(['error', 'info', 'warning']),
      })
    )
    .default([]),
  overall: z.string(),
});

export type FitnessReport = z.infer<typeof ReportSchema>;
type Finding = FitnessReport['findings'][number];

/** Compact per-category summary, e.g. `2 errors, 1 info`. Blank when empty. */
const severityNote = (findings: readonly Finding[]): string => {
  const counts = new Map<string, number>();

  for (const finding of findings) {
    counts.set(finding.severity, (counts.get(finding.severity) ?? 0) + 1);
  }

  const parts: string[] = [];

  for (const severity of SEVERITY_ORDER) {
    const count = counts.get(severity) ?? 0;

    if (count > 0) {
      const label =
        severity === 'info' || count === 1 ? severity : `${severity}s`;
      parts.push(`${count} ${label}`);
    }
  }

  return parts.join(', ');
};

/** Keep the informative tail of an over-long path, prefixed with `...`. */
const truncateTail = (text: string, width: number): string =>
  text.length <= width || width < 4 ? text : `...${text.slice(-(width - 3))}`;

/** Greedy word wrap; hard-breaks any single word wider than `width`. */
const wrapText = (text: string, width: number): string[] => {
  if (width <= 0) return [text];

  const words = text.split(/\s+/).filter((word) => word.length > 0);
  const lines: string[] = [];
  let current = '';

  for (const word of words) {
    let token = word;

    while (token.length > width) {
      if (current.length > 0) {
        lines.push(current);
        current = '';
      }

      lines.push(token.slice(0, width));
      token = token.slice(width);
    }

    if (current.length === 0) {
      current = token;
    } else if (current.length + 1 + token.length <= width) {
      current = `${current} ${token}`;
    } else {
      lines.push(current);
      current = token;
    }
  }

  if (current.length > 0) lines.push(current);

  return lines.length > 0 ? lines : [''];
};

const computeInner = (
  report: FitnessReport,
  clusterWidth: number,
  cols: number
): number => {
  const floor =
    Math.max(...report.categories.map((category) => category.name.length)) +
    1 +
    clusterWidth;

  const naturals = [
    floor,
    report.command.length + 1 + clusterWidth,
    'FINDINGS'.length,
  ];

  for (const finding of report.findings) {
    naturals.push(
      `${finding.category}: ${finding.grade}`.length,
      INDENT + finding.file.length,
      INDENT + finding.remediation.length
    );
  }

  const inner = Math.min(Math.max(...naturals), WIDTH_CAP, cols - MARGIN);

  return Math.max(inner, floor);
};

type FindingsRenderContext = {
  inner: number;
  line: (content: string) => string;
};

/** Renders one category's finding block (blank line, header, then each
 * finding's tag/file/remediation lines). Empty when the category has no
 * findings. Extracted so `renderCard` itself stays flat. */
const renderCategoryFindings = (
  category: {grade: string; name: string},
  findings: readonly Finding[] | undefined,
  context: FindingsRenderContext
): string[] => {
  if (findings === undefined || findings.length === 0) return [];

  const {inner, line} = context;
  const lines: string[] = [
    line(''),
    line(`${category.name}: ${category.grade}`),
  ];

  for (const finding of findings) {
    const tag = `[${finding.severity}]`.padEnd(TAG_WIDTH);
    lines.push(line(`  ${tag} ${truncateTail(finding.file, inner - INDENT)}`));

    for (const wrapped of wrapText(finding.remediation, inner - INDENT)) {
      lines.push(line(`${' '.repeat(INDENT)}${wrapped}`));
    }
  }

  return lines;
};

export const renderCard = (report: FitnessReport, cols: number): string => {
  const categories = report.categories.toSorted((a, b) =>
    a.name.localeCompare(b.name)
  );

  const byCategory = new Map<string, Finding[]>();

  for (const finding of report.findings) {
    const bucket = byCategory.get(finding.category) ?? [];
    bucket.push(finding);
    byCategory.set(finding.category, bucket);
  }

  const noteFor = (name: string): string =>
    severityNote(byCategory.get(name) ?? []);

  const noteWidth = Math.max(
    OVERALL_LABEL.length,
    ...categories.map((category) => noteFor(category.name).length)
  );
  const clusterWidth = noteWidth + GAP + GRADE_WIDTH;
  const inner = computeInner(report, clusterWidth, cols);

  const line = (content: string): string =>
    `| ${content}${' '.repeat(inner - content.length)} |`;
  const bar = (): string => `+${'-'.repeat(inner + 2)}+`;
  const cluster = (note: string, grade: string): string =>
    `${note.padStart(noteWidth)}${' '.repeat(GAP)}${grade.padEnd(GRADE_WIDTH)}`;

  const rightRow = (label: string, note: string, grade: string): string => {
    const right = cluster(note, grade);

    return line(
      `${label}${' '.repeat(inner - label.length - right.length)}${right}`
    );
  };

  const out: string[] = [
    bar(),
    rightRow(report.command, OVERALL_LABEL, report.overall),
    bar(),
  ];

  for (const category of categories) {
    out.push(rightRow(category.name, noteFor(category.name), category.grade));
  }

  if (report.findings.length > 0) {
    out.push(bar(), line('FINDINGS'));

    for (const category of categories) {
      out.push(
        ...renderCategoryFindings(category, byCategory.get(category.name), {
          inner,
          line,
        })
      );
    }
  }

  out.push(bar());

  return out.join('\n');
};

const HELP_TEXT = `Usage: gaia fitness render-card [--cols N]

  Read a /gaia-fitness report JSON document on stdin and write a width-aware
  ASCII report card to stdout. --cols sets the target terminal width
  (default: autodetect, fallback ${FALLBACK_COLS}). The box self-sizes to the
  longest content line, clamped to ${WIDTH_CAP} columns and to the terminal
  width, wrapping remediation text to fit.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const readStdin = async (): Promise<string> => {
  const chunks: Buffer[] = [];

  for await (const chunk of process.stdin) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }

  return Buffer.concat(chunks).toString('utf8');
};

const parseCols = (args: readonly string[]): number | undefined => {
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];

    if (arg === '--cols') {
      // `noUncheckedIndexedAccess` is off, so TS types `args[index]` as
      // `string`, not `string | undefined`; check the bound explicitly
      // instead of comparing the indexed value to `undefined`.
      if (index + 1 >= args.length) return undefined;

      const parsed = Number.parseInt(args[index + 1], 10);

      return Number.isFinite(parsed) ? parsed : undefined;
    }

    if (arg.startsWith('--cols=')) {
      const parsed = Number.parseInt(arg.slice('--cols='.length), 10);

      return Number.isFinite(parsed) ? parsed : undefined;
    }
  }

  return undefined;
};

const resolveCols = (args: readonly string[]): number => {
  const fromArgument = parseCols(args);

  if (fromArgument !== undefined && fromArgument > 0) return fromArgument;

  // `process.stdout.columns` is typed as a plain `number`, but Node only
  // populates it when stdout is a TTY; `isTTY` is the documented guard for
  // whether the value is meaningful (e.g. piped output has no columns).
  const {columns, isTTY} = process.stdout;

  return isTTY && columns > 0 ? columns : FALLBACK_COLS;
};

export const run = async (args: readonly string[]): Promise<number> => {
  const first = args[0] as string | undefined;

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const cols = resolveCols(args);
  const raw = await readStdin();

  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    structuredError({
      code: 'invalid_json',
      message: error instanceof Error ? error.message : String(error),
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  const result = ReportSchema.safeParse(parsed);

  if (!result.success) {
    structuredError({code: 'invalid_report', message: result.error.message});

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  process.stdout.write(`${renderCard(result.data, cols)}\n`);

  return EXIT_CODES.OK;
};
