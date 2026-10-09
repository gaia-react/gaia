# shellcheck shell=bash
# Shared breadcrumb lib for the GitHub pull-request artifact a run produced.
#
# Sourced by the callers that must agree on one on-disk shape:
# .claude/hooks/capture-gh-artifact.sh (the sole writer, fires when
# `gh pr create` succeeds) and its readers, none of which deletes the file.
# .claude/hooks/block-main-destructive-git.sh reads it as proof that a session
# owns the branch it holds the main checkout on; it relies on the branch-keyed
# filename and the session and branch match below, and passes a long ttl
# because a session id never repeats. No cost record reads it: the writing hook
# links the pull request to its branch with `usage.sh link --pr`. The five
# prose maintenance commands and the /gaia-wiki chain bind their artifact by
# direct pass-through instead: the agent reads the URL `gh pr create` printed
# into its own tool result and hands the number to `usage.sh record`, because
# those runs check out and delete their working branch before the run ends, so
# a branch-keyed breadcrumb could never be reclaimed at that point.
#
# No side effects at source time; this file defines functions only. Every
# function below returns 0 and degrades to nothing on failure, never
# blocking a caller, never fabricating a value, except gaia_gh_artifact_write,
# which PROPAGATES failure (non-zero when nothing reached disk) so a lost
# breadcrumb is detectable.
#
# There is no consume function: the reader never deletes the file, because
# every cumulative commit-triggered row on an execution branch must re-read
# the same breadcrumb. The filename is keyed by branch:
# <main_root>/.gaia/local/cache/gh-artifact-pr.<branch-slug>.json (the slug
# from .gaia/scripts/audit-key-lib.sh's gaia_key_slug). <main_root> is one
# checkout every worktree resolves to alike, so an unkeyed shared file would
# let two worktrees' concurrent `gh pr create` runs collide: the second write
# would destroy the first, and the read-side session/branch guard below would
# then correctly refuse the survivor's record and return nothing -- a lost
# breadcrumb, not a wrong one. Keying the filename by the same branch already
# threaded through gaia_gh_artifact_write/_read closes that gap: each tree's
# session reads back only the record its own branch wrote, and a second
# `gh pr create` on the SAME branch still overwrites in place (last writer
# wins within one branch, which is correct: one branch has one open PR).

# gaia_gh_artifact_cache_directory
# Echoes <main_root>/.gaia/local/cache, or nothing when the shared main-root
# resolver (.gaia/scripts/main-root-lib.sh) cannot resolve a main checkout.
# Honors $GAIA_GH_ARTIFACT_CACHE_DIRECTORY when set (test seam). Always returns 0.
gaia_gh_artifact_cache_directory() {
  if [[ -n "${GAIA_GH_ARTIFACT_CACHE_DIRECTORY:-}" ]]; then
    printf '%s' "$GAIA_GH_ARTIFACT_CACHE_DIRECTORY"
    return 0
  fi
  local script_directory main_root errexit_was
  script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Suspend errexit across the load, then RESTORE WHAT WAS THERE. A copy that is
  # present but unparseable abandons the shell AT the source, before the resolver
  # check below can degrade, and no caller can guard it from outside because
  # `bash -n` does not recurse into what a file sources. The restore is
  # conditional rather than a bare `set -e` because this library is sourced by
  # callers that deliberately run without errexit, and arming it in them kills
  # them at their next non-zero command.
  errexit_was=0
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck disable=SC1091
  source "$script_directory/main-root-lib.sh" 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi
  main_root="$(gaia_resolve_main_root)" || return 0
  printf '%s' "$main_root/.gaia/local/cache"
  return 0
}

# gaia_gh_artifact_path <cache_directory> <branch>
# Echoes "<cache_directory>/gh-artifact-pr.<gaia_key_slug branch>.json"; echoes
# nothing when EITHER <cache_directory> or <branch> is empty, or when the slug
# itself fails. Always returns 0.
# Sources .gaia/scripts/audit-key-lib.sh from beside itself via BASH_SOURCE,
# the same idiom gaia_gh_artifact_cache_directory above already uses for
# main-root-lib.sh.
#
# The branch is an explicit argument, never derived here: gaia_audit_key
# derives its own branch from a directory, but this function must not,
# because every caller already resolves a branch and passes it straight
# to gaia_gh_artifact_write / gaia_gh_artifact_read. A second internal
# derivation here could disagree with the one the caller passes, keying the
# FILENAME off one value while the body gets stamped with another -- a
# breadcrumb no reader could ever claim. One derivation per call site,
# threaded into all three functions, is the only shape in which writer and
# reader provably agree.
#
# Empty branch echoes nothing rather than falling back to an unkeyed shared
# path: the same fail-open rule this function already applies to an empty
# cache_directory extends verbatim to an empty branch, and it composes with
# gaia_gh_artifact_write's own refusal to write an unclaimable breadcrumb --
# a caller that cannot name its branch skips its write, it never invents a
# shared key.
gaia_gh_artifact_path() {
  local cache_directory="${1:-}" branch="${2:-}"
  [[ -z "$cache_directory" || -z "$branch" ]] && return 0
  local self_directory errexit_was
  self_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Same state-preserving bracket as gaia_gh_artifact_cache_directory above, and for the same reason.
  errexit_was=0
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck disable=SC1091
  source "$self_directory/audit-key-lib.sh" 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi

  # The slug is captured and checked, not interpolated into the printf: a
  # command substitution discards its own status, so a failing slug inside the
  # format arguments would print "gh-artifact-pr..json" -- the unkeyed shared
  # path this function's contract promises never to invent. A failing slug
  # takes the same empty-output exit as an empty cache_directory or branch, which
  # every caller already handles by skipping.
  local slug
  slug="$(gaia_key_slug "$branch")" || return 0
  printf '%s' "$cache_directory/gh-artifact-pr.$slug.json"
  return 0
}

# gaia_gh_artifact_parse_url <text>
# Scans <text> for the FIRST anchored GitHub pull-request URL
# (https://github.com/<owner>/<name>/pull/<n>, owner/name restricted to
# [A-Za-z0-9._-]+, n restricted to [0-9]+) and echoes compact JSON
# {"type":"pr","number":<int>,"repo":"<owner>/<name>"}. Echoes nothing when
# nothing matches. The input is attacker-influenceable (a repo or branch name
# can reach it via a hook that fires on every Bash call): never eval'd, never
# interpolated into a command or a jq PROGRAM, only ever into jq arguments.
# Always returns 0.
gaia_gh_artifact_parse_url() {
  local text="${1:-}"
  [[ -z "$text" ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local pull_request_url_pattern='https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([0-9]+)'
  if [[ "$text" =~ $pull_request_url_pattern ]]; then
    local owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
    local artifact_json
    artifact_json="$(jq -cn --arg repo "${owner}/${name}" --argjson number "$number" \
      '{type: "pr", number: $number, repo: $repo}' 2>/dev/null)" || artifact_json=""
    [[ -n "$artifact_json" ]] && printf '%s' "$artifact_json"
  fi
  return 0
}

# gaia_gh_artifact_write <path> <number> <repo> <branch> <session_id>
# Builds the breadcrumb JSON with jq --arg/--argjson, validates it, writes it.
# Refuses (non-zero, nothing written) on an empty branch or session_id (an
# unclaimable breadcrumb is worse than none), a non-positive-integer number,
# or a repo outside the safe class. Returns non-zero with a stderr diagnostic
# whenever nothing reached disk.
gaia_gh_artifact_write() {
  local breadcrumb_path="${1:-}" number="${2:-}" repo="${3:-}" branch="${4:-}" session_id="${5:-}"
  if [[ -z "$breadcrumb_path" ]]; then
    printf 'gaia_gh_artifact_write: no path given; nothing written\n' >&2
    return 1
  fi
  if [[ -z "$branch" ]]; then
    printf 'gaia_gh_artifact_write: empty branch; refusing to write an unclaimable breadcrumb\n' >&2
    return 1
  fi
  if [[ -z "$session_id" ]]; then
    printf 'gaia_gh_artifact_write: empty session_id; refusing to write an unclaimable breadcrumb\n' >&2
    return 1
  fi
  if ! [[ "$number" =~ ^[1-9][0-9]*$ ]]; then
    printf 'gaia_gh_artifact_write: number "%s" is not a positive integer; nothing written\n' "$number" >&2
    return 1
  fi
  if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    printf 'gaia_gh_artifact_write: repo "%s" is outside the safe class; nothing written\n' "$repo" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'gaia_gh_artifact_write: jq not found on PATH; breadcrumb %s not written\n' "$breadcrumb_path" >&2
    return 1
  fi
  local timestamp json
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  json="$(jq -n --argjson number "$number" --arg repo "$repo" --arg branch "$branch" \
      --arg session_id "$session_id" --arg timestamp "$timestamp" '
    {type: "pr", number: $number, repo: $repo, branch: $branch, session_id: $session_id, ts: $timestamp}
  ' 2>/dev/null)" || json=""
  if [[ -z "$json" ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json"; then
    printf 'gaia_gh_artifact_write: could not build a valid breadcrumb for %s; nothing written\n' "$breadcrumb_path" >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "$breadcrumb_path")" 2>/dev/null; then
    printf 'gaia_gh_artifact_write: cannot create parent directory for %s\n' "$breadcrumb_path" >&2
    return 1
  fi
  if ! printf '%s\n' "$json" >"$breadcrumb_path" 2>/dev/null; then
    printf 'gaia_gh_artifact_write: cannot write breadcrumb to %s\n' "$breadcrumb_path" >&2
    return 1
  fi
  return 0
}

# gaia_gh_artifact_read <path> <session_id> <branch> [ttl_seconds]
# Echoes {"type","number","repo"} (compact JSON) iff the file parses as an
# object whose session_id AND branch both equal the arguments AND whose ts is
# within ttl_seconds of now (default 86400; a ts more than 60s ahead of now is
# treated as unreadable clock skew). Echoes nothing otherwise. NEVER deletes
# the file. Always returns 0.
gaia_gh_artifact_read() {
  local breadcrumb_path="${1:-}" session_id="${2:-}" branch="${3:-}" ttl_seconds="${4:-}"
  [[ -n "$breadcrumb_path" && -f "$breadcrumb_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=86400
  local content
  content="$(cat "$breadcrumb_path" 2>/dev/null)" || return 0
  [[ -z "$content" ]] && return 0
  local artifact_json
  artifact_json="$(jq -r --arg session_id "$session_id" --arg branch "$branch" --argjson ttl_seconds "$ttl_seconds" '
    def to_epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    if type != "object" then empty
    elif (.session_id | type) != "string" then empty
    elif (.branch | type) != "string" then empty
    elif (.ts | type) != "string" then empty
    elif (.repo | type) != "string" then empty
    elif (.number | type) != "number" then empty
    elif .session_id != $session_id then empty
    elif .branch != $branch then empty
    else
      (try (.ts | to_epoch) catch null) as $epoch
      | (now) as $current_epoch
      | if $epoch == null then empty
        elif ($epoch - $current_epoch) > 60 then empty
        elif ($current_epoch - $epoch) > $ttl_seconds then empty
        else ({type: .type, number: .number, repo: .repo} | tojson)
        end
    end
  ' <<<"$content" 2>/dev/null)" || artifact_json=""
  [[ -n "$artifact_json" ]] && printf '%s' "$artifact_json"
  return 0
}
