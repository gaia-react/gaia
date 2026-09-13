/**
 * The opaque coordinate token minted by the tally and consumed by
 * `residue-cursor` and `residue-record`.
 *
 * The skill drives the CLI as agent Bash, which is a shell string, so a
 * body-derived `--path` would put residual text on a shell command line no
 * matter how it is quoted. A token closed over `[A-Za-z0-9_-]` cannot carry a
 * metacharacter, a space, a quote, or a leading dash, so it is the only
 * argv-safe way to name a candidate. `decodeToken` re-validates the decoded
 * path and line through the same validators the attribution grammar uses, so
 * a hand-forged token is caught here rather than trusted downstream.
 */
import {normalizeRepoRelativePath, parseKeyLine} from './key.js';

export const TOKEN_PATTERN = /^[A-Za-z0-9_-]{1,512}$/;

export type DecodedToken =
  {ok: false; reason: string} | {ok: true; value: TokenCoordinate};

export type TokenCoordinate = {line: number; path: string; pr_number: number};

const base64UrlEncode = (raw: string): string =>
  Buffer.from(raw, 'utf8')
    .toString('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

const base64UrlDecode = (token: string): null | string => {
  const padded = token.replaceAll('-', '+').replaceAll('_', '/');
  const padding = (4 - (padded.length % 4)) % 4;

  try {
    return Buffer.from(padded + '='.repeat(padding), 'base64').toString('utf8');
  } catch {
    return null;
  }
};

/** Base64url (no padding) of `<pr_number>:<path>:<line>`. */
export const encodeToken = (coordinate: TokenCoordinate): string =>
  base64UrlEncode(
    `${coordinate.pr_number}:${coordinate.path}:${coordinate.line}`
  );

export const decodeToken = (token: string): DecodedToken => {
  if (!TOKEN_PATTERN.test(token)) {
    return {
      ok: false,
      reason: 'token does not match the expected character set',
    };
  }

  const decoded = base64UrlDecode(token);

  if (decoded === null) {
    return {ok: false, reason: 'token is not valid base64url'};
  }

  const firstColon = decoded.indexOf(':');
  const lastColon = decoded.lastIndexOf(':');

  if (firstColon === -1 || lastColon === firstColon) {
    return {ok: false, reason: 'decoded token does not carry three fields'};
  }

  const rawPrNumber = decoded.slice(0, firstColon);
  const rawPath = decoded.slice(firstColon + 1, lastColon);
  const rawLine = decoded.slice(lastColon + 1);

  if (!/^\d+$/.test(rawPrNumber)) {
    return {ok: false, reason: 'decoded token carries an invalid pr_number'};
  }

  const prNumber = Number.parseInt(rawPrNumber, 10);

  if (!Number.isSafeInteger(prNumber)) {
    return {ok: false, reason: 'decoded token carries an invalid pr_number'};
  }

  const path = normalizeRepoRelativePath(rawPath);

  if (!path.ok) return {ok: false, reason: path.reason};

  const line = parseKeyLine(rawLine);

  if (!line.ok) return {ok: false, reason: line.reason};

  return {
    ok: true,
    value: {line: line.value, path: path.value, pr_number: prNumber},
  };
};
