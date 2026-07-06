import type {z} from 'zod';

/**
 * Render a `ZodError` into a single-line, human-readable summary prefixed
 * with the offending file path. Shared by the schema `read*` helpers
 * (`automation-config`, `automation-state`, `local-automation`,
 * `revert-ledger`) so the malformed-file message format stays consistent.
 */
export const summarizeZodError = (
  filePath: string,
  error: z.ZodError
): string => {
  const lines = error.issues.map((issue) => {
    const pathString =
      issue.path.length === 0 ? '<root>' : issue.path.join('.');

    return `${pathString}: ${issue.message}`;
  });

  return `${filePath}: ${lines.join('; ')}`;
};
