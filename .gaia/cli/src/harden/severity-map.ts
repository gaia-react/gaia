/**
 * The one grading -> severity map shared by every `code-audit-*` agent file
 * and the findings-block parser. Each agent file declares the gradings it can
 * emit via a `<!-- gaia-audit:gradings: ... -->` line, and every declared
 * grading must be a key here, with every value here in
 * `parse-findings-block.ts`'s `SEVERITIES`. A member that learns a fourth
 * grading must add it here and to the parser's accepted set.
 */
export const SEVERITY_BY_GRADING = {
  Critical: 'error',
  Important: 'warning',
  Suggestion: 'suggestion',
} as const;
