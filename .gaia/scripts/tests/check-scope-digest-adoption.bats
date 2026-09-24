#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-scope-digest-adoption.sh: the
# only thing standing between "a sixth agent definition (or an edit to one
# of the five) drops --scope-digest" and that drift going unnoticed until a
# member spends a whole review round and gets refused at the writer. This
# suite is what actually fails a build when an earned call site loses the
# flag, when the frozen obligation literal drifts or goes missing, or when
# the capture line survives only outside the region where scope is
# resolved, or when the resolver script stops capturing.
#
# Every test drives the check through its <repo_root> parameter against a
# fixture tree, matching check-verb-arming-adoption.bats's reasoning: a
# predicate that only ever runs against the healthy real tree has every
# branch it takes be the passing one, so a broken predicate still reports
# green.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-scope-digest-adoption.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-scope-digest-adoption.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/tests/helpers/path.sh
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  # shellcheck source=.gaia/scripts/check-scope-digest-adoption.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local d
  for d in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

# The frozen obligation literal, byte-identical to FC-2a. Duplicated here
# deliberately: the check itself must never hardcode this text (it reads it
# from the fixture/live file instead), so the only place a literal copy
# belongs is the fixture that stands in for the real one.
OBLIGATION_LITERAL='Capture your own content digest at scope resolution with `.gaia/scripts/audit-scope-digest.sh --capture`, and at marker-write time read that captured value back with `--read` and pass it as `--scope-digest`; never re-derive it in the writing call, and a rotation between the two means the review was superseded and you must be re-dispatched on the new HEAD.'

# write_member_def <dir> <member>: a healthy "simple" member definition --
# scope resolved (the resolver command, which captures) directly under
# "## Remit and self-skip", the
# frozen literal in the same paragraph, and an earned call site (backslash-
# continued, flag on the last line) under a later section, matching the real
# shape of the four non-default members.
write_member_def() {
  local dir="$1" member="$2"
  cat >"$dir/.claude/agents/${member}.md" <<EOF
## Remit and self-skip

Some remit text for ${member}.

\`\`\`bash
<root>/.gaia/scripts/audit-resolve-scope.sh --member ${member} --root <root>
\`\`\`

${OBLIGATION_LITERAL}

## Review dimensions

Some review text.

\`\`\`bash
D_SCOPE="\$("\$AUDIT_ROOT/.gaia/scripts/audit-scope-digest.sh" --read --root "\$AUDIT_ROOT" --member ${member} --base "\$KEY_BASE")"
marker="\$(bash .gaia/scripts/audit-write-clearance.sh \\
  --root "\$AUDIT_ROOT" \\
  --member ${member} \\
  --provenance earned \\
  --base "\$KEY_BASE" \\
  --scope-digest "\$D_SCOPE")"
\`\`\`
EOF
}

# write_frontend_def <dir>: the one structurally different member. Its
# "Remit and self-skip" only decides whether it runs at all; the actual
# scope-resolution command (which captures) sits under "### How to run"
# inside "## Rules-Based Audit" instead, matching the real file.
write_frontend_def() {
  local dir="$1"
  cat >"$dir/.claude/agents/code-audit-frontend.md" <<EOF
## Remit and self-skip

Some remit text for code-audit-frontend. Ask the dispatch oracle here; no
capture happens in this section.

## Rules-Based Audit

### How to run

\`\`\`bash
<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-frontend --root <root> --skip-full-base --review-path '*.ts'
\`\`\`

${OBLIGATION_LITERAL}

### Knip findings

Unrelated section.

## Audit marker (gate handshake)

\`\`\`bash
D_SCOPE="\$("\$AUDIT_ROOT/.gaia/scripts/audit-scope-digest.sh" --read --root "\$AUDIT_ROOT" --member code-audit-frontend --base "\$KEY_BASE")"
marker="\$(bash .gaia/scripts/audit-write-clearance.sh \\
  --root "\$AUDIT_ROOT" \\
  --member code-audit-frontend \\
  --provenance earned \\
  --base "\$KEY_BASE" \\
  --scope-digest "\$D_SCOPE")"
\`\`\`
EOF
}

# write_healthy_workflow <dir>: a workflow copy of the earned call site,
# spelled the way the real YAML prompt block spells it -- an inline
# backtick-delimited code span word-wrapped across several physical lines,
# no backslash continuation anywhere. This is the shape a naive line-at-a-
# time grep cannot see: the script name, --provenance earned, and
# --scope-digest each sit on their own physical line.
#
# The --allowedTools line is here for assertion 4, and it is part of the
# healthy shape rather than decoration: the real workflow grants both
# scripts and invokes both in the relative spelling that grant matches, so
# a fixture that dropped the line would model a workflow whose own prompt
# runs unattended by accident.
write_healthy_workflow() {
  local dir="$1"
  mkdir -p "$dir/.github/workflows"
  cat >"$dir/.github/workflows/fake-audit.yml" <<'EOF'
on: pull_request
jobs:
  audit:
    steps:
      - run: |
          prompt: |
            capture your own content digest with
            `bash .gaia/scripts/audit-scope-digest.sh --capture --root
            "$(git rev-parse --show-toplevel)" --member code-audit-frontend
            --base "${{ steps.base.outputs.base }}"` and read it back with
            `--scope-digest`, `bash .gaia/scripts/audit-write-clearance.sh
            --root "$(git rev-parse --show-toplevel)" --member
            code-audit-frontend --provenance earned --scope-digest
            <the digest you just read back>`, which resolves the digest.
          --allowedTools "Edit,Write,Bash(bash .gaia/scripts/audit-write-clearance.sh:*),Bash(bash .gaia/scripts/audit-scope-digest.sh:*)"
EOF
}

# write_settings <dir> <allow-entry>...: a .claude/settings.json carrying
# exactly the permission grants named, plus one unrelated grant so the
# reader is never handed an empty allow list in the healthy case. The
# baseline passes none: every call site write_member_def and
# write_frontend_def spell is either interpolated-root or assignment-
# wrapped, so no `Bash(bash .gaia/scripts/...)` rule reaches any of them
# and the correct grant set really is empty.
write_settings() {
  local dir="$1"
  shift
  local entry
  mkdir -p "$dir/.claude"
  {
    printf '{\n  "permissions": {\n    "allow": [\n'
    printf '      "Bash(git status:*)"'
    for entry in "$@"; do
      printf ',\n      "%s"' "$entry"
    done
    printf '\n    ]\n  }\n}\n'
  } >"$dir/.claude/settings.json"
  return 0
}

# write_resolver <dir>: the resolver script every definition invokes, reduced
# to what assertion 3 reads of it: its header's prose mention of the capture
# (which must not satisfy the check) and the quoted-path capture call.
write_resolver() {
  local dir="$1"
  mkdir -p "$dir/.gaia/scripts"
  cat >"$dir/.gaia/scripts/audit-resolve-scope.sh" <<'EOF'
#!/usr/bin/env bash
# The capture runs last; audit-scope-digest.sh --capture owns idempotency.
D_SCOPE="$("$root/.gaia/scripts/audit-scope-digest.sh" --capture --root "$root" --member "$member" --base "$KEY_BASE")" || D_SCOPE=""
EOF
}

# write_baseline <dir>: a healthy tree -- all five member definitions
# (four "simple", one frontend-shaped), each with the obligation literal
# once, the resolver command inside its own scope-resolution region, and an earned
# call site carrying --scope-digest; plus one healthy workflow copy. Every
# "must fail" fixture starts here and mutates one thing.
write_roster() {
  local dir="$1"
  shift
  local member
  mkdir -p "$dir/.gaia"
  printf 'auditors:\n' >"$dir/.gaia/audit-ci.yml"
  for member in "$@"; do
    printf '  - name: %s\n    globs:\n      - "app/**"\n' "$member" >>"$dir/.gaia/audit-ci.yml"
  done
  printf 'gate_label: null\n' >>"$dir/.gaia/audit-ci.yml"
}

write_baseline() {
  local dir="$1"
  mkdir -p "$dir/.claude/agents"
  write_frontend_def "$dir"
  write_member_def "$dir" code-audit-github-workflows
  write_member_def "$dir" code-audit-maintainer-node
  write_member_def "$dir" code-audit-maintainer-extra
  write_member_def "$dir" code-audit-maintainer-shell
  write_healthy_workflow "$dir"
  write_resolver "$dir"
  write_settings "$dir"
  write_roster "$dir" code-audit-frontend code-audit-github-workflows \
    code-audit-maintainer-node code-audit-maintainer-extra \
    code-audit-maintainer-shell
  printf 'fixture\n' >"$dir/README.md"
}

make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  write_baseline "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  FIXTURE_REPOS+=("$dir")
  printf '%s' "$dir"
}

@test "structural: sourcing the script defines gaia_check_scope_digest_adoption with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_scope_digest_adoption >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "fixture: healthy baseline passes" {
  local repo
  repo="$(make_fixture_repo healthy)"
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 0 ]
}

@test "real repo: exits 0 with all four assertions satisfied" {
  run gaia_check_scope_digest_adoption "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "earned call-site --scope-digest coverage: all pass" <<<"$output" || return 1
  grep -qF "obligation literal: byte-identical across every definition" <<<"$output" || return 1
  grep -qF "scope-resolution capture placement: every definition in region" <<<"$output" || return 1
  grep -qF "permission-grant spelling: every grant matches a call site" <<<"$output" || return 1
}

@test "fixture: one earned call site dropping --scope-digest fails and names the file" {
  local repo
  repo="$(make_fixture_repo drop-flag)"
  # Rewrite the whole definition rather than sed-editing the fence in place:
  # the mutation is "the earned call site never had --scope-digest", isolated
  # from everything else write_member_def sets up (capture, obligation
  # literal, region placement all stay healthy).
  cat >"$repo/.claude/agents/code-audit-maintainer-node.md" <<EOF
## Remit and self-skip

Some remit text for code-audit-maintainer-node.

\`\`\`bash
<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-maintainer-node --root <root>
\`\`\`

${OBLIGATION_LITERAL}

## Review dimensions

Some review text.

\`\`\`bash
marker="\$(bash .gaia/scripts/audit-write-clearance.sh \\
  --root "\$AUDIT_ROOT" \\
  --member code-audit-maintainer-node \\
  --provenance earned \\
  --base "\$KEY_BASE")"
\`\`\`
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/agents/code-audit-maintainer-node.md: earned call site missing --scope-digest" <<<"$output" || return 1
  # Isolation: the only defect is the flag, so assertion 3 stays green.
  grep -qF "scope-resolution capture placement: every definition in region" <<<"$output" || return 1
}

@test "fixture: an earned call site spanning continuation lines with the flag on a later line passes (join is load-bearing)" {
  local repo
  repo="$(make_fixture_repo continuation-join)"
  run gaia_check_scope_digest_adoption "$repo"
  # The baseline's own earned call sites already spell --scope-digest on the
  # LAST of several backslash-continued lines (the .md members) and the
  # workflow's earned call site spans a backtick span wrapped across six
  # physical lines with no backslash at all (write_healthy_workflow). A
  # naive line-at-a-time grep sees "audit-write-clearance.sh" and
  # "--provenance earned" on different physical lines from --scope-digest in
  # both shapes, so this passing only because the join joined them first.
  [ "$status" -eq 0 ]
}

@test "fixture: a paraphrased obligation literal fails" {
  local repo
  repo="$(make_fixture_repo paraphrase)"
  sed -i.bak 's/Capture your own content digest at scope resolution with/Capture the content digest at scope resolution using/' \
    "$repo/.claude/agents/code-audit-maintainer-extra.md"
  rm -f "$repo/.claude/agents/code-audit-maintainer-extra.md.bak"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/agents/code-audit-maintainer-extra.md: obligation literal present 0 times, expected exactly 1" <<<"$output" || return 1
}

@test "fixture: a definition mentioning capture only outside its Remit-and-self-skip region fails (assertion-3 boundary)" {
  local repo
  repo="$(make_fixture_repo outside-region)"
  cat >"$repo/.claude/agents/code-audit-maintainer-shell.md" <<EOF
## Remit and self-skip

Some remit text for code-audit-maintainer-shell. No capture mentioned here.

${OBLIGATION_LITERAL}

## Review dimensions

Some review text. Mentioned here instead, far outside the region:
\`\`\`bash
<root>/.gaia/scripts/audit-resolve-scope.sh --member code-audit-maintainer-shell --root <root>
marker="\$(bash .gaia/scripts/audit-write-clearance.sh \\
  --root "\$AUDIT_ROOT" \\
  --member code-audit-maintainer-shell \\
  --provenance earned \\
  --base "\$KEY_BASE" \\
  --scope-digest "\$D_SCOPE")"
\`\`\`
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/agents/code-audit-maintainer-shell.md: capture NOT found in its scope-resolution region" <<<"$output" || return 1
}

@test "fixture: a resolver command naming another member fails (assertion 3 is per member)" {
  local repo
  repo="$(make_fixture_repo wrong-member)"
  perl -0pi -e 's/audit-resolve-scope\.sh --member code-audit-maintainer-node --root/audit-resolve-scope.sh --member code-audit-maintainer-shell --root/' \
    "$repo/.claude/agents/code-audit-maintainer-node.md"
  grep -qF 'audit-resolve-scope.sh --member code-audit-maintainer-shell --root' "$repo/.claude/agents/code-audit-maintainer-node.md" || {
    echo "the mutation did not take; this test proves nothing" >&2
    return 1
  }
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/agents/code-audit-maintainer-node.md: capture NOT found in its scope-resolution region" <<<"$output" || return 1
  grep -qF ".claude/agents/code-audit-maintainer-shell.md: capture found in its scope-resolution region" <<<"$output" || return 1
}

@test "fixture: a resolver command whose member name merely extends this one fails" {
  local repo
  repo="$(make_fixture_repo extended-member)"
  perl -0pi -e 's/audit-resolve-scope\.sh --member code-audit-maintainer-node --root/audit-resolve-scope.sh --member code-audit-maintainer-node-v2 --root/' \
    "$repo/.claude/agents/code-audit-maintainer-node.md"
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/agents/code-audit-maintainer-node.md: capture NOT found in its scope-resolution region" <<<"$output" || return 1
}

@test "fixture: a resolver script whose capture call is deleted fails, even with every definition in region" {
  local repo
  repo="$(make_fixture_repo resolver-no-capture)"
  perl -ni -e 'print unless /audit-scope-digest\.sh" --capture --root/' "$repo/.gaia/scripts/audit-resolve-scope.sh"
  grep -qF 'audit-scope-digest.sh" --capture --root' "$repo/.gaia/scripts/audit-resolve-scope.sh" && {
    echo "the mutation did not take; this test proves nothing" >&2
    return 1
  }
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".gaia/scripts/audit-resolve-scope.sh: capture NOT found" <<<"$output" || return 1
  # The header's prose mention of the capture must not answer for the call.
  grep -qF 'audit-scope-digest.sh --capture' "$repo/.gaia/scripts/audit-resolve-scope.sh" || return 1
}

@test "fixture: a missing resolver script fails" {
  local repo
  repo="$(make_fixture_repo resolver-missing)"
  rm "$repo/.gaia/scripts/audit-resolve-scope.sh"
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".gaia/scripts/audit-resolve-scope.sh: MISSING" <<<"$output" || return 1
}

@test "fixture: a definition missing entirely fails and names it across all three assertions" {
  local repo
  repo="$(make_fixture_repo missing-def)"
  rm "$repo/.claude/agents/code-audit-github-workflows.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/agents/code-audit-github-workflows.md: MISSING" <<<"$output" || return 1
}

@test "fixture: a sixth definition dropping --scope-digest fails and names it" {
  local repo
  repo="$(make_fixture_repo sixth-member)"
  # A member the roster has not been told about yet, which is the ordinary
  # order of events: the definition lands, the roster entry follows. The
  # hardcoded five-name array this check used to carry never opened this
  # file, so the omission passed with exit 0 and no line naming it.
  write_member_def "$repo" code-audit-sixth-member
  perl -0pi -e 's/ --scope-digest "\$D_SCOPE"//g' "$repo/.claude/agents/code-audit-sixth-member.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/agents/code-audit-sixth-member.md: earned call site missing --scope-digest" <<<"$output" || return 1
}

@test "fixture: a sixth definition that is well-formed passes (the discovery is not merely noisy)" {
  local repo
  repo="$(make_fixture_repo sixth-member-clean)"
  write_member_def "$repo" code-audit-sixth-member
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 0 ]
}

@test "assertion 4: a settings grant no definition call site can match fails and names the script" {
  local repo
  repo="$(make_fixture_repo grant-unmatched)"
  # audit-scope-digest.sh on purpose: every definition carries the frozen
  # obligation literal, which names `.gaia/scripts/audit-scope-digest.sh
  # --capture` in prose. If the assertion accepted a bare mention rather
  # than a statement that BEGINS with the granted text, that prose alone
  # would answer for a real call site and this grant would pass while
  # matching nothing -- the exact vacuous pass assertion 3 guards against
  # one region over.
  write_settings "$repo" 'Bash(bash .gaia/scripts/audit-scope-digest.sh:*)'
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.claude/settings.json: grants "Bash(bash .gaia/scripts/audit-scope-digest.sh:*)" but nothing in the agent definitions spells a call site that rule can match' <<<"$output" || return 1
}

@test "assertion 4: a matchable definition call site with no settings grant fails" {
  local repo
  repo="$(make_fixture_repo callsite-ungranted)"
  # The other direction, and the one the tree would take if the invocation
  # spelling were ever settled back on the relative form without the grant
  # following it: the call site is now spelled exactly as a rule could match,
  # and no rule does.
  perl -0pi -e 's/marker="\$\(bash \.gaia\/scripts\/audit-write-clearance\.sh/bash .gaia\/scripts\/audit-write-clearance.sh/' \
    "$repo/.claude/agents/code-audit-maintainer-node.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.claude/settings.json: an agent definition spells "bash .gaia/scripts/audit-write-clearance.sh ..." but no grant here covers it' <<<"$output" || return 1
}

@test "assertion 4: a matchable call site WITH its grant passes (the assertion is not merely always-red)" {
  local repo
  repo="$(make_fixture_repo callsite-granted)"
  perl -0pi -e 's/marker="\$\(bash \.gaia\/scripts\/audit-write-clearance\.sh/bash .gaia\/scripts\/audit-write-clearance.sh/' \
    "$repo/.claude/agents/code-audit-maintainer-node.md"
  write_settings "$repo" 'Bash(bash .gaia/scripts/audit-write-clearance.sh:*)'
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 0 ]
  grep -qF "permission-grant spelling: every grant matches a call site" <<<"$output" || return 1
}

@test "assertion 4: a workflow whose --allowedTools drops a grant it still invokes fails and names the file" {
  local repo
  repo="$(make_fixture_repo workflow-ungranted)"
  # The settings surface and the workflow surface are judged separately, so
  # this must fail on the workflow's own allowedTools even though the
  # definitions and settings.json are untouched and healthy.
  perl -0pi -e 's/,Bash\(bash \.gaia\/scripts\/audit-scope-digest\.sh:\*\)//' \
    "$repo/.github/workflows/fake-audit.yml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.github/workflows/fake-audit.yml: this file spells "bash .gaia/scripts/audit-scope-digest.sh ..." but no grant here covers it' <<<"$output" || return 1
}

@test "assertion 4: a workflow granting a script it never invokes fails and names the file" {
  local repo
  repo="$(make_fixture_repo workflow-dead-grant)"
  perl -0pi -e 's/`bash \.gaia\/scripts\/audit-scope-digest\.sh --capture --root/`true --capture --root/' \
    "$repo/.github/workflows/fake-audit.yml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.github/workflows/fake-audit.yml: grants "Bash(bash .gaia/scripts/audit-scope-digest.sh:*)" but nothing in this file spells a call site that rule can match' <<<"$output" || return 1
}

@test "assertion 4: an interpolated-root call site does not count as matchable" {
  local repo
  repo="$(make_fixture_repo interpolated-root)"
  # The spelling the real definitions use today. It names the script and
  # runs it under `bash`, but the literal text a permission rule would have
  # to match begins with an interpolated root, so no rule reaches it. A
  # check that matched on the script name anywhere in the statement would
  # call this granted and go green on the live defect.
  perl -0pi -e 's/marker="\$\(bash \.gaia\/scripts\/audit-write-clearance\.sh/bash "\$AUDIT_ROOT\/.gaia\/scripts\/audit-write-clearance.sh"/' \
    "$repo/.claude/agents/code-audit-maintainer-node.md"
  write_settings "$repo" 'Bash(bash .gaia/scripts/audit-write-clearance.sh:*)'
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.claude/settings.json: grants "Bash(bash .gaia/scripts/audit-write-clearance.sh:*)" but nothing in the agent definitions spells a call site that rule can match' <<<"$output" || return 1
}

@test "assertion 4: an absent settings.json fails rather than skipping the settings surface silently" {
  local repo
  repo="$(make_fixture_repo settings-absent)"
  # The fail-open shape: with no settings file there are no grants to
  # contradict, so the whole settings half reads as satisfied and the
  # verdict prints. A missing scan surface is not a clean one.
  rm -f "$repo/.claude/settings.json"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.claude/settings.json: missing, so no permission grant can be checked against the agent definitions' <<<"$output" || return 1
  grep -qF "permission-grant spelling: every grant matches a call site" <<<"$output" && return 1
  return 0
}

@test "assertion 4: a malformed settings.json fails without discarding the other assertions" {
  local repo
  repo="$(make_fixture_repo settings-malformed)"
  printf 'not json at all\n' >"$repo/.claude/settings.json"
  # A second, unrelated defect the earlier assertions catch. The status has
  # to report a finding, not the environment, or an operator repairs the
  # JSON and never learns the definition is broken too.
  perl -0pi -e 's/ --scope-digest "\$D_SCOPE"//g' "$repo/.claude/agents/code-audit-maintainer-extra.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.claude/settings.json: unreadable or not valid JSON; permission grants cannot be checked' <<<"$output" || return 1
  grep -qF '.claude/agents/code-audit-maintainer-extra.md: earned call site missing --scope-digest' <<<"$output" || return 1
}

@test "assertion 4: a truncated definition scan names the definitions, not the settings file" {
  local repo
  repo="$(make_fixture_repo truncated-definition)"
  # An unmatched backtick leaves the span parser accumulating to end of file,
  # so the call-site set is truncated and assertion 4 cannot answer. The
  # finding has to name where the truncation IS. settings.json is JSON and
  # cannot hold a markdown inline span, so naming it would send the operator
  # to a file that structurally cannot carry the defect.
  printf '\nA stray `backtick opens a span that never closes.\n' \
    >>"$repo/.claude/agents/code-audit-maintainer-node.md"
  write_settings "$repo" 'Bash(bash .gaia/scripts/audit-write-clearance.sh:*)'
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.claude/agents/: unmatched backtick truncated the scan; the grant for audit-write-clearance.sh cannot be checked' <<<"$output" || return 1
  grep -qF '.claude/settings.json: unmatched backtick' <<<"$output" && return 1
  return 0
}

@test "assertion 4: a truncated workflow scan names that workflow file" {
  local repo
  repo="$(make_fixture_repo truncated-workflow)"
  # The same arm on the other surface, where the grant and the call sites do
  # live in one file, so the label is the workflow's own path.
  printf '          # a stray ` backtick\n' >>"$repo/.github/workflows/fake-audit.yml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF '.github/workflows/fake-audit.yml: unmatched backtick truncated the scan' <<<"$output" || return 1
}

# The environment arm, and the aggregation that decides what a run reports
# when it fires. `_gaia_sda_assert4` returns 2 when `jq` is absent, and
# `gaia_check_scope_digest_adoption` RECORDS that rather than returning on the
# spot, because assertion 4 runs after the earlier assertions have already
# found whatever they found: returning 2 from there would discard a real
# finding and send the operator to install jq while the tree still needs
# repairing. Both halves of that contract are driven below, and neither was
# reachable from any other test here -- the malformed-settings case exercises
# the arm below the jq one, and exits 1 identically with or without the
# aggregation, so it stands behind nothing.
#
# The shim is `path_shim_without` from `.gaia/tests/helpers/path.sh`, the
# mirroring shape, rather than a stub directory holding just the binaries the
# check needs. That helper's header states the criterion: which shape fits is
# decided by whether the subject's binary needs are enumerable. This check is a
# large shell program reaching for awk, grep and find among others, so its
# needs are not enumerable, and an allowlist that missed one would fail as a
# missing-tool error inside the fixture rather than on the arm under test.

@test "environment: jq absent on an otherwise-clean tree exits 2 rather than passing" {
  local repo
  # Built before the shim: the fixture builder is git, and it has no business
  # running against a rebuilt PATH.
  repo="$(make_fixture_repo jq-absent-healthy)"
  PATH="$(path_shim_without jq)"
  run gaia_check_scope_digest_adoption "$repo"
  [ "$status" -eq 2 ]
  grep -qF 'jq not found; assertion 4 cannot read .claude/settings.json' <<<"$output" || return 1
}

@test "environment: jq absent alongside an assertion-1 defect exits 1 and still names the defect" {
  local repo
  repo="$(make_fixture_repo jq-absent-defective)"
  perl -0pi -e 's/ --scope-digest "\$D_SCOPE"//g' \
    "$repo/.claude/agents/code-audit-maintainer-extra.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m mutate
  PATH="$(path_shim_without jq)"
  run gaia_check_scope_digest_adoption "$repo"
  # 1, not 2. The environment note is real and still printed, but a status of 2
  # would report the missing tool as the run's verdict and bury the finding.
  [ "$status" -eq 1 ]
  grep -qF '.claude/agents/code-audit-maintainer-extra.md: earned call site missing --scope-digest' <<<"$output" || return 1
  grep -qF 'jq not found; assertion 4 cannot read .claude/settings.json' <<<"$output" || return 1
}

@test "usage: a fixture with no scan surface exits 2 rather than passing vacuously" {
  local dir="$BATS_TEST_TMPDIR/no-scan-surface"
  mkdir -p "$dir"
  printf 'nothing here\n' >"$dir/README.md"
  run gaia_check_scope_digest_adoption "$dir"
  [ "$status" -eq 2 ]
}

@test "usage: no repo_root and not a git repository exits 2" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$dir"
  run bash -c 'cd "$1" && bash "$2"' _ "$dir" "$CHECK"
  [ "$status" -eq 2 ]
}
