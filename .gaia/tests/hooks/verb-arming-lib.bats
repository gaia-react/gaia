#!/usr/bin/env bats
# Tests for .claude/hooks/lib/verb-arming.sh and its lazily-sourced walker
# .claude/hooks/lib/verb-arming-walk.sh, exercised by sourcing them directly
# rather than through any consumer hook. The consumers' own suites cover what
# each of them does once armed; this one covers the arming answer itself.
#
# Every suppression fixture is written as a PAIR. Most of the obvious single
# assertions are already true of a tree with no data proof at all -- a
# heredoc-body verb arms, an over-bound verb arms, an abstaining walk arms --
# so a lone post-change assertion proves nothing. The twin is what makes each
# pair discriminate.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LIBRARY_FILE="$REPO_ROOT/.claude/hooks/lib/verb-arming.sh"
  WALK="$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh"
  [ -f "$LIBRARY_FILE" ] || skip "verb-arming.sh not present"
  [ -f "$WALK" ] || skip "verb-arming-walk.sh not present"

  NEWLINE=$'\n'
  TAB=$'\t'

  # The distinct verb fragments the consumers carry, verbatim.
  MERGE_FRAGMENT='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
  MERGE_WORDS='gh pr merge'
  CREATE_FRAGMENT='gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
  CREATE_WORDS='gh pr create'
  # The tail-reading consumer's fragment: a boundary group that admits a
  # separator abutting the verb, the captured tail, and the remainder group
  # that lets the real bytes be recovered by suffix length against the view.
  CREATE_TAIL_FRAGMENT=$'gh[[:space:]]+pr[[:space:]]+create([[:space:]&;|]|$)([^&;|\n]*)(.*)$'
  GIT_FRAGMENT='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(commit|push)([[:space:]]|$)'
  GIT_WORDS='git commit;git push;git -C * commit;git -C * push'
  DEBT_FRAGMENT='gh[[:space:]]+(pr[[:space:]]+merge|issue[[:space:]]+(create|edit|close|reopen))([[:space:]]|$)'
  DEBT_WORDS='gh pr merge;gh issue create;gh issue edit;gh issue close;gh issue reopen'

  MERGE_INVOCATION='gh pr merge 12'
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# arm_with <library_file> <verb_pattern> <words> <text>: source <library_file> in a fresh shell, ask it
# the arming question, and print one line carrying every result variable.
arm_with() {
  run bash -c '
    . "$1" || exit 9
    if gaia_verb_armed "$2" "$3" "$4"; then verdict=armed; else verdict=not-armed; fi
    if [ "${#GAIA_VERB_ARM_VIEW}" -eq "${#4}" ]; then lengths_match=yes; else lengths_match=no; fi
    printf "verdict=%s kind=%s sup=%s lenmatch=%s vlen=%s tlen=%s\n" \
      "$verdict" "${GAIA_VERB_ARM_KIND:-empty}" "$GAIA_VERB_ARM_SUPPRESSED" \
      "$lengths_match" "${#GAIA_VERB_ARM_VIEW}" "${#4}"
  ' _ "$1" "$2" "$3" "$4"
}

arm() { arm_with "$LIBRARY_FILE" "$1" "$2" "$3"; }

# match_of <verb_pattern> <words> <text>: print the deciding match array, one element
# per line, so a test can assert on group numbering.
match_of() {
  run bash -c '
    . "$1" || exit 9
    if gaia_verb_armed "$2" "$3" "$4"; then
      match_count=${#GAIA_VERB_ARM_MATCH[@]}
      i=0
      while [ "$i" -lt "$match_count" ]; do
        printf "m[%s]=[%s]\n" "$i" "${GAIA_VERB_ARM_MATCH[$i]}"
        i=$(( i + 1 ))
      done
      printf "count=%s kind=%s\n" "$match_count" "$GAIA_VERB_ARM_KIND"
    else
      printf "count=%s kind=none\n" "${#GAIA_VERB_ARM_MATCH[@]}"
    fi
  ' _ "$LIBRARY_FILE" "$1" "$2" "$3"
}

assert_armed()     { grep -qF "verdict=armed " <<<"$output" || return 1; }
assert_not_armed() { grep -qF "verdict=not-armed " <<<"$output" || return 1; }
assert_kind()      { grep -qF "kind=$1 " <<<"$output" || return 1; }
assert_suppressed()       { grep -qF "sup=$1 " <<<"$output" || return 1; }
assert_length_matches()    { grep -qF "lenmatch=yes " <<<"$output" || return 1; }

# lead_regex_admits <words-spec> <text>: build pass 3's pre-filter for
# <words-spec> and print whether it admits <text>, one of `admits`, `rejects`,
# or `no-filter` for the arm that declines to build one at all.
#
# It reads the FILTER rather than the arming verdict, and that is the whole
# reason it exists. Arming for a text whose first word is not the verb's is
# decided by the word compare whatever the filter does, so a test that asserts
# only `not-armed` observes nothing about the filter and stays green on one
# widened to a single character per word.
lead_regex_admits() {
  run bash -c '
    . "$1" || exit 9
    _gaia_va_build_lead_regex "$2"
    if [ -z "$_gaia_va_lead_regex" ]; then printf "no-filter\n"; exit 0; fi
    if [[ "$3" =~ $_gaia_va_lead_regex ]]; then printf "admits\n"; else printf "rejects\n"; fi
  ' _ "$LIBRARY_FILE" "$1" "$2"
}

# make_run <run_length> <char>: a run of exactly <run_length> copies of <char>, from a doubling
# cache so a 16KB fixture costs a handful of concatenations.
make_run() {
  local run_length="$1" run_text="$2"
  while [ "${#run_text}" -lt "$run_length" ]; do run_text="$run_text$run_text"; done
  printf '%s' "${run_text:0:$run_length}"
}

# parity <verb_pattern> <words> <invocation>: the invocation arms at command start and
# after each of the five separators. Every one of these is true before the data
# proof exists as well as after, which is the point of asserting them.
parity() {
  local verb_pattern="$1" words="$2" invocation="$3" separator
  arm "$verb_pattern" "$words" "$invocation"
  assert_armed || return 1
  for separator in '&&' ';' '||' '|'; do
    arm "$verb_pattern" "$words" "echo x $separator $invocation"
    assert_armed || return 1
  done
  arm "$verb_pattern" "$words" "echo x$NEWLINE$invocation"
  assert_armed || return 1
  true
}

# ---------------------------------------------------------------------------
# Arming parity: no spelling that arms today stops arming.
# ---------------------------------------------------------------------------

@test "the merge fragment arms at command start and after every separator" {
  parity "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr merge 12'
}

@test "the pull-request-creation fragment arms at command start and after every separator" {
  parity "$CREATE_FRAGMENT" "$CREATE_WORDS" 'gh pr create --fill'
}

@test "the tail-capturing creation fragment arms at command start and after every separator" {
  parity "$CREATE_TAIL_FRAGMENT" "$CREATE_WORDS" 'gh pr create --fill'
}

@test "the git-operation fragment arms at command start and after every separator" {
  parity "$GIT_FRAGMENT" "$GIT_WORDS" 'git commit -m subject'
  parity "$GIT_FRAGMENT" "$GIT_WORDS" 'git -C /some/path push origin main'
}

@test "the debt-sentinel fragment arms at command start and after every separator" {
  parity "$DEBT_FRAGMENT" "$DEBT_WORDS" 'gh issue create --title subject'
  parity "$DEBT_FRAGMENT" "$DEBT_WORDS" 'gh pr merge 12'
}

# ---------------------------------------------------------------------------
# Substitution openers: a verb inside `$( )`, a backtick, `<( )` or `>( )` is
# run by the shell, so it arms exactly as a verb after a separator does.
# ---------------------------------------------------------------------------

# opener_pair <verb_pattern> <words> <invocation>: the invocation arms after each
# opener, bare and inside double quotes, and the same text with the opener's
# substitution character removed does not. The twin is what makes each case
# discriminate: without it, a text that armed for some other reason would pass.
opener_pair() {
  local verb_pattern="$1" words="$2" invocation="$3" opener
  for opener in '$(' '`' '<(' '>('; do
    arm "$verb_pattern" "$words" "echo x ${opener}${invocation}"
    assert_armed || return 1
    assert_kind sep || return 1
    arm "$verb_pattern" "$words" "echo \"${opener}${invocation}\""
    assert_armed || return 1
    arm "$verb_pattern" "$words" "echo x ${opener} ${invocation}"
    assert_armed || return 1
  done
  # The twins: `(` or `{` alone opens no substitution here, and a bare word
  # ahead of the verb is an argument.
  arm "$verb_pattern" "$words" "echo x (${invocation}"
  assert_not_armed || return 1
  arm "$verb_pattern" "$words" "echo x {${invocation}"
  assert_not_armed || return 1
  arm "$verb_pattern" "$words" "echo x ${invocation}"
  assert_not_armed || return 1
  true
}

@test "the merge fragment arms after every substitution opener" {
  opener_pair "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr merge 12 --squash)'
}

@test "the pull-request-creation fragment arms after every substitution opener" {
  opener_pair "$CREATE_FRAGMENT" "$CREATE_WORDS" 'gh pr create --fill)'
}

@test "the tail-capturing creation fragment arms after every substitution opener" {
  opener_pair "$CREATE_TAIL_FRAGMENT" "$CREATE_WORDS" 'gh pr create --fill)'
}

@test "the git-operation fragment arms after every substitution opener" {
  opener_pair "$GIT_FRAGMENT" "$GIT_WORDS" 'git commit -m subject)'
  opener_pair "$GIT_FRAGMENT" "$GIT_WORDS" 'git -C /some/path push origin main)'
}

@test "the debt-sentinel fragment arms after every substitution opener" {
  opener_pair "$DEBT_FRAGMENT" "$DEBT_WORDS" 'gh issue create --title subject)'
  opener_pair "$DEBT_FRAGMENT" "$DEBT_WORDS" 'gh pr merge 12 --squash)'
}

@test "a substitution opener is the separator group, so the fragment's groups still start at 2" {
  match_of "$MERGE_FRAGMENT" "$MERGE_WORDS" 'echo "$(gh pr merge 12 --squash)"'
  grep -qF "kind=sep" <<<"$output" || return 1
  grep -qF "count=3" <<<"$output" || return 1
  grep -qF 'm[1]=[$(]' <<<"$output" || return 1
  grep -qF "m[2]=[ ]" <<<"$output" || return 1

  match_of "$CREATE_TAIL_FRAGMENT" "$CREATE_WORDS" 'echo `gh pr create --fill`'
  grep -qF "kind=sep" <<<"$output" || return 1
  grep -qF 'm[1]=[`]' <<<"$output" || return 1
  grep -qF "m[2]=[ ]" <<<"$output" || return 1
  grep -qF 'm[3]=[--fill`]' <<<"$output" || return 1
  true
}

# ---------------------------------------------------------------------------
# Dead openers: an opener the parsing shell never runs arms nothing. Each
# fixture's twin is the same text with the opener made live, which arms.
# ---------------------------------------------------------------------------

@test "an opener inside single quotes arms nothing, and its double-quoted twin arms" {
  local backtick='`'
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "gh pr comment 5 --body 'see ${backtick}gh pr merge 30 --squash${backtick}'"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "gh pr comment 5 --body \"see ${backtick}gh pr merge 30 --squash${backtick}\""
  assert_armed || return 1
  assert_kind sep || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo 'x \$(gh pr merge 12)'"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"x \$(gh pr merge 12)\""
  assert_armed || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo 'x <(gh pr merge 12)'"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo x <(gh pr merge 12)"
  assert_armed
}

@test "an apostrophe inside double quotes opens no span, so the opener after it arms" {
  local backtick='`'
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"it's ${backtick}gh pr merge 12${backtick}\""
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo 'it is ${backtick}gh pr merge 12${backtick}'"
  assert_not_armed
}

@test "single quotes inside a substitution inside double quotes are real quotes again" {
  local backtick='`'
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(printf '%s' '${backtick}gh pr merge 12${backtick}')\""
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(printf '%s' ${backtick}gh pr merge 12${backtick})\""
  assert_armed
}

@test "a backslash-escaped opener arms nothing, and its unescaped twin arms" {
  local backtick='`'
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \\${backtick}gh pr merge 12\\${backtick}"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo ${backtick}gh pr merge 12${backtick}"
  assert_armed || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\\\$(gh pr merge 12)\""
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(gh pr merge 12)\""
  assert_armed
}

@test "a quoted-delimiter heredoc read by cat inside a substitution arms nothing, for each body-carrying command" {
  local backtick='`' body command_text
  body="See ${backtick}gh pr merge 30 --squash${backtick} for the merge.${NEWLINE}And a \$(gh pr merge 31) too.${NEWLINE}EOF${NEWLINE})\""
  for command_text in 'gh pr create --title t --body' 'gh issue create --title t --body' 'git commit -m'; do
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$command_text \"\$(cat <<'EOF'${NEWLINE}${body}"
    assert_not_armed || return 1
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$command_text \"\$(cat <<\"EOF\"${NEWLINE}${body}"
    assert_not_armed || return 1
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$command_text \"\$(cat <<\\EOF${NEWLINE}${body}"
    assert_not_armed || return 1
    # The unquoted-delimiter twin runs the substitutions in its body.
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$command_text \"\$(cat <<EOF${NEWLINE}${body}"
    assert_armed || return 1
  done
  true
}

@test "a quoted-delimiter heredoc read by anything but a bare cat or tee keeps its openers live" {
  local backtick='`' body
  body="${backtick}gh pr merge 30${backtick}${NEWLINE}EOF${NEWLINE})\""
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\"\$(cat <<'EOF'${NEWLINE}${body}"
  assert_not_armed || return 1
  # An interpreter reads the body as a script.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\"\$(bash <<'EOF'${NEWLINE}${body}"
  assert_armed || return 1
  # cat's output piped into an interpreter on the opener line.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\"\$(cat <<'EOF' | sh${NEWLINE}${body}"
  assert_armed || return 1
  # A process substitution hands the body to whatever reads it as a file.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "bash <(cat <<'EOF'${NEWLINE}${backtick}gh pr merge 30${backtick}${NEWLINE}EOF${NEWLINE})"
  assert_armed || return 1
  # Two heredocs on one line are not modelled.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\"\$(cat <<'EOF' <<'EOG'${NEWLINE}a${NEWLINE}EOF${NEWLINE}${backtick}gh pr merge 30${backtick}${NEWLINE}EOG${NEWLINE})\""
  assert_armed
}

@test "a dead opener ahead of a live one still arms on the live one" {
  local backtick='`'
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo '${backtick}gh pr merge 1${backtick}'; x=${backtick}gh pr merge 2${backtick}"
  assert_armed || return 1
  assert_kind sep || return 1
  match_of "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo '\$(gh pr merge 1)'; x=\"\$(gh pr merge 2 --squash)\""
  grep -qF 'kind=sep' <<<"$output" || return 1
  grep -qF 'count=3' <<<"$output" || return 1
  grep -qF 'm[1]=[$(]' <<<"$output" || return 1
  grep -qF 'm[2]=[ ]' <<<"$output" || return 1
  true
}

@test "a text the liveness scan cannot model keeps every opener live" {
  local backtick='`'
  # Unterminated single quote.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo 'x ${backtick}gh pr merge 12${backtick}"
  assert_armed || return 1
  # A case arm's bare `)` inside a substitution.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\$(case a in a) echo '${backtick}gh pr merge 12${backtick}';; esac)"
  assert_armed || return 1
  # A dollar-quoted word.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \$'a' '${backtick}gh pr merge 12${backtick}'"
  assert_armed || return 1
  # The terminated, case-free, plainly quoted twin is modelled.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo 'x ${backtick}gh pr merge 12${backtick}'"
  assert_not_armed
}

@test "an ampersand or pipe completing a redirection does not start a new command for the heredoc owner" {
  local body="echo \$(gh pr merge 1)${NEWLINE}EOF"
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "bash -s >& cat <<'EOF'${NEWLINE}${body}"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\$(bash -s >&cat <<'EOF'${NEWLINE}${body}${NEWLINE})"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\$(sh >| cat <<'EOF'${NEWLINE}${body}${NEWLINE})"
  assert_armed || return 1
  # A bare cat owning the same body is still data.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\$(cat <<'EOF'${NEWLINE}${body}${NEWLINE})"
  assert_not_armed
}

@test "a body inside a substitution stays live when bash 3.2's paren matcher would close the substitution in it" {
  local backtick='`'
  # bash 3.2 ends the substitution at the body's first unmatched `)`.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(cat <<'EOF'${NEWLINE})\$(gh pr merge 1)${NEWLINE}EOF${NEWLINE})\""
  assert_armed || return 1
  # Its matcher honours quotes, so a quoted paren does not balance one.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(cat <<'EOF'${NEWLINE}a '(' b ) \$(gh pr merge 1)${NEWLINE}EOF${NEWLINE})\""
  assert_armed || return 1
  # Balanced parentheses and a backticked citation stay data.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(cat <<'EOF'${NEWLINE}See (below) ${backtick}gh pr merge 1${backtick}.${NEWLINE}EOF${NEWLINE})\""
  assert_not_armed || return 1
  # An apostrophe nothing later can close is a 3.2 syntax error, so nothing
  # runs, and the body stays data.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "gh pr create --body \"\$(cat <<'EOF'${NEWLINE}It's ${backtick}gh pr merge 1${backtick}.${NEWLINE}EOF${NEWLINE})\""
  assert_not_armed || return 1
  # A dollar-quoted span honours backslash escapes, so its escaped apostrophe
  # does not end it and the paren after it closes the substitution.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"A\$(cat <<'EOF'${NEWLINE}\$'\\'x' ) \$(gh pr merge 1) '${NEWLINE}EOF${NEWLINE})B\""
  assert_armed || return 1
  # Without the dollar, or with it escaped, the same span is plain quoting.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"A\$(cat <<'EOF'${NEWLINE}'\\'x' ) \$(gh pr merge 1) '${NEWLINE}EOF${NEWLINE})B\""
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"A\$(cat <<'EOF'${NEWLINE}\\\$'\\'x' ) \$(gh pr merge 1) '${NEWLINE}EOF${NEWLINE})B\""
  assert_not_armed || return 1
  # The same apostrophe with a later one to pair with is not.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\"\$(cat <<'EOF'${NEWLINE}It's ${backtick}gh pr merge 1${backtick}.${NEWLINE}EOF${NEWLINE})\"; echo 'y'"
  assert_armed
}

@test "bash 3.2's matcher starts at the substitution's opener, so a paren before the body can close it first" {
  local tail="cat <<'B'${NEWLINE}\$(gh pr merge 1)${NEWLINE}B${NEWLINE})\""
  # An unmatched paren in an earlier, live heredoc body.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(tr a b <<'A'${NEWLINE})${NEWLINE}A${NEWLINE}${tail}"
  assert_armed || return 1
  # One in a comment, which the matcher reads as text.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(# a )${NEWLINE}${tail}"
  assert_armed || return 1
  # One in a delimiter line, unquoted to the matcher.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(cat <<'E)'${NEWLINE}x${NEWLINE}E)${NEWLINE}${tail}"
  assert_armed || return 1
  # Nothing ahead of the body in the substitution: still data.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"\$(${tail}"
  assert_not_armed
}

@test "a hash after a subshell's closing parenthesis opens a comment the scan honours" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "(true)#it's${NEWLINE}x=\$(gh pr merge 1) # it's"
  assert_armed || return 1
  # After a substitution's closing parenthesis the hash continues the word.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \$(true)#x '\$(gh pr merge 1)'"
  assert_not_armed
}

@test "a heredoc operator inside parentheses is not modelled, so its openers stay live" {
  local backtick='`'
  # Arithmetic reads 1<<EOF as a shift, not a heredoc.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "(( y = 1<<EOF ))${NEWLINE}echo 'a${NEWLINE}EOF${NEWLINE}' ; merge_result=\$(gh pr merge 1) # '"
  assert_armed || return 1
  # A subshell's output can feed an interpreter.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "(cat <<'EOF'${NEWLINE}${backtick}gh pr merge 1${backtick}${NEWLINE}EOF${NEWLINE}) | bash"
  assert_armed || return 1
  # The same body directly in a command substitution is still modelled.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "x=\"\$(cat <<'EOF'${NEWLINE}${backtick}gh pr merge 1${backtick}${NEWLINE}EOF${NEWLINE})\""
  assert_not_armed
}

@test "an apostrophe in a comment opens no span that could hide a later live opener" {
  local backtick='`'
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "# don't${NEWLINE}echo ${backtick}gh pr merge 12${backtick}"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo don't ${backtick}gh pr merge 12${backtick}'"
  assert_not_armed
}

@test "the tail-capturing fragment recovers its real tail by length when a dead opener sits in it" {
  # The consumer's own recovery: slice the text by the suffix and tail lengths
  # the view's match reports. The view masks the dead opener, so the captured
  # group differs from the real bytes and only the slice returns them.
  run bash -c '
    . "$1" || exit 9
    command_text=$2
    gaia_verb_armed "$3" "gh pr create" "$command_text" || { echo not-armed; exit 0; }
    captured_tail="${GAIA_VERB_ARM_MATCH[3]-}"
    remainder="${GAIA_VERB_ARM_MATCH[4]-}"
    start=$(( ${#command_text} - ${#remainder} - ${#captured_tail} ))
    printf "kind=%s\n" "$GAIA_VERB_ARM_KIND"
    printf "captured=[%s]\n" "$captured_tail"
    printf "real=[%s]\n" "${command_text:start:${#captured_tail}}"
  ' _ "$LIBRARY_FILE" "x=\"\$(gh pr create --title 'x \$(y)' --fill)\"" "$CREATE_TAIL_FRAGMENT"
  grep -qF 'kind=sep' <<<"$output" || return 1
  grep -qF "real=[--title 'x \$(y)' --fill)\"]" <<<"$output" || return 1
  grep -qF "captured=[--title 'x \$(y)' --fill)\"]" <<<"$output" && return 1
  true
}

# ---------------------------------------------------------------------------
# The data proof
# ---------------------------------------------------------------------------

@test "a heredoc body written to a file by cat does not arm, and the same payload without the opener does" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed || return 1
  assert_suppressed 1 || return 1
  assert_length_matches || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed
}

@test "tee, tee -a and an appending redirect prove the same thing cat does" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "tee /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "tee -a /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat >> /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed
}

@test "the body starts after the opener line's newline, so a verb still on the opener line arms" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF && $MERGE_INVOCATION${NEWLINE}body${NEWLINE}EOF"
  assert_armed || return 1
  # The body was masked even so; the arm comes from the opener line itself.
  assert_suppressed 1 || return 1
  assert_kind sep
}

@test "a heredoc fed to an interpreter or a remote shell arms in every spelling" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat <<EOF | bash$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "bash <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "ssh host <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "\$RUNNER <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed
}

@test "a heredoc belonging to a second command on the opener line keeps the match" {
  # Condition 6. The command word at the line's start and the redirect on it
  # both belong to `cat`, while the heredoc belongs to the command after the
  # separator, and that is the one the shell hands the body to. Reading the
  # line as a whole cannot tell the two apart, so without the pre-operator
  # scan each of these masks a merge the shell really runs.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f && bash <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f ; bash <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f & bash <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "tee /tmp/f || sh <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f && ssh host <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed
}

@test "a word between the redirect and the operator is an operand, so the body stays data" {
  # The other side of condition 6, and the reason it scans for separators
  # rather than for a second word: here `bash` is an operand of `cat`, the
  # heredoc is still cat's, and the shell writes the body to the file. A rule
  # that rejected any word before the operator would arm this and undo the
  # suppression the whitelist exists to grant.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f bash <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed || return 1
  assert_suppressed 1 || return 1
  assert_length_matches
}

@test "an expansion or a backtick anywhere on the opener line keeps the match" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > \"\$(mktemp)\" <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > f\${SUFFIX} <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > \$OUT <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > \`mktemp\` <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed
}

@test "output going anywhere but a file keeps the match" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat <<EOF | wc -l$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  # No redirect and no file operand at all: the body reaches stdout, which the
  # whitelist does not accept as a file.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed
}

@test "the <<- form suppresses under a tab-indented delimiter and keeps the match when the delimiter is unreachable" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<-EOF$NEWLINE$MERGE_INVOCATION$NEWLINE${TAB}EOF"
  assert_not_armed || return 1
  assert_length_matches || return 1
  # Spaces are not what the dash strips, so this delimiter line never closes
  # the heredoc and the walk abandons suppression.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<-EOF$NEWLINE$MERGE_INVOCATION$NEWLINE    EOF"
  assert_armed
}

@test "a quoted or backslash-escaped delimiter is read the same as a bare one" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<'EOF'$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<\"EOF\"$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<\\EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed
}

@test "a substitution in an unquoted-delimiter body arms, and the quoted-delimiter twin is data" {
  # The shell runs `$( )` and backticks inside a heredoc body whose delimiter
  # is unquoted, so that body is not data however the opener line reads. A
  # quoted or escaped delimiter turns substitution off, which is what makes
  # the twin data.
  local substitution
  for substitution in "\$($MERGE_INVOCATION --squash)" "\`$MERGE_INVOCATION --squash\`" "x \$( $MERGE_INVOCATION --squash)"; do
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$substitution${NEWLINE}EOF"
    assert_armed || return 1
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<-EOF$NEWLINE$substitution$NEWLINE${TAB}EOF"
    assert_armed || return 1
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<'EOF'$NEWLINE$substitution${NEWLINE}EOF"
    assert_not_armed || return 1
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<\"EOF\"$NEWLINE$substitution${NEWLINE}EOF"
    assert_not_armed || return 1
    arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<\\EOF$NEWLINE$substitution${NEWLINE}EOF"
    assert_not_armed || return 1
  done
  # A plain parameter expansion runs nothing, so it leaves the body data.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE\$HOME$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed
}

@test "an apostrophe in a heredoc body does not open a span the walk then loses" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF${NEWLINE}do not merge${NEWLINE}$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF${NEWLINE}don't merge${NEWLINE}$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed
}

# ---------------------------------------------------------------------------
# Abstention, whole-input
# ---------------------------------------------------------------------------

@test "an unterminated single quote abandons suppression, and its terminated twin does not" {
  local base="cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF${NEWLINE}echo "
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$base'"
  assert_armed || return 1
  assert_suppressed 0 || return 1
  assert_length_matches || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$base''"
  assert_not_armed
}

@test "an unterminated double quote abandons suppression, and its terminated twin does not" {
  local base="cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF${NEWLINE}echo "
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$base\""
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$base\"\""
  assert_not_armed
}

@test "a heredoc whose delimiter never appears abandons suppression, and its reachable twin does not" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<NOPE$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  assert_suppressed 0 || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_not_armed
}

@test "a dollar-quoted word abandons suppression, and the same payload without one does not" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF${NEWLINE}echo \$'x'"
  assert_armed || return 1
  assert_suppressed 0 || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF${NEWLINE}echo x"
  assert_not_armed
}

@test "a payload at the bound is suppressed and the same payload past it is not" {
  local head="cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION$NEWLINE"
  local tail="${NEWLINE}EOF"
  local fill=$(( 16384 - ${#head} - ${#tail} ))

  local under
  under="$head$(make_run "$fill" y)$tail"
  [ "${#under}" -eq 16384 ] || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$under"
  assert_not_armed || return 1
  assert_suppressed 1 || return 1

  local over
  over="$head$(make_run $(( fill + 10 )) y)$tail"
  [ "${#over}" -eq 16394 ] || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$over"
  assert_armed || return 1
  assert_suppressed 0 || return 1
  assert_length_matches
}

@test "a text too dense to walk cheaply abandons suppression, and its sparse twin does not" {
  # Same length, same structure, same heredoc; only the density of the
  # characters the walk has to step past differs.
  local dense sparse
  dense="cat > /tmp/f <<EOF && echo $(make_run 15000 "'ab' ")$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  sparse="cat > /tmp/f <<EOF && echo $(make_run 15000 'xxxxxx')$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  [ "${#dense}" -eq "${#sparse}" ] || return 1
  [ "${#dense}" -le 16384 ] || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$dense"
  assert_armed || return 1
  assert_suppressed 0 || return 1
  assert_length_matches || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$sparse"
  assert_not_armed || return 1
  assert_suppressed 1
}

# ---------------------------------------------------------------------------
# Never suppressed
# ---------------------------------------------------------------------------

@test "a quoted string carrying a separator before the verb still arms" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"finish the audit && $MERGE_INVOCATION\""
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo \"x; $MERGE_INVOCATION\""
  assert_armed
}

@test "a mid-word hash still arms and a verb after a word-initial hash on its own line does not" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "git checkout fix#12 && $MERGE_INVOCATION"
  assert_armed || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo hi$NEWLINE# $MERGE_INVOCATION"
  assert_not_armed
}

# ---------------------------------------------------------------------------
# The tokenizer arm
# ---------------------------------------------------------------------------

@test "a quoted verb in the first command arms through the tokenizer" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr "merge" 12'
  assert_armed || return 1
  assert_kind first-command || return 1
  assert_suppressed 0
}

@test "a quoted verb that is not the first command arms nothing" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" 'echo x && gh pr "merge" 12'
  assert_not_armed
}

@test "the tokenizer reads a git -C invocation through the wildcard word" {
  arm "$GIT_FRAGMENT" "$GIT_WORDS" 'git -C /some/path "commit" -m subject'
  assert_armed || return 1
  assert_kind first-command
}

@test "an empty words spec turns the tokenizer arm off" {
  arm "$MERGE_FRAGMENT" "" 'gh pr "merge" 12'
  assert_not_armed || return 1
  # The text arm is untouched by an empty spec.
  arm "$MERGE_FRAGMENT" "" 'gh pr merge 12'
  assert_armed
}

@test "the tokenizer's bounded prefix can create an arm the full text does not carry" {
  # `merge` ends exactly at the 2048-character bound, so the truncated prefix
  # reads a word the whole text never spells.
  local padding
  padding="$(make_run 2038 ' ')"
  local armed_text="gh pr${padding}mergeZZZZZZZZZZ"
  [ "${#armed_text}" -eq 2058 ] || return 1
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$armed_text"
  assert_armed || return 1
  assert_kind first-command || return 1

  # One character shorter, the cut lands inside the word instead.
  local quiet_text="gh pr${padding:1}mergeZZZZZZZZZZ"
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$quiet_text"
  assert_not_armed
}

# ---------------------------------------------------------------------------
# The view contract
# ---------------------------------------------------------------------------

@test "the view is the same length as the text when suppressed, when the identity, and when over the bound" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_length_matches || return 1
  assert_suppressed 1 || return 1

  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo x && $MERGE_INVOCATION"
  assert_length_matches || return 1
  assert_suppressed 0 || return 1

  local head="cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION$NEWLINE"
  local tail="${NEWLINE}EOF"
  local over
  over="$head$(make_run $(( 16384 - ${#head} - ${#tail} + 10 )) y)$tail"
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "$over"
  assert_length_matches || return 1
  assert_suppressed 0
}

@test "the view is the same length as a text whose final character is a newline" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF$NEWLINE"
  assert_not_armed || return 1
  assert_suppressed 1 || return 1
  assert_length_matches || return 1
  grep -qF "vlen=38 tlen=38" <<<"$output" || return 1
  true
}

@test "the suppressed flag is 1 exactly when the view differs from the text" {
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_suppressed 1 || return 1
  # Same shape, but the walk abstains, so nothing anywhere is suppressed.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<NOPE$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_suppressed 0 || return 1
  # No heredoc at all.
  arm "$MERGE_FRAGMENT" "$MERGE_WORDS" "echo x && $MERGE_INVOCATION"
  assert_suppressed 0
}

@test "the match array numbers the fragment's groups from 1 under start and from 2 under sep" {
  match_of "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr merge 12'
  grep -qF "kind=start" <<<"$output" || return 1
  grep -qF "count=2" <<<"$output" || return 1
  grep -qF "m[1]=[ ]" <<<"$output" || return 1

  match_of "$MERGE_FRAGMENT" "$MERGE_WORDS" 'echo x && gh pr merge 12'
  grep -qF "kind=sep" <<<"$output" || return 1
  grep -qF "count=3" <<<"$output" || return 1
  grep -qF "m[1]=[&&]" <<<"$output" || return 1
  grep -qF "m[2]=[ ]" <<<"$output" || return 1
  true
}

@test "the tail-capturing fragment keeps its own group numbering under both patterns" {
  match_of "$CREATE_TAIL_FRAGMENT" "$CREATE_WORDS" 'gh pr create --fill --base main'
  grep -qF "kind=start" <<<"$output" || return 1
  grep -qF "m[1]=[ ]" <<<"$output" || return 1
  grep -qF "m[2]=[--fill --base main]" <<<"$output" || return 1

  match_of "$CREATE_TAIL_FRAGMENT" "$CREATE_WORDS" 'echo x && gh pr create --fill'
  grep -qF "kind=sep" <<<"$output" || return 1
  grep -qF "m[1]=[&&]" <<<"$output" || return 1
  grep -qF "m[2]=[ ]" <<<"$output" || return 1
  grep -qF "m[3]=[--fill]" <<<"$output" || return 1
  true
}

@test "the match array is empty when the tokenizer decides and when nothing arms" {
  match_of "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr "merge" 12'
  grep -qF "count=0 kind=first-command" <<<"$output" || return 1
  match_of "$MERGE_FRAGMENT" "$MERGE_WORDS" 'echo hello'
  grep -qF "count=0 kind=none" <<<"$output" || return 1
  true
}

# ---------------------------------------------------------------------------
# Fail direction, and the walker's own contract
# ---------------------------------------------------------------------------

@test "with the walker absent the raw match stands and the view is the identity" {
  local stage="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$stage"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$stage/lib"
  rm -f "$stage/lib/verb-arming-walk.sh"
  [ ! -f "$stage/lib/verb-arming-walk.sh" ] || return 1

  arm_with "$stage/lib/verb-arming.sh" "$MERGE_FRAGMENT" "$MERGE_WORDS" \
    "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  assert_armed || return 1
  assert_suppressed 0 || return 1
  assert_length_matches || return 1
  assert_kind sep
}

@test "the walker is sourceable on its own under nounset and defaults the bound" {
  run bash -c '
    set -u
    . "$1"
    GAIA_VERB_ARM_VIEW=""
    gaia_verb_arm_view "$2"
    printf "len=%s sup=%s\n" "${#GAIA_VERB_ARM_VIEW}" \
      "$( [ "$GAIA_VERB_ARM_VIEW" = "$2" ] && printf 0 || printf 1 )"
  ' _ "$WALK" "cat > /tmp/f <<EOF${NEWLINE}gh pr merge 12${NEWLINE}EOF"
  [ "$status" -eq 0 ]
  grep -qF "len=37 sup=1" <<<"$output" || return 1
  true
}

# ---------------------------------------------------------------------------
# Shell-option safety. The not-armed case is the real one: a bare `return 1`
# reaching an ERR trap would exit the hook before it did any of its work.
# ---------------------------------------------------------------------------

@test "an armed call returns into a caller running errexit with an ERR trap" {
  run bash -c '
    set -euo pipefail
    trap "exit 0" ERR
    . "$1"
    if gaia_verb_armed "$2" "$3" "$4"; then :; fi
    printf "REACHED kind=%s\n" "$GAIA_VERB_ARM_KIND"
  ' _ "$LIBRARY_FILE" "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr merge 12'
  grep -qF "REACHED kind=start" <<<"$output" || return 1
  true
}

@test "a not-armed call returns into a caller running errexit with an ERR trap" {
  run bash -c '
    set -euo pipefail
    trap "exit 0" ERR
    . "$1"
    if gaia_verb_armed "$2" "$3" "$4"; then :; fi
    printf "REACHED kind=%s\n" "${GAIA_VERB_ARM_KIND:-empty}"
  ' _ "$LIBRARY_FILE" "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh issue list --state open'
  grep -qF "REACHED kind=empty" <<<"$output" || return 1
  true
}

@test "a not-armed call returns into a caller trapping ERR without errexit" {
  run bash -c '
    set -uo pipefail
    trap "exit 0" ERR
    . "$1"
    if gaia_verb_armed "$2" "$3" "$4"; then :; fi
    printf "REACHED\n"
  ' _ "$LIBRARY_FILE" "$MERGE_FRAGMENT" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  grep -qF "REACHED" <<<"$output" || return 1
  true
}

# ---------------------------------------------------------------------------
# The two lazy library loads, under a caller running errexit
#
# verb-arming.sh sources repo-scope.sh (pass 3's tokenizer) and
# verb-arming-walk.sh (pass 2's view) lazily, from its own directory. Neither
# can be guarded from outside: a consumer's `bash -n` on verb-arming.sh does
# not recurse into what verb-arming.sh itself sources. Under errexit an
# unparseable copy of either abandoned the shell before the `type` check on the
# next line could degrade, and in the errexit consumers that exit is 2 --
# the PreToolUse deny code.
#
# Every case here is pinned to stock /bin/bash. On bash 5 a failed source
# returns non-zero and execution continues, so only 3.2 expresses this half of
# the class; on a bash-5 /bin/bash (Linux CI) these pass either way, the same
# honest caveat the sibling suites' pinned cases carry.
#
# Each unparseable case is PAIRED with a control on the same interpreter and
# the same staging. The degraded verdicts below (not-armed for the tokenizer,
# the raw match for the walker) are equally satisfied by a library that never
# loaded anything at all, so the control is what proves the staging still arms
# normally when the lib parses.
# ---------------------------------------------------------------------------

# arm_staged <interpreter> <library_file> <verb_pattern> <words> <text>: ask the arming question
# from a caller running errexit, exactly as the four errexit consumer hooks do.
# The errexit is the point of the harness: without it an unparseable lib merely
# returns non-zero and execution continues on every bash, so the class these
# cases cover cannot be expressed at all.
arm_staged() {
  local interpreter="$1" library_file="$2" verb_pattern="$3" words="$4" text="$5"
  run "$interpreter" -c '
    set -euo pipefail
    . "$1" || exit 9
    if gaia_verb_armed "$2" "$3" "$4"; then verdict=armed; else verdict=not-armed; fi
    printf "verdict=%s kind=%s sup=%s\n" "$verdict" "${GAIA_VERB_ARM_KIND:-empty}" \
      "${GAIA_VERB_ARM_SUPPRESSED:-0}"
  ' _ "$library_file" "$verb_pattern" "$words" "$text"
}

# Copies the real lib directory somewhere the test can corrupt, and prints the
# staged verb-arming.sh path.
stage_library() {
  local stage="$BATS_TEST_TMPDIR/staged-$1"
  rm -rf "$stage"; mkdir -p "$stage"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$stage/lib"
  printf '%s' "$stage/lib/verb-arming.sh"
}

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_library() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

@test "control: a staged lib arms through the tokenizer under errexit on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local library_file; library_file="$(stage_library tokctl)"
  arm_staged /bin/bash "$library_file" "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr "merge" 12'
  [ "$status" -eq 0 ]
  assert_armed || return 1
  assert_kind first-command
}

@test "an unparseable repo-scope.sh degrades to not-armed instead of denying, on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local library_file; library_file="$(stage_library tokbad)"
  write_conflicted_library "$(dirname "$library_file")/repo-scope.sh"
  arm_staged /bin/bash "$library_file" "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr "merge" 12'
  [ "$status" -eq 0 ]
  assert_not_armed
}

@test "control: a staged lib suppresses a heredoc body under errexit on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local library_file; library_file="$(stage_library walkctl)"
  arm_staged /bin/bash "$library_file" "$MERGE_FRAGMENT" "$MERGE_WORDS" \
    "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  [ "$status" -eq 0 ]
  assert_not_armed
}

@test "an unparseable verb-arming-walk.sh leaves the raw match standing instead of denying, on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local library_file; library_file="$(stage_library walkbad)"
  write_conflicted_library "$(dirname "$library_file")/verb-arming-walk.sh"
  arm_staged /bin/bash "$library_file" "$MERGE_FRAGMENT" "$MERGE_WORDS" \
    "cat > /tmp/f <<EOF$NEWLINE$MERGE_INVOCATION${NEWLINE}EOF"
  [ "$status" -eq 0 ]
  # Same degrade the absent-walker case above gets: with no view to suppress
  # by, the raw match stands and the call arms.
  assert_armed || return 1
  assert_kind sep
}

# The load guard suspends errexit across the source and must put back exactly
# what it found. Several of this library's consumers deliberately run
# WITHOUT errexit -- pr-merge-audit-check.sh, worthiness-presence-check.sh,
# debt-sentinel-touch.sh, issue-claim-release.sh, and token-tally-review.sh --
# and several are PreToolUse deny gates where a stray
# non-zero exit becomes a verdict. An unconditional `set -e` restore would arm
# errexit in every one of them, so this case pins the restore as conditional.
# It needs no interpreter pin: the leak it guards against is present on bash
# 3.2 and bash 5 alike.
@test "a load from a caller without errexit leaves errexit off" {
  local library_file; library_file="$(stage_library noerrexit)"
  run bash -c '
    set -uo pipefail
    . "$1"
    gaia_verb_armed "$2" "$3" "$4" || true
    case $- in *e*) printf "errexit=ON\n" ;; *) printf "errexit=OFF\n" ;; esac
    false
    printf "SURVIVED\n"
  ' _ "$library_file" "$MERGE_FRAGMENT" "$MERGE_WORDS" 'gh pr "merge" 12'
  grep -qF "errexit=OFF" <<<"$output" || return 1
  grep -qF "SURVIVED" <<<"$output" || return 1
  true
}
