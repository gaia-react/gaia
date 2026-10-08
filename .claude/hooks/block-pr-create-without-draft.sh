#!/usr/bin/env bash
#
# PreToolUse Bash hook: deny a `gh pr create` for this project's own repository
# that does not open a draft.
#
# Exit 2 = block the tool call; stderr is shown to Claude as the reason.
#
# WHY DRAFT-FIRST. Reviewers should be notified when a pull request is actually
# ready, and in a GAIA project that moment is the audit posting its GAIA-Audit
# success status. So a PR starts as a draft and the status posters
# (post-audit-status.sh, the bypass stamp, the wiki CLI's land step) flip it to
# ready right after the status lands; a refusal posts `failure` and converts it
# back to draft. A PR opened ready would notify reviewers before any audit ran.
#
# WHAT IT READS. Each top-level command of the tool call (split on list
# operators and newlines), through the shared shell-word scanner
# (`gaia_scan_first_command`), so `git push ... && gh pr create ...` is read,
# and a `;` or a quote inside a title stays title text. Heredoc bodies the
# arming walk proves are data are masked first. Draft spellings: `--draft`,
# `--draft=true`, `-d`. Repository spellings: `--repo <v>`, `--repo=<v>`,
# `-R <v>`, `-R<v>`.
#
# OWN REPOSITORY. No `--repo`/`-R`, or one whose `owner/name` equals the
# `origin` remote's (URL forms, a `.git` suffix and case are normalized on both
# sides). A `--repo` naming any other repository is allowed unchanged, for
# example the release command's PR into the scaffold repository.
#
# WHAT IT ALLOWS, rather than guessing (the honest limits):
#   - a `--repo`/`-R` value the shell expands (`$` or a backtick), whose value
#     only the shell knows;
#   - a `--repo`/`-R` when `origin` cannot be read or parsed, since the own
#     repository cannot be told from another one;
#   - a `gh pr create` nested inside a command or process substitution, a
#     subshell, or a compound-command body (`if`, `while`, `{ }`), which the
#     top-level read does not enter;
#   - an unloadable hook library for the scanner (the jq and payload libraries
#     fail loud instead).

payload=$(cat)

# jq-availability arm, narrowed by the `gh pr` literal so the command that
# installs jq is never caught: .claude/hooks/lib/jq-availability.sh.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-pr-create-without-draft.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the draft pull request guard' "$payload" tool_input 'gh pr'

# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: block-pr-create-without-draft.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
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

verb_pattern='gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
if gaia_verb_armed "$verb_pattern" 'gh pr create' "$command_text"; then
  :
else
  exit 0
fi

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

# normalize_repository <url-or-slug>: print lowercase `owner/name`, or nothing.
# Takes the last two path components after dropping a scheme, a trailing slash
# and a `.git` suffix, so `https://github.com/O/N.git`, `git@github.com:O/N` and
# `HOST/O/N` all read as `o/n`.
normalize_repository() {
  local value="$1" owner name
  value="${value%/}"
  value="${value%.git}"
  value="${value%/}"
  case "$value" in
    *[!A-Za-z0-9._:/@~-]*) return 0 ;;
  esac
  value="${value//:/\/}"
  name="${value##*/}"
  value="${value%/*}"
  owner="${value##*/}"
  { [ -n "$name" ] && [ -n "$owner" ] && [ "$value" != "$name" ]; } || return 0
  printf '%s/%s\n' "$owner" "$name" | tr '[:upper:]' '[:lower:]'
}

origin_repository=""
origin_read=0
read_origin_repository() {
  [ "$origin_read" = 0 ] || return 0
  origin_read=1
  local origin_url
  origin_url=$(git -C "$repository_root" remote get-url origin 2>/dev/null) || return 0
  origin_repository=$(normalize_repository "$origin_url")
}

# Reads GAIA_FIRST_COMMAND_WORDS for one `gh pr create` and sets draft_used,
# repository_given and repository_value.
read_create_command() {
  local index=3 word_count="${#GAIA_FIRST_COMMAND_WORDS[@]}" word
  draft_used=0
  repository_given=0
  repository_value=""
  while [ "$index" -lt "$word_count" ]; do
    word="${GAIA_FIRST_COMMAND_WORDS[$index]}"
    case "$word" in
      --draft | --draft=true | -d) draft_used=1 ;;
      --repo | -R)
        index=$((index + 1))
        repository_given=1
        repository_value="${GAIA_FIRST_COMMAND_WORDS[$index]:-}"
        ;;
      --repo=*)
        repository_given=1
        repository_value="${word#--repo=}"
        ;;
      -R?*)
        repository_given=1
        repository_value="${word#-R}"
        ;;
    esac
    index=$((index + 1))
  done
}

deny_without_draft() {
  cat >&2 <<'EOF'
BLOCKED: `gh pr create` for this repository must open a draft pull request.

Run it again with the flag: `gh pr create --draft --title "<type>(<scope>): <summary>" --body-file <file> ...`.

Reviewers are notified when a pull request is ready, and here that is when the audit posts its GAIA-Audit success status; the poster then marks the draft ready for review by itself, so never run `gh pr ready` ahead of the audit. A pull request into another repository is not covered: name it with `--repo <owner>/<name>`.
EOF
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
    [ "${GAIA_FIRST_COMMAND_WORDS[1]}" = pr ] &&
    [ "${GAIA_FIRST_COMMAND_WORDS[2]}" = create ]; then
    read_create_command
    if [ "$draft_used" = 0 ]; then
      if [ "$repository_given" = 0 ]; then
        deny_without_draft
      fi
      case "$repository_value" in
        *'$'* | *'`'*) ;;
        *)
          read_origin_repository
          requested_repository=$(normalize_repository "$repository_value")
          if [ -n "$origin_repository" ] && [ "$requested_repository" = "$origin_repository" ]; then
            deny_without_draft
          fi
          ;;
      esac
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
