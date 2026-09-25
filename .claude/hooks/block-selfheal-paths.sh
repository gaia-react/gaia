#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit + Bash hook: deny a Code Audit Team
# member's attempt to repair a path outside its self-heal boundary.
#
# This is the LOCAL producer's enforcement point. The CI producer's
# equivalent is the "Commit and push self-heal" step's push gate in
# .github/workflows/code-review-audit.yml, which reads the whole self-heal
# diff at push time. Phase 1 of this SPEC makes `local` the default
# resolved mode, and the CI push gate binds only forks and the override
# label, so a local-mode member had no deterministic boundary at all until
# this hook. Both enforcement points source the SAME refusal set from
# .claude/hooks/lib/audit-selfheal-paths.sh; neither carries a second copy.
#
# THE GATE BINDS MEMBERS, NOT THE TREE. A PreToolUse payload carries
# `agent_type` only when the hook fires inside a subagent call; it is
# absent for the main session / orchestrator. This hook no-ops immediately
# whenever `agent_type` is absent or does not carry the `code-audit-`
# prefix, so the orchestrator (trusted by the SPEC's own design, and which
# this very plan's execution requires to repair .gaia/**, test/**, and
# .github/workflows/** on nearly every phase) is never touched. Only a
# dispatched Code Audit Team member (`code-audit-frontend`,
# `code-audit-github-workflows`, etc.) is bound, including advisory members:
# an advisory member returns a byte-identical tree anyway, so refusing it
# costs nothing, and a future self-healing member is bound the day it lands
# rather than the day someone remembers to add it.
#
# Membership is a NAME-PREFIX match, not a roster lookup: the hook fires on
# every edit in every session, so it stays off the classifier's parse path
# and carries no dependency on the roster's record contract. A member named
# off the `code-audit-` convention escapes this hook; that convention is
# already load-bearing in the roster glob, the machinery lists, and the
# release scrub's leak-check, so this adds no new coupling.
#
# HONEST ABOUT THE BASH VECTOR: this is a best-effort, defense-in-depth
# guard, not an airtight one, mirroring block-manifest-write.sh's own stated
# posture. Bash vectors are unbounded; this covers the well-known write
# shapes (output redirect in any of bash's spellings, tee, sed -i with or
# without a macOS '' backup suffix, sponge, cp/mv as destination including
# GNU -t) and no more; the redirect scan states its own limits where it is
# built. Anything else that writes (an interpreter's own file API, `dd of=`,
# `install`, `rsync`, `ln`, a `bash -c` or `eval` string) passes. CI's gate
# reads the whole diff at push time and cannot be evaded by the shape of the
# write; this hook reads one attempted edit at a time and can be. That
# asymmetry is real and accepted: under local mode a human watches every turn.
#
# The Bash branch also carries one EXECUTION-shape refusal, not a write
# shape: a dispatched member may not invoke
# .gaia/scripts/write-audit-remits.sh at all, since running it edits
# .claude/agents/code-audit-*.md and rotates every member's clearance
# digest. That literal lives here, not in the shared
# AUDIT_SELFHEAL_REFUSE_ERE, because that ERE is a path matcher the CI push
# gate applies to a diff, and a script invocation is not a path in a diff.
set -euo pipefail

payload=$(cat)

# jq-availability arm, the shape this hook originated and the whole PreToolUse
# layer now shares. What it buys, and the contract the literal satisfies, live
# in .claude/hooks/lib/jq-availability.sh.
#
# The literal is `code-audit-`, which a bound member's agent_type must contain.
# Its ABSENCE proves the payload carries no such agent_type and the call sits
# outside this gate's remit, so it is allowed exactly as a parsed non-member is.
# Its presence is not proof of membership -- an ordinary Bash command naming a
# member satisfies it too -- and that over-deny is the same safe direction the
# tokenizer below takes everywhere else.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-selfheal-paths.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the self-heal repair boundary (.claude/hooks/lib/audit-selfheal-paths.sh)' "$payload" - 'code-audit-'

# Cheapest possible filter first: the common case is "no agent_type at all"
# (the main session). Read it before anything else and exit before sourcing
# the refusal-set lib or resolving the repo root.
agent_type=$(jq -r '.agent_type // empty' <<<"$payload")
case "$agent_type" in
  code-audit-*) ;;
  *) exit 0 ;;
esac

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

# Source the refusal-set lib from THIS hook's own on-disk location, never
# cwd. A missing lib means the refusal set cannot be determined for a member
# that IS bound, so fail loudly and deny rather than silently allowing the
# edit through.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SELF_DIR/lib/audit-selfheal-paths.sh"
# Bracketed in `set +e` because errexit is armed above. Absence is not the only
# way this library can fail to define the refusal set: an unparseable copy (an
# unresolved merge conflict, a truncated write) abandons the shell AT the load,
# and that exit is 2 -- a deny carrying a raw syntax error instead of the crafted
# message below. Testing what the library DEFINES rather than whether the file
# exists routes both failures to the same fail-loud refusal.
#
# Unset first, so the test reads what the LOAD defined rather than what the
# environment happened to carry: this hook inherits its parent process's
# environment, and ANY ambient copy of this name there, however it arrived,
# would satisfy the guard after the load failed -- fail-open, in the one place
# this hook is written to fail loud.
unset AUDIT_SELFHEAL_REFUSE_ERE
set +e
# shellcheck source=/dev/null
[ -f "$LIB" ] && . "$LIB" 2>/dev/null
set -e
# Two causes, two messages. The load discards its own stderr, so a member that
# reads "unavailable", finds the file present, and has no parse error anywhere
# in its session is left with nothing to act on -- and an interrupted update is
# exactly the scenario this guard is built for.
if [ -z "${AUDIT_SELFHEAL_REFUSE_ERE:-}" ]; then
  if [ ! -f "$LIB" ]; then
    printf 'block-selfheal-paths.sh: refusal-set library unavailable: %s\n' "$LIB" >&2
    deny "BLOCKED: the self-heal repair-boundary library ($LIB) is unavailable, so this edit cannot be checked against it. Fail-loud, not fail-open -- restore the library before retrying."
  fi
  printf 'block-selfheal-paths.sh: refusal-set library present but defined nothing: %s\n' "$LIB" >&2
  deny "BLOCKED: the self-heal repair-boundary library ($LIB) is present but did not define the refusal set, so this edit cannot be checked against it. Run \`bash -n $LIB\` -- an unparseable copy (an unresolved merge conflict, a truncated write) is the usual cause. Fail-loud, not fail-open."
fi

# Repo root, resolved the same way .claude/hooks/lib/repo-scope.sh resolves
# the home repo (`git rev-parse --show-toplevel`), not a second way. The
# refusal set is repo-relative; an absolute `tool_input.file_path` (or a
# Bash-command absolute path) must be relativized against this before it is
# tested, or every check silently misses.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

MATCHED_PATH=""

# Strip one matching pair of surrounding quotes from a token, into SQ_OUT.
# Sets a variable rather than printing because a `$(...)` per call is a fork,
# and the write-shape arms call it once per argument word. The trailing-newline
# strip keeps the result identical to that `$(...)` form, which dropped them.
strip_quotes() {
  SQ_OUT=$1
  case "$SQ_OUT" in
    \"*\") SQ_OUT=${SQ_OUT#\"}; SQ_OUT=${SQ_OUT%\"} ;;
    \'*\') SQ_OUT=${SQ_OUT#\'}; SQ_OUT=${SQ_OUT%\'} ;;
  esac
  while [ "${SQ_OUT%$'\n'}" != "$SQ_OUT" ]; do SQ_OUT=${SQ_OUT%$'\n'}; done
}

# is_refused_path <token>: strip quotes and a leading ./, relativize an
# absolute token against REPO_ROOT when it resolves under it, then test the
# result against AUDIT_SELFHEAL_REFUSE_ERE. On a match, sets MATCHED_PATH to
# the relative path (so the caller can name it in the deny reason) and
# returns 0. An absolute token that does not resolve
# under REPO_ROOT is ambiguous (out-of-repo, or the root could not be
# resolved) and is left alone -- the safe direction is to allow.
is_refused_path() {
  local p rel
  strip_quotes "$1"
  p=${SQ_OUT#./}
  [ -n "$p" ] || return 1
  case "$p" in
    /*)
      if [ -n "$REPO_ROOT" ] && [ "${p#"$REPO_ROOT"/}" != "$p" ]; then
        rel="${p#"$REPO_ROOT"/}"
      else
        return 1
      fi
      ;;
    *) rel="$p" ;;
  esac
  [[ "$rel" =~ $AUDIT_SELFHEAL_REFUSE_ERE ]] || return 1
  MATCHED_PATH="$rel"
  return 0
}

deny_reason() {
  printf 'BLOCKED: self-heal may not edit %s -- off-limits to the repair boundary (tests, the CI pipeline and the rest of .github/, .gaia/ gate & roster machinery, instruction/convention surfaces, or root build config). This is a defect to report as a finding, not to repair. See .claude/hooks/lib/audit-selfheal-paths.sh.' "$1"
}

# scan_exec_positions <token>...: deny when the remit writer basename appears
# at an EXECUTION position in the given token stream. Denies or returns; never
# reports back, since `deny` exits.
#
# Called once per tokenization (see the Bash branch below). Every piece of
# state is `local`, so the two calls cannot leak boundary or interpreter state
# into each other.
scan_exec_positions() {
  local prev_sep=1 after_interp=0 cand exec_pos skip

  for cand in "$@"; do
    # strip_quotes, inlined: bash 3.2 copies the caller's positional list on
    # every function call, and this function holds one per token, so a call
    # here makes the scan quadratic in the token count. A token from
    # `read -a` holds no newline, so the newline strip is not needed.
    case "$cand" in
      \"*\") cand=${cand#\"}; cand=${cand%\"} ;;
      \'*\') cand=${cand#\'}; cand=${cand%\'} ;;
    esac

    exec_pos=0
    [ "$prev_sep" -eq 1 ] && exec_pos=1

    if [ "$after_interp" -eq 1 ]; then
      skip=0
      case "$cand" in
        -c) ;;
        -*) skip=1 ;;
      esac
      if [ "$skip" -eq 0 ]; then
        exec_pos=1
        after_interp=0
      fi
    fi

    if [ "$exec_pos" -eq 1 ]; then
      case "${cand##*/}" in
        write-audit-remits.sh)
          deny "BLOCKED: a dispatched Code Audit Team member may not run the remit writer (.gaia/scripts/write-audit-remits.sh). Regenerating a remit region rewrites every code-audit-*.md definition under .claude/agents/, which are audit-machinery paths: it rotates every member's content digest and invalidates every clearance marker on this PR. Reporting the remit drift as a finding is your only correct action here; repairing it is the orchestrator's, never a member's."
          ;;
      esac
      case "$cand" in
        bash | sh | zsh)
          after_interp=1
          ;;
      esac
    fi

    # Single characters, not `&&` / `||`: the separator padding has already
    # split every multi-character operator into adjacent single-character
    # tokens. `(` and `{` are openers rather than separators, but they mark
    # the same thing this flag tracks: the next token starts a command. `{`
    # earns its place here without any padding of its own, since a real brace
    # group always presents it as a separate word already. In the unpadded
    # stream these arms simply never match a lone bracket, which is correct.
    case "$cand" in
      ';' | '&' | '|' | '(' | '{') prev_sep=1 ;;
      *) prev_sep=0 ;;
    esac
  done
}

tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

case "$tool_name" in
  Edit | Write | MultiEdit)
    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
    [[ -n "$file_path" ]] || exit 0
    is_refused_path "$file_path" && deny "$(deny_reason "$MATCHED_PATH")"
    exit 0
    ;;

  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
    [[ -n "$cmd" ]] || exit 0

    # `read` stops at the first newline, so a multi-line payload would leave
    # everything past line 1 untokenized and invisible to every scan below.
    # Fold the payload onto one line ahead of every `read -r -a` call. The two newline kinds are not interchangeable: a
    # backslash-newline is a line CONTINUATION and folds to a plain space,
    # while a bare newline is a command separator and folds to `;`. Folding a
    # continuation to a separator instead would break a continued
    # `cp` / `sed` / `tee` argument scan at the line boundary and allow the
    # very write it is meant to deny. The fold is line-oriented and knows
    # nothing about heredocs, so a heredoc BODY folds into command position
    # too and can false-deny on data rather than on a command. That is an
    # accepted over-deny, the safe direction here; narrowing it would mean
    # tracking heredoc regions, not relaxing the fold.
    cmd="${cmd//\\$'\n'/ }"

    # The tee/sponge, sed and cp/mv arms stop their argument scan at a
    # separator, and a separator glued to a neighbour (`x.sh;`, `a&&b`) is
    # not its own token in the unpadded `toks`, so a scan over `toks` runs on
    # into the NEXT command and reads its paths as this command's write
    # target: a false deny on `sed -i ... /tmp/x.sh; bash <refused>`, and an
    # under-deny on `cp /tmp/a <refused>;echo`, where the destination is `echo`.
    # These arms get a third tokenization, `wtoks`, rather than the blindly
    # padded `stoks` below: a quoted sed script routinely carries `;`, `&`
    # and `|` (`s/foo/&bar/`, `s/a/b/;s/c/d/`), and padding those ends the
    # scan inside the script, before the target, which ALLOWS the write. The
    # union trick the execution scan uses is unavailable, because the union
    # keeps the false deny these arms must drop. So pad `;` `|` `&` only
    # outside single and double quotes, keep a backslash-escaped character
    # literal (`s/a/b/\;s/c/d/` stays one word), and leave an `&` inside a
    # redirection (`>&`, `<&`, `&>`) unpadded so `2>&1` stays one word, and a
    # `|` after `>` unpadded so the clobber operator `>|` stays one word.
    # ANSI-C quoting (`$'...'`) is its own state: a backslash there escapes
    # the next character, so `$'it\'s;x'` stays quoted past the `\'`, where
    # plain single-quote rules would close it early and pad the `;`. A
    # standalone `\;` is the terminator of a `find -exec` command, so the arms
    # treat it as a boundary too; otherwise `find -exec cp {} <refused> \;`
    # reads `\;` as the cp destination and allows the write.
    #
    # awk runs per ORIGINAL line, before the newline fold, so an unbalanced
    # quote on a heredoc-body line mis-scopes only that line. The honest
    # limit: a quote opened on one line and closed on a later one is not
    # tracked across the boundary, so such a line can mis-scope, an
    # under-deny inside the best-effort posture this hook already states.
    wsrc=$(printf '%s\n' "$cmd" | awk '
      {
        out = ""; q = ""; lit = 0; len = length($0)
        for (k = 1; k <= len; k++) {
          c = substr($0, k, 1)
          if (q == "") {
            if (c == "\\") { out = out c substr($0, k + 1, 1); k++; lit = k; continue }
            if (c == "\047" && k > 1 && substr($0, k - 1, 1) == "$" && lit != k - 1) { q = "$" }
            else if (c == "\047" || c == "\"") { q = c }
            else if (c == ";" || (c == "|" && substr($0, k - 1, 1) != ">") || (c == "&" && substr($0, k - 1, 1) != ">" && substr($0, k - 1, 1) != "<" && substr($0, k + 1, 1) != ">")) { out = out " " c " "; continue }
          } else if ((q == "\"" || q == "$") && c == "\\") { out = out c substr($0, k + 1, 1); k++; continue }
          else if ((q != "$" && c == q) || (q == "$" && c == "\047")) { q = "" }
          out = out c
        }
        print out
      }')
    wsrc="${wsrc//$'\n'/ ; }"
    read -r -a wtoks <<<"$wsrc"

    # Output-redirection targets, one per line, read by a character scanner
    # rather than by matching whitespace-split words. Word matching is what
    # kept missing spellings: bash ends a word at `>` whatever precedes it,
    # so `echo x>RP`, `true;>RP`, `a&&b>RP` and `2>/dev/null>RP` all redirect
    # into RP while presenting no word that starts with the operator. The
    # scanner treats every `>` outside quotes as an operator, which covers
    # each prefix bash allows before one (`N`, `&`, `{fd}`, `<` for the
    # read-write `<>`, which creates its file) and each suffix (`>>`, `>|`,
    # `>&`). It then reads the target word with bash's quote removal, so
    # `>"RP"` and `>'RP'` name RP. `>&WORD` is an fd duplication only when
    # WORD is digits or `-`; any other word is a file bash writes (`>&RP`,
    # `1>&RP`) or refuses as ambiguous, so it is a target either way.
    #
    # Quote-aware because a `>` inside single or double quotes is data: a
    # member's findings payload that quotes a redirect into a refused path
    # (`printf '... >RP ...'`) is not a write. Command substitution
    # (`$(...)`, backticks) re-enters command context even inside double
    # quotes, and a `>(...)` process substitution is not a redirect, only its
    # body is scanned. A comment and a heredoc body are data too, except that
    # an unquoted-delimiter body still expands `$(...)`, so that body is
    # scanned the way a double-quoted string is. Tracking heredocs is not
    # optional here: an apostrophe in body prose would otherwise open a
    # quote that swallows the commands after the heredoc.
    #
    # Honest limits, all in the safe direction or rarer than the shapes above:
    # a quoted string handed to `bash -c`, `sh -c` or `eval` is a script to
    # the shell but data to this scan, so a redirect inside it passes, the
    # same gap the execution-position scan below states for `-c`; telling it
    # apart from a quoted `printf` payload would mean knowing which commands
    # execute their arguments. A `>` inside `[[ ]]`, `(( ))` or `$(( ))`
    # reads as a redirect, an over-deny only when the next word is a refused
    # path; a target reached
    # through an expansion (`>"$R/x"`) cannot be resolved here, as in every
    # other arm; a `case` pattern's unbalanced `)` inside a double-quoted
    # `$(...)` ends the substitution early and can hide a redirect after it.
    # When the scan ends inside an unterminated quote, substitution or
    # heredoc, its scoping cannot be trusted, so a quote-blind pass that reads
    # every `>` as an operator runs as well and the two are unioned: a
    # mis-scope can then only add denies, never lose one.
    rtargets=$(printf '%s\n' "$cmd" | awk '
      function readword(p,   w, c, e, d) {
        w = ""; WQ = 0
        while (p <= L) {
          c = substr(S, p, 1)
          if (index(META, c)) break
          if (c == "\\") { w = w substr(S, p + 1, 1); p += 2; WQ = 1; continue }
          if (c == "$" && substr(S, p + 1, 1) == "\047") { p++; continue }
          if (c == "\047") {
            e = index(substr(S, p + 1), "\047")
            if (e == 0) { w = w substr(S, p + 1); p = L + 1; break }
            w = w substr(S, p + 1, e - 1); p += e + 1; WQ = 1; continue
          }
          if (c == "\"") {
            p++; WQ = 1
            while (p <= L) {
              d = substr(S, p, 1)
              if (d == "\\") { w = w substr(S, p + 1, 1); p += 2; continue }
              if (d == "\"") { p++; break }
              w = w d; p++
            }
            continue
          }
          w = w c; p++
        }
        WEND = p
        return w
      }
      # Reads the target after the `>` at k, prints it, and returns where the
      # main loop resumes: the target word itself, so a quote or substitution
      # inside it is scoped like any other.
      function redirect(k,   p, d, dup, w) {
        p = k + 1; dup = 0; d = substr(S, p, 1)
        if (d == "(") return p
        if (d == ">" || d == "|") p++
        else if (d == "&") { p++; dup = 1 }
        while (substr(S, p, 1) == " " || substr(S, p, 1) == "\t") p++
        w = readword(p)
        if (w != "" && !(dup && w ~ /^[0-9]*-?$/)) print w
        return p
      }
      function push(t) { SP++; ST[SP] = t; DEP[SP] = 0 }
      # Enters the body of the next pending heredoc, which starts at b.
      function body(b) {
        HP++; push(PQ[HP] ? "Q" : "H")
        HD[SP] = PD[HP]; HS[SP] = PS[HP]; HB[SP] = b
      }
      function scan(   k, c, t, pv, e, line, strip, w) {
        SP = 0; ST[0] = "N"; NP = 0; HP = 0; k = 1
        while (k <= L) {
          c = substr(S, k, 1); t = ST[SP]
          if (t == "H" || t == "Q") {
            if (k == HB[SP] || substr(S, k - 1, 1) == "\n") {
              e = index(substr(S, k), "\n"); e = e ? k + e - 1 : L + 1
              line = substr(S, k, e - k)
              if (HS[SP]) sub(/^\t+/, "", line)
              if (line == HD[SP]) {
                SP--
                if (HP < NP) { body(e + 1); k = e + 1 }
                else { NP = 0; HP = 0; k = e }
                continue
              }
              if (t == "Q") { k = e + 1; continue }
            }
            if (t == "Q") { k++; continue }
          }
          if (t == "S") { if (c == "\047") SP--; k++; continue }
          if (t == "A") { if (c == "\\") k++; else if (c == "\047") SP--; k++; continue }
          if (c == "\\") { k += 2; continue }
          if (c == "$" && substr(S, k + 1, 1) == "(") { push("C"); k += 2; continue }
          if (c == "`") { if (t == "B") SP--; else push("B"); k++; continue }
          if (t == "D" || t == "H") { if (c == "\"" && t == "D") SP--; k++; continue }
          # Command context from here on: N (top level), C, B.
          if (c == "\047") { if (substr(S, k - 1, 1) == "$") push("A"); else push("S"); k++; continue }
          if (c == "\"") { push("D"); k++; continue }
          if (c == "(" && t == "C") { DEP[SP]++; k++; continue }
          if (c == ")" && t == "C") { if (DEP[SP] > 0) DEP[SP]--; else SP--; k++; continue }
          pv = substr(S, k - 1, 1)
          if (c == "#" && (k == 1 || index(" \t\n;&|()", pv))) {
            e = index(substr(S, k), "\n"); k = e ? k + e - 1 : L + 1; continue
          }
          if (c == "\n" && HP < NP) { body(k + 1); k++; continue }
          if (c == ">") { k = redirect(k); continue }
          if (c == "<") {
            if (substr(S, k + 1, 2) == "<<") { k += 3; continue }
            if (substr(S, k + 1, 1) == "<") {
              k += 2; strip = 0
              if (substr(S, k, 1) == "-") { strip = 1; k++ }
              while (substr(S, k, 1) == " " || substr(S, k, 1) == "\t") k++
              w = readword(k)
              if (w != "") { NP++; PD[NP] = w; PQ[NP] = WQ; PS[NP] = strip }
              k = WEND; continue
            }
          }
          k++
        }
        return SP != 0
      }
      { S = (NR == 1 ? $0 : S "\n" $0) }
      END {
        META = " \t\n;&|()<>"; L = length(S)
        if (scan()) {
          for (k = 1; k <= L; k++) if (substr(S, k, 1) == ">") k = redirect(k) - 1
        }
      }')

    cmd="${cmd//$'\n'/ ; }"

    # A dispatched member may not repair its own declared remit. This is an
    # EXECUTION shape, not a write shape: `bash .gaia/scripts/write-audit-remits.sh`
    # presents no redirect, tee, sed -i, sponge, or cp/mv destination, so the
    # write-shape loop below never sees it. The literal lives here rather than in
    # the shared AUDIT_SELFHEAL_REFUSE_ERE because that ERE is a path matcher the
    # CI push gate applies to a diff, and an invocation is not a path in a diff.
    #
    # Matched only at an EXECUTION position: token 0, a token immediately
    # following a `;` / `&&` / `||` / `|` separator, or -- after an
    # interpreter-like token (bash, sh, zsh) -- the first following token that
    # is not a `-`-prefixed option, so `sh -x <writer>` and
    # `bash --norc <writer>` both deny. `-c` is never treated as a skippable
    # option: its argument is a quoted script STRING this whitespace tokenizer
    # cannot safely parse, so `bash -c '<writer>'` is a stated, out-of-scope
    # gap. A backtick-quoted invocation is a second
    # stated gap, and deliberately not closed the way the brackets below are:
    # a backtick is common inside ordinary quoted prose (a commit message
    # naming a script), so padding it would false-deny commands that write
    # nothing. A read-only command that merely NAMES the file as an argument
    # (`shellcheck .gaia/scripts/write-audit-remits.sh`, `cat ...`,
    # `git log --grep ...`) is not an invocation of it and must stay allowed.
    #
    # A separator only ends a token when whitespace happens to follow it, so
    # `<check>; <writer>`, `true&&bash <writer>`, and `echo x| bash <writer>`
    # would otherwise present the separator glued to a neighbour and never
    # mark a boundary at all. That is the realistic bypass, not an
    # adversarial one: the check prints `repair:  bash .gaia/scripts/write-
    # audit-remits.sh` under every finding, so chaining the printed repair
    # onto the check that printed it is the natural next keystroke. Pad every
    # separator character into a standalone token for THIS scan only, in its
    # own array: the write-shape arms read their own quote-aware `wtoks`
    # and the redirect arm reads its own character scan, both built above,
    # where `>` and `2>&1` are load-bearing. `&&` and `||` degrade to two
    # adjacent single-character tokens, which is harmless because this scan
    # only asks whether a boundary occurred, never which operator produced it.
    # Padding can also split a quoted argument, which only ever widens the
    # deny surface, the safe direction here.
    #
    # A subshell opener needs the same padding for a second reason: unpadded it
    # GLUES to the command it opens, so `(bash <writer>` tokenizes as `(bash`,
    # which is not the interpreter `bash`. Padded, `(` becomes a standalone
    # token that marks a boundary and the command it opens reads at an
    # execution position; `)` is padded so a closer glued to the writer
    # (`<writer>)`) cannot defeat the `${cand##*/}` basename match. Padding `(`
    # deliberately makes `(cd foo && ...)` an execution position as well, and
    # turns both an array literal (`files=(<writer>)`) and paren-led quoted
    # prose (`echo "(<writer>)"`, the likeliest of the three to be hit in
    # practice) into a false deny: over-denying is the safe direction for this
    # guard.
    #
    # PADDING SHREDS, so the scan never trusts a single tokenization. Any
    # character padded into a standalone token also splits every construct
    # that embeds it mid-word: `(` shreds `$(pwd)/<writer>` into `"$` `(`
    # `pwd` `)` `/<writer>`, stranding the basename away from an execution
    # position. Padding `{` would do the identical thing to `${ROOT}/<writer>`,
    # the repo-relative path form GAIA scripts write, which is why
    # braces are NOT padded (and do not need to be: `{bash foo; }` is a syntax
    # error, so a real brace group already presents `{` as its own word, and
    # `}` is already detached by the `;` padding).
    #
    # Rather than hand-audit each padded character for that hazard, scan BOTH
    # tokenizations and take the union. The scan only ever denies, so a second
    # pass is structurally incapable of losing a deny: whatever a padded
    # stream shreds, the unpadded stream still carries whole. That makes the
    # guard immune to this class for any character padded here in future,
    # rather than fixing one bracket at a time.
    ssrc="$cmd"
    ssrc="${ssrc//;/ ; }"
    ssrc="${ssrc//&/ & }"
    ssrc="${ssrc//|/ | }"
    esrc="$ssrc"
    esrc="${esrc//(/ ( }"
    esrc="${esrc//)/ ) }"
    read -r -a stoks <<<"$ssrc"
    read -r -a etoks <<<"$esrc"

    # `${arr[@]+"${arr[@]}"}` is required, not decoration: bash 3.2 under
    # `set -u` errors on an empty-array expansion, the class
    # .gaia/scripts/lint-hook-array-guard.sh exists to catch.
    scan_exec_positions ${stoks[@]+"${stoks[@]}"}
    scan_exec_positions ${etoks[@]+"${etoks[@]}"}

    while IFS= read -r target; do
      is_refused_path "$target" && deny "$(deny_reason "$MATCHED_PATH")"
    done <<<"$rtargets"

    sn=${#wtoks[@]}
    # A redirection word: an optional fd or `&`, then an operator, longest
    # alternative first so a bare `>|`, `<<<` or `<<` equals its whole match
    # and has its operand skipped.
    redir_re='^([0-9]+|&)?(>>|>[|]|>&|>|<<<|<<|<&|<)'
    # The target-directory option, short and long; group 1 is an attached
    # argument, empty when it is the next word.
    tshort_re='^-[A-RT-Za-su-z0-9]*t(.*)$'
    tlong_re='^--t[a-z-]*=?(.*)$'
    i=0
    while [ "$i" -lt "$sn" ]; do
      tok="${wtoks[$i]}"
      case "$tok" in
        tee | sponge)
          j=$((i + 1))
          while [ "$j" -lt "$sn" ]; do
            t2="${wtoks[$j]}"
            case "$t2" in
              ';' | '&' | '|' | '\;') break ;;
            esac
            is_refused_path "$t2" && deny "$(deny_reason "$MATCHED_PATH")"
            j=$((j + 1))
          done
          ;;
        sed)
          has_i=0
          sed_match=""
          j=$((i + 1))
          while [ "$j" -lt "$sn" ]; do
            t2="${wtoks[$j]}"
            case "$t2" in
              ';' | '&' | '|' | '\;') break ;;
            esac
            [[ "$t2" == "-i" || "$t2" == -i* ]] && has_i=1
            if is_refused_path "$t2"; then sed_match="$MATCHED_PATH"; fi
            j=$((j + 1))
          done
          [ "$has_i" -eq 1 ] && [ -n "$sed_match" ] && deny "$(deny_reason "$sed_match")"
          ;;
        cp | mv)
          dest=""
          tdir=0
          j=$((i + 1))
          while [ "$j" -lt "$sn" ]; do
            t2="${wtoks[$j]}"
            case "$t2" in
              ';' | '&' | '|' | '\;') break ;;
            esac
            # GNU `-t DIR` / `--target-directory=DIR` names the destination
            # up front and every positional after it is a source, so the
            # last-positional rule would read a source as dest and allow the
            # write. getopt accepts the option clustered (`-vt DIR`), with its
            # argument attached (`-tDIR`), and the long name abbreviated to
            # any prefix (`--target=DIR`); no other cp or mv long option
            # starts with `--t`. BSD cp and mv have no `-t` and reject it.
            # `-S` takes an argument too, so a `t` after it is suffix text.
            if [ "$tdir" -eq 0 ] && [[ "$t2" =~ $tshort_re || "$t2" =~ $tlong_re ]]; then
              if [ "${t2:0:2}" != "--" ] || [[ "--target-directory" == "${t2%%=*}"* ]]; then
                tdir=1
                dest="${BASH_REMATCH[1]}"
                if [ -z "$dest" ]; then
                  j=$((j + 1))
                  dest="${wtoks[$j]:-}"
                fi
              fi
            # A trailing redirection is not the destination: read as one,
            # `cp a <refused> 2>/dev/null` names `2>/dev/null` as dest and
            # allows the write. A bare operator (`2>`, `>`) also takes the
            # next word as its operand, so that word is skipped too.
            elif [[ "$t2" =~ $redir_re ]]; then
              [ "$t2" = "${BASH_REMATCH[0]}" ] && j=$((j + 1))
            elif [ "$tdir" -eq 0 ] && [[ "$t2" != -* ]]; then
              dest="$t2"
            fi
            j=$((j + 1))
          done
          is_refused_path "$dest" && deny "$(deny_reason "$MATCHED_PATH")"
          ;;
      esac
      i=$((i + 1))
    done

    exit 0
    ;;
esac
