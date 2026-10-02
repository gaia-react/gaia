#!/usr/bin/env bash
# Per-PR cost block for a `gh pr merge` Bash call. token-rollup-merge.sh runs
# this with the PostToolUse payload on stdin and prints what it prints; it
# always exits 0 and prints nothing when it has nothing to say.
#
# One merge does three things: flush the merging session's transcript, read
# the PR once with `gh pr view` (the only confirmation a merge happened), and
# render `usage.sh pr`. The merge boundary is recorded as a `merge` row only
# when that read says MERGED, so a pending `--auto`, a refused merge, and a
# retry each leave the ledger exactly as a single clean merge would.
#
# Both background jobs share one cap, GAIA_USAGE_MERGE_CAP_SECONDS (default 5).
# The flusher is never killed at the cap, because a kill could land mid-append;
# it is left to commit on its own and the block says `partial: flush
# incomplete`. Both jobs close descriptor 3 so a bats run that captures this
# script does not wait on the survivor. The `gh` read is killed at the cap and treated as unavailable.
# The ledger writes run with the lock timeout set to the seconds the cap has
# left (at least 1), so a held lock cannot stretch the merge past the cap by
# the mutex's own default wait.
#
# The render has its own cap, GAIA_USAGE_RENDER_CAP_SECONDS (default 10). The
# hook registration sets no timeout, so a render the host kills would take
# the roll-up printed after this block down with it. Measured on synthetic
# ledgers, a warm render over twelve months of heavy use takes about 2 to 2.5 s, so
# 10 s is headroom for a slower machine without letting a pathological ledger
# hold the merge. At the cap the render and its children are killed and one
# `! readout timed out` line replaces the block.
#
# Branch resolution, first answer wins: the read's headRefName; the `pr:<N>`
# edge recorded at `gh pr create` (through `usage.sh pr-branch`, never parsed
# here); the current branch when the command named no PR. Normalization and
# keying happen only inside usage.sh.
#
# A merge aimed at another repository prints no per-PR block, reads nothing,
# and records nothing: the hook exits 0 before any `gh` call, flush, render,
# or ledger write, and never falls back to the current branch's pull request.
# Aimed at another repository means a repo flag (`-R`, `-Rvalue`, `--repo`,
# `--repo=`) anywhere in the text after the verb, including later lines, or a
# PR URL naming a repository other than the local origin's. A `--repo` value
# naming the local repository itself counts as foreign too, which fails toward
# no output. A flag inside quoted prose also counts, for the same reason.
# A URL is compared with the origin remote's owner/repo (https and ssh forms,
# no network); an absent or unparseable origin counts every URL as foreign.
#
# Operand shapes, for a merge aimed at this repository: no operand resolves
# the current branch's pull request through an operand-less `gh pr view`; a
# number or a same-repo URL is handed to `gh pr view` as given; a branch name
# is handed to `gh pr view` as given, which resolves the pull request whose
# head is that branch. Flag values (`--subject 45`, `-t 45`, `--body 45`,
# `--match-head-commit <sha>`, `--author-email x`) are skipped and never become
# the operand. A named operand the scan cannot read (a wrapper, a quote the
# statement cut off, an odd spelling) resolves nothing and prints the
# unresolved line; it never reads the current branch's pull request.
#
# Honest limits: the operand scan reads the first `gh pr merge` statement as
# raw text and stops at `;`, `&`, `|`, and a newline.
#
# GAIA_USAGE_HOOKS_DISABLE=1 makes this do nothing. It is a test seam for the
# suites that run the real merge hook and must not drive ledger writes.

_um_script_path="${BASH_SOURCE[0]:-$0}"
case "$_um_script_path" in */*) UM_SCRIPT_DIRECTORY="${_um_script_path%/*}" ;; *) UM_SCRIPT_DIRECTORY=. ;; esac

UM_WORK=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
_um_cleanup() { [ -z "$UM_WORK" ] || rm -rf "$UM_WORK" 2>/dev/null; }
trap '_um_cleanup; exit 0' EXIT
trap 'exit 0' INT TERM

[ "${GAIA_USAGE_HOOKS_DISABLE:-}" = 1 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=usage-lib.sh
. "$UM_SCRIPT_DIRECTORY/usage-lib.sh" 2>/dev/null || exit 0
[ -f "$UM_SCRIPT_DIRECTORY/usage.sh" ] || exit 0
UM_MAIN="$(gaia_usage_main_root)" || exit 0
[ -n "$UM_MAIN" ] || exit 0

payload="$(cat)"
tool_command="$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null)" || exit 0
session_id="$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null)" || session_id=""
transcript_path="$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null)" || transcript_path=""

cap="${GAIA_USAGE_MERGE_CAP_SECONDS:-5}"
case "$cap" in '' | *[!0-9]* | 0) cap=5 ;; esac
render_cap="${GAIA_USAGE_RENDER_CAP_SECONDS:-10}"
case "$render_cap" in '' | *[!0-9]* | 0) render_cap=10 ;; esac

# Prints the lowercased owner/repo of the origin remote, nothing when it is
# absent or unparseable. Reads git config only.
_um_origin_slug() {
  local remote_url owner repository_name
  remote_url="$(git -C "$UM_MAIN" remote get-url origin 2>/dev/null)" || return 0
  remote_url="${remote_url%/}"
  remote_url="${remote_url%.git}"
  case "$remote_url" in *[:/]*/* | *:*/*) ;; *) return 0 ;; esac
  repository_name="${remote_url##*[:/]}"
  owner="${remote_url%[:/]*}"
  owner="${owner##*[:/]}"
  [ -n "$owner" ] && [ -n "$repository_name" ] || return 0
  printf '%s/%s' "$owner" "$repository_name" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# Sets UM_PR (a PR number), UM_GH_ARGUMENT (what to hand `gh pr view`), UM_NAMED
# (1 when the statement carried a positional argument, readable or not, or the
# scan was cut inside a quoted value), and UM_FOREIGN (1 when the merge is aimed
# at another repository: a repo flag anywhere in the text after the verb, or a
# URL for a repository other than origin). A foreign merge is terminal for the
# caller, which exits before reading anything.
_um_parse_command() {
  local merge_command_regex='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' rest token skip=0 open_quote="" last slug origin full
  UM_PR="" UM_GH_ARGUMENT="" UM_NAMED=0 UM_FOREIGN=0
  [[ $tool_command =~ $merge_command_regex ]] || return 0
  full="${tool_command#*"${BASH_REMATCH[0]}"}"
  rest="${full%%[;&|]*}"
  rest="${rest%%$'\n'*}"
  set -f
  # shellcheck disable=SC2086  # word splitting is the scan
  for token in $rest; do
    if [ -n "$open_quote" ]; then
      last="${token: -1}"
      [ "$last" = "$open_quote" ] && open_quote=""
      continue
    fi
    if [ "$skip" = 1 ]; then
      skip=0
      case "$token" in
        \"* | \'*)
          open_quote="${token:0:1}"
          if [ "${#token}" -gt 1 ] && [ "${token: -1}" = "$open_quote" ]; then open_quote=""; fi ;;
      esac
      continue
    fi
    case "$token" in
      -b | --body | -F | --body-file | -t | --subject | -A | --author-email | --match-head-commit | -R | --repo) skip=1 ;;
      -*) ;;
      *)
        UM_NAMED=1
        case "$token" in \"*\" | \'*\') token="${token:1:${#token}-2}" ;; esac
        if [[ $token =~ ^[1-9][0-9]{0,9}$ ]]; then
          UM_PR="$token" UM_GH_ARGUMENT="$token"
        elif [[ $token =~ ^https?://[^[:space:]]+/pull/([1-9][0-9]{0,9})([/?#].*)?$ ]]; then
          UM_PR="${BASH_REMATCH[1]}" UM_GH_ARGUMENT="$token"
          if [[ $token =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/ ]]; then
            slug="$(printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
            origin="$(_um_origin_slug)"
            [ -n "$origin" ] && [ "$slug" = "$origin" ] || UM_FOREIGN=1
          else
            UM_FOREIGN=1
          fi
        elif [[ $token =~ ^[A-Za-z0-9._/:+@-]+$ ]]; then
          UM_GH_ARGUMENT="$token"
        fi
        break ;;
    esac
  done
  set +f
  # A quote the statement cut off hides the rest of the operands.
  [ -z "$open_quote" ] || UM_NAMED=1
  local repo_flag_regex='(^|[[:space:]])(-R|--repo)'
  if [[ $full =~ $repo_flag_regex ]]; then UM_FOREIGN=1; fi
  if [ "$UM_FOREIGN" = 1 ]; then UM_PR="" UM_GH_ARGUMENT=""; fi
}
_um_parse_command
[ "$UM_FOREIGN" = 1 ] && exit 0

UM_WORK="$(mktemp -d 2>/dev/null)" || exit 0
projects_directory="$(gaia_usage_projects_root "$transcript_path")"
common=(--main-root "$UM_MAIN" --projects-root "$projects_directory")

_um_now_seconds() { date +%s; }
_um_now_microseconds() { local microseconds="${EPOCHREALTIME-}"; microseconds="${microseconds//[.,]/}"; printf '%s' "$microseconds"; }
start_seconds="$(_um_now_seconds)"
start_microseconds="$(_um_now_microseconds)"
ticks=0
# Bash 3.2 has no EPOCHREALTIME: there the deadline is a tick count, each tick
# at least one 0.1 s sleep, so the cap can overshoot by loop overhead but never
# undershoot.
_um_expired() {
  local cap_seconds="${1:-$cap}"
  if [ -n "$start_microseconds" ]; then
    [ "$(($(_um_now_microseconds) - start_microseconds))" -ge $((cap_seconds * 1000000)) ]
  else
    ticks=$((ticks + 1))
    [ "$ticks" -ge $((cap_seconds * 10)) ]
  fi
}
_um_left() {
  local left=$((cap - ($(_um_now_seconds) - start_seconds)))
  [ "$left" -ge 1 ] || left=1
  printf '%s' "$left"
}

flush_pid="" gh_pid=""
if gaia_usage_valid_reference "session:$session_id"; then
  flush_arguments=(--session "$session_id" --finished-main --projects-root "$projects_directory" --main-root "$UM_MAIN")
  [ -z "$transcript_path" ] || flush_arguments+=(--transcript "$transcript_path")
  bash "$UM_SCRIPT_DIRECTORY/usage-flush.sh" "${flush_arguments[@]}" </dev/null >/dev/null 2>&1 3>&- &
  flush_pid=$!
fi
gh_view_file="$UM_WORK/gh.json"
if command -v gh >/dev/null 2>&1; then
  if [ -n "$UM_GH_ARGUMENT" ]; then
    GH_PROMPT_DISABLED=1 gh pr view "$UM_GH_ARGUMENT" --json number,headRefName,state,mergedAt </dev/null >"$gh_view_file" 2>/dev/null 3>&- &
    gh_pid=$!
  elif [ "$UM_NAMED" = 0 ]; then
    GH_PROMPT_DISABLED=1 gh pr view --json number,headRefName,state,mergedAt </dev/null >"$gh_view_file" 2>/dev/null 3>&- &
    gh_pid=$!
  fi
fi

while :; do
  alive=0
  if [ -n "$flush_pid" ] && kill -0 "$flush_pid" 2>/dev/null; then alive=1; fi
  if [ -n "$gh_pid" ] && kill -0 "$gh_pid" 2>/dev/null; then alive=1; fi
  [ "$alive" = 1 ] || break
  _um_expired && break
  sleep 0.1
done

partial=0
if [ -n "$flush_pid" ] && kill -0 "$flush_pid" 2>/dev/null; then partial=1; fi
gh_ok=0
if [ -n "$gh_pid" ]; then
  if kill -0 "$gh_pid" 2>/dev/null; then
    disown "$gh_pid" 2>/dev/null
    kill -TERM "$gh_pid" 2>/dev/null
    wait_ticks=0
    while [ "$wait_ticks" -lt 10 ] && kill -0 "$gh_pid" 2>/dev/null; do sleep 0.1; wait_ticks=$((wait_ticks + 1)); done
    kill -KILL "$gh_pid" 2>/dev/null
  elif wait "$gh_pid" 2>/dev/null; then
    gh_ok=1
  fi
fi

gh_number="" gh_head_branch="" gh_state="" gh_merged_at=""
if [ "$gh_ok" = 1 ] && [ -s "$gh_view_file" ]; then
  IFS=$'\t' read -r gh_number gh_head_branch gh_state gh_merged_at < <(jq -r '[(.number // "-" | tostring), (.headRefName // "-" | tostring),
      (.state // "-" | tostring), (.mergedAt // "-" | tostring)] | @tsv' "$gh_view_file" 2>/dev/null)
  [ "$gh_number" = - ] && gh_number=""
  [ "$gh_head_branch" = - ] && gh_head_branch=""
  [ "$gh_state" = - ] && gh_state=""
  [ "$gh_merged_at" = - ] && gh_merged_at=""
  [[ $gh_number =~ ^[1-9][0-9]{0,9}$ ]] || gh_number=""
  [[ $gh_merged_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] || gh_merged_at=""
fi

pr="$UM_PR"
[ -n "$pr" ] || pr="$gh_number"

branch="" key="" from_gh=0
if [ -n "$gh_head_branch" ]; then
  branch="$gh_head_branch" from_gh=1
elif [ -n "$pr" ]; then
  key="$(bash "$UM_SCRIPT_DIRECTORY/usage.sh" pr-branch "$pr" "${common[@]}" </dev/null 2>/dev/null)" || key=""
  case "$key" in branch:*) ;; *) key="" ;; esac
fi
if [ -z "$branch" ] && [ -z "$key" ] && [ "$UM_NAMED" = 0 ]; then
  current_branch="$(git branch --show-current 2>/dev/null)" || current_branch=""
  if [ -n "$current_branch" ] && [ "$current_branch" != "$(gaia_usage_default_branch "$UM_MAIN")" ]; then branch="$current_branch"; fi
fi

branch_flags=()
if [ -n "$branch" ]; then branch_flags=(--branch "$branch"); elif [ -n "$key" ]; then branch_flags=(--key "$key"); fi

confirmed=0
if [ "$gh_state" = MERGED ] && [ -n "$pr" ] && [ "${#branch_flags[@]}" -gt 0 ]; then
  merged_at_flags=()
  [ -z "$gh_merged_at" ] || merged_at_flags=(--merged-at "$gh_merged_at")
  if GAIA_LEDGER_LOCK_TIMEOUT_SECONDS="$(_um_left)" bash "$UM_SCRIPT_DIRECTORY/usage.sh" link --merge "$pr" "${branch_flags[@]}" \
    ${merged_at_flags[@]+"${merged_at_flags[@]}"} --source gh-pr-merge </dev/null >/dev/null 2>&1; then
    confirmed=1
    if [ "$from_gh" = 1 ]; then
      GAIA_LEDGER_LOCK_TIMEOUT_SECONDS="$(_um_left)" bash "$UM_SCRIPT_DIRECTORY/usage.sh" link --pr "$pr" --branch "$branch" \
        --source gh-pr-merge </dev/null >/dev/null 2>&1 || true
    fi
  fi
fi

if [ -z "$pr" ] && [ "${#branch_flags[@]}" -eq 0 ]; then
  printf '[PR cost] unresolved: no PR number or branch\n'
  exit 0
fi

# _um_tree <pid>: the pid and every descendant, parents first. Listed before
# any kill, because a killed parent hands its children to init and `pgrep -P`
# then no longer finds them. Without pgrep only the pid itself is listed.
_um_tree() {
  local child_pid
  printf '%s\n' "$1"
  command -v pgrep >/dev/null 2>&1 || return 0
  for child_pid in $(pgrep -P "$1" 2>/dev/null); do _um_tree "$child_pid"; done
}

# render <pr or ""> [flags...]: sets `render_output` to what usage.sh printed; rc 1 when
# the render cap, shared by every render this run, ran out first.
render() {
  local -a usage_arguments=(pr)
  local render_file="$UM_WORK/render.out" render_pid pids wait_ticks
  [ -z "$1" ] || usage_arguments+=("$1")
  shift
  render_output=""
  bash "$UM_SCRIPT_DIRECTORY/usage.sh" "${usage_arguments[@]}" "$@" "${common[@]}" </dev/null >"$render_file" 2>/dev/null 3>&- &
  render_pid=$!
  while kill -0 "$render_pid" 2>/dev/null; do
    _um_expired "$render_cap" && break
    sleep 0.1
  done
  if kill -0 "$render_pid" 2>/dev/null; then
    pids="$(_um_tree "$render_pid")"
    disown "$render_pid" 2>/dev/null
    # shellcheck disable=SC2086  # one pid per word
    kill -TERM $pids 2>/dev/null
    wait_ticks=0
    while [ "$wait_ticks" -lt 10 ] && kill -0 "$render_pid" 2>/dev/null; do sleep 0.1; wait_ticks=$((wait_ticks + 1)); done
    # shellcheck disable=SC2086  # one pid per word
    kill -KILL $pids 2>/dev/null
    return 1
  fi
  wait "$render_pid" 2>/dev/null
  render_output="$(cat "$render_file")"
}
render_arguments=()
[ "${#branch_flags[@]}" -eq 0 ] || render_arguments=("${branch_flags[@]}")
if [ "$confirmed" = 1 ]; then
  [ -z "$gh_merged_at" ] || render_arguments+=(--merged-at "$gh_merged_at")
else
  render_arguments+=(--unconfirmed)
fi
[ "$partial" = 0 ] || render_arguments+=(--partial)
start_microseconds="$(_um_now_microseconds)"
ticks=0
timed_out=0
render "$pr" ${render_arguments[@]+"${render_arguments[@]}"} || timed_out=1
if [ "$timed_out" = 0 ] && [ -z "$render_output" ] && [ -n "$pr" ] && [ "${#branch_flags[@]}" -gt 0 ]; then
  fallback=(--unconfirmed)
  [ "$partial" = 0 ] || fallback+=(--partial)
  render "$pr" "${fallback[@]}" || timed_out=1
fi
if [ "$timed_out" = 1 ]; then
  if [ -n "$pr" ]; then
    printf '! readout timed out after %ss; rerun: bash .gaia/scripts/usage.sh pr %s\n' "$render_cap" "$pr"
  else
    # The branch name is chosen by whoever opened the PR and this line is a
    # runnable command: print the grammar-checked key, else a shell-inert
    # name, else a placeholder.
    rerun_key="$key"
    if [ -z "$rerun_key" ] && [ -n "$branch" ] && _gaia_usage_load gaia_branch_normalize branch-name-lib.sh 2>/dev/null; then
      rerun_branch="$(gaia_branch_normalize "$branch" 2>/dev/null)" || rerun_branch=""
      [ -z "$rerun_branch" ] || rerun_key="$(gaia_usage_branch_key "$rerun_branch" 2>/dev/null)" || rerun_key=""
    fi
    if [[ $rerun_key =~ ^branch:(%[0-9a-f]{16}|[A-Za-z0-9._/-]{1,128})$ ]]; then rerun_flags="--key $rerun_key"
    elif [[ $branch =~ ^[A-Za-z0-9._/+-]+$ && $branch != -* ]]; then rerun_flags="--branch $branch"
    else rerun_flags="--branch <branch>"; fi
    printf '! readout timed out after %ss; rerun: bash .gaia/scripts/usage.sh pr %s\n' "$render_cap" "$rerun_flags"
  fi
  exit 0
fi
[ -z "$render_output" ] || printf '%s\n' "$render_output"
exit 0
