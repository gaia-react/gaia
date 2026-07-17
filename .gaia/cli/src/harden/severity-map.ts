/**
 * The one grading -> severity map shared by every `code-audit-*` agent file
 * and the findings-block parser (README FC-7). Each agent file declares the
 * gradings it can emit via a `<!-- gaia-audit:gradings: ... -->` line, and
 * `severity-map.test.ts` asserts every declared grading is a key here, and
 * every value here is in `parse-findings-block.ts`'s `SEVERITIES`. A member
 * that learns a fourth grading must add it here and to the parser's accepted
 * set, or the divergence test fails.
 */
export const SEVERITY_BY_GRADING = {
  Critical: 'error',
  Important: 'warning',
  Suggestion: 'suggestion',
} as const;
