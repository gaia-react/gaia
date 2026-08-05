#!/usr/bin/env bash
# shellcheck shell=bash
#
# Keep the Code Audit Team's five members on ONE review base.
#
# `gaia_audit_key` (.gaia/scripts/audit-key-lib.sh) is
# `<base_sha>.<branch-slug>`, and co-dispatched members share a branch, so
# the findings sidecars and the shared re-run ledger land under one key
# exactly when the base shas agree. A member that derives its own base
# writes under a key no reader globs: `post-findings-block.sh` finds the
# other members' sidecars, silently misses that one, and posts a
# consolidated block short a whole member's findings with no error anywhere.
# That is the false-green shape this check exists to end -- nothing about it
# is visible in a passing run.
#
# Executing the five real derivation snippets proves they agree TODAY. It
# cannot stop tomorrow's edit from reintroducing a private derivation in a
# definition the run does not happen to exercise. This static check closes
# that gap the way check-audit-key-callers.sh closes the matching one for the
# key itself.
# gaia:maintainer-only:start
#
# The behavioral suite that executes them is
# .gaia/scripts/tests/audit-base-agreement.bats.
# gaia:maintainer-only:end
#
# Over `.claude/agents/`, FOUR assertions:
#
#   1. No REVIEW base is derived by a bare `merge-base` against a branch.
#      The review base must come from `.github/audit/resolve-audit-base.sh`,
#      which anchors on the newest ancestor carrying a clean audit signal
#      under the current .gaia/VERSION and resets to full scope on a
#      machinery change. A bare merge-base against the default branch is the
#      pre-fix derivation: it never moves across fix rounds, so the member
#      re-reviews the whole PR every round AND keys its artifacts to a base
#      no other consumer uses.
#
#      One bare merge-base is legitimate and is deliberately exempted by
#      NAME: `FULL_BASE`, the whole-PR fork point a member resolves whenever
#      it needs one that is not a review base. A specialist keeps it for its
#      SELF-SKIP arm: self-skip is a membership decision, and membership is
#      resolved over the whole PR diff (.gaia/scripts/resolve-audit-members.sh,
#      and the "Full-PR scope (load-bearing)" note in
#      .github/audit/gate-pending-members.sh). A member that self-skipped on
#      the increment could write no marker while membership still demanded
#      one, deadlocking the merge. The default member keeps its own
#      `FULL_BASE` for a different job: the eligibility set the out-of-scope
#      machinery-waive abuse-check reads (.claude/hooks/lib/audit-dispositions.sh),
#      never a review base either. So the exemption is not a loophole in this
#      check; it is the other half of the design, and the variable name is
#      what tells a legitimate whole-PR base apart from a drifted review base
#      regardless of which job it serves. The assignment that owns a
#      `merge-base` call is the nearest `IDENT=` to its left, and `FULL_BASE`
#      is the only name allowed to own a call that does not pass `BASE_REF`.
#
#   2. Every file that NAMES `BASE_SHA` also names `resolve-audit-base.sh`.
#      A token-presence net over the whole file, not a call-shape check: the
#      grep is a fixed-string match, so the sentence explaining where the
#      base comes from satisfies it exactly as the executable line does.
#      That is deliberate, and it is the same shape (and the same reasoning)
#      as assertion 2 of check-audit-key-callers.sh.
#
#      The two assertions are not symmetric. (1) rejects the specific bad
#      derivation. (2) catches the weaker case of a definition that keeps
#      talking about `BASE_SHA` while dropping every reference to where the
#      base comes from -- prose drift that (1) cannot see because it removes
#      a line rather than adding one. Both run independently.
#
#   3. No `diff --name-only` CONSUMES the base without a three-dot range.
#      (1) and (2) police how the base is DERIVED; nothing there constrains
#      what is then handed to `git diff`, and the failures are independent: a
#      member can derive BASE_SHA correctly through the resolver and still
#      scope its review off the resolver's output directly one line later,
#      which is precisely the shape this assertion was added for.
#
#      What makes that a defect is the TWO-DOT comparison it performs, not a
#      missing `merge-base` call. `git diff <rev> -- <paths>` compares <rev> to
#      the WORKING TREE, while a member's clearance digest is computed over
#      `git ls-tree HEAD` (.claude/hooks/lib/audit-digest.sh), so a two-dot
#      scope lets a member certify a digest over content it never read. It
#      also widens: when the base is a ref whose tip has advanced past the
#      fork point, every file the default branch changed enters the list.
#
#      `git diff <rev>...HEAD` resolves its own merge base internally, so the
#      three-dot form is correct whether <rev> is a sha or a ref, and no
#      separate `merge-base` step is needed to make the DIFF right. The
#      members still derive BASE_SHA through `merge-base` because the audit
#      key, the ledger, the findings sidecar, and every `--base` argument need
#      a stable sha; that is a keying requirement, not this assertion's.
#
#      Same shape as (1): a wide fixed-string net (`diff --name-only`) narrowed
#      in awk, where the discriminations are expressible. A call is a violation
#      when it names ANY spelling of the review base (`resolve-audit-base.sh`,
#      `BASE_REF`, `BASE_SHA`, `FULL_BASE`) and carries no `...` range.
#
#      All four spellings, not only the pre-merge-base ones, because what makes
#      a call wrong is the two-dot comparison and NOT which variable reached
#      it: `git diff --name-only "${BASE_SHA}"` compares against the working
#      tree exactly as `"$BASE_REF"` does. A rule keyed to the raw-base
#      spellings alone would police a member's choice of variable while
#      missing a two-dot diff on the correct one, which is the likelier drift.
#      This assertion says nothing about WHICH spelling a call should use; the
#      three-dot range is the whole requirement.
#
#      Scoped per CALL by three walls: the next `diff --name-only` (without
#      which the window runs to end of line and a two-dot call is vouched for
#      by a LATER correct call's dots), `#`, and a backtick. The latter two end
#      a shell line's code and close a markdown code span; without them a
#      correct call carrying a trailing `# was BASE_REF` comment would report
#      itself, and so would prose naming the command and a base in one
#      sentence.
#
#      This assertion scans `.claude/agents/code-audit-*.md`, NOT the whole
#      directory that (1) and (2) range over. Only a Code Audit Team member HAS
#      a review base; an agent that takes its file list from the orchestrator
#      (.claude/agents/worthiness-evaluator.md) has nothing for this rule to be
#      about, and scanning it buys only a false-positive surface, since its
#      prose stays clean on the backtick wall alone and a rewording could red
#      the check for a file with no base at all. The `code-audit-` prefix is
#      the same convention the roster globs in .gaia/audit-ci.yml, the CI
#      paths filter in audit-ci-tests.yml, and block-selfheal-paths.sh all
#      already key on, so this narrows to what the rest of the system treats
#      as the member set rather than inventing a second one.
#
#      What it does NOT see, deliberately, is the multi-line form: a fence
#      assigning `changed=$(git diff --name-only "$X" ...)` where `X` took the
#      resolver's output on an earlier line. Line-scoped, like every assertion
#      here.
# gaia:maintainer-only:start
#      The behavioural suite next door executes the real fences and compares
#      the resulting file lists, which is what covers that shape.
# gaia:maintainer-only:end
#
#   4. No `diff --name-only` CONSUMES the base without `-z`.
#
#      (3) polices the RANGE a call compares. This polices the ENCODING of
#      what it prints back, and the two are independent: a correct three-dot
#      call still emits a C-quoted token for any path carrying non-ASCII or
#      control bytes, because git's default `core.quotePath` wraps such a path
#      in double quotes and backslash-escapes the offending bytes. A tracked
#      file whose name carries an accented character comes back as a quoted
#      token full of octal escapes rather than as its own name.
#
#      What earns this an assertion rather than a style note is that the
#      consequence FAILS OPEN, in two different places and two different ways.
#
#      `full_changed` decides whether a specialist runs at all: it filters that
#      list against the member's remit globs and self-skips when nothing
#      matches. A quoted token matches no glob, so a pull request whose only
#      in-remit change is such a file yields an empty filtered set and the
#      member self-skips, writing no marker. A clean skip and a genuine
#      no-match are indistinguishable by then, so nothing records that the file
#      went unreviewed.
#
#      The same derivation decides MEMBERSHIP one step earlier, in
#      .gaia/scripts/resolve-audit-members.sh, and that is the more dangerous
#      of the two because it is silent rather than stuck. A quoted token has no
#      owner, the resolver answers with an empty set, and resolve-audit-spawn.sh
#      falls through to its ownerless probe, which spawns the default member.
#      So the file does get an auditor -- just never the specialist whose remit
#      it is in, and the merge completes looking audited. (The specialist's own
#      self-skip is the less quiet failure: when membership DID name it, a
#      self-skip leaves a marker the gate still demands, which deadlocks
#      loudly rather than passing.)
#
#      `-z` rather than `-c core.quotePath=false`, which is the narrower fix
#      and the tempting one: the flag only stops treating bytes above 0x7f as
#      unusual, so a path containing a double quote, a backslash, or a control
#      byte is still C-quoted. `-z` suppresses quoting outright and terminates
#      each path with a NUL instead. Every derivation in the roster already
#      spells it that way, so this pins the shape rather than introducing one.
#
#      Shares assertion 3's candidate net and its per-call window, for the
#      reason the shared helper's own header gives.
#
#      What it does NOT see is a call that carries `-z` and never converts the
#      NULs back, which fails open the same way: bash drops NUL bytes in a
#      command substitution, so every path concatenates into one token that
#      matches no glob. Requiring the conversion is not available to this net,
#      because the net cannot tell a fence from prose and code-audit-frontend.md
#      states the command inside a markdown code span with no pipeline after
#      it, which such a requirement would red.
# gaia:maintainer-only:start
#      The behavioural suite next door executes the real fences against a
#      repository carrying a non-ASCII path, which is what covers that shape.
# gaia:maintainer-only:end
#
#      The flag has to sit IMMEDIATELY after the `--name-only` it modifies, not
#      merely somewhere in the call. Anywhere-in-the-call is a weaker claim than
#      it looks: a pathspec (`-- "app/[a-z]/*"`) or an emptiness test on the
#      same line contains the token while the call still quotes, so the
#      assertion would vouch for exactly the shape it exists to reject.
#      The rejected set is therefore every correct spelling that does not put
#      `-z` immediately after `--name-only`, separated by exactly one space:
#      `git diff -z --name-only`, an intervening flag
#      (`--name-only --diff-filter=d -z`), and a tab or a double space. That is
#      the accepted cost, and it is accepted rather than worked around because
#      no positional rule admits every spelling, the roster spells all eight of
#      its own sites the one way, and the failure this trades into is loud and
#      one edit from resolved where the false green it replaces is silent.
#
# Comment lines are NOT stripped from either scan, unlike
# check-main-root-derivation.sh, which scans executable source where a
# commented-out shape cannot run. These are agent definitions: the file IS
# the instruction, and a "commented-out" derivation in one is still a line a
# model can follow. A comment that spells the bad shape reds this check on
# purpose.
#
# Dual-mode, like the repo's other check scripts: source it for
# gaia_check_audit_base_derivation, or run it directly as a script (see
# "Executable entry" at the bottom).
#
# gaia_check_audit_base_derivation <repo_root>
#   Runs `git -C <repo_root> grep` over `.claude/agents/` (recursive) for
#   every assertion. Prints every match line, then one verdict line per
#   assertion. Returns 0 when ALL FOUR hold, 1 otherwise.
#   <repo_root> is a required parameter -- this check never derives it
#   itself: a CI caller passes the plain checkout root, a bats fixture
#   passes a temp repo, so "would this literal fail the check" is testable
#   without touching real tracked source.
#
# GREEN against this repo's real `.claude/agents/`: all five definitions
# resolve their review base through the resolver, the only bare merge-base
# left is each specialist's `FULL_BASE`, and every changed-file diff is a
# three-dot range against HEAD carrying `-z`.

# Assertion 1's candidate shape: any assignment whose value reaches a
# `merge-base` call. Deliberately a wide net -- BOTH discriminations that
# narrow it run in awk below, where they are expressible and an ERE's are
# not.
#
# Enumerating the bad shapes here does not work, because the set is open.
# `origin/${default_branch}`, the bare `"${default_branch}"` fallback, and a
# literal `merge-base HEAD main` are three spellings of one drift, and the
# third defeats a branch-name literal in the pattern: `main` appears in the
# ordinary English of these files (`main-thread-authored` at
# code-audit-frontend.md:654), so an ERE carrying it reds a correct tree.
#
# So the check identifies the ONE shape that is right instead. A review base
# derived through the resolver always passes BASE_REF to its own merge-base
# call; every drifted spelling names a branch instead, and FULL_BASE names
# neither. That single positive rule covers every drift SPELLING without
# naming any of them, which is what the open set above defeats.
#
# It is not unconditional, in two ways.
#
# The candidate net still requires the literal `merge-base`, so a base
# derived some other way entirely (`BASE_SHA=$(git rev-parse
# "origin/${default_branch}")`) is never a candidate and this check does not
# see it.
#
# Nearer, and likelier: the two-step resolver shape survives verbatim while
# only BASE_REF's SOURCE changes, `BASE_REF="origin/${default_branch}"`
# feeding the same `merge-base "${BASE_REF}" HEAD`. Assertion 1 exempts that
# call correctly by its own rule, because BASE_REF genuinely is an argument
# to it; assertion 2 passes, because the file still names the resolver in
# its prose. The member has nonetheless reverted fully to the pre-fix bare
# derivation, and the charter sentence at the top of this file ("The review
# base must come from `.github/audit/resolve-audit-base.sh`") promises more
# than the assertion delivers. Neither gap is closed statically.
# gaia:maintainer-only:start
#
# The behavioural suite next door covers both, by executing the real fences.
# gaia:maintainer-only:end
GAIA_AUDIT_BARE_MERGE_BASE_PATTERN='[A-Za-z_][A-Za-z0-9_]*=.*merge-base'

# Assertion 2's two fixed strings.
GAIA_AUDIT_BASE_VAR='BASE_SHA'
GAIA_AUDIT_BASE_RESOLVER='resolve-audit-base.sh'

# Assertion 3's candidate net: every `diff --name-only`, correct ones included.
# A fixed string, not an ERE, for the same reason assertion 2's are: the set of
# ways to spell a wrong consumer is open, so the awk below identifies the one
# shape that is right instead of enumerating the ones that are not.
# The awk below receives this via -v and measures it with length(), so the grep
# net and the scan cannot disagree about what a call looks like. (Assertion 1
# predates that and still restates its `merge-base` literal by hand.)
GAIA_AUDIT_DIFF_CALL='diff --name-only'

# _gaia_drop_full_base_matches: reads `file:line:content` lines on stdin (git
# grep's -n format) and keeps only the lines that are actually violations,
# applying the two discriminations the ERE cannot express. A line survives
# when it carries at least one `merge-base` call that neither takes BASE_REF
# inside its own argument list (the resolver-derived shape this check
# requires) nor is owned by FULL_BASE (the self-skip base and the default
# member's waive-eligibility base, deliberately exempt). Both tests are per
# CALL, never per line: "its own argument list" ends at the `)` that closes
# the call, so a BASE_REF named anywhere after that vouches for nothing.
#
# `sub` on a copy removes only the FIRST two colon-delimited fields, so a
# colon inside the content itself never shifts the boundary. The owning
# assignment is the LAST `IDENT=` occurring before a call, which is what
# "nearest to the left" means on one line.
#
# The name is narrower than the job: it predates the BASE_REF rule.
#
# EVERY `merge-base` on the line is tested, not just the first. The real
# FULL_BASE assignment already puts two on one line (the `origin/` form and
# its bare fallback, joined by `||`), so a rule keyed to the first
# occurrence alone would clear a whole line whose first call belongs to
# FULL_BASE and whose second belongs to something else.
_gaia_drop_full_base_matches() {
  awk '
    {
      content = $0
      sub(/^[^:]*:[^:]*:/, "", content)
      # `consumed` is how much of content `rest` starts past, so the prefix
      # handed to the ownership walk is always measured from column 1 of the
      # real line rather than from the current search window.
      consumed = 0
      rest = content
      while ((pos = index(rest, "merge-base")) > 0) {
        # Discrimination 1, the positive rule: a call taking BASE_REF as an
        # argument derives its base through the resolver, the shape this
        # check REQUIRES. That is what lets the ERE above stay a wide
        # `merge-base` net without every correct line becoming a violation.
        #
        # Scoped to THIS call'"'"'s own argument list, not the whole line and
        # not merely the text after it. A line-wide test is unsound for the
        # same reason the occurrence walk below exists: `BASE_REF=... ;
        # BASE_SHA=$(git merge-base HEAD origin/main)` would clear on the
        # mention alone, and so would a trailing `# was BASE_REF` comment.
        #
        # The stop set has to close the argument list, and `)` is what
        # actually does that: the call lives inside a `$( )`, so a BASE_REF
        # occurring AFTER the substitution ends is not an argument to it.
        # Without `)` a prose line like "was BASE_SHA=$(git merge-base HEAD
        # main), now BASE_REF" exempts itself. The backtick closes a markdown
        # code span, the same escape one sentence later. Neither character
        # can precede BASE_REF inside the canonical
        # `merge-base "${BASE_REF}" HEAD`.
        #
        # BASE_REF also has to be a WHOLE identifier on its LEFT edge. Matched
        # as a bare substring it is satisfied by the TAIL of a longer name, so
        # a drift routed through an alias exempts itself: `merge-base HEAD
        # "$GITHUB_BASE_REF"` names a branch, and that is an ordinary CI
        # variable rather than an invented one. The class closing the prefix
        # group is that boundary; `"${BASE_REF}"` and `"$BASE_REF"` clear it
        # on their `{` and `$`. The group is optional only so a token at
        # position 0 still matches.
        #
        # That boundary class subtracts the stop set as well, which is not
        # redundant with the run before it. A bare `[^A-Za-z0-9_]` is a
        # SUPERSET of the stop set, so the group could end ON a stop character
        # and hand the exemption straight back: `merge-base HEAD main)BASE_REF`
        # would clear on the `)` that closes the call, the one character the
        # stop set exists to treat as a wall. All six behave that way, so the
        # boundary atom excludes them too.
        #
        # The mirrored RIGHT edge (`${BASE_REF_OLD}`) is knowingly left open,
        # and not for want of a construct: `BASE_REF([^A-Za-z0-9_]|$)` is
        # plain ERE, and the alternation keeps a line that ENDS at the token
        # exempt. It is unused because no drift spelling builds a name by
        # SUFFIXING the token, where `GITHUB_BASE_REF` makes the prefix side
        # live, so the assertion would guard nothing.
        right = substr(content, consumed + pos + 10)
        if (right ~ /^([^|;&#)`]*[^A-Za-z0-9_|;&#)`])?BASE_REF/) {
          consumed += pos + 9
          rest = substr(content, consumed + 1)
          continue
        }
        left = substr(content, 1, consumed + pos - 1)
        name = ""
        while (match(left, /[A-Za-z_][A-Za-z0-9_]*=/)) {
          name = substr(left, RSTART, RLENGTH - 1)
          left = substr(left, RSTART + RLENGTH)
        }
        if (name != "FULL_BASE") { print; next }
        consumed += pos + 9
        rest = substr(content, consumed + 1)
      }
    }
  '
}

# _gaia_keep_diff_matches_missing <token>: reads `file:line:content` lines on
# stdin (git grep's -n format) and keeps only the `diff --name-only` calls that
# consume the review base and do NOT carry <token> inside their own text.
#
# TWO assertions share this walk, and the sharing is deliberate rather than
# incidental. Assertion 3 passes `...` (the call compares against the fork
# point) and assertion 4 passes `-z` (the call does not let git quote what it
# prints). Both are the same sentence about a base-consuming call, differing
# only in the token it must carry, and the window logic below is subtle enough
# that a second copy of it would drift from this one. A fix applied to one of
# two sibling derivations and not the other is precisely the defect class
# assertion 4 exists to close, so this file does not open a second instance of
# it in its own source.
#
# The `consumes` test and the token test are both per CALL and measured from
# the call, never line-wide: a line may legitimately carry a correct diff and,
# further along, prose naming the resolver.
#
# The call's text ends at the first `#`, backtick, `;`, or `)` after it. Those
# four characters are the walls that matter here: `#` opens a shell comment,
# a backtick closes a markdown code span, `;` ends the command outright, `)`
# closes the `$( )` the call lives inside, and past any of them the text is no
# longer part of this call. `;` and `)` are walls for the same reason
# _gaia_drop_full_base_matches treats them as one -- nothing in a real call's
# argument list contains either, so each can only introduce text belonging to
# something OTHER than this call, which must never vouch for it.
#
# `)` earns its place on a concrete escape rather than on symmetry. Without it
# the window of `changed=$(git diff --name-only "${BASE}...HEAD") && [ -z
# "$changed" ]` runs to end of line, and the emptiness test's own `-z` then
# satisfies assertion 4 for a call that quotes. None of the other three walls
# closes that: there is no second call, no comment, and no code span.
#
# `|` is deliberately NOT a wall, which is where this walk and the ownership
# walk part company: a pathspec or a redirect routinely follows the revision
# argument, and `2>/dev/null || true` closes almost every real call, so
# treating `|` as a wall would cut the window before the tokens this assertion
# is looking for.
#
# `sub` on a copy removes only the FIRST two colon-delimited fields, so a colon
# inside the content itself never shifts the boundary -- the same framing the
# ownership walk uses.
# <anchored>, any non-empty value, additionally requires the token to sit at the
# START of the window, which is the position immediately after the call. That is
# the difference between "this call passes -z" and "these two characters occur
# somewhere in this call", and the two are not the same claim: a pathspec like
# `-- "app/[a-z]/*"` contains the token while the call still lets git quote.
# Assertion 4 anchors for that reason; assertion 3 must not, because `...` is
# legitimately written on either side of the revision argument.
_gaia_keep_diff_matches_missing() {
  local tok="${1:?_gaia_keep_diff_matches_missing requires a token argument}"
  local anchored="${2:-}"
  awk -v call="$GAIA_AUDIT_DIFF_CALL" -v tok="$tok" -v anchored="$anchored" '
    BEGIN { calllen = length(call) }
    {
      content = $0
      sub(/^[^:]*:[^:]*:/, "", content)
      consumed = 0
      rest = content
      while ((pos = index(rest, call)) > 0) {
        # The call window: everything after this occurrence, cut at the first
        # wall. FIVE walls, and the first is what makes "per call" true rather
        # than merely claimed: without it the window runs to end of line, so a
        # two-dot call followed on the same line by a correct three-dot one is
        # vouched for by the dots belonging to that LATER call. The `;` and `)`
        # walls close the same hole for later text that is not a diff call at
        # all, which the first wall cannot see.
        # _gaia_drop_full_base_matches bounds its own scan at the closing paren
        # for the same reason.
        #
        # Each cut applies to the already-shortened window, so the walls
        # compose to the EARLIEST of the five and their order here is
        # immaterial.
        #
        # No apostrophe anywhere in this program: it is a single-quoted shell
        # string, so one would end it and hand the rest to bash as source.
        window = substr(content, consumed + pos + calllen)
        if ((w = index(window, call)) > 0)  window = substr(window, 1, w - 1)
        if ((w = index(window, "#")) > 0)   window = substr(window, 1, w - 1)
        if ((w = index(window, ")")) > 0)   window = substr(window, 1, w - 1)
        if ((w = index(window, "`")) > 0)   window = substr(window, 1, w - 1)
        if ((w = index(window, ";")) > 0)   window = substr(window, 1, w - 1)

        # Does this call consume the review base at all? Every spelling of it
        # counts, before and after merge-base alike: the defect is the TWO-DOT
        # comparison, and `"${BASE_SHA}"` performs it exactly as
        # `"$BASE_REF"` does. Keying on the pre-merge-base spellings alone
        # would police which variable a member names while missing a two-dot
        # diff on the correct one, which is the likelier drift by far.
        consumes = index(window, "resolve-audit-base.sh") > 0 \
                || index(window, "BASE_REF") > 0 \
                || index(window, "BASE_SHA") > 0 \
                || index(window, "FULL_BASE") > 0

        # A base-consuming call must carry the token, and `anchored` decides
        # WHERE. Unanchored for `...`, whose correct forms put it on either
        # side of the revision argument depending on the spelling
        # (`"${BASE_SHA}...HEAD"` after, a pathspec-first variant before), so a
        # rule pinning the side would reject a correct call to reject a
        # stylistic one. Anchored for `-z`, where the position IS the claim:
        # unanchored, any `-z` occurring later in the call satisfies it, and a
        # pathspec is the ordinary way that happens by accident.
        missing = anchored != "" ? index(window, tok) != 1 : index(window, tok) == 0
        if (consumes && missing) { print; next }
        consumed += pos + calllen - 1
        rest = substr(content, consumed + 1)
      }
    }
  '
}

gaia_check_audit_base_derivation() {
  local repo_root="${1:?gaia_check_audit_base_derivation requires a repo_root argument}"
  local bare_failed=0 resolver_failed=0 consumer_failed=0 quoting_failed=0

  # A `git grep` that cannot run returns nothing, which is byte-identical to
  # "scanned it, found no violations". Both assertions would then print 0 and
  # the function would report a clean tree it never read. The no-argument
  # path at the bottom of this file already fails closed on this; an explicit
  # argument pointing outside a repository reached the same silence.
  # Exit 2, distinct from assertion failure (1), so a caller can tell "the
  # check says no" from "the check could not run".
  # --show-prefix, not --git-dir: --git-dir succeeds from any path INSIDE a
  # repo, so a subdirectory passed as repo_root would clear the guard and
  # then scan a `.claude/agents/` that does not exist beneath it, returning
  # the same unscanned-tree 0/0 this guard exists to stop.
  #
  # --show-prefix answers both questions in one call and needs no `cd`
  # (.claude/rules/shell-cwd.md): it fails outright outside a repository, and
  # inside one it prints the path from the repo root down to the directory,
  # which is empty exactly at the root. Comparing paths textually would need
  # a subshell `cd` to resolve symlinks on both sides; this does not.
  # --is-inside-work-tree as well: --show-prefix exits 0 with empty output
  # inside a BARE repository and inside a `.git` directory, so either would
  # clear a prefix-only guard as a work-tree root, and the `git grep` below
  # would then fail for want of a work tree with its diagnostic swallowed by
  # the same 2>/dev/null -- the identical unscanned-tree 0/0. It reports
  # false for both shapes and true for a root, a linked worktree root, and a
  # symlink to one.
  local prefix
  if ! prefix="$(git -C "$repo_root" rev-parse --show-prefix 2>/dev/null)" || [ -n "$prefix" ] \
    || [ "$(git -C "$repo_root" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    printf 'check-audit-base-derivation: %s is not a git repository root; nothing was scanned\n' "$repo_root" >&2
    return 2
  fi

  # ---------- assertion 1: no bare-merge-base review derivation ----------
  local candidates bare_matches bare_count=0
  # git grep exits 1 when it finds nothing, a normal outcome here, not a
  # script error -- so it is not run under -e and its status is captured
  # explicitly via the variable assignment instead.
  candidates="$(git -C "$repo_root" grep -nIE "$GAIA_AUDIT_BARE_MERGE_BASE_PATTERN" -- '.claude/agents/' 2>/dev/null)"
  bare_matches="$(printf '%s\n' "$candidates" | _gaia_drop_full_base_matches)"
  if [ -n "$bare_matches" ]; then
    printf '%s\n' "$bare_matches"
    bare_count="$(printf '%s\n' "$bare_matches" | wc -l | tr -d ' ')"
    bare_failed=1
  fi
  printf 'review bases derived by a bare merge-base against the default branch: %s\n' "$bare_count"

  # ---------- assertion 2: every BASE_SHA namer names the resolver ----------
  local base_files f missing_count=0
  base_files="$(git -C "$repo_root" grep -lIF "$GAIA_AUDIT_BASE_VAR" -- '.claude/agents/' 2>/dev/null)"
  if [ -n "$base_files" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! git -C "$repo_root" grep -qF "$GAIA_AUDIT_BASE_RESOLVER" -- "$f" 2>/dev/null; then
        printf 'names BASE_SHA but never names resolve-audit-base.sh: %s\n' "$f"
        missing_count=$((missing_count + 1))
        resolver_failed=1
      fi
    done <<< "$base_files"
  fi
  printf 'agent files naming BASE_SHA without naming resolve-audit-base.sh: %s\n' "$missing_count"

  # ---------- assertion 3: no diff consumes an un-anchored base ----------
  #
  # One candidate net feeds assertions 3 and 4: they range over the same calls
  # and differ only in the token each requires, so a second `git grep` would be
  # the same list resolved twice with the two able to disagree.
  local diff_candidates diff_matches diff_count=0
  diff_candidates="$(git -C "$repo_root" grep -nIF "$GAIA_AUDIT_DIFF_CALL" -- '.claude/agents/code-audit-*.md' 2>/dev/null)"
  diff_matches="$(printf '%s\n' "$diff_candidates" | _gaia_keep_diff_matches_missing '...')"
  if [ -n "$diff_matches" ]; then
    printf '%s\n' "$diff_matches"
    diff_count="$(printf '%s\n' "$diff_matches" | wc -l | tr -d ' ')"
    consumer_failed=1
  fi
  printf 'review diffs consuming a base that never reached the fork point: %s\n' "$diff_count"

  # ---------- assertion 4: no diff lets git quote the paths it prints -------
  local quote_matches quote_count=0
  quote_matches="$(printf '%s\n' "$diff_candidates" | _gaia_keep_diff_matches_missing ' -z' anchored)"
  if [ -n "$quote_matches" ]; then
    printf '%s\n' "$quote_matches"
    quote_count="$(printf '%s\n' "$quote_matches" | wc -l | tr -d ' ')"
    quoting_failed=1
  fi
  printf 'changed-file diffs that let git C-quote a path: %s\n' "$quote_count"

  [ "$bare_failed" -eq 0 ] && [ "$resolver_failed" -eq 0 ] && [ "$consumer_failed" -eq 0 ] \
    && [ "$quoting_failed" -eq 0 ]
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-audit-base-derivation: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_audit_base_derivation "$repo_root"
  exit $?
fi
