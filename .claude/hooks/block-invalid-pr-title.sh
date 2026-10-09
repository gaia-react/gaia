#!/usr/bin/env bash
#
# PreToolUse Bash hook: deny a `gh pr create` or `gh pr edit` whose `--title`
# would fail the PR Conventions title check in CI.
#
# Exit 2 = block the tool call; stderr is shown to Claude as the reason.
#
# WHY THE TITLE NEEDS ITS OWN CHECK. `.github/workflows/pr-conventions.yml`
# lints `"<title> (#<number>)"`, the subject a squash merge lands on main, so
# the 100-character header limit applies to the title PLUS its ` (#N)` suffix.
# Every other check Claude meets applies the limit to the bare text: the
# commit-msg hook passes a 99-character subject, and the merge workflow
# prescribes `gh pr create --draft --title "<commit subject>"`. A title that cleared
# every local check then failed CI after the PR was already open.
#
# WHAT IT RUNS. The same commitlint, against the same config, on the same
# string CI builds, so this hook holds no copy of the limit or the type list.
# The number is the real one for `gh pr edit <N>`. For a create it is one past
# the highest `(#N)` in recent history on HEAD, which matches the digit count
# the new PR will carry; with no such subject it is 99999, the conservative
# direction. A ~0.6s node start, paid only on a `gh pr create` or `gh pr edit`
# that carries a title.
#
# WHAT IT READS. Each top-level command of the tool call (split on list
# operators and newlines), through the shared shell-word scanner
# (`gaia_scan_first_command`), so `git push ... && gh pr create --title "..."`
# is read, and a `;` or a quote inside the title stays title text. Heredoc bodies the arming walk proves are data are masked first.
# Title spellings: `--title <v>`, `--title=<v>`, `-t <v>`; the last one wins,
# as in gh.
#
# WHAT IT LEAVES TO CI, allowing rather than guessing:
#   - a title carrying `$` or a backtick, whose value only the shell knows;
#   - `--repo` / `-R`, a PR in another repository, under that repository's rules;
#   - a `gh pr create|edit` nested inside a command or process substitution, a
#     subshell, or a compound-command body (`if`, `while`, `{ }`), which the
#     top-level read does not enter;
#   - no commitlint installed (`pnpm install` not run), or an unloadable
#     hook library;
#   - a commitlint that cannot run (node missing from the hook's PATH, a config
#     that fails to load): only output carrying commitlint's own problem report
#     denies, so any other non-zero exit is an internal error, not a bad title.
#
# `--fill`, `--fill-first`, `--fill-verbose` and `-f` with no `--title` are
# DENIED: gh derives that title from commits or the branch name, which this hook
# cannot see, and the repair (pass `--title`) costs nothing.

payload=$(cat)

# jq-availability arm, narrowed by the `gh pr` literal so the command that
# installs jq is never caught: .claude/hooks/lib/jq-availability.sh.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-invalid-pr-title.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the PR title guard' "$payload" tool_input 'gh pr'

# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: block-invalid-pr-title.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_hook_payload_read "$payload" || exit 0

tool_name=$GAIA_HOOK_TOOL_NAME
[ "$tool_name" = "Bash" ] || exit 0
command_text=$GAIA_HOOK_COMMAND
[ -n "$command_text" ] || exit 0

_hook_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || exit 0
repository_root="$(cd "$_hook_library_directory/../../.." 2>/dev/null && pwd)" || exit 0
# shellcheck source=/dev/null
"${BASH:-bash}" -n "$_hook_library_directory/verb-arming.sh" 2>/dev/null && . "$_hook_library_directory/verb-arming.sh" 2>/dev/null
type gaia_verb_armed >/dev/null 2>&1 || exit 0

verb_pattern='gh[[:space:]]+pr[[:space:]]+(create|edit)([[:space:]]|$)'
if gaia_verb_armed "$verb_pattern" 'gh pr create;gh pr edit' "$command_text"; then
  :
else
  exit 0
fi

commitlint_binary="$repository_root/node_modules/.bin/commitlint"
[ -x "$commitlint_binary" ] || exit 0

# The scanner lives in repo-scope.sh, which verb-arming.sh loads lazily; load
# it here in case the arming decision never needed it.
if ! type gaia_scan_first_command >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  "${BASH:-bash}" -n "$_hook_library_directory/repo-scope.sh" 2>/dev/null && . "$_hook_library_directory/repo-scope.sh" 2>/dev/null
  type gaia_scan_first_command >/dev/null 2>&1 || exit 0
fi

# The data-masked view keeps byte offsets, so it scans like the original.
scan_text="$command_text"
case "${GAIA_VERB_ARM_KIND:-}" in
  start | sep) [ -n "${GAIA_VERB_ARM_VIEW:-}" ] && scan_text="$GAIA_VERB_ARM_VIEW" ;;
esac

# One past the highest `(#N)` squash suffix in recent history on HEAD.
estimate_next_pr_number() {
  local highest
  highest=$(git -C "$repository_root" log -200 --format=%s HEAD 2>/dev/null |
    sed -n 's/.*(#\([0-9][0-9]*\))$/\1/p' | sort -n | tail -1)
  if [ -n "$highest" ]; then
    printf '%s\n' "$((highest + 1))"
  else
    printf '99999\n'
  fi
}

# Reads GAIA_FIRST_COMMAND_WORDS for one `gh pr create|edit` command and sets
# title, title_found, fill_used, foreign_repository, pr_number.
read_pr_command() {
  local index=3 word_count="${#GAIA_FIRST_COMMAND_WORDS[@]}" word
  title=""
  title_found=0
  fill_used=0
  foreign_repository=0
  pr_number=""
  while [ "$index" -lt "$word_count" ]; do
    word="${GAIA_FIRST_COMMAND_WORDS[$index]}"
    case "$word" in
      --title | -t)
        index=$((index + 1))
        title="${GAIA_FIRST_COMMAND_WORDS[$index]:-}"
        title_found=1
        ;;
      --title=*)
        title="${word#--title=}"
        title_found=1
        ;;
      --fill | --fill-first | --fill-verbose | -f) fill_used=1 ;;
      --repo | -R | --repo=* | -R?*) foreign_repository=1 ;;
      *)
        if [ -z "$pr_number" ] && [ "$operation" = edit ]; then
          case "$word" in
            '#'[0-9]*) pr_number="${word#\#}" ;;
            [0-9]*) pr_number="$word" ;;
            https://*/pull/[0-9]*) pr_number="${word##*/pull/}" ;;
          esac
          case "$pr_number" in *[!0-9]*) pr_number="" ;; esac
        fi
        ;;
    esac
    index=$((index + 1))
  done
}

deny_fill() {
  cat >&2 <<'EOF'
BLOCKED: `gh pr create --fill` without `--title` lets gh pick the title from commits or the branch name, and that title is never checked before CI's PR Conventions lint.

Pass the title explicitly: `gh pr create --draft --title "<type>(<scope>): <summary>" ...`. CI lints "<title> (#<number>)" against the 100-character header limit, so keep the title at least 8 characters under it.
EOF
  exit 2
}

deny_title() {
  local subject="$1" lint_output="$2"
  {
    printf 'BLOCKED: this PR title fails the commitlint check CI runs on "<title> (#<number>)", the subject a squash merge lands on main.\n\n'
    printf 'Checked as: %s\n\n%s\n\n' "$subject" "$lint_output"
    printf 'The " (#N)" suffix counts toward the header limit, so a title that fits as a commit subject can still fail here. Shorten the title (or fix its type) and run the command again.\n'
  } >&2
  exit 2
}

newline=$'\n'
offset=0
scan_guard=0
# The scan returns 1 for a command holding no words (a bare comment line), so
# the walk continues on its status and stops only when the offset stops
# advancing. 64 commands bounds a pathological input.
while [ "$scan_guard" -lt 64 ] && [ "$offset" -lt "${#scan_text}" ]; do
  scan_guard=$((scan_guard + 1))
  GAIA_FIRST_COMMAND_WORDS=()
  gaia_scan_first_command "$scan_text" "$offset" || true
  next_offset="$GAIA_FIRST_COMMAND_END"
  if [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -ge 3 ] &&
    [ "${GAIA_FIRST_COMMAND_WORDS[0]}" = gh ] &&
    [ "${GAIA_FIRST_COMMAND_WORDS[1]}" = pr ]; then
    operation="${GAIA_FIRST_COMMAND_WORDS[2]}"
    if [ "$operation" = create ] || [ "$operation" = edit ]; then
      read_pr_command
      if [ "$foreign_repository" = 0 ]; then
        if [ "$title_found" = 0 ]; then
          [ "$operation" = create ] && [ "$fill_used" = 1 ] && deny_fill
        else
          case "$title" in
            *'$'* | *'`'*) ;;
            *)
              [ -n "$pr_number" ] || pr_number="$(estimate_next_pr_number)"
              subject="$title (#$pr_number)"
              if ! lint_output=$(printf '%s\n' "$subject" | "$commitlint_binary" --cwd "$repository_root" --color false 2>&1); then
                # Only commitlint's problem report proves the title failed; a
                # crash or config-load error prints none and is left to CI.
                if grep -Eq 'found [0-9]+ problems' <<<"$lint_output"; then
                  deny_title "$subject" "$lint_output"
                fi
              fi
              ;;
          esac
        fi
      fi
    fi
  fi
  # A comment closed the command: skip to the end of its line.
  if [ "$next_offset" -gt 0 ] && [ "${scan_text:$((next_offset - 1)):1}" = '#' ]; then
    rest="${scan_text:$next_offset}"
    after_newline="${rest#*"$newline"}"
    [ "$after_newline" != "$rest" ] || break
    next_offset=$((next_offset + ${#rest} - ${#after_newline}))
  fi
  [ "$next_offset" -gt "$offset" ] || break
  offset="$next_offset"
done

exit 0
