#!/usr/bin/env bash
# SC2016 is intentional file-wide: single-quoted case patterns match the literal
# text $HOME/$PWD/${PWD}, so shell expansion is deliberately suppressed.
# shellcheck disable=SC2016
# PreToolUse Bash hook: deny dangerous `rm -rf` invocations.
#
# The `rm` command word is matched case-insensitively and through quote/backslash
# splitting, so `RM`, `r""m`, and `r\m` are all the command `rm`, exactly as bash
# resolves them. Flags are matched case-insensitively too.
#
# Denied targets:
#   - any command using --no-preserve-root
#   - rm -rf / (root)
#   - rm -rf $HOME, ${HOME}, ~, ~/, $HOME/...
#   - rm -rf .   (cwd, incl. $PWD)
#   - rm -rf *   (unscoped glob)
#   - rm -rf .*  (dotfile glob, incl. the .[!.]* / ..?* / {.,}* spellings)
#   - rm -rf .git
#   - rm -rf .claude (the Claude config: hooks, skills, agents, rules, settings)
#   - rm -rf node_modules (anywhere, must use pnpm clean / explicit path)
#
# Allowed (whitelist of safe scratch paths):
#   - .gaia/local/plans/*
#   - .gaia/local/specs/*
#   - .gaia/local/audit/*
#   - .gaia/local/handoff/*
#   - .gaia/local/cache/*
#   - dist/*
#   - build/*
#
# Each is whitelisted in both its relative and its absolute spelling, so
# `rm -rf /path/to/repo/dist` is allowed exactly as `rm -rf dist` is. The absolute
# form is what .claude/rules/shell-cwd.md requires of every Bash call, and a guard
# that took only the relative one denied the form the rule mandates.
#
# Anything that does not match a denied pattern AND is not on the whitelist
# falls through (exit 0), this hook intentionally only blocks the well-known
# footguns; broader policy lives in settings.json permissions.
#
# SCOPE, read before trusting this guard. It text-matches target tokens, so it
# is porous by construction. Do not read the deny list above as a guarantee.
#
# A target the shell *computes* rather than spells is out of reach by design:
# command substitution (`rm -rf "$(git rev-parse --show-toplevel)"`), an
# arbitrary variable holding a dangerous path, a relative escape
# (`rm -rf ../..`), and targets arriving via `xargs` all pass.
#
# Some *literally spelled* targets also pass. Treat the deny list as a floor,
# never a ceiling: it is not exhaustive, and for a heuristic text matcher
# completeness was never on offer.
#
# That incompleteness is the design, not a standing defect backlog. Do NOT file a
# porosity finding on the strength of a hypothesis, a hole reasoned to from the
# source, or an audit that enumerates shapes this guard does not catch. The supply
# of those is unbounded, each one costs real review, and this guard is explicitly
# the second layer behind settings.json permissions rather than the thing standing
# between anyone and disaster.
#
# A porosity finding requires a CONCRETE, RUNNABLE ARTIFACT, in one of two forms.
# Either an observed incident, a command that actually ran and should not have, or
# was actually denied and should not have been, with the transcript that shows it;
# or an executable reproduction, a failing test case against this hook that anyone
# can re-run. The second is if anything the stronger evidence, being deterministic
# and re-runnable rather than a one-time observation, and constructing commands
# against the hook is how these bugs actually get found; it is not the speculation
# this policy bars. What the bar excludes is the ARGUMENT with no artifact behind
# it. Bring either and it is worth fixing. Bring neither, and the correct response
# to "this guard could be evaded" is yes, it could.
#
# One such hole sits at the seam between the two halves. When the command word is
# not literally spelled (`$RMBIN`, an alias), no anchor matches, so the guard never
# identifies the command as an `rm` at all and every protected target passes: that
# is the computed-command case above. A target whose final path component is
# literally `rm` (`$RMBIN /usr/bin/rm -rf`) is the same hole, not a narrower one:
# it lands where the command word would sit, and the word is skipped by position.
# Nothing the deny list claims is lost, because a computed command word already
# carried `/`, `$HOME`, `.git`, `.claude`, and `node_modules` straight through.
#
# One direction is deliberately NOT repaired, and it looks like a bug. The guard
# denies commands that merely *mention* a flagged target in a quoted string, so
# `git commit -m "fix: rm -rf $HOME bypass"` is a false deny. Making a quoted
# `rm` not-a-command would fix that, and would also allow `bash -c "rm -rf /"`,
# `ssh host "rm -rf /"`, and `eval "rm -rf /"`. A text matcher cannot tell a
# quoted command from a quoted string; of the two failure directions the false
# deny is the safe one, so it stays. Deliver such text via `--body-file` / `-F`,
# or through a variable.
#
# The word FLAGGED is load-bearing there. Each segment is judged only when it
# carries its own `-r`/`-f`, so quoting a non-recursive `rm` is not a false deny
# even beside a real removal. That narrowing is exact rather than a partial repair
# of the above: it turns on the destructive flag, which the guard already required,
# and never on whether a token sits in command position, which it cannot know.
#
# `jq` is a hard dependency: without it the hook exits non-zero, which Claude
# Code treats as a non-blocking error, so the command proceeds unguarded
# (loudly, on stderr, never bricking the session).
#
# This is heuristic defense-in-depth behind settings.json permissions, not a
# sandbox. It is the second layer, never the first.
#
# LAYOUT. Everything above `main` is a definition: sourcing this file defines the
# helpers and constants and runs nothing. The executed body lives in `main`,
# called from the bottom only when the file is run rather than sourced, so a test
# can source the file and assert an internal helper directly instead of inferring
# it from an end-to-end verdict. `set -euo pipefail` therefore sits inside `main`,
# not at the top: at the top, a `source` would push those options onto the
# *caller's* shell. Nothing above `main` depends on them (function definitions do
# not execute, and the two assignments cannot fail), so the executed path still
# sets them before its first real command.

# Neutralize `;`, `&`, and `|` INSIDE quoted spans, rewriting each to a space.
#
# Both the short-circuit grep and the segment extraction below stop a segment at
# the first `;&|` byte, on the assumption that those bytes always terminate a
# command. Inside quotes they do not: they are ordinary characters in an operand.
# `rm -rf ";" $HOME` hands bash the argv [-rf] [;] [$HOME] and deletes home, while
# the unrepaired guard extracts only `rm -rf "`, never tokenizes `$HOME`, and
# allows it. This has to run before the short-circuit, not just before extraction:
# `rm ";" -rf $HOME` puts the quoted separator between `rm` and its flags, so the
# short-circuit misses too and the deny logic below never runs at all.
#
# A space is the right rewrite, not deletion and not a sentinel byte. The guard is
# already quote-blind at the token level (it strips quotes, then word-splits), so
# an extra token boundary inside a quoted string costs nothing, while any other
# filler would glue onto the token and break the anchored arms below: `rm -rf
# "$HOME;"` must still reach the $HOME arm, and with a space it does.
#
# Substituting rather than DELETING is also what lets the gate below skip this walk
# for any command whose raw text holds no `rm`. That skip is provably a no-op only
# because the walk writes each character back in its own position and the only byte
# it ever writes is a space, so it cannot close a gap and manufacture an `rm` the
# raw text did not already contain. A deletion could: a quoted `r;m` would close up
# into `rm`. That particular one is a phantom (bash reads `"r;m"` as a command
# literally named `r;m`, never as `rm`), so the divergence would surface as a false
# deny rather than a bypass, but the gate's justification is an equivalence proof
# and a deletion falsifies it. Do not switch this to a deletion without re-deriving
# that proof, or dropping the gate with it. The proof is asserted directly, on this
# function, by the position-preserving test cases covering it:
# a deletion fails them even though it changes no end-to-end verdict.
#
# This only ever WIDENS what gets inspected, so it can add denials and never
# remove one.
#
# It deliberately does NOT skip an `rm` that is itself inside quotes, which looks
# like the matching fix for this guard's false denies on prose that merely mentions
# a command (`git commit -m "fix: stop rm -rf $HOME from bypassing the guard"` is
# denied today, and that is annoying). Do not "fix" it: the same change allows
# `bash -c "rm -rf /"`, `ssh host "rm -rf /"`, and `eval "rm -rf /"`, which are real
# shapes this guard catches today. A text matcher cannot tell a quoted command from
# a quoted string, and of the two failure directions the false deny is the safe one.
# Work around it by delivering the text via `--body-file` / `-F`, or via a variable.
#
# Escaped quotes inside a quoted span are not tracked. The guard is a heuristic
# matcher; mis-tracking there misplaces a space, which fails safe.
neutralize_quoted_separators() {
  local s=$1 out='' quote='' ch i len=${#1}
  for ((i = 0; i < len; i++)); do
    ch=${s:i:1}
    if [[ -n "$quote" ]]; then
      if [[ "$ch" == "$quote" ]]; then
        quote=''
      else
        case "$ch" in ';'|'&'|'|') ch=' ' ;; esac
      fi
    else
      case "$ch" in '"'|"'") quote=$ch ;; esac
    fi
    out+=$ch
  done
  printf '%s' "$out"
}

# The `rm` command word, matched the way bash RESOLVES it rather than the way it
# is spelled. Bash removes quote and backslash bytes from a word before resolving
# it, so `r""m`, `"r"m`, `r"m"`, and `r\m` are all the command `rm`; and macOS
# ships a case-insensitive volume by default, so `/bin/RM` really is `/bin/rm` and
# `RM -rf ~` really deletes home.
#
# The target half of this guard already normalizes exactly this way (it strips
# quotes and backslashes per token, below). The command half has to agree, or a
# spelling of the WORD carries every protected target out through the matching
# sites in one move, before a single deny arm is reachable. The flag half was
# already case-tolerant (`[rRfF]`), which is what made the command half's
# case-sensitivity an oversight rather than a decision.
#
# The class is the three bytes bash's quote removal drops: backslash, double
# quote, single quote. The backslash leads it deliberately. A POSIX bracket
# expression takes a backslash literally, so the set is the same either way, but a
# TRAILING one would sit against the closing `]` and read as an escape of it to
# anything that does not implement that rule, leaving the bracket unterminated.
# Leading, the worst case is that a stricter engine reads `\"` as an escaped quote
# and the set quietly loses the backslash: the pattern stays well-formed and only
# `r\m` degrades to today's verdict.
#
# All THREE `rm`-matching sites share this rule: the two greps below, which take
# it as an ERE, and the walk gate immediately below, which needs the glob spelling
# of it. Anything that widens one has to widen the others in step, so the greps
# take it from one definition and the gate's comment states the tie explicitly.
rm_word="[Rr][\\\"']*[Mm][\\\"']*"
rm_anchor="(^|[^[:alnum:]_-])${rm_word}[[:space:]]+"

# The destructive flag, shared by the short-circuit probe and the segment
# extraction below so the two cannot drift. They have to agree: the probe decides
# whether to look at the command at all, and the extraction decides which segments
# get judged. When only the probe carried this clause, a flag anywhere in the
# command licensed judging every `rm` segment in it, including segments that were
# not removals at all.
#
# A flag is its own shell WORD, and requiring that is what separates `-rf` from a
# hyphenated path component. `-[a-zA-Z]*[rRfF]` alone matches the `-matcher` inside
# `c-text-matcher-guards`, so a flagless `rm /path/to/c-text-matcher-guards/x`
# read as a destructive `rm -r` on the strength of a directory NAME. That is not a
# hypothetical shape: `-matcher`, `-perf`, `-refactor`, and `-user` are all
# ordinary branch and directory names, and an agent that cannot delete its own
# scratch routes around the guard entirely.
#
# The boundary is a separate piece from the flag because it has to sit INSIDE the
# segment's own `[^;&|]*` run rather than in front of it. The anchor above already
# consumes the whitespace after the command word, so a boundary byte demanded
# ahead of the flag would have nothing left to match in `rm -rf /`.
#
# Quote and backslash bytes count as boundaries alongside whitespace. Bash drops
# them during quote removal, so `rm "-rf" /` is a genuine flag and has to stay
# denied; this is the same three-byte class the command word above matches through,
# and it is a boundary here for the same reason.
rm_flag_boundary="([^;&|]*[\\\"'[:space:]])?"
rm_flag="(-[a-zA-Z]*[rRfF]|--recursive|--force|--no-preserve-root)"

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

main() {
  set -euo pipefail

  # Declared, not assigned: `local x=$(cmd)` would mask a non-zero status behind
  # `local`'s own exit code and defeat the errexit above, which is what carries the
  # fail-open on a missing jq. The file is sourceable, so scoping these also keeps a
  # caller that invokes `main` from having its own globals clobbered.
  local payload cmd rm_segments rm_segment tokens tok i first_seg

  payload=$(cat)
  cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")

  [[ -n "$cmd" ]] || exit 0

  # Splice backslash-newline continuations before anything else looks at $cmd.
  # Both greps below are line-oriented, so a target on a continuation line carries
  # no `rm` token of its own, no segment is ever extracted for it, and it becomes
  # invisible to the guard, while the byte-identical one-line command is denied.
  # A multi-line `rm -rf \` is idiomatic, not contrived, and the target is a plain
  # literal token, exactly what this guard claims to match.
  #
  # Join with NOTHING, not a space: bash removes the backslash-newline entirely,
  # so a continuation splitting a token mid-word (`$HOM\` + newline + `E`)
  # reassembles into that one token. A space-join would instead cut it into two
  # fragments that match no pattern, which is the bypass rather than the fix. The
  # space that already precedes a normal continuation's backslash is what keeps
  # the token boundary in the idiomatic case, so nothing is lost here.
  cmd=${cmd//\\$'\n'/}

  # Only pay for the character walk when it could change an outcome. This hook runs
  # on EVERY Bash call, and the walk is O(n) bash over the command string, so a long
  # inline `git commit -m "…" && git push` would otherwise pay for nothing.
  #
  # All three ingredients are required, and gating on `rm` is equivalence-preserving
  # rather than a heuristic: the walk only ever rewrites `;`, `&`, and `|` to spaces,
  # so it can neither synthesize the letters of `rm` nor remove them, and it neither
  # writes nor deletes a quote or backslash byte. The probe below therefore returns
  # the same verdict on the walked command as on the unwalked one, which makes
  # skipping the walk a no-op by construction, not a judgment call.
  #
  # The probe is the glob spelling of the command-word rule above, and it has to
  # stay in step with it: drop the bytes bash's quote removal drops, then match `rm`
  # case-insensitively. A gate that knows only the literal lowercase spelling skips
  # the walk for `RM -rf ";" $HOME`, segment extraction then stops at the quoted `;`,
  # and `$HOME` is never tokenized, so widening the greps alone leaves this site
  # blind and the whole fix hollow.
  if [[ "${cmd//[\"\'\\]/}" == *[Rr][Mm]* && "$cmd" == *[\"\']* && "$cmd" == *[\;\&\|]* ]]; then
    cmd=$(neutralize_quoted_separators "$cmd")
  fi

  # Short-circuit: only act on commands containing `rm` with `-rf`/`-fr`/`-r -f`/etc.
  #
  # The flag is matched anywhere in the rm segment, not just immediately after
  # `rm`. GNU getopt permutes argv, so `rm $HOME -rf` is exactly `rm -rf $HOME`
  # and deletes home on Linux (CI, devcontainers, Linux adopters); BSD/macOS `rm`
  # does not permute, which is why an operand-first invocation looks harmless when
  # hand-tested on a Mac. Requiring adjacency let both that shape and a leading
  # `--no-preserve-root` exit here, before the deny logic below ever ran.
  #
  # A looser short-circuit is fail-safe, not free. It can only ADD denials, never
  # turn a previously-denied command into an allow, because it decides what to
  # *inspect* and the case arms below decide what to block. It does widen the
  # false-deny surface: `git rm --cached -r .` now denies (the canonical
  # `git rm -r --cached .` already did), which is annoying but safe. Widen this
  # regex only with that asymmetry in mind.
  if ! grep -Eq "${rm_anchor}${rm_flag_boundary}${rm_flag}" <<<"$cmd"; then
    exit 0
  fi

  # 1. --no-preserve-root is always denied.
  if grep -Eq -- '--no-preserve-root' <<<"$cmd"; then
    deny "BLOCKED: rm with --no-preserve-root is forbidden."
  fi

  # 2. Catastrophic targets.
  #    Match an rm token followed (after flags) by one of: /, ~, ~/, \$HOME, ., *, .git, node_modules
  #    We scan every whitespace-separated token after `rm`.
  # Extract the rm-segments: each runs from an `rm` to the next `;`/`&&`/`||`/`|`
  # or end-of-line. EVERY segment is inspected, not just the first: a chained
  # command whose leading `rm` is benign is an ordinary cleanup shape
  # (`rm -rf node_modules && rm -rf dist`), so stopping at the first match let a
  # dangerous target ride along behind a harmless one.
  #
  # Each segment must carry its OWN destructive flag. The short-circuit above is a
  # whole-command probe, so without this clause one real `rm -rf dist` licensed
  # judging every other `rm` in the same invocation, and `rm -rf dist && rm /abs/x`
  # denied on a target the guard allows when it stands alone.
  #
  # This is the rare narrowing that costs no coverage. The guard's entire advertised
  # scope is `rm -rf`; a segment with no `-r`/`-f` cannot recurse into a directory,
  # and its targets were already allowed in every spelling when no flagged sibling
  # shared the command. So the removed denials were reachable only by deleting the
  # harmless sibling, which is to say they stopped nobody. What they did cost was
  # every Bash call quoting a non-recursive `rm` as prose, including this repo's own
  # always-loaded shell-cwd rule and its worked example.
  #
  # A flagged segment is unaffected: `rm -rf dist && rm -rf /` is still denied, and
  # so is a flagged `rm` sitting inside a quoted string. That false deny is the
  # deliberate one documented in the header, and narrowing by flag does not touch it.
  rm_segments=$(grep -oE "${rm_anchor}${rm_flag_boundary}${rm_flag}[^;&|]*" <<<"$cmd" || true)
  [[ -n "$rm_segments" ]] || exit 0

  # A here-string keeps the loop in the current shell, so deny()'s exit is the
  # hook's exit rather than a subshell's.
  while IFS= read -r rm_segment; do
    [[ -n "$rm_segment" ]] || continue

    # Tokenize and inspect non-flag args.
    read -r -a tokens <<<"$rm_segment"

    # Start at index 1. Token 0 is the `rm` command word, and it is never an operand:
    # the anchor above begins every segment AT that word (after its leading boundary
    # byte, if any), so whatever spelling carried it here (`rm`, `RM`, `r""m`, `r\m`)
    # arrives first and nothing else can.
    #
    # Skipping it by POSITION rather than by spelling is what admits a PATH-QUALIFIED
    # command word. `/bin/rm` reaches this loop as the token `/rm`, because the
    # anchor's boundary byte is the `/` in front of the word, and a guard that
    # recognizes the word only by its spelling judges `/rm` as a TARGET: it trips the
    # absolute-path arm and denies a whitelisted `dist`, blaming a path the user never
    # wrote.
    #
    # Widening the spelling test to cover `/rm` is the fix that looks right and is
    # not: any pattern loose enough to match `/rm` (say `*/[Rr][Mm]`) also matches
    # `/usr/bin/rm` when that is the TARGET, so `rm -rf /usr/bin/rm` would stop being
    # an absolute-path deny. Position separates the two for free.
    #
    # It also retires an invisible constraint. Skipping the word by spelling was safe
    # only for as long as the normalized `rm` matched no deny arm and fell through to
    # the catch-all, which silently bound anyone who later added an arm.
    #
    # `${#tokens[@]}` is the count form the array-guard lint accepts, and unlike a bare
    # "${tokens[@]}" it is safe under `set -u` on bash 3.2 for an ASSIGNED array, empty
    # or not. Assigned is the load-bearing word. On 3.2 the count of a declared-but-
    # never-assigned array is a fatal unbound-variable abort rather than 0, and the
    # `local tokens` in main's declaration list is what makes that state representable
    # at all. The `read -r -a tokens` immediately above is what rules it out, because it
    # assigns unconditionally, even on wordless input. Two edits would break that and
    # leave `tokens` unset at a count: adding a count UPSTREAM of the read, or making
    # the read CONDITIONAL. Either aborts the hook mid-body, and an aborted guard emits
    # no deny, which is a silent allow. (A `continue` slipped between the read and the
    # count is harmless by contrast: it skips the count along with the rest of the
    # iteration.)
    #
    # (tokens is provably non-empty here anyway: rm_segment is guarded non-empty above
    # and always carries the word.)
    for ((i = 1; i < ${#tokens[@]}; i++)); do
      tok=${tokens[i]}

      # Skip flag tokens.
      [[ "$tok" == -* ]] && continue

      # Drop every quote character before matching. `read -r -a` word-splits but
      # does not remove quotes, so the token for `rm -rf "$HOME"` is the literal
      # 7-character "$HOME" (quotes included) and matches none of the patterns
      # below. Quoting the expansion is the *careful* way to write the command, so
      # a quote-blind guard misses precisely the well-written form and catches only
      # the sloppy one. Removing all quotes rather than just a surrounding pair also
      # covers `rm -rf "$HOME"/projects`, where the quotes sit mid-token. A path
      # whose real name contains a quote character is not a case worth protecting
      # here: the cost is a false deny, which fails safe.
      tok=${tok//\"/}
      tok=${tok//\'/}
      # Backslash goes for the same reason, and it is the same defect: bash strips
      # a backslash before an ordinary character, so `\/` reassembles into `/` and
      # hands root to rm while matching no pattern here. Stripping quotes but not
      # escapes would be half a fix.
      tok=${tok//\\/}
      [[ -n "$tok" ]] || continue

      # `$PWD` spells the cwd, so `$PWD/.git` IS `.git` and a bare `$PWD` IS `.`.
      # Rewrite the prefix and let the arms below judge whatever is left, rather
      # than growing a parallel set of $PWD arms that would drift from them. This
      # is why `$PWD/dist` stays on the dist whitelist while `$PWD/.git` reaches
      # the .git arm: denying every $PWD path would be the easy over-fix.
      case "$tok" in
        # `$PWD/` with nothing after it is still the cwd. It has to be caught here,
        # ahead of the prefix strips below, or the strip yields an empty token that
        # falls through to the catch-all and allows it.
        '$PWD'|'${PWD}'|'$PWD/'|'${PWD}/') tok='.' ;;
        '$PWD/'*) tok=${tok#'$PWD/'} ;;
        '${PWD}/'*) tok=${tok#'${PWD}/'} ;;
      esac
      [[ -n "$tok" ]] || continue

      # Normalize the way bash reads the path, so every arm below sees one spelling
      # of a target rather than an unbounded family of them. Bash collapses `//` to
      # `/`, and a `./` prefix is cosmetic and repeatable, so `.*`, `./.*`,
      # `././.*`, and `.//.*` are all the same cwd dotfile glob, and `.//.git` is
      # `.git`. Stripping a single `./` would close only the spelling people reach
      # for by accident and leave every evasion spelling of it open, which is the
      # half-fix the arms below exist to avoid.
      #
      # `./` alone is left intact (the strip requires something after the slash),
      # so the cwd arm still owns it rather than reducing it to an empty token.
      #
      # An INTERIOR `/./` collapses for the same reason a doubled slash does: it is
      # a cosmetic, repeatable spelling of the same path. Leaving it in place let a
      # single dot stand in as a path segment, which is enough to satisfy any arm
      # below that requires a non-empty parent: `/./dist` and `/../dist` both
      # resolve to `/dist`, the filesystem-root removal the absolute arms refuse.
      # Normalizing here rather than growing dot-segment arms is what keeps the
      # arms reading one spelling of a target, which is this block's whole purpose.
      #
      # Both substitutions run in ONE loop, to a fixed point. They feed each other
      # (`/.//x` needs the slash collapse before the dot collapse can see `/./`, and
      # `/././x` needs a second pass because the replacements do not overlap), so
      # two sequential loops would each terminate on a token the other still
      # reduces. `..` is deliberately NOT collapsed: it depends on the tree, and the
      # traversal arm below denies it rather than guessing where it lands.
      while [[ "$tok" == *//* || "$tok" == */./* ]]; do
        tok=${tok//\/\//\/}
        tok=${tok//\/.\//\/}
      done
      while [[ "$tok" == ./?* ]]; do
        tok=${tok#./}
      done

      # Unscoped expansions in the FIRST path segment. These expand in the cwd, so
      # they sweep up `.git` and `.claude`.
      #
      # `rm -rf .*` is the one hole here that is plausibly an ACCIDENT rather than
      # evasion. It sits precisely between `rm -rf .` and `rm -rf *`, both denied,
      # and anyone reaching for `.*` is trying to clear dotfiles, which is exactly
      # when `.git` is the thing they least want to lose. `rm` refuses `.` and
      # `..`, so everything else goes: the repo history and the whole `.claude`
      # config. The `.[!.]*` and `..?*` idioms people reach for to skip `.` and
      # `..` still match `.git`, so they are the same hole, not a safer spelling.
      #
      # Only the first segment counts. A glob deeper in the path expands inside a
      # named directory, which is what makes the whitelisted `.gaia/local/plans/*`
      # an ordinary cleanup rather than this. The normalization above already
      # removed any `./` prefix, so the first segment is whatever precedes the
      # first slash.
      first_seg=${tok%%/*}
      if [[ "$first_seg" == .* && "$first_seg" == *[*?\[]* ]]; then
        deny "BLOCKED: rm -rf of a dotfile glob ('$tok') is forbidden, it removes .git and .claude."
      fi

      # `{.,}*` expands to `.* *`, the dotfile glob and the unscoped glob at once,
      # spelled so that neither arm below sees either one. A comma is what makes a
      # brace group an expansion list: `${HOME}` has none, so the parameter-
      # expansion arms below still own it. The `*` requirement keeps a scoped
      # `dist/{a,b}` allowed, and anchoring on the first segment keeps the brace
      # group that reaches the cwd distinct from one nested under a named dir.
      if [[ "$first_seg" == *'{'*','*'}'* && "$tok" == *'*'* ]]; then
        deny "BLOCKED: rm -rf of an unscoped brace glob ('$tok') is forbidden, it removes .git and .claude."
      fi

      # SC2088 (tilde does not expand in quotes) is disabled for this whole case: the
      # `~` / `$HOME` patterns below are literal match targets, not paths to expand.
      # They are tested against the raw command string, where the user's unexpanded
      # token is exactly what must be caught; expanding here would break the guard.
      # The directive has to sit in front of the `case` itself, not the branch (SC1124).
      # shellcheck disable=SC2088
      case "$tok" in
        # An absolute path carrying a `..` segment resolves somewhere its spelling
        # does not name, so it can never reach the whitelist below: the escape
        # `/repo/.gaia/local/audit/../../../.git` spells a whitelisted scratch
        # directory and lands on `.git`. Ordering this ahead of the whitelist is what
        # keeps the suffix match from becoming a bypass. (Relative `..` escapes stay
        # out of reach, as the SCOPE note above says; this arm is not that claim.)
        #
        # The leading spellings are listed separately because the interior patterns
        # cannot reach them: `/../x` has nothing between the root slash and the `..`
        # for the `/*/` prefix to match, so it would otherwise fall through to the
        # whitelist with `..` serving as its non-empty parent segment.
        /../*|/..|/*/../*|/*/..)
          deny "BLOCKED: rm -rf of absolute path '$tok' is forbidden."
          ;;
        # The whitelisted scratch paths, in their ABSOLUTE spelling.
        #
        # `.claude/rules/shell-cwd.md` mandates an absolute path on every Bash call,
        # repo-wide, because a single `cd` persists for the rest of the session and
        # breaks every relative-path hook. Whitelisting these directories relatively
        # only put that rule in direct conflict with this guard: the form the rule
        # requires is the form the arm below denies, and an agent could satisfy one
        # or the other but never both. Both spellings are accepted now, and absolute
        # is the authoritative one to write.
        #
        # Matched as a SUFFIX on the scratch segment, deliberately. Recognizing the
        # absolute spelling of a repo-relative target otherwise means resolving the
        # repo root, and both routes there are closed: a live `git rev-parse` is the
        # computed state this guard is designed to do without, and a literal absolute
        # prefix baked into a `.claude/`-distributed file would violate
        # .claude/rules/instruction-files.md. A suffix needs neither.
        #
        # The widening is honest and small: it permits these scratch directories
        # under ANY parent, not just the current repo. The relative arms already did
        # that, since they resolve against whatever the cwd happens to be.
        #
        # `/?*/` requires a non-empty parent segment, so `/dist` and
        # `/.gaia/local/audit/x` stay denied. Those are filesystem-root removals that
        # merely share a name with project scratch, and the whitelist is about scratch
        # inside a project.
        /?*/.gaia/local/plans/*|/?*/.gaia/local/specs/*|/?*/.gaia/local/audit/*|/?*/.gaia/local/handoff/*|/?*/.gaia/local/cache/*|/?*/dist|/?*/dist/*|/?*/build|/?*/build/*)
          : # whitelisted
          ;;
        /|/*)
          deny "BLOCKED: rm -rf of absolute path '$tok' is forbidden."
          ;;
        # The brace form is matched alongside the bare one. `${HOME}` is if anything
        # the more careful spelling of the expansion, and leaving it out reproduced
        # the exact bug the quote-strip above fixes: the guard catching only the
        # casual spelling of the target and missing the deliberate one. Neighbours
        # like ${HOMEBREW_PREFIX} do not match, the arms are anchored, not prefixes.
        # The backslash-escaped arms (\$HOME, \${HOME}) are unreachable now that the
        # strip above removes backslashes before matching. They stay as belt-and-braces.
        # Do not read them as proof the strip is redundant and delete the strip: the
        # strip is what catches \/ and \.git, which have no arms of their own.
        #
        # The tilde arm is a prefix match, not the three literals `~`, `~/`, `~/…`,
        # because `~user` is a home directory too: `~root` names root's home and
        # matched none of the literal arms. A `~foo` that is not a real user stays
        # literal in bash and removes a directory named `~foo`, so denying it is a
        # false deny, which fails safe.
        '~'*|'$HOME'|'$HOME/'*|'\$HOME'|'\$HOME/'*|'${HOME}'|'${HOME}/'*|'\${HOME}'|'\${HOME}/'*)
          deny "BLOCKED: rm -rf of \$HOME / ~ is forbidden."
          ;;
        '.'|'./')
          deny "BLOCKED: rm -rf of cwd ('.') is forbidden."
          ;;
        '*'|'./*')
          deny "BLOCKED: rm -rf of unscoped glob ('*') is forbidden."
          ;;
        .git|./.git|.git/*|./.git/*)
          deny "BLOCKED: rm -rf of .git is forbidden."
          ;;
        # `.claude` is `.git`'s peer, not a lesser sibling: it is the whole Claude
        # configuration (hooks, skills, agents, rules, settings.json), it sits in
        # the cwd of every session, and losing it is unrecoverable in the same way.
        # The dotfile-glob and brace-glob arms above already deny the globs that
        # sweep it up, and they name it in their own deny text, so the direct
        # spelling of it denies here rather than being the one shape that walks past
        # a guard advertising the target.
        .claude|./.claude|.claude/*|./.claude/*)
          deny "BLOCKED: rm -rf of .claude is forbidden, it removes the hooks, skills, agents, and settings."
          ;;
        node_modules|./node_modules|*/node_modules|node_modules/*)
          deny "BLOCKED: rm -rf of node_modules is forbidden, use 'pnpm store prune' or remove deliberately."
          ;;
        .gaia/local/plans/*|./.gaia/local/plans/*)
          : # whitelisted
          ;;
        .gaia/local/specs/*|./.gaia/local/specs/*)
          : # whitelisted (colocated plan scratch under specs/<SPEC-ID>/plan)
          ;;
        .gaia/local/audit/*|./.gaia/local/audit/*)
          : # whitelisted
          ;;
        .gaia/local/handoff/*|./.gaia/local/handoff/*)
          : # whitelisted
          ;;
        .gaia/local/cache/*|./.gaia/local/cache/*)
          : # whitelisted
          ;;
        dist|dist/*|./dist|./dist/*)
          : # whitelisted
          ;;
        build|build/*|./build|./build/*)
          : # whitelisted
          ;;
        *)
          : # unknown relative path, let it through; permissions / other hooks may still gate it.
          ;;
      esac
    done
  done <<<"$rm_segments"

  exit 0
}

# Run the body only when EXECUTED. A `source` stops here with the helpers above
# defined and stdin untouched, which is what lets the suite assert
# neutralize_quoted_separators directly: its position-preserving invariant is what
# makes the walk's fast-path gate a no-op, and no end-to-end payload can reach it
# (substitution and deletion agree on every verdict a caller could ever provoke).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
