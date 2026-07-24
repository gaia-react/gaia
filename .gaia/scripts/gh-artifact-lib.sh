# shellcheck shell=bash
# Shared breadcrumb lib for the GitHub pull-request artifact a run produced.
#
# Sourced by two producers that must agree on one on-disk shape:
# .claude/hooks/capture-gh-artifact.sh (the sole writer, fires when
# `gh pr create` succeeds) and token-tally.sh's `--action execute` path (the
# sole reader, never deletes). Every other cost record, the five prose
# maintenance commands and the /gaia-wiki chain, binds its artifact by direct
# pass-through instead: the agent reads the URL `gh pr create` printed into
# its own tool result and hands the number straight to the tally, because
# those runs check out and delete their working branch before the run ends,
# so a branch-keyed breadcrumb could never be reclaimed at that point. Only
# plan execution has no agent in the loop (its rows come from a PreToolUse
# hook on `git commit` / `git push`), so it alone reads this breadcrumb.
#
# No side effects at source time; this file defines functions only. Every
# function below returns 0 and degrades to nothing on failure, never
# blocking a caller, never fabricating a value, except gaia_gh_artifact_write,
# which PROPAGATES failure (non-zero when nothing reached disk) so a lost
# breadcrumb is detectable. Mirrors .gaia/scripts/audit-window-lib.sh.
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

# gaia_gh_artifact_cache_dir
# Echoes <main_root>/.gaia/local/cache, or nothing when the shared main-root
# resolver (.gaia/scripts/main-root-lib.sh) cannot resolve a main checkout.
# Honors $GAIA_GH_ARTIFACT_CACHE_DIR when set (test seam). Always returns 0.
gaia_gh_artifact_cache_dir() {
  if [[ -n "${GAIA_GH_ARTIFACT_CACHE_DIR:-}" ]]; then
    printf '%s' "$GAIA_GH_ARTIFACT_CACHE_DIR"
    return 0
  fi
  local script_dir main_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$script_dir/main-root-lib.sh"
  main_root="$(gaia_resolve_main_root)" || return 0
  printf '%s' "$main_root/.gaia/local/cache"
  return 0
}

# gaia_gh_artifact_path <cache_dir> <branch>
# Echoes "<cache_dir>/gh-artifact-pr.<gaia_key_slug branch>.json"; echoes
# nothing when EITHER <cache_dir> or <branch> is empty. Always returns 0.
# Sources .gaia/scripts/audit-key-lib.sh from beside itself via BASH_SOURCE,
# the same idiom gaia_gh_artifact_cache_dir above already uses for
# main-root-lib.sh.
#
# The branch is an explicit argument, never derived here: gaia_audit_key
# derives its own branch from a directory, but this function must not,
# because both of its callers already resolve a branch and pass it straight
# to gaia_gh_artifact_write / gaia_gh_artifact_read. A second internal
# derivation here could disagree with the one the caller passes, keying the
# FILENAME off one value while the body gets stamped with another -- a
# breadcrumb no reader could ever claim. One derivation per call site,
# threaded into all three functions, is the only shape in which writer and
# reader provably agree.
#
# Empty branch echoes nothing rather than falling back to an unkeyed shared
# path: the same fail-open rule this function already applies to an empty
# cache_dir extends verbatim to an empty branch, and it composes with
# gaia_gh_artifact_write's own refusal to write an unclaimable breadcrumb --
# a caller that cannot name its branch skips its write, it never invents a
# shared key.
gaia_gh_artifact_path() {
  local cache_dir="${1:-}" branch="${2:-}"
  [[ -z "$cache_dir" || -z "$branch" ]] && return 0
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$self_dir/audit-key-lib.sh"
  printf '%s' "$cache_dir/gh-artifact-pr.$(gaia_key_slug "$branch").json"
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
  local re='https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([0-9]+)'
  if [[ "$text" =~ $re ]]; then
    local owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
    local out
    out="$(jq -cn --arg repo "${owner}/${name}" --argjson number "$number" \
      '{type: "pr", number: $number, repo: $repo}' 2>/dev/null)" || out=""
    [[ -n "$out" ]] && printf '%s' "$out"
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
  local bc_path="${1:-}" number="${2:-}" repo="${3:-}" branch="${4:-}" session_id="${5:-}"
  if [[ -z "$bc_path" ]]; then
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
    printf 'gaia_gh_artifact_write: jq not found on PATH; breadcrumb %s not written\n' "$bc_path" >&2
    return 1
  fi
  local ts json
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  json="$(jq -n --argjson number "$number" --arg repo "$repo" --arg branch "$branch" \
      --arg session_id "$session_id" --arg ts "$ts" '
    {type: "pr", number: $number, repo: $repo, branch: $branch, session_id: $session_id, ts: $ts}
  ' 2>/dev/null)" || json=""
  if [[ -z "$json" ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json"; then
    printf 'gaia_gh_artifact_write: could not build a valid breadcrumb for %s; nothing written\n' "$bc_path" >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "$bc_path")" 2>/dev/null; then
    printf 'gaia_gh_artifact_write: cannot create parent directory for %s\n' "$bc_path" >&2
    return 1
  fi
  if ! printf '%s\n' "$json" >"$bc_path" 2>/dev/null; then
    printf 'gaia_gh_artifact_write: cannot write breadcrumb to %s\n' "$bc_path" >&2
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
  local bc_path="${1:-}" session_id="${2:-}" branch="${3:-}" ttl_seconds="${4:-}"
  [[ -n "$bc_path" && -f "$bc_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=86400
  local content
  content="$(cat "$bc_path" 2>/dev/null)" || return 0
  [[ -z "$content" ]] && return 0
  local out
  out="$(jq -r --arg sid "$session_id" --arg br "$branch" --argjson ttl "$ttl_seconds" '
    def toe: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    if type != "object" then empty
    elif (.session_id | type) != "string" then empty
    elif (.branch | type) != "string" then empty
    elif (.ts | type) != "string" then empty
    elif (.repo | type) != "string" then empty
    elif (.number | type) != "number" then empty
    elif .session_id != $sid then empty
    elif .branch != $br then empty
    else
      (try (.ts | toe) catch null) as $epoch
      | (now) as $n
      | if $epoch == null then empty
        elif ($epoch - $n) > 60 then empty
        elif ($n - $epoch) > $ttl then empty
        else ({type: .type, number: .number, repo: .repo} | tojson)
        end
    end
  ' <<<"$content" 2>/dev/null)" || out=""
  [[ -n "$out" ]] && printf '%s' "$out"
  return 0
}
