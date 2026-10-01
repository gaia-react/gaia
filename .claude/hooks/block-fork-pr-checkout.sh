#!/usr/bin/env bash
# PreToolUse Bash hook: deny bringing a fork pull request's head into this
# checkout. Arms on `gh pr checkout <n>` and on a `git fetch` whose refspec
# names `pull/<n>/head` (or `pull/<n>/merge`, which carries the same fork
# content), asks gh whether pull request <n> is cross-repository, and denies
# when it is, or when gh cannot answer.
#
# WHY BEFORE THE CHECKOUT. Every other fork refusal (the merge gate, the audit
# loop checkpoint) runs the hook copy in the working tree, and once a fork
# head is checked out that copy is the fork's: it can be edited to allow
# anything. This hook runs from the tree that is current before the checkout,
# which is still the maintainer's own, so it is the one fork control that
# acts before fork content lands. The check and the refusal message live in
# .claude/hooks/lib/cross-repo-refusal.sh.
#
# WHAT IT DOES NOT CATCH, stated so nobody relies on it for more:
#   - A head fetched by some other spelling: `git fetch <fork-url> <branch>`,
#     `git remote add` of the fork, `git pull`, a refspec assembled from a
#     variable. Only the forms above name the pull request this hook can ask
#     gh about.
#   - A pull request in another repository (`-R`/`--repo`, a `cd` into a
#     sibling checkout): gh is asked about the number in the repository of the
#     working directory. A `-R`/`--repo` checkout is denied outright for that
#     reason; a `cd` is not modelled.
# The fail direction for a `gh pr checkout` whose target is not a number or a
# pull-request URL is deny, with the by-number spelling named.
set -uo pipefail

input=$(cat)

# Every call this hook binds carries `checkout` (gh pr checkout) or `pull/`
# (the fetch refspec), so a payload holding neither word is outside its remit.
# This runs on every Bash call, so it decides that in bash alone, before any
# library load or jq spawn. `pull` rather than `pull/` because the payload is
# JSON, which may escape the slash.
case "$input" in
  *checkout* | *pull*) ;;
  *) exit 0 ;;
esac

# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literals below satisfy, live in .claude/hooks/lib/jq-availability.sh.
# A refspec spelled without `pull/` (assembled by the shell) is outside what
# the arming below reads anyway.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _lib_dir=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_lib_dir" ] && [ -f "$_lib_dir/jq-availability.sh" ] && . "$_lib_dir/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-fork-pr-checkout.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the fork pull request checkout guard' "$input" tool_input 'checkout' 'pull/'

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Empty for any tool but Bash, so one read covers both checks.
cmd=$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then .tool_input.command // "" else "" end' 2>/dev/null)
[ -n "$cmd" ] || exit 0

checkout_fragment='gh[[:space:]]+pr[[:space:]]+checkout([[:space:]]|$)'
fetch_fragment='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+fetch([[:space:]]|$)'
pull_ref_pattern='pull/[0-9]+/(head|merge)'

# Arming. With the shared decision loaded, a verb only cited in data (a heredoc
# body, a commit message) does not arm. Without it the raw match decides, which
# over-arms: a library that cannot load must deny an armed call rather than let
# it through, and the raw match is the widest reading available.
verb_arming_loaded=0
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/verb-arming.sh" ]; then
  # shellcheck source=lib/verb-arming.sh
  if . "$_lib_dir/verb-arming.sh" 2>/dev/null && type gaia_verb_armed >/dev/null 2>&1; then
    verb_arming_loaded=1
  fi
fi

checkout_armed=0
fetch_armed=0
if [ "$verb_arming_loaded" -eq 1 ]; then
  if gaia_verb_armed "$checkout_fragment" 'gh pr checkout' "$cmd"; then
    checkout_armed=1
  fi
  if gaia_verb_armed "$fetch_fragment" 'git fetch;git -C * fetch' "$cmd" && [[ "$cmd" =~ $pull_ref_pattern ]]; then
    fetch_armed=1
  fi
else
  [[ "$cmd" =~ $checkout_fragment ]] && checkout_armed=1
  [[ "$cmd" =~ $fetch_fragment ]] && [[ "$cmd" =~ $pull_ref_pattern ]] && fetch_armed=1
fi
[ "$checkout_armed" -eq 1 ] || [ "$fetch_armed" -eq 1 ] || exit 0

if [ "$verb_arming_loaded" -ne 1 ]; then
  deny "Fork pull request checkout guard: cannot load .claude/hooks/lib/verb-arming.sh, so it cannot tell whether this call checks out a pull request. It denies rather than let a fork's head into this checkout. Restore the library (it ships with the framework) and retry."
fi
cross_repo_loaded=0
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/cross-repo-refusal.sh" ]; then
  # shellcheck source=lib/cross-repo-refusal.sh
  if . "$_lib_dir/cross-repo-refusal.sh" 2>/dev/null && type gaia_cross_repo_deny_reason >/dev/null 2>&1; then
    cross_repo_loaded=1
  fi
fi
if [ "$cross_repo_loaded" -ne 1 ]; then
  deny "Fork pull request checkout guard: cannot load .claude/hooks/lib/cross-repo-refusal.sh, so it cannot tell whether this pull request comes from a fork. It denies rather than let a fork's head into this checkout. Restore the library (it ships with the framework) and retry."
fi

# Collect every pull request number the call names, one per line.
pr_numbers=''
unreadable_target=''

if [ "$checkout_armed" -eq 1 ]; then
  # Each `gh pr checkout` occurrence up to the next separator; its first
  # positional is the target. The flags that take a separated value are the
  # ones gh documents for this subcommand.
  while IFS= read -r occurrence; do
    [ -n "$occurrence" ] || continue
    set -f
    # shellcheck disable=SC2086 # word splitting is the tokenizer here
    set -- ${occurrence#gh*checkout}
    set +f
    target=''
    while [ "$#" -gt 0 ]; do
      token="${1//\"/}"
      token="${token//\'/}"
      shift
      case "$token" in
        -R | --repo | -R=* | --repo=* | -R?*)
          deny "Fork pull request checkout guard: this \`gh pr checkout\` names another repository (${token}), and this guard can only ask gh about pull requests in the repository of the working directory, so it denies. Check out that pull request from a clone of its own repository."
          ;;
        -b | --branch) [ "$#" -gt 0 ] && shift ;;
        -*) ;;
        *)
          target="$token"
          break
          ;;
      esac
    done
    case "$target" in
      '') unreadable_target='(none)' ;;
      \#*[!0-9]* | \#) unreadable_target="$target" ;;
      \#*) pr_numbers="${pr_numbers}${target#\#}"$'\n' ;;
      *[!0-9]*)
        if [[ "$target" =~ /pull/([0-9]+)(/|$|[?#]) ]]; then
          pr_numbers="${pr_numbers}${BASH_REMATCH[1]}"$'\n'
        else
          unreadable_target="$target"
        fi
        ;;
      *) pr_numbers="${pr_numbers}${target}"$'\n' ;;
    esac
  done <<EOF
$(printf '%s\n' "$cmd" | grep -oE 'gh[[:space:]]+pr[[:space:]]+checkout([[:space:]]+[^;&|]*)?')
EOF
fi

if [ "$fetch_armed" -eq 1 ]; then
  while IFS= read -r reference; do
    [ -n "$reference" ] || continue
    reference="${reference#pull/}"
    pr_numbers="${pr_numbers}${reference%%/*}"$'\n'
  done <<EOF
$(printf '%s\n' "$cmd" | grep -oE "$pull_ref_pattern")
EOF
fi

if [ -n "$unreadable_target" ]; then
  deny "Fork pull request checkout guard: cannot read which pull request this \`gh pr checkout\` targets (${unreadable_target}), so it cannot ask gh whether it comes from a fork, and it denies rather than guess. Name the pull request by number: \`gh pr checkout <number>\`."
fi

checked=' '
while IFS= read -r pr_number; do
  [ -n "$pr_number" ] || continue
  case "$checked" in *" $pr_number "*) continue ;; esac
  checked="${checked}${pr_number} "
  if fork_reason=$(gaia_cross_repo_deny_reason "$pr_number" '' \
    "Fork pull request checkout guard: pull request ${pr_number}. " \
    "Fork pull request checkout guard: cannot tell whether pull request ${pr_number}" \
    "so it denies rather than let a fork's head into this checkout. Check gh (gh auth status, the network) and retry."); then
    deny "$fork_reason"
  fi
done <<EOF
$pr_numbers
EOF

exit 0
