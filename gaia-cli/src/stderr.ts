/**
 * Structured-error printer for the gaia CLI.
 *
 * Hooks parse stderr line-by-line as JSON; humans see the same line.
 * Never use `console.error` — it tripwires lint rules (no-console) and
 * doesn't guarantee a trailing newline on every Node version.
 */
type StructuredErrorPayload = {
  [key: string]: unknown;
  code: string;
};

export const structuredError = (payload: StructuredErrorPayload): void => {
  process.stderr.write(`${JSON.stringify(payload)}\n`);
};
