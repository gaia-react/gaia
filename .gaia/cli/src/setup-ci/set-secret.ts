/**
 * `gaia setup-ci set-secret <name>` handler.
 *
 * Reads the token from `process.stdin` and pipes it directly to
 * `gh secret set <name>` via the child's stdin. The implementation
 * is designed to never leak the secret on any code path:
 *
 *   - The token is NEVER appended to argv. The `gh` invocation always
 *     receives the literal `['secret', 'set', <name>]`.
 *   - The token is NEVER written to a file.
 *   - The token is NEVER echoed to stdout or stderr.
 *   - On any failure (including `gh` non-zero, gh missing from PATH,
 *     stdin empty, unknown name, etc.), the structured-error / JSON
 *     payload contains a generic message, never the captured `gh`
 *     stdout/stderr verbatim.
 *
 * If `gh` writes the secret to its OWN stderr (which it should not,
 * but defense in depth), the wrapper captures the stderr but this
 * handler reports a generic `gh_failure` message rather than echoing
 * the captured stderr in the structured error. This is the only place
 * in the codebase that intentionally suppresses stderr propagation;
 * the trade-off is an opaque error message in exchange for a strict
 * no-leak guarantee.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {runGh} from './util/gh.js';

const HELP_TEXT = `Usage: gaia setup-ci set-secret <name>

  Read a secret value from stdin and pipe it into \`gh secret set <name>\`.
  The token is never echoed, logged, or passed on the command line.

  <name> must be one of: CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUPPORTED_SECRET_NAMES = [
  'CLAUDE_CODE_OAUTH_TOKEN',
  'ANTHROPIC_API_KEY',
] as const;

type SupportedSecretName = (typeof SUPPORTED_SECRET_NAMES)[number];

type RunOptions = {
  cwd?: string;
  stdin?: NodeJS.ReadableStream;
};

const readStdinToBuffer = (stream: NodeJS.ReadableStream): Promise<Buffer> => {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];

    stream.on('data', (chunk: Buffer | string) => {
      chunks.push(
        typeof chunk === 'string' ? Buffer.from(chunk, 'utf8') : chunk
      );
    });

    stream.on('end', () => {
      resolve(Buffer.concat(chunks));
    });

    stream.on('error', (error: Error) => {
      reject(error);
    });
  });
};

const trimTrailingWhitespace = (buf: Buffer): Buffer => {
  let end = buf.length;

  while (end > 0) {
    const byte = buf[end - 1];

    if (byte === 0x0a /* \n */ || byte === 0x0d /* \r */) {
      end -= 1;

      continue;
    }
    break;
  }

  return buf.subarray(0, end);
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const name = argv[0] as string;
  const rest = argv.slice(1);

  if (rest.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${rest[0] as string}`,
      subcommand: 'setup-ci set-secret',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!(SUPPORTED_SECRET_NAMES as readonly string[]).includes(name)) {
    structuredError({
      code: 'unknown_secret_name',
      message: `unsupported secret name: ${name}. Supported: ${SUPPORTED_SECRET_NAMES.join(', ')}`,
      subcommand: 'setup-ci set-secret',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const validatedName = name as SupportedSecretName;

  const stream = options.stdin ?? process.stdin;
  let stdinBuffer: Buffer;

  try {
    stdinBuffer = await readStdinToBuffer(stream);
  } catch {
    structuredError({
      code: 'stdin_read_error',
      message: 'failed to read secret from stdin',
      subcommand: 'setup-ci set-secret',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const trimmed = trimTrailingWhitespace(stdinBuffer);

  if (trimmed.length === 0) {
    structuredError({
      code: 'empty_secret',
      message: 'no secret value provided on stdin',
      subcommand: 'setup-ci set-secret',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = await runGh({
    args: ['secret', 'set', validatedName],
    cwd: options.cwd ?? process.cwd(),
    stdin: trimmed,
  });

  if (!result.ok) {
    // Defensive no-leak: never include `result.stderr` (which `gh`
    // populated) in any user-visible payload. The captured stderr
    // could in principle echo the secret if `gh` misbehaves; we report
    // a generic failure marker instead.
    process.stdout.write(
      `${JSON.stringify({error: 'gh_failure', name: validatedName, set: false})}\n`
    );

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  process.stdout.write(`${JSON.stringify({name: validatedName, set: true})}\n`);

  return EXIT_CODES.OK;
};
