#!/usr/bin/env bash
# shellcheck shell=bash
#
# Adoption check for SPEC-077's scope-digest staleness gate. The shared
# clearance writer's `--scope-digest` refusal only closes the loop when the
# omission is caught before a member spends a full review round, not after
# it calls the writer and gets refused. Nothing stops a sixth agent
# definition, or an edit to any definition that ships today, from dropping
# `--scope-digest` again once it lands everywhere. This check makes four
# things machine-detectable:
#
#   1. Every earned clearance-write call site, across every agent
#      definition and every workflow copy, passes `--scope-digest`.
#   2. The frozen scope-resolution obligation literal is present, exactly
#      once, byte-identical, in every agent definition.
#   3. The capture happens at scope resolution. A definition resolves its
#      scope with one command, `<root>/.gaia/scripts/audit-resolve-scope.sh
#      --member <that member> --root <root>`, and that script performs the
#      capture. So the assertion has two halves: the resolver command, naming
#      THIS member, sits inside each definition's own scope-resolution
#      region, not merely somewhere later in the file (code-audit-frontend.md
#      names the resolver and `audit-scope-digest.sh` in several places
#      outside that region, so a whole-file grep would still pass on a
#      definition whose command survived only as a stray mention); and the
#      resolver script itself still calls `audit-scope-digest.sh --capture`,
#      since a definition invoking a resolver that no longer captures says
#      it captures while nothing does.
#   4. Every pre-approval granted for these two scripts actually covers a
#      call site that is spelled the way the grant is spelled. A permission
#      rule is a literal prefix match, so a grant and an invocation can
#      agree in meaning and still miss each other completely, and nothing
#      reports the miss: the call falls through to a prompt exactly as if
#      no grant had ever been written. Assertion 4 is what stops those two
#      spellings drifting apart silently again.
#
# Scan surface for assertion 1 (and the fourth entry, why it's here):
#   .claude/agents/code-audit-*.md
#   .github/workflows/
#   .gaia/cli/src/automation/templates/workflows/
#   .gaia/cli/templates/workflows/
# The fourth is the bundled artifact byte-derived from the third;
# `.gaia/scripts/tests/audit-guard-structural.bats` already asserts the two
# hash equal, so this check's coverage of it is a cheap belt, not an
# independent judgement about a generated file.
#
# Assertion 1's join, and why two different joins: the agent definitions
# spell an earned call site as a fenced bash block whose lines end in a
# trailing backslash; the workflow copies spell the same call as an inline
# backtick-delimited code span word-wrapped across several physical lines of
# a YAML `prompt: |` block, no backslash in sight. A single pass handles
# both without knowing which file it is looking at: a line opening a triple-
# backtick fence toggles fenced mode, where lines are joined on a trailing
# backslash exactly as a shell continuation would join them; outside a
# fence, a single backtick opens or closes an inline span, and a span still
# open at end-of-line absorbs the line break as one space and keeps
# accumulating on the next line. A line-at-a-time grep cannot see either
# shape reliably, since neither the script name nor `--provenance earned`
# nor `--scope-digest` line up on one physical line often enough to be
# found together without the join.
#
# Honest limit: this is a token-and-shape check over prose, not a proof that
# a member run actually captures or reads anything. It proves a definition
# *says* it captures where scope is resolved and passes the flag on every
# earned write it spells out; a member could still say one thing and do
# another at runtime, which nothing here observes.
#
# Dual-mode, mirroring check-verb-arming-adoption.sh: source it for
# gaia_check_scope_digest_adoption, or run it directly as a script.
#
# gaia_check_scope_digest_adoption <repo_root>
#   Prints one line per finding plus a verdict line per assertion. Returns 0
#   when all four hold, 1 when any does not, 2 on the check's own failure.
#   The 2 cases: an unresolvable root, a repo_root with no `.claude/agents/`
#   directory at all (nothing to scan, not a vacuous pass), and assertion
#   4's `jq` being absent. The last of those is reported as 2 only when
#   assertions 1-3 found nothing; when one of them did, the run exits 1 and
#   names it, so an environment note never hides those findings behind a
#   status that reads as "fix your toolchain and re-run".
#
#   What a missing `jq` still costs, and it is not hidden: assertion 4
#   returns at its own settings arm, so its WORKFLOW half does not run
#   either, even though that half needs no `jq`. A grant-versus-call-site
#   drift inside a workflow file is therefore neither found nor named on a
#   `jq`-less machine. Nothing merges on it -- exit 2 is non-zero and
#   `.gaia/tests/whole-tree-invariants.sh` fails on any non-zero -- so this
#   is a coverage gap behind a blocking status, not a fail-open.
#
#   <repo_root> is a required parameter -- this check never derives it
#   itself, so a bats fixture can drive it against a throwaway repo.

# The Code Audit Team members this check reasons about, and assertion 3's
# per-member region anchor beside each. Both are DISCOVERED by
# _gaia_sda_load_members below, never transcribed here. A transcribed roster
# cannot see the one definition this check's own header names as the thing it
# exists to catch: a newly registered member whose earned call sites omit
# `--scope-digest` would never be opened, every pre-merge check would pass,
# and the defect would surface mid-round as a forfeited review. Declared
# empty so the loader is the only writer.
GAIA_SDA_MEMBERS=()
GAIA_SDA_START_ANCHOR=()

# Assertion 3's scope-resolution region start anchor. Nearly every member
# resolves its scope (and captures there) directly under its own
# "## Remit and self-skip" section, which is the default. code-audit-frontend
# is the standing exception: its "Remit and self-skip" only decides whether
# it reviews at all, and the resolver command that actually derives
# KEY_BASE/BASE_SHA/D_SCOPE lives under "### How to run" inside
# "## Rules-Based Audit" instead (that file's own "Re-run carry-forward
# ledger" section names this location). Giving every member the default
# anchor would make this assertion vacuous for the one member it most needs
# to catch drift in. The exception rides in a table keyed by member NAME
# rather than in a positional array beside the roster, because a positional
# pair desyncs the moment the roster gains or reorders an entry, and the
# roster is now discovered rather than written down.
GAIA_SDA_DEFAULT_START_ANCHOR='^## Remit and self-skip'
GAIA_SDA_ANCHOR_OVERRIDES=(
  'code-audit-frontend|^### How to run'
)

# _gaia_sda_start_anchor <member>: this member's region anchor -- its
# override when the table carries one, otherwise the default.
_gaia_sda_start_anchor() {
  local member="$1" entry
  for entry in "${GAIA_SDA_ANCHOR_OVERRIDES[@]}"; do
    case "$entry" in
      "${member}|"*) printf '%s\n' "${entry#*|}"; return 0 ;;
    esac
  done
  printf '%s\n' "$GAIA_SDA_DEFAULT_START_ANCHOR"
}

# _gaia_sda_roster_members <repo_root>: the member names .gaia/audit-ci.yml
# declares, one per line; nothing when that file is absent. Parsed with the
# same block discipline .claude/hooks/lib/audit-scope.sh's own auditors
# reader uses -- `auditors:` opens the block and the next column-0 key closes
# it -- rather than grepping `- name:` file-wide, which would also collect a
# name out of an unrelated top-level list.
_gaia_sda_roster_members() {
  local config="$1/.gaia/audit-ci.yml"
  [ -f "$config" ] || return 0
  awk '
    /^auditors[[:space:]]*:/ { in_auditors = 1; next }
    !in_auditors { next }
    /^[A-Za-z_]/ { in_auditors = 0; next }
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      gsub(/"/, "", line)
      if (line != "") print line
    }
  ' "$config"
}

# _gaia_sda_load_members <repo_root>: fill the two parallel arrays, in one
# pass so they cannot desync, from the UNION of two sources.
#
# The definitions on disk are what makes a newly registered member visible:
# that is the case this check's header names as its reason to exist, and a
# transcribed roster is blind to it by construction. The roster declared in
# .gaia/audit-ci.yml is what keeps a DELETED definition visible: discovery
# alone cannot miss a file that is not there, it simply stops calling it a
# member, so a member silently dropped from disk would read as clean. Each
# source covers the other's blind spot, which is why this takes both rather
# than picking one.
#
# Returns non-zero when the union is empty, which the caller reports as an
# environment error rather than a pass: a check whose own input set came back
# empty has verified nothing, and reporting that as clean is exactly the
# failure .claude/rules/guards-must-fail.md names.
_gaia_sda_load_members() {
  local repo_root="$1" file base names="" name
  GAIA_SDA_MEMBERS=()
  GAIA_SDA_START_ANCHOR=()

  for file in "$repo_root"/.claude/agents/code-audit-*.md; do
    [ -f "$file" ] || continue
    base="${file##*/}"
    names="${names}${base%.md}
"
  done
  names="${names}$(_gaia_sda_roster_members "$repo_root")"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    GAIA_SDA_MEMBERS+=("$name")
    GAIA_SDA_START_ANCHOR+=("$(_gaia_sda_start_anchor "$name")")
  done <<EOF
$(printf '%s\n' "$names" | LC_ALL=C sort -u)
EOF

  [ "${#GAIA_SDA_MEMBERS[@]}" -gt 0 ]
}

# Terminator: the next heading at level 2 or 3, whichever bounds the fence
# for that member. Matches the extraction idiom already in
# .gaia/tests/lib/doc-machinery-waive-prose.bats.
GAIA_SDA_REGION_TERMINATOR='^#{2,3} '

# The three directories carrying a workflow copy of the earned call site,
# beside the agent definitions. Every regular file under each is
# scanned; nothing here depends on the copy's exact filename.
GAIA_SDA_WORKFLOW_DIRS=(
  .github/workflows
  .gaia/cli/src/automation/templates/workflows
  .gaia/cli/templates/workflows
)

# The stable anchor phrase assertion 2 uses to locate the obligation literal
# without transcribing a paraphrase of it into this script: the literal is
# read out of the first member's own file and every other member is compared
# against THAT text, so this check cannot drift from the thing it checks.
GAIA_SDA_OBLIGATION_ANCHOR='Capture your own content digest at scope resolution with'

# The scripts assertion 4 judges: the two this file's header already names
# as its subject, and no others. Widening this list would pull in grants
# whose call sites live outside every directory this check scans (the plan
# and registry helpers are invoked from skills and commands, not from an
# agent definition or a workflow), so each would read as an ungranted or
# unmatched spelling on evidence this check never gathered. A third entry
# earns its place by having its call sites inside the scan surface, not by
# appearing in the same `permissions.allow` block.
GAIA_SDA_GRANTED_SCRIPTS=(
  audit-scope-digest.sh
  audit-write-clearance.sh
)

# _gaia_sda_extract_joined <file>: prints one "logical line" per accumulated
# statement, joining continuations per the header comment above. A fenced
# code block's lines join on a trailing backslash; prose outside a fence
# joins across an inline backtick span that stays open past a line break.
_gaia_sda_extract_joined() {
  awk '
    BEGIN { in_fence = 0; in_span = 0; cont = ""; span = "" }
    {
      raw = $0
      stripped = raw
      sub(/^[[:space:]]*/, "", stripped)
      if (stripped ~ /^```/) {
        if (cont != "") { print cont; cont = "" }
        in_fence = !in_fence
        next
      }
      if (in_fence) {
        line = raw
        if (cont != "") { line = cont " " line }
        if (line ~ /\\[[:space:]]*$/) {
          sub(/\\[[:space:]]*$/, "", line)
          cont = line
          next
        }
        print line
        cont = ""
      } else {
        n = length(raw)
        for (i = 1; i <= n; i++) {
          c = substr(raw, i, 1)
          if (c == "`") {
            if (in_span) { print span; span = ""; in_span = 0 }
            else { in_span = 1; span = "" }
          } else if (in_span) {
            span = span c
          }
        }
        if (in_span) { span = span " " }
      }
    }
    END {
      if (cont != "") print cont
      # A span still open at end of file means an unmatched backtick absorbed
      # everything after it. Emit what was absorbed so a call site inside it is
      # still examined, then fail: reporting coverage over a set this parser
      # silently truncated is the fail-open shape this check exists to prevent,
      # and a single stray backtick in a 900-line prompt block is enough to
      # invert the span state for the whole remainder of the file.
      if (in_span) { if (span != "") print span; exit 3 }
    }
  ' "$1"
}

# _gaia_sda_bad_call_sites <file> <label>: prints one line per joined
# statement that names audit-write-clearance.sh with --provenance earned but
# no --scope-digest. Returns 0 iff none found in <file>.
_gaia_sda_bad_call_sites() {
  local file="$1" label="$2" hits joined
  local rc=0
  # Capture the extraction and its status separately, so a truncated scan set is
  # a finding rather than a silent all-pass. The status is taken off the
  # assignment's own failure arm so the read is correct with or without errexit:
  # this script arms none today, but under errexit a command substitution hands
  # its status to the assignment and a following `$?` read would be dead.
  joined="$(_gaia_sda_extract_joined "$file")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: unmatched backtick leaves an inline span open at end of file; the scanned set is truncated, so coverage here cannot be trusted\n' "$label"
    return 1
  fi
  hits="$(printf '%s\n' "$joined" \
    | grep -F 'audit-write-clearance.sh' \
    | grep -F -- '--provenance earned' \
    | grep -vF -- '--scope-digest')"
  [ -z "$hits" ] && return 0
  printf '%s: earned call site missing --scope-digest\n' "$label"
  return 1
}

# _gaia_sda_assert1 <repo_root>: assertion 1 over every discovered definition
# plus every file under the workflow directories.
_gaia_sda_assert1() {
  local repo_root="$1" failed=0 member rel file wdir wfile rel2
  for member in "${GAIA_SDA_MEMBERS[@]}"; do
    rel=".claude/agents/${member}.md"
    file="$repo_root/$rel"
    if [ ! -f "$file" ]; then
      printf '%s: MISSING (agent definition not found)\n' "$rel"
      failed=1
      continue
    fi
    _gaia_sda_bad_call_sites "$file" "$rel" || failed=1
  done

  for wdir in "${GAIA_SDA_WORKFLOW_DIRS[@]}"; do
    [ -d "$repo_root/$wdir" ] || continue
    while IFS= read -r -d '' wfile; do
      rel2="${wfile#"$repo_root"/}"
      _gaia_sda_bad_call_sites "$wfile" "$rel2" || failed=1
    done < <(find "$repo_root/$wdir" -type f -print0 2>/dev/null)
  done

  [ "$failed" -eq 0 ] && printf 'earned call-site --scope-digest coverage: all pass\n'
  return "$failed"
}

# _gaia_sda_assert2 <repo_root>: the obligation literal, read from the first
# member and compared for byte identity (and exactly-once presence) against
# every other discovered definition.
_gaia_sda_assert2() {
  local repo_root="$1" failed=0 i member file count
  local -a text
  for i in "${!GAIA_SDA_MEMBERS[@]}"; do
    member="${GAIA_SDA_MEMBERS[$i]}"
    file="$repo_root/.claude/agents/${member}.md"
    text[i]=""
    if [ ! -f "$file" ]; then
      printf '.claude/agents/%s.md: MISSING\n' "$member"
      failed=1
      continue
    fi
    count="$(grep -cF -- "$GAIA_SDA_OBLIGATION_ANCHOR" "$file")"
    if [ "$count" -ne 1 ]; then
      printf '.claude/agents/%s.md: obligation literal present %s times, expected exactly 1\n' "$member" "$count"
      failed=1
      continue
    fi
    text[i]="$(grep -F -- "$GAIA_SDA_OBLIGATION_ANCHOR" "$file")"
  done

  local first="${text[0]}"
  if [ -z "$first" ]; then
    printf 'obligation literal: source-of-truth definition (%s) carries no literal to compare against\n' "${GAIA_SDA_MEMBERS[0]}"
    return 1
  fi
  for i in "${!GAIA_SDA_MEMBERS[@]}"; do
    [ -n "${text[$i]}" ] || continue
    if [ "${text[$i]}" != "$first" ]; then
      printf '.claude/agents/%s.md: obligation literal diverges from %s\n' "${GAIA_SDA_MEMBERS[$i]}" "${GAIA_SDA_MEMBERS[0]}"
      failed=1
    fi
  done

  [ "$failed" -eq 0 ] && printf 'obligation literal: byte-identical across every definition\n'
  return "$failed"
}

# _gaia_sda_extract_section <file> <start_ERE> <term_ERE>: prints from the
# first line matching <start_ERE> (inclusive) up to, excluding, the next
# line matching <term_ERE>.
_gaia_sda_extract_section() {
  awk -v start="$2" -v term="$3" '
    $0 ~ start { found=1; print; next }
    found && $0 ~ term { exit }
    found { print }
  ' "$1"
}

# The resolver every definition invokes at scope resolution, and the capture
# spelling assertion 3 requires inside it.
GAIA_SDA_RESOLVER='.gaia/scripts/audit-resolve-scope.sh'

# _gaia_sda_assert3 <repo_root>: the resolver command, naming this member,
# sits inside each member's own scope-resolution region
# (GAIA_SDA_START_ANCHOR), not merely somewhere later in the file; and the
# resolver script still performs the capture.
_gaia_sda_assert3() {
  local repo_root="$1" failed=0 i member file section
  for i in "${!GAIA_SDA_MEMBERS[@]}"; do
    member="${GAIA_SDA_MEMBERS[$i]}"
    file="$repo_root/.claude/agents/${member}.md"
    if [ ! -f "$file" ]; then
      printf '.claude/agents/%s.md: MISSING\n' "$member"
      failed=1
      continue
    fi
    section="$(_gaia_sda_extract_section "$file" "${GAIA_SDA_START_ANCHOR[$i]}" "$GAIA_SDA_REGION_TERMINATOR")"
    if [ -z "$section" ]; then
      printf '.claude/agents/%s.md: scope-resolution region anchor "%s" matched nothing\n' "$member" "${GAIA_SDA_START_ANCHOR[$i]}"
      failed=1
      continue
    fi
    # The needle is the resolver's name followed by `--member <this member>`
    # and a space, not the bare script name: prose in the same region names
    # the script in backticks with no `--member` after it, and a bare match
    # would pass on that mention alone with the command deleted. The
    # trailing space is what keeps a sibling whose name extends this one
    # from answering for it, and naming the member at all is what reds a
    # command copied from another definition unedited, which would resolve
    # and capture under the wrong member's name. `--root` must ride the same
    # line, as it does on the real command.
    if printf '%s\n' "$section" | grep -F -- "audit-resolve-scope.sh --member ${member} " | grep -qF -- ' --root '; then
      printf '.claude/agents/%s.md: capture found in its scope-resolution region\n' "$member"
    else
      printf '.claude/agents/%s.md: capture NOT found in its scope-resolution region (no %s --member %s --root command there; may exist only outside it)\n' "$member" "$GAIA_SDA_RESOLVER" "$member"
      failed=1
    fi
  done
  # 'sh" --capture --root', not a bare 'sh --capture': the resolver's header
  # names `audit-scope-digest.sh --capture` in prose too. The real
  # invocation's quoted-path form closes the quote immediately before
  # --capture and is followed by --root; the prose mention never is.
  if [ ! -f "$repo_root/$GAIA_SDA_RESOLVER" ]; then
    printf '%s: MISSING, so no definition that invokes it captures\n' "$GAIA_SDA_RESOLVER"
    failed=1
  elif grep -qF -- 'audit-scope-digest.sh" --capture --root' "$repo_root/$GAIA_SDA_RESOLVER"; then
    printf '%s: capture found\n' "$GAIA_SDA_RESOLVER"
  else
    printf '%s: capture NOT found, so no definition that invokes it captures\n' "$GAIA_SDA_RESOLVER"
    failed=1
  fi
  [ "$failed" -eq 0 ] && printf 'scope-resolution capture placement: every definition in region\n'
  return "$failed"
}

# _gaia_sda_grant_matchable <file> <script>: exits 0 when <file> spells at
# least one invocation of <script> that a `Bash(bash .gaia/scripts/<script>:*)`
# permission rule could actually prefix-match, exits 1 when it spells none,
# and exits 2 when the join truncated and the answer cannot be trusted.
#
# "Could prefix-match" is the whole point, and it is stricter than "mentions
# the script". A permission rule matches a command by literal prefix, so the
# only spelling it reaches is a statement that BEGINS with the granted text.
# Of the spellings this tree uses, only the bare one qualifies:
#
#   bash .gaia/scripts/audit-write-clearance.sh --root ...   <- matchable
#   bash "$AUDIT_ROOT/.gaia/scripts/audit-write-clearance.sh" ...
#   marker="$(bash .gaia/scripts/audit-write-clearance.sh ...
#
# The interpolated-root form begins with a root the rule's literal text
# cannot spell; the assignment form begins with an assignment, so no
# `Bash(bash ...)` rule of any spelling reaches it. Anchoring at statement
# start is also what keeps
# the obligation literal from answering for a real call site: that prose
# names `.gaia/scripts/audit-scope-digest.sh --capture` with no `bash`
# ahead of it, so it does not begin with the granted text either. That is
# the same vacuous-pass hazard assertion 3 guards against, in the same file.
_gaia_sda_grant_matchable() {
  local file="$1" script="$2" joined line trimmed
  local needle="bash .gaia/scripts/${script}"
  local rc=0
  joined="$(_gaia_sda_extract_joined "$file")" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      "$needle"|"$needle "*) return 0 ;;
    esac
  done <<EOF
$joined
EOF
  return 1
}

# _gaia_sda_grant_verdict <label> <script> <grant_state> <matchable>
#                         <scope_plural> <scope_singular> <callsite_label>
#   The grant-versus-call-site rule, held in one place so the two surfaces
#   below cannot come to disagree about it. The surfaces differ only in where
#   they look for a call site, which is what the two scope phrases carry;
#   keeping a second copy of the ladder per surface is the drifting-duplicate
#   shape this whole check exists to catch, so it does not get one.
#   Prints one finding line and returns 1 when the pair does not hold,
#   returns 0 silently when it does.
#
#   <callsite_label> is separate from <label> because the two name different
#   files on the settings surface, and only one of them can be right. A
#   truncation is a property of the file the CALL SITES were read from, and
#   for the settings surface that is an agent definition, never the JSON the
#   grant lives in: settings.json cannot carry a markdown inline span, so
#   naming it there sends the operator to a file that structurally cannot
#   hold the defect. On the workflow surface the two labels coincide, since
#   one file carries both the grant and the call sites.
_gaia_sda_grant_verdict() {
  local label="$1" script="$2" grant_state="$3" matchable="$4"
  local scope_plural="$5" scope_singular="$6" callsite_label="$7"
  if [ "$matchable" = untrusted ]; then
    printf '%s: unmatched backtick truncated the scan; the grant for %s cannot be checked\n' \
      "$callsite_label" "$script"
    return 1
  fi
  if [ "$grant_state" = granted ] && [ "$matchable" = none ]; then
    printf '%s: grants "Bash(bash .gaia/scripts/%s:*)" but nothing in %s spells a call site that rule can match\n' \
      "$label" "$script" "$scope_plural"
    return 1
  fi
  if [ "$grant_state" = ungranted ] && [ "$matchable" = some ]; then
    printf '%s: %s spells "bash .gaia/scripts/%s ..." but no grant here covers it\n' \
      "$label" "$scope_singular" "$script"
    return 1
  fi
  return 0
}

# _gaia_sda_assert4 <repo_root>: every pre-approval for the two scripts
# above covers a call site spelled the way the grant is spelled, in both
# directions and on both surfaces.
#
# Two surfaces, because the two run under different permission sets. A local
# session reads `.claude/settings.json` and dispatches the AGENT DEFINITIONS;
# a CI run reads the `--allowedTools` list in its own workflow file and
# dispatches the prompt in that same file. So the settings grants are judged
# against the definitions, and each workflow file's grants are judged against
# that file alone. Judging either against the other's call sites is what let
# the drift hide: the workflow copies kept spelling the granted form long
# after the definitions stopped, so a check that pooled every call site in
# the tree would have gone on passing.
#
# Both directions fail, and they fail for different reasons. A grant with no
# matchable call site is inert: it reads as a pre-approval, the operator
# believes the call runs unattended, and it prompts instead. A matchable
# call site with no grant is the same prompt arriving from the other end.
# Neither is observable at runtime -- a permission prompt looks identical
# whether a grant was never written or was written in a spelling that misses
# -- which is why this is a static check and not a runtime assertion.
_gaia_sda_assert4() {
  local repo_root="$1" failed=0 script settings granted matchable grant_state
  local mfile wdir wfile rel allowed

  settings="$repo_root/.claude/settings.json"
  if [ ! -f "$settings" ]; then
    # Not "no grants, therefore nothing to check". A caller reaching this
    # point already has a `.claude/agents/` directory, so the settings file
    # is a surface this repo_root is expected to carry; its absence leaves
    # the whole settings half unread, and reporting that as a pass is the
    # vacuous pass this file's own header refuses. Reported as a finding
    # rather than as the check's own failure, so a run that also found real
    # defects still exits 1 and names them all.
    printf '.claude/settings.json: missing, so no permission grant can be checked against the agent definitions\n'
    failed=1
  elif ! command -v jq >/dev/null 2>&1; then
    printf 'check-scope-digest-adoption: jq not found; assertion 4 cannot read %s\n' \
      '.claude/settings.json' >&2
    return 2
  elif ! granted="$(jq -r '(.permissions.allow // [])[]' "$settings" 2>/dev/null)"; then
    printf '.claude/settings.json: unreadable or not valid JSON; permission grants cannot be checked\n'
    failed=1
  else
    for script in "${GAIA_SDA_GRANTED_SCRIPTS[@]}"; do
      case "$granted" in
        *"Bash(bash .gaia/scripts/${script}:*)"*) grant_state=granted ;;
        *) grant_state=ungranted ;;
      esac
      matchable=none
      for mfile in "$repo_root"/.claude/agents/code-audit-*.md; do
        [ -f "$mfile" ] || continue
        _gaia_sda_grant_matchable "$mfile" "$script"
        case "$?" in
          0) matchable=some; break ;;
          2) matchable=untrusted; break ;;
        esac
      done
      _gaia_sda_grant_verdict '.claude/settings.json' "$script" \
        "$grant_state" "$matchable" \
        'the agent definitions' 'an agent definition' '.claude/agents/' || failed=1
    done
  fi

  for wdir in "${GAIA_SDA_WORKFLOW_DIRS[@]}"; do
    [ -d "$repo_root/$wdir" ] || continue
    while IFS= read -r -d '' wfile; do
      rel="${wfile#"$repo_root"/}"
      # grep exits 1 on no match, which is the ordinary case for a workflow
      # that arms no tool list; the `|| true` keeps that from reading as a
      # failure under a caller that armed errexit.
      #
      # Honest limit, and the direction it fails in: the grant set is every
      # line in the file carrying `--allowedTools`, pooled. So a file with
      # two tool-armed steps is judged as if one step armed all of them,
      # which can let one step's grant vouch for another step's call site,
      # and a value wrapped onto a continuation line is not seen as granted
      # at all. Neither shape exists in this tree today: every workflow here
      # carries at most one such line with its whole value on it. Parsing
      # per step means parsing YAML, which is the hand-rolled-parser trade
      # this check declines elsewhere for the same reason.
      allowed="$(grep -F -- '--allowedTools' "$wfile" 2>/dev/null || true)"
      for script in "${GAIA_SDA_GRANTED_SCRIPTS[@]}"; do
        case "$allowed" in
          *"Bash(bash .gaia/scripts/${script}:*)"*) grant_state=granted ;;
          *) grant_state=ungranted ;;
        esac
        _gaia_sda_grant_matchable "$wfile" "$script"
        case "$?" in
          0) matchable=some ;;
          2) matchable=untrusted ;;
          *) matchable=none ;;
        esac
        _gaia_sda_grant_verdict "$rel" "$script" \
          "$grant_state" "$matchable" \
          'this file' 'this file' "$rel" || failed=1
      done
    done < <(find "$repo_root/$wdir" -type f -print0 2>/dev/null)
  done

  [ "$failed" -eq 0 ] && printf 'permission-grant spelling: every grant matches a call site\n'
  return "$failed"
}

# gaia_check_scope_digest_adoption <repo_root>
gaia_check_scope_digest_adoption() {
  local repo_root="${1:?gaia_check_scope_digest_adoption requires a repo_root argument}"
  if [ ! -d "$repo_root/.claude/agents" ]; then
    printf 'check-scope-digest-adoption: %s/.claude/agents not found; nothing to scan\n' "$repo_root" >&2
    return 2
  fi

  if ! _gaia_sda_load_members "$repo_root"; then
    printf 'check-scope-digest-adoption: no .claude/agents/code-audit-*.md under %s; nothing to scan\n' "$repo_root" >&2
    return 2
  fi

  local assert1_failed=0 assert2_failed=0 assert3_failed=0 assert4_failed=0
  local assert4_rc=0 assert4_env=0

  printf -- '-- earned call-site --scope-digest coverage --\n'
  _gaia_sda_assert1 "$repo_root" || assert1_failed=1

  printf -- '-- obligation literal --\n'
  _gaia_sda_assert2 "$repo_root" || assert2_failed=1

  printf -- '-- scope-resolution capture placement --\n'
  _gaia_sda_assert3 "$repo_root" || assert3_failed=1

  printf -- '-- permission-grant spelling --\n'
  _gaia_sda_assert4 "$repo_root" || assert4_rc=$?
  # 2 is the check's own environment failure (no jq), not a finding. Unlike
  # the two early-out arms above, it is reached AFTER the other assertions
  # have run and possibly found real defects, so it is recorded rather than
  # returned here: returning 2 from this point would discard those findings'
  # status and send the operator to install jq when the tree also needs
  # repairing. Any other non-zero is a finding.
  if [ "$assert4_rc" -eq 2 ]; then
    assert4_env=1
  elif [ "$assert4_rc" -ne 0 ]; then
    assert4_failed=1
  fi

  if [ "$assert1_failed" -ne 0 ] || [ "$assert2_failed" -ne 0 ] ||
    [ "$assert3_failed" -ne 0 ] || [ "$assert4_failed" -ne 0 ]; then
    return 1
  fi
  [ "$assert4_env" -eq 0 ] || return 2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-scope-digest-adoption: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_scope_digest_adoption "$repo_root"
  exit $?
fi
