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
# Both background jobs share one cap, GAIA_USAGE_MERGE_CAP_SECS (default 5).
# The flusher is never killed at the cap, because a kill could land mid-append;
# it is left to commit on its own and the block says `partial: flush
# incomplete`. Both jobs close descriptor 3 so a bats run that captures this
# script does not wait on the survivor. The `gh` read is killed at the cap and treated as unavailable.
# The ledger writes run with the lock timeout set to the seconds the cap has
# left (at least 1), so a held lock cannot stretch the merge past the cap by
# the mutex's own default wait.
#
# The render has its own cap, GAIA_USAGE_RENDER_CAP_SECS (default 10). The
# hook registration sets no timeout, so a render the host kills would take
# the roll-up printed after this block down with it. Measured on synthetic
# ledgers, a render over twelve months of heavy use takes about 3 to 4 s, so
# 10 s is headroom for a slower machine without letting a pathological ledger
# hold the merge. At the cap the render and its children are killed and one
# `! readout timed out` line replaces the block.
#
# Branch resolution, first answer wins: the read's headRefName; the `pr:<N>`
# edge recorded at `gh pr create` (through `usage.sh pr-branch`, never parsed
# here); the current branch when the command named no PR. Normalization and
# keying happen only inside usage.sh.
#
# Honest limits: the operand scan reads the first `gh pr merge` statement as
# raw text, stops at `;`, `&`, `|`, and a newline, and treats a repo flag, a
# wrapper, or a spelling it cannot read as no resolvable operand, which falls
# through to the resolution above. A repo flag naming another repository is
# not followed.
#
# GAIA_USAGE_HOOKS_DISABLE=1 makes this do nothing. It is a test seam for the
# suites that run the real merge hook and must not drive ledger writes.

_um_src="${BASH_SOURCE[0]:-$0}"
case "$_um_src" in */*) UM_DIR="${_um_src%/*}" ;; *) UM_DIR=. ;; esac

UM_WORK=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
_um_cleanup() { [ -z "$UM_WORK" ] || rm -rf "$UM_WORK" 2>/dev/null; }
trap '_um_cleanup; exit 0' EXIT
trap 'exit 0' INT TERM

[ "${GAIA_USAGE_HOOKS_DISABLE:-}" = 1 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=usage-lib.sh
. "$UM_DIR/usage-lib.sh" 2>/dev/null || exit 0
[ -f "$UM_DIR/usage.sh" ] || exit 0
UM_MAIN="$(gaia_usage_main_root)" || exit 0
[ -n "$UM_MAIN" ] || exit 0

payload="$(cat)"
cmd="$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null)" || exit 0
sid="$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null)" || sid=""
tpath="$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null)" || tpath=""

cap="${GAIA_USAGE_MERGE_CAP_SECS:-5}"
case "$cap" in '' | *[!0-9]* | 0) cap=5 ;; esac
rcap="${GAIA_USAGE_RENDER_CAP_SECS:-10}"
case "$rcap" in '' | *[!0-9]* | 0) rcap=10 ;; esac

# Sets UM_PR (a PR number), UM_GHARG (what to hand `gh pr view`), UM_NAMED
# (1 when the statement carried a positional argument, readable or not).
_um_parse_cmd() {
  local rx='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' rest tok skip=0 q="" last
  UM_PR="" UM_GHARG="" UM_NAMED=0
  [[ $cmd =~ $rx ]] || return 0
  rest="${cmd#*"${BASH_REMATCH[0]}"}"
  rest="${rest%%[;&|]*}"
  rest="${rest%%$'\n'*}"
  set -f
  # shellcheck disable=SC2086  # word splitting is the scan
  for tok in $rest; do
    if [ -n "$q" ]; then
      last="${tok: -1}"
      [ "$last" = "$q" ] && q=""
      continue
    fi
    if [ "$skip" = 1 ]; then
      skip=0
      case "$tok" in
        \"* | \'*)
          q="${tok:0:1}"
          if [ "${#tok}" -gt 1 ] && [ "${tok: -1}" = "$q" ]; then q=""; fi ;;
      esac
      continue
    fi
    case "$tok" in
      -b | --body | -F | --body-file | -t | --subject | -A | --author-email | --match-head-commit | -R | --repo) skip=1 ;;
      -*) ;;
      *)
        UM_NAMED=1
        case "$tok" in \"*\" | \'*\') tok="${tok:1:${#tok}-2}" ;; esac
        if [[ $tok =~ ^[1-9][0-9]{0,9}$ ]]; then
          UM_PR="$tok" UM_GHARG="$tok"
        elif [[ $tok =~ ^https?://[^[:space:]]+/pull/([1-9][0-9]{0,9})([/?#].*)?$ ]]; then
          UM_PR="${BASH_REMATCH[1]}" UM_GHARG="$tok"
        elif [[ $tok =~ ^[A-Za-z0-9._/:+@-]+$ ]]; then
          UM_GHARG="$tok"
        fi
        break ;;
    esac
  done
  set +f
}
_um_parse_cmd

UM_WORK="$(mktemp -d 2>/dev/null)" || exit 0
proj="$(gaia_usage_projects_root "$tpath")"
common=(--main-root "$UM_MAIN" --projects-root "$proj")

_um_now_s() { date +%s; }
_um_us() { local t="${EPOCHREALTIME-}"; t="${t//[.,]/}"; printf '%s' "$t"; }
start_s="$(_um_now_s)"
start_us="$(_um_us)"
ticks=0
# Bash 3.2 has no EPOCHREALTIME: there the deadline is a tick count, each tick
# at least one 0.1 s sleep, so the cap can overshoot by loop overhead but never
# undershoot.
_um_expired() {
  local c="${1:-$cap}"
  if [ -n "$start_us" ]; then
    [ "$(($(_um_us) - start_us))" -ge $((c * 1000000)) ]
  else
    ticks=$((ticks + 1))
    [ "$ticks" -ge $((c * 10)) ]
  fi
}
_um_left() {
  local left=$((cap - ($(_um_now_s) - start_s)))
  [ "$left" -ge 1 ] || left=1
  printf '%s' "$left"
}

fpid="" gpid=""
if gaia_usage_valid_ref "session:$sid"; then
  fargs=(--session "$sid" --finished-main --projects-root "$proj" --main-root "$UM_MAIN")
  [ -z "$tpath" ] || fargs+=(--transcript "$tpath")
  bash "$UM_DIR/usage-flush.sh" "${fargs[@]}" </dev/null >/dev/null 2>&1 3>&- &
  fpid=$!
fi
gfile="$UM_WORK/gh.json"
if command -v gh >/dev/null 2>&1; then
  if [ -n "$UM_GHARG" ]; then
    GH_PROMPT_DISABLED=1 gh pr view "$UM_GHARG" --json number,headRefName,state,mergedAt </dev/null >"$gfile" 2>/dev/null 3>&- &
  else
    GH_PROMPT_DISABLED=1 gh pr view --json number,headRefName,state,mergedAt </dev/null >"$gfile" 2>/dev/null 3>&- &
  fi
  gpid=$!
fi

while :; do
  alive=0
  if [ -n "$fpid" ] && kill -0 "$fpid" 2>/dev/null; then alive=1; fi
  if [ -n "$gpid" ] && kill -0 "$gpid" 2>/dev/null; then alive=1; fi
  [ "$alive" = 1 ] || break
  _um_expired && break
  sleep 0.1
done

partial=0
if [ -n "$fpid" ] && kill -0 "$fpid" 2>/dev/null; then partial=1; fi
gh_ok=0
if [ -n "$gpid" ]; then
  if kill -0 "$gpid" 2>/dev/null; then
    disown "$gpid" 2>/dev/null
    kill -TERM "$gpid" 2>/dev/null
    n=0
    while [ "$n" -lt 10 ] && kill -0 "$gpid" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    kill -KILL "$gpid" 2>/dev/null
  elif wait "$gpid" 2>/dev/null; then
    gh_ok=1
  fi
fi

g_num="" g_head="" g_state="" g_merged=""
if [ "$gh_ok" = 1 ] && [ -s "$gfile" ]; then
  IFS=$'\t' read -r g_num g_head g_state g_merged < <(jq -r '[(.number // "-" | tostring), (.headRefName // "-" | tostring),
      (.state // "-" | tostring), (.mergedAt // "-" | tostring)] | @tsv' "$gfile" 2>/dev/null)
  [ "$g_num" = - ] && g_num=""
  [ "$g_head" = - ] && g_head=""
  [ "$g_state" = - ] && g_state=""
  [ "$g_merged" = - ] && g_merged=""
  [[ $g_num =~ ^[1-9][0-9]{0,9}$ ]] || g_num=""
  [[ $g_merged =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] || g_merged=""
fi

pr="$UM_PR"
[ -n "$pr" ] || pr="$g_num"

branch="" key="" from_gh=0
if [ -n "$g_head" ]; then
  branch="$g_head" from_gh=1
elif [ -n "$pr" ]; then
  key="$(bash "$UM_DIR/usage.sh" pr-branch "$pr" "${common[@]}" </dev/null 2>/dev/null)" || key=""
  case "$key" in branch:*) ;; *) key="" ;; esac
fi
if [ -z "$branch" ] && [ -z "$key" ] && [ "$UM_NAMED" = 0 ]; then
  cur="$(git branch --show-current 2>/dev/null)" || cur=""
  if [ -n "$cur" ] && [ "$cur" != "$(gaia_usage_default_branch "$UM_MAIN")" ]; then branch="$cur"; fi
fi

bflag=()
if [ -n "$branch" ]; then bflag=(--branch "$branch"); elif [ -n "$key" ]; then bflag=(--key "$key"); fi

confirmed=0
if [ "$g_state" = MERGED ] && [ -n "$pr" ] && [ "${#bflag[@]}" -gt 0 ]; then
  mflag=()
  [ -z "$g_merged" ] || mflag=(--merged-at "$g_merged")
  if GAIA_LEDGER_LOCK_TIMEOUT_SECS="$(_um_left)" bash "$UM_DIR/usage.sh" link --merge "$pr" "${bflag[@]}" \
    ${mflag[@]+"${mflag[@]}"} --source gh-pr-merge </dev/null >/dev/null 2>&1; then
    confirmed=1
    if [ "$from_gh" = 1 ]; then
      GAIA_LEDGER_LOCK_TIMEOUT_SECS="$(_um_left)" bash "$UM_DIR/usage.sh" link --pr "$pr" --branch "$branch" \
        --source gh-pr-merge </dev/null >/dev/null 2>&1 || true
    fi
  fi
fi

if [ -z "$pr" ] && [ "${#bflag[@]}" -eq 0 ]; then
  printf '[PR cost] unresolved: no PR number or branch\n'
  exit 0
fi

# _um_tree <pid>: the pid and every descendant, parents first. Listed before
# any kill, because a killed parent hands its children to init and `pgrep -P`
# then no longer finds them. Without pgrep only the pid itself is listed.
_um_tree() {
  local c
  printf '%s\n' "$1"
  command -v pgrep >/dev/null 2>&1 || return 0
  for c in $(pgrep -P "$1" 2>/dev/null); do _um_tree "$c"; done
}

# render <pr or ""> [flags...]: sets `out` to what usage.sh printed; rc 1 when
# the render cap, shared by every render this run, ran out first.
render() {
  local -a a=(pr)
  local rf="$UM_WORK/render.out" rpid pids n
  [ -z "$1" ] || a+=("$1")
  shift
  out=""
  bash "$UM_DIR/usage.sh" "${a[@]}" "$@" "${common[@]}" </dev/null >"$rf" 2>/dev/null 3>&- &
  rpid=$!
  while kill -0 "$rpid" 2>/dev/null; do
    _um_expired "$rcap" && break
    sleep 0.1
  done
  if kill -0 "$rpid" 2>/dev/null; then
    pids="$(_um_tree "$rpid")"
    disown "$rpid" 2>/dev/null
    # shellcheck disable=SC2086  # one pid per word
    kill -TERM $pids 2>/dev/null
    n=0
    while [ "$n" -lt 10 ] && kill -0 "$rpid" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    # shellcheck disable=SC2086  # one pid per word
    kill -KILL $pids 2>/dev/null
    return 1
  fi
  wait "$rpid" 2>/dev/null
  out="$(cat "$rf")"
}
rargs=()
[ "${#bflag[@]}" -eq 0 ] || rargs=("${bflag[@]}")
if [ "$confirmed" = 1 ]; then
  [ -z "$g_merged" ] || rargs+=(--merged-at "$g_merged")
else
  rargs+=(--unconfirmed)
fi
[ "$partial" = 0 ] || rargs+=(--partial)
start_us="$(_um_us)"
ticks=0
timed_out=0
render "$pr" ${rargs[@]+"${rargs[@]}"} || timed_out=1
if [ "$timed_out" = 0 ] && [ -z "$out" ] && [ -n "$pr" ] && [ "${#bflag[@]}" -gt 0 ]; then
  fallback=(--unconfirmed)
  [ "$partial" = 0 ] || fallback+=(--partial)
  render "$pr" "${fallback[@]}" || timed_out=1
fi
if [ "$timed_out" = 1 ]; then
  if [ -n "$pr" ]; then
    printf '! readout timed out after %ss; rerun: bash .gaia/scripts/usage.sh pr %s\n' "$rcap" "$pr"
  else
    printf '! readout timed out after %ss; rerun: bash .gaia/scripts/usage.sh pr %s %s\n' "$rcap" "${bflag[0]}" "${bflag[1]}"
  fi
  exit 0
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit 0
