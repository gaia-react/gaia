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
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LIB="$REPO_ROOT/.claude/hooks/lib/verb-arming.sh"
  WALK="$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh"
  [ -f "$LIB" ] || skip "verb-arming.sh not present"
  [ -f "$WALK" ] || skip "verb-arming-walk.sh not present"

  # The wrapper-table readers block-no-verify.bats reads the same table with.
  # shellcheck disable=SC2034 # read by helpers/wrapper-table.sh
  WRAPPER_TABLE_FILE="$REPO_ROOT/.claude/hooks/lib/command-wrappers.sh"
  . "$BATS_TEST_DIRNAME/helpers/wrapper-table.sh"

  NL=$'\n'
  TAB=$'\t'

  # The distinct verb fragments the consumers carry, verbatim.
  MERGE_FRAG='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
  MERGE_WORDS='gh pr merge'
  CREATE_FRAG='gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
  CREATE_WORDS='gh pr create'
  # The tail-reading consumer's fragment: a boundary group that admits a
  # separator abutting the verb, the captured tail, and the remainder group
  # that lets the real bytes be recovered by suffix length against the view.
  CREATE_TAIL_FRAG=$'gh[[:space:]]+pr[[:space:]]+create([[:space:]&;|]|$)([^&;|\n]*)(.*)$'
  GIT_FRAG='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(commit|push)([[:space:]]|$)'
  GIT_WORDS='git commit;git push;git -C * commit;git -C * push'
  DEBT_FRAG='gh[[:space:]]+(pr[[:space:]]+merge|issue[[:space:]]+(create|edit|close|reopen))([[:space:]]|$)'
  DEBT_WORDS='gh pr merge;gh issue create;gh issue edit;gh issue close;gh issue reopen'

  V='gh pr merge 12'
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# arm_with <lib> <frag> <words> <text>: source <lib> in a fresh shell, ask it
# the arming question, and print one line carrying every result variable.
arm_with() {
  run bash -c '
    . "$1" || exit 9
    if gaia_verb_armed "$2" "$3" "$4"; then v=armed; else v=not-armed; fi
    if [ "${#GAIA_VERB_ARM_VIEW}" -eq "${#4}" ]; then lm=yes; else lm=no; fi
    printf "verdict=%s kind=%s sup=%s lenmatch=%s vlen=%s tlen=%s\n" \
      "$v" "${GAIA_VERB_ARM_KIND:-empty}" "$GAIA_VERB_ARM_SUPPRESSED" \
      "$lm" "${#GAIA_VERB_ARM_VIEW}" "${#4}"
  ' _ "$1" "$2" "$3" "$4"
}

arm() { arm_with "$LIB" "$1" "$2" "$3"; }

# match_of <frag> <words> <text>: print the deciding match array, one element
# per line, so a test can assert on group numbering.
match_of() {
  run bash -c '
    . "$1" || exit 9
    if gaia_verb_armed "$2" "$3" "$4"; then
      n=${#GAIA_VERB_ARM_MATCH[@]}
      i=0
      while [ "$i" -lt "$n" ]; do
        printf "m[%s]=[%s]\n" "$i" "${GAIA_VERB_ARM_MATCH[$i]}"
        i=$(( i + 1 ))
      done
      printf "count=%s kind=%s\n" "$n" "$GAIA_VERB_ARM_KIND"
    else
      printf "count=%s kind=none\n" "${#GAIA_VERB_ARM_MATCH[@]}"
    fi
  ' _ "$LIB" "$1" "$2" "$3"
}

assert_armed()     { grep -qF "verdict=armed " <<<"$output" || return 1; }
assert_not_armed() { grep -qF "verdict=not-armed " <<<"$output" || return 1; }
assert_kind()      { grep -qF "kind=$1 " <<<"$output" || return 1; }
assert_sup()       { grep -qF "sup=$1 " <<<"$output" || return 1; }
assert_len_ok()    { grep -qF "lenmatch=yes " <<<"$output" || return 1; }

# lead_re_admits <words-spec> <text>: build pass 3's pre-filter for
# <words-spec> and print whether it admits <text>, one of `admits`, `rejects`,
# or `no-filter` for the arm that declines to build one at all.
#
# It reads the FILTER rather than the arming verdict, and that is the whole
# reason it exists. Arming for a text whose first word is not the verb's is
# decided by the word compare whatever the filter does, so a test that asserts
# only `not-armed` observes nothing about the filter and stays green on one
# widened to a single character per word.
lead_re_admits() {
  run bash -c '
    . "$1" || exit 9
    _gaia_va_build_lead_re "$2"
    if [ -z "$_gaia_va_lead_re" ]; then printf "no-filter\n"; exit 0; fi
    if [[ "$3" =~ $_gaia_va_lead_re ]]; then printf "admits\n"; else printf "rejects\n"; fi
  ' _ "$LIB" "$1" "$2"
}

# mk_run <n> <char>: a run of exactly <n> copies of <char>, from a doubling
# cache so a 16KB fixture costs a handful of concatenations.
mk_run() {
  local n="$1" p="$2"
  while [ "${#p}" -lt "$n" ]; do p="$p$p"; done
  printf '%s' "${p:0:$n}"
}

# parity <frag> <words> <invocation>: the invocation arms at command start and
# after each of the five separators. Every one of these is true before the data
# proof exists as well as after, which is the point of asserting them.
parity() {
  local frag="$1" words="$2" inv="$3" sep
  arm "$frag" "$words" "$inv"
  assert_armed || return 1
  for sep in '&&' ';' '||' '|'; do
    arm "$frag" "$words" "echo x $sep $inv"
    assert_armed || return 1
  done
  arm "$frag" "$words" "echo x$NL$inv"
  assert_armed || return 1
  true
}

# ---------------------------------------------------------------------------
# Arming parity: no spelling that arms today stops arming.
# ---------------------------------------------------------------------------

@test "the merge fragment arms at command start and after every separator" {
  parity "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr merge 12'
}

@test "the pull-request-creation fragment arms at command start and after every separator" {
  parity "$CREATE_FRAG" "$CREATE_WORDS" 'gh pr create --fill'
}

@test "the tail-capturing creation fragment arms at command start and after every separator" {
  parity "$CREATE_TAIL_FRAG" "$CREATE_WORDS" 'gh pr create --fill'
}

@test "the git-operation fragment arms at command start and after every separator" {
  parity "$GIT_FRAG" "$GIT_WORDS" 'git commit -m subject'
  parity "$GIT_FRAG" "$GIT_WORDS" 'git -C /some/path push origin main'
}

@test "the debt-sentinel fragment arms at command start and after every separator" {
  parity "$DEBT_FRAG" "$DEBT_WORDS" 'gh issue create --title subject'
  parity "$DEBT_FRAG" "$DEBT_WORDS" 'gh pr merge 12'
}

# ---------------------------------------------------------------------------
# Substitution openers: a verb inside `$( )`, a backtick, `<( )`, `>( )`, zsh's
# `=( )`, or bash 5.3's `${ ...; }` and `${| ...; }` is run by the shell, so it
# arms exactly as a verb after a separator does.
# ---------------------------------------------------------------------------

# opener_pair <frag> <words> <invocation>: the invocation arms after each
# opener, bare and inside double quotes, and the same text with the opener's
# substitution character removed does not. The twin is what makes each case
# discriminate: without it, a text that armed for some other reason would pass.
opener_pair() {
  local frag="$1" words="$2" inv="$3" op
  for op in '$(' '`' '<(' '>(' '=(' '${ ' '${|'; do
    arm "$frag" "$words" "echo x ${op}${inv}"
    assert_armed || return 1
    assert_kind sep || return 1
    arm "$frag" "$words" "echo \"${op}${inv}\""
    assert_armed || return 1
    arm "$frag" "$words" "echo x ${op} ${inv}"
    assert_armed || return 1
  done
  # The twins: `(` or `{` alone opens no substitution here, and a bare word
  # ahead of the verb is an argument.
  arm "$frag" "$words" "echo x (${inv}"
  assert_not_armed || return 1
  arm "$frag" "$words" "echo x {${inv}"
  assert_not_armed || return 1
  arm "$frag" "$words" "echo x ${inv}"
  assert_not_armed || return 1
  true
}

@test "the merge fragment arms after every substitution opener" {
  opener_pair "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr merge 12 --squash)'
}

@test "the pull-request-creation fragment arms after every substitution opener" {
  opener_pair "$CREATE_FRAG" "$CREATE_WORDS" 'gh pr create --fill)'
}

@test "the tail-capturing creation fragment arms after every substitution opener" {
  opener_pair "$CREATE_TAIL_FRAG" "$CREATE_WORDS" 'gh pr create --fill)'
}

@test "the git-operation fragment arms after every substitution opener" {
  opener_pair "$GIT_FRAG" "$GIT_WORDS" 'git commit -m subject)'
  opener_pair "$GIT_FRAG" "$GIT_WORDS" 'git -C /some/path push origin main)'
}

@test "the debt-sentinel fragment arms after every substitution opener" {
  opener_pair "$DEBT_FRAG" "$DEBT_WORDS" 'gh issue create --title subject)'
  opener_pair "$DEBT_FRAG" "$DEBT_WORDS" 'gh pr merge 12 --squash)'
}

@test "a substitution opener is the separator group, so the fragment's groups still start at 2" {
  match_of "$MERGE_FRAG" "$MERGE_WORDS" 'echo "$(gh pr merge 12 --squash)"'
  grep -qF "kind=sep" <<<"$output" || return 1
  grep -qF "count=3" <<<"$output" || return 1
  grep -qF 'm[1]=[$(]' <<<"$output" || return 1
  grep -qF "m[2]=[ ]" <<<"$output" || return 1

  match_of "$CREATE_TAIL_FRAG" "$CREATE_WORDS" 'echo `gh pr create --fill`'
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
  local bt='`'
  arm "$MERGE_FRAG" "$MERGE_WORDS" "gh pr comment 5 --body 'see ${bt}gh pr merge 30 --squash${bt}'"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "gh pr comment 5 --body \"see ${bt}gh pr merge 30 --squash${bt}\""
  assert_armed || return 1
  assert_kind sep || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo 'x \$(gh pr merge 12)'"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"x \$(gh pr merge 12)\""
  assert_armed || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo 'x <(gh pr merge 12)'"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo x <(gh pr merge 12)"
  assert_armed
}

@test "an apostrophe inside double quotes opens no span, so the opener after it arms" {
  local bt='`'
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"it's ${bt}gh pr merge 12${bt}\""
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo 'it is ${bt}gh pr merge 12${bt}'"
  assert_not_armed
}

@test "single quotes inside a substitution inside double quotes are real quotes again" {
  local bt='`'
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(printf '%s' '${bt}gh pr merge 12${bt}')\""
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(printf '%s' ${bt}gh pr merge 12${bt})\""
  assert_armed
}

@test "a backslash-escaped opener arms nothing, and its unescaped twin arms" {
  local bt='`'
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \\${bt}gh pr merge 12\\${bt}"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo ${bt}gh pr merge 12${bt}"
  assert_armed || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\\\$(gh pr merge 12)\""
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(gh pr merge 12)\""
  assert_armed
}

@test "a quoted-delimiter heredoc read by cat inside a substitution arms nothing, for each body-carrying command" {
  local bt='`' body cmd
  body="See ${bt}gh pr merge 30 --squash${bt} for the merge.${NL}And a \$(gh pr merge 31) too.${NL}EOF${NL})\""
  for cmd in 'gh pr create --title t --body' 'gh issue create --title t --body' 'git commit -m'; do
    arm "$MERGE_FRAG" "$MERGE_WORDS" "$cmd \"\$(cat <<'EOF'${NL}${body}"
    assert_not_armed || return 1
    arm "$MERGE_FRAG" "$MERGE_WORDS" "$cmd \"\$(cat <<\"EOF\"${NL}${body}"
    assert_not_armed || return 1
    arm "$MERGE_FRAG" "$MERGE_WORDS" "$cmd \"\$(cat <<\\EOF${NL}${body}"
    assert_not_armed || return 1
    # The unquoted-delimiter twin runs the substitutions in its body.
    arm "$MERGE_FRAG" "$MERGE_WORDS" "$cmd \"\$(cat <<EOF${NL}${body}"
    assert_armed || return 1
  done
  true
}

@test "a quoted-delimiter heredoc read by anything but a bare cat or tee keeps its openers live" {
  local bt='`' body
  body="${bt}gh pr merge 30${bt}${NL}EOF${NL})\""
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\"\$(cat <<'EOF'${NL}${body}"
  assert_not_armed || return 1
  # An interpreter reads the body as a script.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\"\$(bash <<'EOF'${NL}${body}"
  assert_armed || return 1
  # cat's output piped into an interpreter on the opener line.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\"\$(cat <<'EOF' | sh${NL}${body}"
  assert_armed || return 1
  # A process substitution hands the body to whatever reads it as a file.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "bash <(cat <<'EOF'${NL}${bt}gh pr merge 30${bt}${NL}EOF${NL})"
  assert_armed || return 1
  # Two heredocs on one line are not modelled.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\"\$(cat <<'EOF' <<'EOG'${NL}a${NL}EOF${NL}${bt}gh pr merge 30${bt}${NL}EOG${NL})\""
  assert_armed
}

@test "a dead opener ahead of a live one still arms on the live one" {
  local bt='`'
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo '${bt}gh pr merge 1${bt}'; x=${bt}gh pr merge 2${bt}"
  assert_armed || return 1
  assert_kind sep || return 1
  match_of "$MERGE_FRAG" "$MERGE_WORDS" "echo '\$(gh pr merge 1)'; x=\"\$(gh pr merge 2 --squash)\""
  grep -qF 'kind=sep' <<<"$output" || return 1
  grep -qF 'count=3' <<<"$output" || return 1
  grep -qF 'm[1]=[$(]' <<<"$output" || return 1
  grep -qF 'm[2]=[ ]' <<<"$output" || return 1
  true
}

@test "a text the liveness scan cannot model keeps every opener live" {
  local bt='`'
  # Unterminated single quote.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo 'x ${bt}gh pr merge 12${bt}"
  assert_armed || return 1
  # A case arm's bare `)` inside a substitution.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\$(case a in a) echo '${bt}gh pr merge 12${bt}';; esac)"
  assert_armed || return 1
  # A dollar-quoted word.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \$'a' '${bt}gh pr merge 12${bt}'"
  assert_armed || return 1
  # The terminated, case-free, plainly quoted twin is modelled.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo 'x ${bt}gh pr merge 12${bt}'"
  assert_not_armed
}

@test "inside backticks a backslash-escaped opener is live, and the same escape at top level is not" {
  local bt='`'
  # The shell strips the backslash from \$ inside backticks before parsing the
  # inner command, so each of these runs the merge.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=${bt}echo \\\$(gh pr merge 1)${bt}"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=${bt}echo \"\\\$(gh pr merge 1)\"${bt}"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"${bt}echo \\\$(gh pr merge 1)${bt}\""
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \\\$(gh pr merge 1)"
  assert_not_armed
}

@test "under backticks a backtick inside quotes ends the substitution for bash, so the scan stops" {
  local bt='`'
  # bash closes the outer backquote at the quoted backtick, leaving the
  # substitution after it live.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo ${bt}echo 'a${bt} \$(gh pr merge 1) ${bt}'${bt}"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo ${bt}echo \"a${bt} \$(gh pr merge 1) ${bt}\"${bt}"
  assert_armed || return 1
  # The same quoted text outside backticks is one quoted span.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo 'a${bt} \$(gh pr merge 1) ${bt}'"
  assert_not_armed
}

@test "an ampersand or pipe completing a redirection does not start a new command for the heredoc owner" {
  local body="echo \$(gh pr merge 1)${NL}EOF"
  arm "$MERGE_FRAG" "$MERGE_WORDS" "bash -s >& cat <<'EOF'${NL}${body}"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\$(bash -s >&cat <<'EOF'${NL}${body}${NL})"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\$(sh >| cat <<'EOF'${NL}${body}${NL})"
  assert_armed || return 1
  # A bare cat owning the same body is still data.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\$(cat <<'EOF'${NL}${body}${NL})"
  assert_not_armed
}

@test "a body inside a substitution stays live when bash 3.2's paren matcher would close the substitution in it" {
  local bt='`'
  # bash 3.2 ends the substitution at the body's first unmatched `)`.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(cat <<'EOF'${NL})\$(gh pr merge 1)${NL}EOF${NL})\""
  assert_armed || return 1
  # Its matcher honours quotes, so a quoted paren does not balance one.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(cat <<'EOF'${NL}a '(' b ) \$(gh pr merge 1)${NL}EOF${NL})\""
  assert_armed || return 1
  # Balanced parentheses and a backticked citation stay data.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(cat <<'EOF'${NL}See (below) ${bt}gh pr merge 1${bt}.${NL}EOF${NL})\""
  assert_not_armed || return 1
  # An apostrophe nothing later can close is a 3.2 syntax error, so nothing
  # runs, and the body stays data.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "gh pr create --body \"\$(cat <<'EOF'${NL}It's ${bt}gh pr merge 1${bt}.${NL}EOF${NL})\""
  assert_not_armed || return 1
  # A dollar-quoted span honours backslash escapes, so its escaped apostrophe
  # does not end it and the paren after it closes the substitution.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"A\$(cat <<'EOF'${NL}\$'\\'x' ) \$(gh pr merge 1) '${NL}EOF${NL})B\""
  assert_armed || return 1
  # Without the dollar, or with it escaped, the same span is plain quoting.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"A\$(cat <<'EOF'${NL}'\\'x' ) \$(gh pr merge 1) '${NL}EOF${NL})B\""
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"A\$(cat <<'EOF'${NL}\\\$'\\'x' ) \$(gh pr merge 1) '${NL}EOF${NL})B\""
  assert_not_armed || return 1
  # The same apostrophe with a later one to pair with is not.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\"\$(cat <<'EOF'${NL}It's ${bt}gh pr merge 1${bt}.${NL}EOF${NL})\"; echo 'y'"
  assert_armed
}

@test "bash 3.2's matcher starts at the substitution's opener, so a paren before the body can close it first" {
  local tail="cat <<'B'${NL}\$(gh pr merge 1)${NL}B${NL})\""
  # An unmatched paren in an earlier, live heredoc body.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(tr a b <<'A'${NL})${NL}A${NL}${tail}"
  assert_armed || return 1
  # One in a comment, which the matcher reads as text.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(# a )${NL}${tail}"
  assert_armed || return 1
  # One in a delimiter line, unquoted to the matcher.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(cat <<'E)'${NL}x${NL}E)${NL}${tail}"
  assert_armed || return 1
  # Nothing ahead of the body in the substitution: still data.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"\$(${tail}"
  assert_not_armed
}

@test "a hash after a subshell's closing parenthesis opens a comment the scan honours" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "(true)#it's${NL}x=\$(gh pr merge 1) # it's"
  assert_armed || return 1
  # After a substitution's closing parenthesis the hash continues the word.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \$(true)#x '\$(gh pr merge 1)'"
  assert_not_armed
}

@test "a heredoc operator inside parentheses is not modelled, so its openers stay live" {
  local bt='`'
  # Arithmetic reads 1<<EOF as a shift, not a heredoc.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "(( y = 1<<EOF ))${NL}echo 'a${NL}EOF${NL}' ; z=\$(gh pr merge 1) # '"
  assert_armed || return 1
  # A subshell's output can feed an interpreter.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "(cat <<'EOF'${NL}${bt}gh pr merge 1${bt}${NL}EOF${NL}) | bash"
  assert_armed || return 1
  # The same body directly in a command substitution is still modelled.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "x=\"\$(cat <<'EOF'${NL}${bt}gh pr merge 1${bt}${NL}EOF${NL})\""
  assert_not_armed
}

@test "an apostrophe in a comment opens no span that could hide a later live opener" {
  local bt='`'
  arm "$MERGE_FRAG" "$MERGE_WORDS" "# don't${NL}echo ${bt}gh pr merge 12${bt}"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo don't ${bt}gh pr merge 12${bt}'"
  assert_not_armed
}

@test "the tail-capturing fragment recovers its real tail by length when a dead opener sits in it" {
  # The consumer's own recovery: slice the text by the suffix and tail lengths
  # the view's match reports. The view masks the dead opener, so the captured
  # group differs from the real bytes and only the slice returns them.
  run bash -c '
    . "$1" || exit 9
    cmd=$2
    gaia_verb_armed "$3" "gh pr create" "$cmd" || { echo not-armed; exit 0; }
    t="${GAIA_VERB_ARM_MATCH[3]-}"
    s="${GAIA_VERB_ARM_MATCH[4]-}"
    start=$(( ${#cmd} - ${#s} - ${#t} ))
    printf "kind=%s\n" "$GAIA_VERB_ARM_KIND"
    printf "captured=[%s]\n" "$t"
    printf "real=[%s]\n" "${cmd:start:${#t}}"
  ' _ "$LIB" "x=\"\$(gh pr create --title 'x \$(y)' --fill)\"" "$CREATE_TAIL_FRAG"
  grep -qF 'kind=sep' <<<"$output" || return 1
  grep -qF "real=[--title 'x \$(y)' --fill)\"]" <<<"$output" || return 1
  grep -qF "captured=[--title 'x \$(y)' --fill)\"]" <<<"$output" && return 1
  true
}

# ---------------------------------------------------------------------------
# The data proof
# ---------------------------------------------------------------------------

@test "a heredoc body written to a file by cat does not arm, and the same payload without the opener does" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$V${NL}EOF"
  assert_not_armed || return 1
  assert_sup 1 || return 1
  assert_len_ok || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "$V${NL}EOF"
  assert_armed
}

@test "tee, tee -a and an appending redirect prove the same thing cat does" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "tee /tmp/f <<EOF$NL$V${NL}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "tee -a /tmp/f <<EOF$NL$V${NL}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat >> /tmp/f <<EOF$NL$V${NL}EOF"
  assert_not_armed
}

@test "the body starts after the opener line's newline, so a verb still on the opener line arms" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF && $V${NL}body${NL}EOF"
  assert_armed || return 1
  # The body was masked even so; the arm comes from the opener line itself.
  assert_sup 1 || return 1
  assert_kind sep
}

@test "a heredoc fed to an interpreter or a remote shell arms in every spelling" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat <<EOF | bash$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "bash <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "ssh host <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "\$RUNNER <<EOF$NL$V${NL}EOF"
  assert_armed
}

@test "a heredoc belonging to a second command on the opener line keeps the match" {
  # Condition 6. The command word at the line's start and the redirect on it
  # both belong to `cat`, while the heredoc belongs to the command after the
  # separator, and that is the one the shell hands the body to. Reading the
  # line as a whole cannot tell the two apart, so without the pre-operator
  # scan each of these masks a merge the shell really runs.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f && bash <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f ; bash <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f & bash <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "tee /tmp/f || sh <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f && ssh host <<EOF$NL$V${NL}EOF"
  assert_armed
}

@test "a word between the redirect and the operator is an operand, so the body stays data" {
  # The other side of condition 6, and the reason it scans for separators
  # rather than for a second word: here `bash` is an operand of `cat`, the
  # heredoc is still cat's, and the shell writes the body to the file. A rule
  # that rejected any word before the operator would arm this and undo the
  # suppression the whitelist exists to grant.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f bash <<EOF$NL$V${NL}EOF"
  assert_not_armed || return 1
  assert_sup 1 || return 1
  assert_len_ok
}

@test "an expansion or a backtick anywhere on the opener line keeps the match" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > \"\$(mktemp)\" <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > f\${SUFFIX} <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > \$OUT <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > \`mktemp\` <<EOF$NL$V${NL}EOF"
  assert_armed
}

@test "output going anywhere but a file keeps the match" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat <<EOF | wc -l$NL$V${NL}EOF"
  assert_armed || return 1
  # No redirect and no file operand at all: the body reaches stdout, which the
  # whitelist does not accept as a file.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat <<EOF$NL$V${NL}EOF"
  assert_armed
}

@test "the <<- form suppresses under a tab-indented delimiter and keeps the match when the delimiter is unreachable" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<-EOF$NL$V$NL${TAB}EOF"
  assert_not_armed || return 1
  assert_len_ok || return 1
  # Spaces are not what the dash strips, so this delimiter line never closes
  # the heredoc and the walk abandons suppression.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<-EOF$NL$V$NL    EOF"
  assert_armed
}

@test "a quoted or backslash-escaped delimiter is read the same as a bare one" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<'EOF'$NL$V${NL}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<\"EOF\"$NL$V${NL}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<\\EOF$NL$V${NL}EOF"
  assert_not_armed
}

@test "a substitution in an unquoted-delimiter body arms, and the quoted-delimiter twin is data" {
  # The shell runs `$( )` and backticks inside a heredoc body whose delimiter
  # is unquoted, so that body is not data however the opener line reads. A
  # quoted or escaped delimiter turns substitution off, which is what makes
  # the twin data.
  local sub
  for sub in "\$($V --squash)" "\`$V --squash\`" "x \$( $V --squash)" \
             "\${ $V --squash; }" "\${| $V --squash; }"; do
    arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$sub${NL}EOF"
    assert_armed || return 1
    arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<-EOF$NL$sub$NL${TAB}EOF"
    assert_armed || return 1
    arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<'EOF'$NL$sub${NL}EOF"
    assert_not_armed || return 1
    arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<\"EOF\"$NL$sub${NL}EOF"
    assert_not_armed || return 1
    arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<\\EOF$NL$sub${NL}EOF"
    assert_not_armed || return 1
  done
  # A plain parameter expansion runs nothing, so it leaves the body data.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL\$HOME$NL$V${NL}EOF"
  assert_not_armed
}

@test "an apostrophe in a heredoc body does not open a span the walk then loses" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF${NL}do not merge${NL}$V${NL}EOF"
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF${NL}don't merge${NL}$V${NL}EOF"
  assert_not_armed
}

# ---------------------------------------------------------------------------
# Abstention, whole-input
# ---------------------------------------------------------------------------

@test "an unterminated single quote abandons suppression, and its terminated twin does not" {
  local base="cat > /tmp/f <<EOF$NL$V${NL}EOF${NL}echo "
  arm "$MERGE_FRAG" "$MERGE_WORDS" "$base'"
  assert_armed || return 1
  assert_sup 0 || return 1
  assert_len_ok || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "$base''"
  assert_not_armed
}

@test "an unterminated double quote abandons suppression, and its terminated twin does not" {
  local base="cat > /tmp/f <<EOF$NL$V${NL}EOF${NL}echo "
  arm "$MERGE_FRAG" "$MERGE_WORDS" "$base\""
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "$base\"\""
  assert_not_armed
}

@test "a heredoc whose delimiter never appears abandons suppression, and its reachable twin does not" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<NOPE$NL$V${NL}EOF"
  assert_armed || return 1
  assert_sup 0 || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$V${NL}EOF"
  assert_not_armed
}

@test "a dollar-quoted word abandons suppression, and the same payload without one does not" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$V${NL}EOF${NL}echo \$'x'"
  assert_armed || return 1
  assert_sup 0 || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$V${NL}EOF${NL}echo x"
  assert_not_armed
}

@test "a payload at the bound is suppressed and the same payload past it is not" {
  local head="cat > /tmp/f <<EOF$NL$V$NL"
  local tail="${NL}EOF"
  local fill=$(( 16384 - ${#head} - ${#tail} ))

  local under
  under="$head$(mk_run "$fill" y)$tail"
  [ "${#under}" -eq 16384 ] || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "$under"
  assert_not_armed || return 1
  assert_sup 1 || return 1

  local over
  over="$head$(mk_run $(( fill + 10 )) y)$tail"
  [ "${#over}" -eq 16394 ] || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "$over"
  assert_armed || return 1
  assert_sup 0 || return 1
  assert_len_ok
}

@test "a text too dense to walk cheaply abandons suppression, and its sparse twin does not" {
  # Same length, same structure, same heredoc; only the density of the
  # characters the walk has to step past differs.
  local dense sparse
  dense="cat > /tmp/f <<EOF && echo $(mk_run 15000 "'ab' ")$NL$V${NL}EOF"
  sparse="cat > /tmp/f <<EOF && echo $(mk_run 15000 'xxxxxx')$NL$V${NL}EOF"
  [ "${#dense}" -eq "${#sparse}" ] || return 1
  [ "${#dense}" -le 16384 ] || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "$dense"
  assert_armed || return 1
  assert_sup 0 || return 1
  assert_len_ok || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "$sparse"
  assert_not_armed || return 1
  assert_sup 1
}

# ---------------------------------------------------------------------------
# Never suppressed
# ---------------------------------------------------------------------------

@test "a quoted string carrying a separator before the verb still arms" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"finish the audit && $V\""
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo \"x; $V\""
  assert_armed
}

@test "a mid-word hash still arms and a verb after a word-initial hash on its own line does not" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "git checkout fix#12 && $V"
  assert_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo hi$NL# $V"
  assert_not_armed
}

# ---------------------------------------------------------------------------
# The tokenizer arm
# ---------------------------------------------------------------------------

@test "a quoted verb in the first command arms through the tokenizer" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr "merge" 12'
  assert_armed || return 1
  assert_kind first-command || return 1
  assert_sup 0
}

@test "a quoted verb that is not the first command arms nothing" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'echo x && gh pr "merge" 12'
  assert_not_armed
}

@test "a dollar-quoted verb arms nothing" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "\$'gh' pr merge 12"
  assert_not_armed
}

@test "the tokenizer reads a git -C invocation through the wildcard word" {
  arm "$GIT_FRAG" "$GIT_WORDS" 'git -C /some/path "commit" -m subject'
  assert_armed || return 1
  assert_kind first-command
}

@test "an empty words spec turns the tokenizer arm off" {
  arm "$MERGE_FRAG" "" 'gh pr "merge" 12'
  assert_not_armed || return 1
  # The text arm is untouched by an empty spec.
  arm "$MERGE_FRAG" "" 'gh pr merge 12'
  assert_armed
}

@test "the tokenizer's bounded prefix can create an arm the full text does not carry" {
  # `merge` ends exactly at the 2048-character bound, so the truncated prefix
  # reads a word the whole text never spells.
  local pad
  pad="$(mk_run 2038 ' ')"
  local armed_text="gh pr${pad}mergeZZZZZZZZZZ"
  [ "${#armed_text}" -eq 2058 ] || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" "$armed_text"
  assert_armed || return 1
  assert_kind first-command || return 1

  # One character shorter, the cut lands inside the word instead.
  local quiet_text="gh pr${pad:1}mergeZZZZZZZZZZ"
  arm "$MERGE_FRAG" "$MERGE_WORDS" "$quiet_text"
  assert_not_armed
}

# ---------------------------------------------------------------------------
# The view contract
# ---------------------------------------------------------------------------

@test "the view is the same length as the text when suppressed, when the identity, and when over the bound" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$V${NL}EOF"
  assert_len_ok || return 1
  assert_sup 1 || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo x && $V"
  assert_len_ok || return 1
  assert_sup 0 || return 1

  local head="cat > /tmp/f <<EOF$NL$V$NL"
  local tail="${NL}EOF"
  local over
  over="$head$(mk_run $(( 16384 - ${#head} - ${#tail} + 10 )) y)$tail"
  arm "$MERGE_FRAG" "$MERGE_WORDS" "$over"
  assert_len_ok || return 1
  assert_sup 0
}

@test "the view is the same length as a text whose final character is a newline" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$V${NL}EOF$NL"
  assert_not_armed || return 1
  assert_sup 1 || return 1
  assert_len_ok || return 1
  grep -qF "vlen=38 tlen=38" <<<"$output" || return 1
  true
}

@test "the suppressed flag is 1 exactly when the view differs from the text" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$V${NL}EOF"
  assert_sup 1 || return 1
  # Same shape, but the walk abstains, so nothing anywhere is suppressed.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<NOPE$NL$V${NL}EOF"
  assert_sup 0 || return 1
  # No heredoc at all.
  arm "$MERGE_FRAG" "$MERGE_WORDS" "echo x && $V"
  assert_sup 0
}

@test "the match array numbers the fragment's groups from 1 under start and from 2 under sep" {
  match_of "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr merge 12'
  grep -qF "kind=start" <<<"$output" || return 1
  grep -qF "count=2" <<<"$output" || return 1
  grep -qF "m[1]=[ ]" <<<"$output" || return 1

  match_of "$MERGE_FRAG" "$MERGE_WORDS" 'echo x && gh pr merge 12'
  grep -qF "kind=sep" <<<"$output" || return 1
  grep -qF "count=3" <<<"$output" || return 1
  grep -qF "m[1]=[&&]" <<<"$output" || return 1
  grep -qF "m[2]=[ ]" <<<"$output" || return 1
  true
}

@test "the tail-capturing fragment keeps its own group numbering under both patterns" {
  match_of "$CREATE_TAIL_FRAG" "$CREATE_WORDS" 'gh pr create --fill --base main'
  grep -qF "kind=start" <<<"$output" || return 1
  grep -qF "m[1]=[ ]" <<<"$output" || return 1
  grep -qF "m[2]=[--fill --base main]" <<<"$output" || return 1

  match_of "$CREATE_TAIL_FRAG" "$CREATE_WORDS" 'echo x && gh pr create --fill'
  grep -qF "kind=sep" <<<"$output" || return 1
  grep -qF "m[1]=[&&]" <<<"$output" || return 1
  grep -qF "m[2]=[ ]" <<<"$output" || return 1
  grep -qF "m[3]=[--fill]" <<<"$output" || return 1
  true
}

@test "the match array is empty when the tokenizer decides and when nothing arms" {
  match_of "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr "merge" 12'
  grep -qF "count=0 kind=first-command" <<<"$output" || return 1
  match_of "$MERGE_FRAG" "$MERGE_WORDS" 'echo hello'
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

  arm_with "$stage/lib/verb-arming.sh" "$MERGE_FRAG" "$MERGE_WORDS" \
    "cat > /tmp/f <<EOF$NL$V${NL}EOF"
  assert_armed || return 1
  assert_sup 0 || return 1
  assert_len_ok || return 1
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
  ' _ "$WALK" "cat > /tmp/f <<EOF${NL}gh pr merge 12${NL}EOF"
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
  ' _ "$LIB" "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr merge 12'
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
  ' _ "$LIB" "$MERGE_FRAG" "$MERGE_WORDS" 'gh issue list --state open'
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
  ' _ "$LIB" "$MERGE_FRAG" "$MERGE_WORDS" "cat > /tmp/f <<EOF$NL$V${NL}EOF"
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

# arm_staged <interpreter> <lib> <frag> <words> <text>: ask the arming question
# from a caller running errexit, exactly as the four errexit consumer hooks do.
# The errexit is the point of the harness: without it an unparseable lib merely
# returns non-zero and execution continues on every bash, so the class these
# cases cover cannot be expressed at all.
arm_staged() {
  local interp="$1" lib="$2" frag="$3" words="$4" text="$5"
  run "$interp" -c '
    set -euo pipefail
    . "$1" || exit 9
    if gaia_verb_armed "$2" "$3" "$4"; then v=armed; else v=not-armed; fi
    printf "verdict=%s kind=%s sup=%s\n" "$v" "${GAIA_VERB_ARM_KIND:-empty}" \
      "${GAIA_VERB_ARM_SUPPRESSED:-0}"
  ' _ "$lib" "$frag" "$words" "$text"
}

# Copies the real lib directory somewhere the test can corrupt, and prints the
# staged verb-arming.sh path.
stage_lib() {
  local stage="$BATS_TEST_TMPDIR/staged-$1"
  rm -rf "$stage"; mkdir -p "$stage"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$stage/lib"
  printf '%s' "$stage/lib/verb-arming.sh"
}

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

@test "control: a staged lib arms through the tokenizer under errexit on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local lib; lib="$(stage_lib tokctl)"
  arm_staged /bin/bash "$lib" "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr "merge" 12'
  [ "$status" -eq 0 ]
  assert_armed || return 1
  assert_kind first-command
}

@test "an unparseable repo-scope.sh degrades to not-armed instead of denying, on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local lib; lib="$(stage_lib tokbad)"
  write_conflicted_lib "$(dirname "$lib")/repo-scope.sh"
  arm_staged /bin/bash "$lib" "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr "merge" 12'
  [ "$status" -eq 0 ]
  assert_not_armed
}

@test "control: a staged lib suppresses a heredoc body under errexit on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local lib; lib="$(stage_lib walkctl)"
  arm_staged /bin/bash "$lib" "$MERGE_FRAG" "$MERGE_WORDS" \
    "cat > /tmp/f <<EOF$NL$V${NL}EOF"
  [ "$status" -eq 0 ]
  assert_not_armed
}

@test "an unparseable verb-arming-walk.sh leaves the raw match standing instead of denying, on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local lib; lib="$(stage_lib walkbad)"
  write_conflicted_lib "$(dirname "$lib")/verb-arming-walk.sh"
  arm_staged /bin/bash "$lib" "$MERGE_FRAG" "$MERGE_WORDS" \
    "cat > /tmp/f <<EOF$NL$V${NL}EOF"
  [ "$status" -eq 0 ]
  # Same degrade the absent-walker case above gets: with no view to suppress
  # by, the raw match stands and the call arms.
  assert_armed || return 1
  assert_kind sep
}

# The load guard suspends errexit across the source and must put back exactly
# what it found. Several of this library's consumers deliberately run
# WITHOUT errexit -- audit-disposition-check.sh, audit-residual-shape-check.sh,
# pr-merge-audit-check.sh, worthiness-presence-check.sh, debt-sentinel-touch.sh,
# issue-claim-release.sh, distribution-preflight-check.sh and
# token-tally-review.sh -- and several are PreToolUse deny gates where a stray
# non-zero exit becomes a verdict. An unconditional `set -e` restore would arm
# errexit in every one of them, so this case pins the restore as conditional.
# It needs no interpreter pin: the leak it guards against is present on bash
# 3.2 and bash 5 alike.
@test "a load from a caller without errexit leaves errexit off" {
  local lib; lib="$(stage_lib noerrexit)"
  run bash -c '
    set -uo pipefail
    . "$1"
    gaia_verb_armed "$2" "$3" "$4" || true
    case $- in *e*) printf "errexit=ON\n" ;; *) printf "errexit=OFF\n" ;; esac
    false
    printf "SURVIVED\n"
  ' _ "$lib" "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr "merge" 12'
  grep -qF "errexit=OFF" <<<"$output" || return 1
  grep -qF "SURVIVED" <<<"$output" || return 1
  true
}

# ---------------------------------------------------------------------------
# Command wrappers
# ---------------------------------------------------------------------------
#
# A command WRAPPER occupies the command-word slot, so the verb behind it is
# neither at the start of the text nor after a separator, and the scanned
# first-command words begin with the wrapper rather than with the verb. Before
# this was closed, every case below armed nothing, which on the apex merge gate
# meant a merge landing with no GAIA-Audit marker.
#
# The wrapper set is DERIVED from the table in lib/command-wrappers.sh through
# helpers/wrapper-table.sh, the same reader block-no-verify.bats uses, rather
# than restated here: a row added to the table is driven by both suites the
# moment it lands.

@test "every wrapper in the shared table exposes the verb to the arming decision" {
  local name operands read_n=0 rows
  rows=$(wrapper_table_rows)
  [ "$rows" -gt 0 ] || return 1
  while read -r name operands; do
    [ -n "$name" ] || continue
    read_n=$((read_n + 1))
    arm "$MERGE_FRAG" "$MERGE_WORDS" "$(wrapper_prefix "$name" "$operands") gh pr merge 12"
    assert_armed || return 1
    assert_kind first-command || return 1
  done <<<"$(wrapper_table)"
  [ "$read_n" -eq "$rows" ]
}

# The test above builds each invocation from the row it checks, so it proves
# the arming reads the TABLE and never that the table matches the WRAPPER.
# These are the hand-written real spellings: the two the issue named, plus the
# option and assignment forms a row would have to get right.
@test "a wrapper's own options and operands do not hide the verb from the arming decision" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'timeout 5 gh pr merge 1 --squash'
  assert_armed || return 1
  assert_kind first-command || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" 'timeout -k 30 5 gh pr merge 1 --squash'
  assert_armed || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" 'nice -n 5 gh pr merge 1'
  assert_armed || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" 'xargs -n 1 gh pr merge 1'
  assert_armed
}

@test "an assignment a wrapper carries does not hide the verb behind it" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'env GH_PAGER=cat gh pr merge 1 --squash'
  assert_armed || return 1
  assert_kind first-command
}

@test "a stacked wrapper chain does not hide the verb from the arming decision" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'nohup timeout 5 env GH_PAGER=cat gh pr merge 12'
  assert_armed || return 1
  assert_kind first-command
}

# The strip must not invent an arm. A wrapper running some other program is
# exactly the case a blind word-drop would misread.
@test "reading past a wrapper does not arm on a non-verb program behind it" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'env GH_PAGER=cat git status'
  assert_not_armed || return 1
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'timeout 5 ls -la'
  assert_not_armed
}

# The wrapper arm rides pass 3, which carries no view and no capture groups, so
# it must leave both result variables exactly where an unwrapped tokenizer arm
# leaves them. This is what keeps the one consumer that recovers real bytes by
# OFFSET (distribution-preflight-check.sh) safe: it reads a groupless arm as
# "no tail" and falls back to the default base, rather than slicing its own
# command text at an offset computed against a shorter, stripped one.
@test "a wrapper arm reports no groups and an unsuppressed identity view" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'timeout 5 gh pr merge 1 --squash'
  assert_armed || return 1
  assert_sup 0 || return 1
  assert_len_ok || return 1
  match_of "$MERGE_FRAG" "$MERGE_WORDS" 'timeout 5 gh pr merge 1 --squash'
  grep -qF "count=0 kind=first-command" <<<"$output"
}

# The pre-filter is widened to admit each wrapper's own lead, and this is the
# case that proves the widening did not swallow the filter whole. `echo` shares
# its first character with two wrappers and must still be turned away;
# verb-arming-cost.bats's non-matching payload is built on exactly that word,
# so a filter that admitted it would move that suite's budget rather than red.
#
# It asserts the FILTER, through `lead_re_admits`, because the arming verdict
# cannot see it: `echo` fails the word compare whatever the filter admits, so
# an `assert_not_armed`-only version of this test greens on the one-character
# alternation its own name forbids. The end-to-end verdict rides along at the
# end as a companion rather than as the claim.
@test "the pre-filter still turns away a word that only shares a wrapper's first character" {
  lead_re_admits "$MERGE_WORDS" 'echo gh pr merge 12'
  grep -qF "rejects" <<<"$output" || return 1

  # The second character is the discriminator, so both a wrapper's own lead and
  # the verb's must still get through. Without these, a filter narrowed to
  # nothing would satisfy the assertion above.
  lead_re_admits "$MERGE_WORDS" 'env gh pr merge 12'
  grep -qF "admits" <<<"$output" || return 1
  lead_re_admits "$MERGE_WORDS" 'timeout 5 gh pr merge 12'
  grep -qF "admits" <<<"$output" || return 1
  lead_re_admits "$MERGE_WORDS" 'gh pr merge 12'
  grep -qF "admits" <<<"$output" || return 1

  arm "$MERGE_FRAG" "$MERGE_WORDS" 'echo gh pr merge 12'
  assert_not_armed
}

# A wrapper AFTER a separator is the residual this change leaves open, and it
# is pinned rather than left to be rediscovered: closing it needs the wrapper
# alternation inside sep_re, which cannot be written without adding a capture
# group, and the group numbering is a published contract the tail-reading
# consumer depends on. Pass 3 reads the first command only, which is the same
# boundary the quoted-verb case already documents. Tracked as
# gaia-react/gaia#2205; this test is what flips when it closes.
@test "a wrapper after a separator is a known residual and arms nothing" {
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'git push && timeout 5 gh pr merge 1'
  assert_not_armed || return 1
  # The unwrapped spelling after the same separator still arms, so the case
  # above is the wrapper's doing and not the separator's.
  arm "$MERGE_FRAG" "$MERGE_WORDS" 'git push && gh pr merge 1'
  assert_armed
}

# Fail DIRECTION for a missing table. The library's stated convention is that a
# component it cannot load degrades to the answer it gave before that component
# existed, never to silence and never to a new refusal: an absent walker leaves
# the raw match standing. An absent wrapper table is the same shape -- it leaves
# the wrapper hole exactly where it was rather than opening a new one -- and it
# must not disturb the arms that never needed the table.
@test "an absent command-wrappers.sh degrades to the unwrapped answer" {
  local lib; lib="$(stage_lib nowrap)"
  rm -f "$(dirname "$lib")/command-wrappers.sh"
  arm_with "$lib" "$MERGE_FRAG" "$MERGE_WORDS" 'timeout 5 gh pr merge 1'
  assert_not_armed || return 1
  # Everything that never needed the table is untouched.
  arm_with "$lib" "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr merge 1'
  assert_armed || return 1
  arm_with "$lib" "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr "merge" 12'
  assert_armed || return 1
  assert_kind first-command
}

@test "an unparseable command-wrappers.sh degrades rather than denying" {
  local lib; lib="$(stage_lib wrapbad)"
  write_conflicted_lib "$(dirname "$lib")/command-wrappers.sh"
  arm_with "$lib" "$MERGE_FRAG" "$MERGE_WORDS" 'gh pr merge 1'
  [ "$status" -eq 0 ] || return 1
  assert_armed
}

# GAIA_COMMAND_WRAPPER_NAMES is a second spelling of the table's row set, kept
# because a `case` statement cannot be asked what it matches. This is what
# stops the two drifting. It compares the whole set both ways rather than
# checking containment in one direction, because each direction fails
# differently: a name the table lost leaves the pre-filter wider than it needs
# to be, and a row the list never gained leaves that wrapper turned away before
# the strip can run, which is the hole the strip exists to close.
@test "the wrapper name list and the wrapper table name the same set" {
  local from_table from_list rows read_n=0 name operands
  rows=$(wrapper_table_rows)
  [ "$rows" -gt 0 ] || return 1
  from_table=""
  while read -r name operands; do
    [ -n "$name" ] || continue
    read_n=$((read_n + 1))
    from_table="$from_table$name$NL"
  done <<<"$(wrapper_table)"
  # A parse that reads fewer rows than the table holds would otherwise compare
  # a short set against a short list and agree with itself.
  [ "$read_n" -eq "$rows" ] || return 1

  from_list=$(
    . "$WRAPPER_TABLE_FILE"
    for name in $GAIA_COMMAND_WRAPPER_NAMES; do printf '%s\n' "$name"; done
  )
  [ -n "$from_list" ] || return 1
  [ "$(printf '%s' "$from_table" | sort)" = "$(printf '%s\n' "$from_list" | sort)" ]
}
