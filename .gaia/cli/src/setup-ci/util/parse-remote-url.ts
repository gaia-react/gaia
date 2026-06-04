/**
 * Pure helper for parsing GitHub remote URLs.
 *
 * Supports the five forms `git remote get-url origin` produces in the
 * wild. Returns `null` for any other shape; callers surface the
 * "no GitHub origin" message themselves.
 *
 * Accepted forms:
 *   git@github.com:owner/repo.git
 *   git@github.com:owner/repo
 *   https://github.com/owner/repo.git
 *   https://github.com/owner/repo
 *   ssh://git@github.com/owner/repo.git
 *
 * Rejection behaviour: any URL with extra path segments (e.g. GitLab
 * subgroups), missing owner/repo, or a non-host-and-path shape parses
 * to `null`. The host field is preserved as-is so the caller can
 * branch on `host !== "github.com"` for the "GitHub-only v1" guard.
 */

export type ParsedRemote = {
  host: string;
  owner: string;
  repo: string;
  url: string;
};

const stripGitSuffix = (value: string): string =>
  value.endsWith('.git') ? value.slice(0, -4) : value;

const isValidSegment = (value: string): boolean =>
  value.length > 0 && !value.includes('/');

// SSH "scp-style" form: git@host:owner/repo[.git]
const SCP_SSH_RE = /^([^@]+)@([^:]+):(.+)$/u;

// HTTPS form: https://host/owner/repo[.git]
const HTTPS_RE = /^https?:\/\/([^/]+)\/(.+)$/u;

// SSH protocol form: ssh://git@host/owner/repo[.git]
const SSH_PROTO_RE = /^ssh:\/\/[^/]+\/(.+)$/u;
const SSH_PROTO_HOST_RE = /^ssh:\/\/(?:[^@/]+@)?([^/]+)\//u;

const parseTwoSegments = (
  url: string,
  host: string,
  rest: string
): ParsedRemote | null => {
  const trimmedRest = stripGitSuffix(rest).replace(/\/+$/u, '');
  const segments = trimmedRest.split('/');

  if (segments.length !== 2) return null;

  const [owner, repo] = segments;

  if (
    owner === undefined ||
    repo === undefined ||
    !isValidSegment(owner) ||
    !isValidSegment(repo)
  ) {
    return null;
  }

  return {host, owner, repo, url};
};

export const parseRemoteUrl = (url: string): ParsedRemote | null => {
  if (typeof url !== 'string' || url.trim() === '') return null;

  const trimmed = url.trim();

  if (trimmed.startsWith('ssh://')) {
    const hostMatch = SSH_PROTO_HOST_RE.exec(trimmed);
    const restMatch = SSH_PROTO_RE.exec(trimmed);

    if (hostMatch === null || restMatch === null) return null;

    return parseTwoSegments(
      trimmed,
      hostMatch[1] as string,
      restMatch[1] as string
    );
  }

  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    const match = HTTPS_RE.exec(trimmed);

    if (match === null) return null;

    return parseTwoSegments(trimmed, match[1] as string, match[2] as string);
  }

  const scpMatch = SCP_SSH_RE.exec(trimmed);

  if (scpMatch !== null) {
    const host = scpMatch[2] as string;
    const rest = scpMatch[3] as string;

    return parseTwoSegments(trimmed, host, rest);
  }

  return null;
};
