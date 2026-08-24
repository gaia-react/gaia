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

  NL=$'\n'
  TAB=$'\t'

  # The five distinct verb fragments the eleven consumers carry, verbatim.
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
