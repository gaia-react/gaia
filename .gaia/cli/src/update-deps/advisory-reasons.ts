/**
 * The closed set of reasons an advisory source did not answer, each with fixed
 * text. Every surface that explains a missing source (the advisories payload,
 * the update-check cache, the statusline, the /update-deps report) renders one
 * of these strings, never gh or pnpm stderr, which can carry a token or
 * attacker-controlled text.
 */

/** Every reason token, in the order the advisories payload documents them. */
export const ADVISORY_REASON_TOKENS = [
  'ci',
  'gh-missing',
  'gh-unauthenticated',
  'no-remote',
  'non-github-remote',
  'alerts-disabled',
  'forbidden',
  'alerts-request-failed',
  'alerts-invalid-response',
  'pnpm-audit-failed',
  'cli-failed',
  'jq-missing',
] as const;

export type AdvisoryReasonToken = (typeof ADVISORY_REASON_TOKENS)[number];

/** The fixed human-readable text for each reason token. */
export const ADVISORY_REASON_TEXT: Readonly<
  Record<AdvisoryReasonToken, string>
> = {
  'alerts-disabled': 'Dependabot alerts are disabled',
  'alerts-invalid-response': 'alerts response was not valid JSON',
  'alerts-request-failed': 'alerts request failed',
  ci: 'CI run',
  'cli-failed': 'advisories refresh failed',
  forbidden: 'token lacks permission to read Dependabot alerts',
  'gh-missing': 'gh not installed',
  'gh-unauthenticated': 'gh not authenticated',
  'jq-missing': 'jq not installed',
  'no-remote': 'no origin remote',
  'non-github-remote': 'origin is not a GitHub remote',
  'pnpm-audit-failed': 'pnpm audit produced no advisories object',
};

/** The texts of `tokens`, joined by "; " (empty for no tokens). */
export const reasonText = (tokens: readonly AdvisoryReasonToken[]): string =>
  tokens.map((token) => ADVISORY_REASON_TEXT[token]).join('; ');
