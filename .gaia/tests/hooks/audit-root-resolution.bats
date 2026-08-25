#!/usr/bin/env bats

# Tests for the audit machinery's root resolution, end to end (#1055).
#
# #1055 found the audit chain deciding "which checkout am I operating on"
# independently in eight places, each answering from the ambient cwd. Option C
# (README.md FC-5) fixes it by having the CALLER anchor: each entry point `cd`s
# into the audited root once, in a subshell, before the chain beneath it runs.
# Per-site unit tests (Phase 2) prove each fixed site behaves; they cannot
# prove nothing was missed. This suite is the missed-site harness #1055 asks
# for: it drives the whole chain from a session whose OWN cwd is outside the
# audited root and asserts every stage answers for the tree it was anchored
# on, never the other one.
#
# Fixture, built once per test (setup()):
#   MAIN     a real git repo, populated with copies of the real hooks/scripts/
#            libs/roster (never symlinked), holding one committed file per
#            Code Audit Team roster member. The roster is read out of
#            .gaia/audit-ci.yml, so a member added there is a member this
#            suite drives.
#   WT       a real linked worktree of MAIN, on its own branch, with every
#            roster member's file changed to DIFFERENT content, so MAIN and WT
#            produce genuinely different per-member content digests. MAIN and
#            WT never share a `.gaia/local` (no symlink): the two clearance
#            stores stay physically separate, matching an unprovisioned
#            worktree, so a root derivation that quietly collapsed onto the
#            wrong tree is observable rather than papered over.
#   OUTSIDE  a non-repository temp directory. This is the bats process's OWN
#            cwd for every test in this file (set once in setup()).
#
# Eight stages, one per #1055 instance (README.md FC-5/FC-6, task doc table):
#   1  resolve-audit-members.sh    --root flag
#   2  resolve-audit-spawn.sh      no root argument, D-3's fail-closed guard
#   3  audit-member-digest.sh      --root flag
#   4  audit-write-clearance.sh    --root flag, subdirectory rejection
#   5  audit-stamp-trailer.sh      no root argument, caller anchors via cd
#   6  post-audit-status.sh        no root argument, caller anchors via cd
#   7  pr-merge-audit-check.sh     no root argument, caller anchors via cd,
#                                  FC-4's two independent roots
#   8  agent handshake block       AUDIT_ROOT derivation (extracted from the
#                                  agent's own fenced code block, never a
#                                  hand-maintained copy)
#
# Stages 1, 3, 4, 7 and 8 are proven live by SOURCE MUTATION: the minimal edit
# that reintroduces the ambient-cwd resolution the stage guards against,
# confirmed to turn that stage's own assertion red, then restored
# byte-identical and checksum-verified. Every mutation is applied to this
# fixture's OWN copy under $MAIN, never to the real checked-out files this
# session is running under. Stage 2's guard already reflects Phase 2's D-3;
# its mutation reintroduces the pre-D-3 fail-open shape.
#
# Stages 5 and 6 take no root argument at all (Phase 2 was explicitly
# forbidden from adding one, that is option A, ruled out in #1053), so there
# is no line inside them to mutate. Their non-vacuity control is an
# INVOCATION control instead: the same hook, anchored on MAIN instead of WT,
# must name MAIN, and the same hook with no anchor at all, from OUTSIDE, must
# decline out loud and write nothing.
#
# See README.md FC-4, FC-5, FC-6 for the frozen contracts this suite asserts
# against, and the task doc's "what 'from OUTSIDE' means" section for why
# stages 5-7 are anchored via `( cd "$root" && ... )` rather than run with a
# bare non-repository cwd.

# Prints the Code Audit Team roster, one member name per line, read out of the
# `auditors:` block of the audit-ci.yml at $1. That file is the roster's source
# of truth, so a member added there is a member this suite drives, with no
# second list to remember to grow.
#
# A line scan rather than a YAML parse, on purpose: this runs while building
# the fixture for every test in the file, and PyYAML is an optional dependency
# here in a way it is not in the suites that gate on it.
#
# The block closes on any non-blank, non-comment line starting in column 0,
# rather than on a character class that has to guess which spellings a top-level
# key can take. A close rule reading `/^[A-Za-z_]+:/` looks equivalent and is
# not: it steps over a hyphenated or digit-leading key, leaving the block open
# so that key's own `- name:` children read as roster members.
#
# The column-0 rule is a claim about THIS file, not about YAML. A block sequence
# may legally sit at its parent key's own indentation, so a roster written with
# `- name:` in column 0 is valid YAML that this scan reads as zero members. The
# caller's non-empty guard turns that into a red, and its message names both
# causes, because the scan cannot tell them apart and a reader staring at a
# populated audit-ci.yml needs the second one to make sense of it. Measured, not
# reasoned: a roster MIXING the two indentations is not valid YAML in either
# direction, so no INDENTATION choice can lose a member here while the guard
# stays satisfied.
#
# Indentation is not the only way to spell a roster, and this scan reads exactly
# one spelling: an indented `- name: X` carrying its value on the entry line. An
# expanded block entry, a flow mapping (`- {name: x}`), a quoted key, `globs:`
# written before `name:`, or a value held over to a more-indented line below the
# key are each valid YAML this scan would otherwise read short.
#
# Deliberately NOT widened to accept them. The parser the rest of the machinery
# uses, `.claude/hooks/lib/audit-scope.sh`'s _audit_scope_parse_auditors, is
# LOOSER on three readings, not equal: its member line at `:302` leads with
# `[[:space:]]*`, so a column-0 sequence reads as members there; that same line
# spells the key `name[[:space:]]*:`, so `- name : x` reads there; and the
# `unq()` it calls at `:309` (defined at `:244`) strips a quoted value this
# scan keeps verbatim. Measured on three fixtures, each confirmed valid YAML
# and two members first: that parser reads both members in all three, where
# this scan reads NONE (column-0), REFUSES (`- name : x`), or reads the name
# verbatim with its quotes still on it (`- name: "X"`).
#
# What none of them reaches is a SILENT member drop, the only failure this
# helper exists to prevent. Two are read short and stop: a column-0 roster
# drops every member and reds at the caller's non-empty guard, and `- name : x`
# reds at the count below. The third is read WRONG rather than short, so it
# satisfies the count and stops one step later, at setup()'s `cp` of a path no
# agent file has. Loud in all three.
#
# Note which way that cuts, because it is the opposite of the obvious reading:
# widening this scan toward those readings would AGREE with that parser more,
# not less. Agreement is not what earns the strictness. This helper's contract
# is that a roster it cannot read canonically stops the suite, and every
# spelling it accepts is one more that can shrink the roster instead of
# stopping it. It stays strict because stopping is the product.
#
# What that leaves is counted instead of assumed. The block's member entries are
# its shallowest `-` lines (a `globs:` item is indented deeper), so an entry that
# yields no name is an entry this scan cannot read, and the scan fails rather
# than returning the short list. Without that count the dangerous case is ONE
# off-spelled member: the list comes back shorter but non-empty, the caller's
# non-empty guard stays satisfied, and the suite drives a subset while its test
# names still say "every definition" -- the silent drop this helper exists to
# remove, reintroduced one level up.
#
# Reading a name and counting one are therefore the same act. A name counts only
# when the entry line carries a value that is not a comment, so `- name:` alone,
# a value held over to the next line, and `- name:  # deferred` each reach the
# count as an unread entry. Counting a bare `name:` key instead would satisfy
# the count while contributing an EMPTY name, which the caller's per-entry
# `[ -n "$m" ]` then drops: the short-but-non-empty roster above, arrived at
# through the check meant to forbid it.
#
# The count is what guards it, not CI. `.gaia/scripts/verify-audit-roster.sh`
# does red on every one of those spellings, but its workflow is advisory by
# design and deliberately not a required check
# (`.github/workflows/audit-roster.yml`), so it is a visible red rather than a
# merge block and cannot be leaned on here.
#
# `.claude/hooks/lib/audit-scope.sh`'s _audit_scope_parse_auditors parses the
# same block canonically and is deliberately NOT reused here: it emits a record
# per glob, so a member declaring no globs produces no record and vanishes from
# its output. Silently dropping a member is the failure this helper exists to
# remove, so the two answer different questions and both stay.
roster_members() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^auditors[[:space:]]*:/ { in_block = 1; next }
    /^[^[:space:]]/ { in_block = 0; next }
    !in_block { next }
    /^[[:space:]]+-([[:space:]]|$)/ {
      match($0, /^[[:space:]]+/)
      indent = RLENGTH
      if (entry_indent == 0) entry_indent = indent
      if (indent != entry_indent) next
      entries++
      if ($2 == "name:" && $3 != "" && $3 !~ /^#/) names[++n] = $3
      next
    }
    END {
      if (entries != n) {
        printf "roster_members: %s has %d auditors entr(ies) but %d readable `- name: X`; an entry this scan cannot read would silently shrink the roster\n", FILENAME, entries, n > "/dev/stderr"
        exit 1
      }
      for (i = 1; i <= n; i++) print names[i]
    }
  ' "$1"
}

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  MAIN=$(mktemp -d -t audit-root-main-XXXXXX)
  OUTSIDE=$(mktemp -d -t audit-root-outside-XXXXXX)
  WT="${MAIN}-wt"
  rm -rf "$WT"

  # Keeps OUTSIDE genuinely non-repository regardless of where the system
  # tempdir happens to sit, mirroring resolve-audit-members.bats's own idiom.
  # Harmless to MAIN/WT: the ceiling only limits upward search FROM a given
  # cwd, and neither tree's path sits under OUTSIDE.
  export GIT_CEILING_DIRECTORIES="$OUTSIDE"

  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false

  mkdir -p "$MAIN/.gaia/scripts" "$MAIN/.claude/hooks/lib" "$MAIN/.claude/agents"
  printf '1.4.0\n' > "$MAIN/.gaia/VERSION"
  echo ".gaia/local/" > "$MAIN/.gitignore"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$MAIN/.gaia/audit-ci.yml"

  local f
  for f in resolve-audit-members.sh resolve-audit-spawn.sh audit-member-digest.sh \
           audit-write-clearance.sh main-root-lib.sh audit-key-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$f" "$MAIN/.gaia/scripts/$f"
    chmod +x "$MAIN/.gaia/scripts/$f"
  done
  for f in pr-merge-audit-check.sh post-audit-status.sh audit-stamp-trailer.sh; do
    cp "$REPO_ROOT/.claude/hooks/$f" "$MAIN/.claude/hooks/$f"
    chmod +x "$MAIN/.claude/hooks/$f"
  done
  for f in audit-scope.sh audit-machinery.sh audit-clearance.sh audit-digest.sh gaia-version.sh audit-base-provenance.sh \
           verb-arming.sh verb-arming-walk.sh repo-scope.sh; do
    cp "$REPO_ROOT/.claude/hooks/lib/$f" "$MAIN/.claude/hooks/lib/$f"
  done
  # Read the roster out of .gaia/audit-ci.yml rather than restating it. The
  # tests these members drive are named "every definition", and a hand-copied
  # array is only every definition until the next member joins the roster:
  # the array does not grow, the loops silently skip the newcomer, and the
  # names keep saying "every" with nothing red. Deliberately no count here or
  # in any name below, for the same reason.
  local m roster_out
  # Captured rather than piped into the loop: a process substitution discards
  # roster_members' exit status, which is the whole signal when an entry is
  # spelled in a way the scan cannot read.
  roster_out="$(roster_members "$REPO_ROOT/.gaia/audit-ci.yml")" || {
    echo "roster_members could not read .gaia/audit-ci.yml's auditors block; see its message above" >&2
    return 1
  }
  ALL_MEMBERS=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    ALL_MEMBERS+=("$m")
  done <<<"$roster_out"
  [ "${#ALL_MEMBERS[@]}" -gt 0 ] || {
    echo "no auditors read out of .gaia/audit-ci.yml; every member loop below would run over an empty set. Either the auditors: block is empty, or its entries are not indented under it (roster_members reads only indented entries; see its header)" >&2
    return 1
  }

  # Every definition, not just the default member's: stage 8 asserts the
  # AUDIT_ROOT derivation resolves correctly in all of them, so all of them
  # have to be here for the extractor to read. The block is byte-identical
  # across them (FC-5), which is exactly what driving each one independently
  # proves. A roster name with no definition to copy reds here, which is the
  # answer that suite wants for a roster and a tree that disagree.
  for m in "${ALL_MEMBERS[@]}"; do
    cp "$REPO_ROOT/.claude/agents/${m}.md" "$MAIN/.claude/agents/${m}.md"
  done

  SCRIPT_RESOLVE_MEMBERS="$MAIN/.gaia/scripts/resolve-audit-members.sh"
  SCRIPT_RESOLVE_SPAWN="$MAIN/.gaia/scripts/resolve-audit-spawn.sh"
  SCRIPT_MEMBER_DIGEST="$MAIN/.gaia/scripts/audit-member-digest.sh"
  SCRIPT_WRITE_CLEARANCE="$MAIN/.gaia/scripts/audit-write-clearance.sh"
  HOOK_STAMP="$MAIN/.claude/hooks/audit-stamp-trailer.sh"
  HOOK_POST="$MAIN/.claude/hooks/post-audit-status.sh"
  HOOK_MERGE="$MAIN/.claude/hooks/pr-merge-audit-check.sh"
  AGENT_MD="$MAIN/.claude/agents/code-audit-frontend.md"
  DIGEST_LIB="$MAIN/.claude/hooks/lib/audit-digest.sh"

  # Roster-owned, non-machinery seed files: one per roster member (per
  # .gaia/audit-ci.yml's globs), none of them listed in
  # .claude/hooks/lib/audit-machinery.sh, so diverging one rotates only its
  # owning member's digest, never every member's at once.
  mkdir -p "$MAIN/app" "$MAIN/.github/workflows" "$MAIN/.gaia/cli/src" "$MAIN/.claude/skills/audit-root-fixture"
  printf 'export const x = 1;\n' > "$MAIN/app/x.ts"
  printf 'name: ci\n' > "$MAIN/.github/workflows/ci.yml"
  printf '#!/bin/bash\necho shell\n' > "$MAIN/.gaia/scripts/fixture-example.sh"
  chmod +x "$MAIN/.gaia/scripts/fixture-example.sh"
  printf 'export const y = 1;\n' > "$MAIN/.gaia/cli/src/foo.ts"
  printf '# fixture skill\n' > "$MAIN/.claude/skills/audit-root-fixture/SKILL.md"

  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "seed audit-root-resolution fixture"

  git -C "$MAIN" worktree add --quiet -b feature "$WT" main

  # Diverge every roster member's owned file so MAIN and WT produce genuinely
  # different per-member content digests (verified by the fixture-sanity test
  # below). No symlink between the two `.gaia/local` directories: they stay
  # physically separate stores throughout this file.
  printf 'export const x = 2;\n' > "$WT/app/x.ts"
  printf 'name: ci-changed\n' > "$WT/.github/workflows/ci.yml"
  printf '#!/bin/bash\necho shell-changed\n' > "$WT/.gaia/scripts/fixture-example.sh"
  printf 'export const y = 2;\n' > "$WT/.gaia/cli/src/foo.ts"
  printf '# fixture skill changed\n' > "$WT/.claude/skills/audit-root-fixture/SKILL.md"
  git -C "$WT" add -A
  git -C "$WT" commit --quiet -m "worktree change: diverge every roster member's owned file"

  cd "$OUTSIDE" || return 1
}

teardown() {
  cd "$REPO_ROOT" 2>/dev/null || true
  if [ -n "${WT:-}" ]; then
    git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
    git -C "$MAIN" worktree prune 2>/dev/null || true
  fi
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN"
  [ -n "${OUTSIDE:-}" ] && rm -rf "$OUTSIDE"
  [ -n "${GH_BIN:-}" ] && rm -rf "$GH_BIN"
  return 0
}

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------

# phys <dir>: symlink-resolved absolute path, the same physical form
# main-root-lib.sh's own resolver prints, so a comparison against it never
# trips on a /tmp-vs-/private/tmp style difference.
phys() {
  ( cd "$1" 2>/dev/null && pwd -P )
}

# digest_of <root> <member> [<ref>]: the real content digest, sourced fresh
# from this fixture's own copy of the digest engine (mirrors
# audit-stamp-trailer.bats's digest_of), so every assertion below compares
# against the SAME computation the hooks themselves perform, never a
# hand-derived value.
digest_of() {
  local root="$1" member="$2" ref="${3:-HEAD}"
  bash -c '. "$1"; audit_member_digest "$2" "$3" "$4"' _ "$DIGEST_LIB" "$root" "$member" "$ref"
}

# run_stdout_only <cmd...>: runs `bats run` with stderr discarded, so $output
# is purely stdout. The four raw scripts (stages 1-4) emit a diagnostic to
# stderr on their fail-closed paths in addition to their stdout answer;
# without this, bats' combined stdout+stderr capture would fold the
# diagnostic into $output and break an exact-match assertion. Same idiom as
# resolve-audit-members.bats's own `2>/dev/null` wrapping.
run_stdout_only() {
  run bash -c '"$@" 2>/dev/null' _ "$@"
}

sha_of() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# backup_file <file> -> its sha256 on stdout, and leaves a restore copy beside
# it. Pair with restore_file.
backup_file() {
  local file="$1"
  cp -p "$file" "${file}.orig-for-restore"
  sha_of "$file"
}

# restore_file <file> <expected_sha256> -> moves the restore copy back and
# verifies the checksum matches. Exit 0 iff the restore is byte-identical.
restore_file() {
  local file="$1" expected_sum="$2" got
  mv -f "${file}.orig-for-restore" "$file"
  got="$(sha_of "$file")"
  [ "$got" = "$expected_sum" ]
}

# mutate_lines <file> <start> <end> [<replacement-line>...]: splices lines
# start..end (1-indexed, inclusive) out of <file> and substitutes zero or more
# replacement lines in their place. Locating start/end is each mutation
# test's own job (grep -n against known, distinguishing text), so this stays a
# generic splice with no per-stage knowledge.
mutate_lines() {
  local file="$1" start="$2" end="$3"
  shift 3
  {
    head -n $((start - 1)) "$file"
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    fi
    tail -n +$((end + 1)) "$file"
  } > "${file}.mutated-tmp"
  mv -f "${file}.mutated-tmp" "$file"
}

# pool_snapshot <root>: name + content hash of every file under <root>'s audit
# pool, to prove a run wrote nothing (mirrors pr-merge-audit-check.bats).
pool_snapshot() {
  local dir="$1/.gaia/local/audit"
  [ -d "$dir" ] || { printf '<no-pool>'; return 0; }
  ( cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; shasum "$f" 2>/dev/null; done )
}

# write_marker_at <store_root> <digest_root> <member> -> the digest on stdout.
# Writes a writer-shaped schema-4 earned clearance directly (mirrors
# pr-merge-audit-check.bats's write_marker), keyed to <digest_root>'s content
# but LANDING under <store_root>. The two roots are independent parameters on
# purpose: stage 7 needs a marker keyed to WT's content but stored under
# MAIN's separate pool, which the real writer script cannot produce (its
# --root controls both digest and storage location together).
write_marker_at() {
  local store_root="$1" digest_root="$2" member="$3"
  local digest sha tree infix flag
  digest="$(digest_of "$digest_root" "$member")"
  sha="$(git -C "$digest_root" rev-parse HEAD)"
  tree="$(git -C "$digest_root" rev-parse "HEAD^{tree}")"
  if [ "$member" = "code-audit-frontend" ]; then infix=""; flag="true"; else infix=".$member"; flag="false"; fi
  mkdir -p "$store_root/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":4,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s,"dispositions_sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$flag" "$flag" \
    > "$store_root/.gaia/local/audit/${digest}${infix}.ok"
  printf '%s\n' "$digest"
}

write_sidecar_at() {
  local store_root="$1" digest="$2"
  mkdir -p "$store_root/.gaia/local/audit"
  printf '{"schema":1,"backend":"absent","findings":[]}\n' \
    > "$store_root/.gaia/local/audit/${digest}.dispositions.json"
}

# provision_all_members <root>: an earned marker for every roster member,
# keyed to and stored under <root> itself (self-consistent, single-root use).
provision_all_members() {
  local root="$1" m
  for m in "${ALL_MEMBERS[@]}"; do
    write_marker_at "$root" "$root" "$m" >/dev/null
  done
}

# trailer_digest_on <root>: the GAIA-Audit trailer's digest field (position 2)
# on <root>'s current HEAD, empty when no trailer is present.
trailer_digest_on() {
  local root="$1" trailer
  trailer=$(git -C "$root" log -1 --format='%B' HEAD 2>/dev/null \
    | git -C "$root" interpret-trailers --parse 2>/dev/null \
    | grep '^GAIA-Audit:' || true)
  [ -n "$trailer" ] || return 0
  awk '{print $3}' <<<"$trailer"
}

# install_gh_stub: a `gh` on a fresh PATH-only directory that logs every
# invocation's OWN $PWD (the load-bearing field, stage 6) plus its argv to
# GH_LOG, then answers just enough to let post-audit-status.sh proceed:
# `auth status` ok, `repo view` a fixed slug, `pr view` fails (so the hook
# falls back to local HEAD instead of needing a real PR), `api` (the status
# POST) ok.
install_gh_stub() {
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  GH_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  mkdir -p "$GH_BIN"
  : > "$GH_LOG"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$PWD" "\$*" >> "$GH_LOG"
case "\$1" in
  auth) exit 0 ;;
  repo) printf 'test-owner/test-repo\n'; exit 0 ;;
  pr) exit 1 ;;
  api) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
}

# write_merge_payload -> a fresh PreToolUse JSON payload file for a
# `gh pr merge` Bash call, the shape pr-merge-audit-check.sh reads on stdin.
#
# NO positional pull-request reference, deliberately. Every permit the gate
# issues is bound to the pull request the command names, and this suite's stub
# makes `gh pr view` FAIL on purpose, so a merge naming a number would deny for
# want of a record on every case here. That would be the gate working, but it
# would also stop this suite from testing what it is for: which ROOT a marker
# is read from. An absent positional is gh's current-branch default, which the
# binding permits outright without reaching the network, so root anchoring is
# what decides each case again.
write_merge_payload() {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/merge-payload-XXXXXX")"
  jq -n --arg c "gh pr merge --squash --delete-branch" \
    '{tool_name: "Bash", tool_input: {command: $c}}' > "$f"
  printf '%s' "$f"
}

# extract_audit_root_block <file>: pulls the fenced code block containing the
# AUDIT_ROOT derivation, verbatim, exclusive of the fences. Same awk
# state-machine technique main-only-lib.bats's extract_block uses for the
# refusal call sites, retargeted here: an executed extraction of the file's
# own text, never a hand-maintained copy that can drift from it. Deliberately
# a separate, small extractor rather than importing main-only-lib.bats's
# helper across suites (different anchor text, different file set).
#
# The anchor is any first-column assignment to AUDIT_ROOT, deliberately wider
# than the shipped `${AUDIT_ROOT:-` shape: stage 8's non-vacuity mutation
# rewrites the derivation into its ambient-cwd form, and an anchor tied to the
# shipped shape stops matching the moment that mutation lands. The extraction
# then returns nothing, run_audit_root_block runs a script with no derivation
# in it, and the control measures an empty block instead of a mutated one.
extract_audit_root_block() {
  awk '
    /^```/ {
      if (in_block) {
        if (found) { printf "%s", buf; exit }
        in_block = 0; buf = ""; found = 0
      } else {
        in_block = 1; buf = ""
      }
      next
    }
    in_block {
      buf = buf $0 "\n"
      if ($0 ~ /^AUDIT_ROOT=/) found = 1
    }
  ' "$1"
}

# run_audit_root_block <AUDIT_ROOT-or-empty> <cwd> <block> -> runs the
# extracted block in a fresh bash script anchored on <cwd>, then prints the
# resulting $AUDIT_ROOT. Writing the block to a temp file sidesteps the
# quoting hazard of nesting the block's own double quotes inside a `bash -c`
# string.
#
# An empty block is refused rather than run. The script would then be the
# trailing printf alone, which echoes the supplied AUDIT_ROOT straight back
# without deriving anything, and every caller here compares that output
# against a root it supplied itself. That is a passing answer produced by no
# derivation at all, so it fails closed and names itself.
run_audit_root_block() {
  local audit_root_env="$1" cwd="$2" block="$3" script
  if [ -z "$block" ]; then
    echo "run_audit_root_block: empty block; refusing to echo AUDIT_ROOT back as if a derivation produced it" >&2
    return 2
  fi
  script="$(mktemp "$BATS_TEST_TMPDIR/audit-root-block-XXXXXX")"
  {
    printf '%s\n' "$block"
    printf 'printf %%s "$AUDIT_ROOT"\n'
  } > "$script"
  if [ -n "$audit_root_env" ]; then
    ( cd "$cwd" && AUDIT_ROOT="$audit_root_env" bash "$script" )
  else
    ( cd "$cwd" && bash "$script" )
  fi
}

# -----------------------------------------------------------------------------
# Fixture sanity (acceptance criterion 6)
# -----------------------------------------------------------------------------

@test "fixture: every roster member's digest differs between MAIN and WT" {
  local m main_d wt_d all_differ=1
  for m in "${ALL_MEMBERS[@]}"; do
    main_d="$(digest_of "$MAIN" "$m")"
    wt_d="$(digest_of "$WT" "$m")"
    [ -n "$main_d" ] || { echo "$m: MAIN digest empty" >&2; return 1; }
    [ -n "$wt_d" ] || { echo "$m: WT digest empty" >&2; return 1; }
    if [ "$main_d" = "$wt_d" ]; then
      echo "$m: MAIN and WT digests are identical ($main_d); fixture is not discriminating" >&2
      all_differ=0
    else
      echo "$m: MAIN=$main_d WT=$wt_d" >&2
    fi
  done
  [ "$all_differ" -eq 1 ]
}

# -----------------------------------------------------------------------------
# Stage 1: resolve-audit-members.sh (flag: --root). Instance 5.
# -----------------------------------------------------------------------------

@test "stage 1 (flag: --root) supplied, from OUTSIDE: emits WT's dispatched member set" {
  local expected_set
  expected_set="$(printf '%s\n' "${ALL_MEMBERS[@]}" | LC_ALL=C sort -u)"
  run_stdout_only bash "$SCRIPT_RESOLVE_MEMBERS" --root "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_set" ]
}

@test "stage 1 (flag: --root) omitted, from OUTSIDE: exits 2 with empty stdout rather than emitting MAIN's set or an empty success" {
  run_stdout_only bash "$SCRIPT_RESOLVE_MEMBERS"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "stage 1 non-vacuity (source mutation): dropping --root handling turns the supplied-root assertion red; byte-identical restore verified" {
  local orig_sum expected_set start mutated_sum went_red=0 restored_sum
  orig_sum="$(backup_file "$SCRIPT_RESOLVE_MEMBERS")"
  expected_set="$(printf '%s\n' "${ALL_MEMBERS[@]}" | LC_ALL=C sort -u)"

  run_stdout_only bash "$SCRIPT_RESOLVE_MEMBERS" --root "$WT"
  if [ "$status" -ne 0 ] || [ "$output" != "$expected_set" ]; then
    echo "baseline (unmutated) stage 1 check failed" >&2
    restore_file "$SCRIPT_RESOLVE_MEMBERS" "$orig_sum"
    return 1
  fi

  start=$(grep -n '^      ROOT_OVERRIDE="\$2"$' "$SCRIPT_RESOLVE_MEMBERS" | head -1 | cut -d: -f1)
  if [ -z "$start" ]; then
    echo "could not locate the ROOT_OVERRIDE anchor" >&2
    restore_file "$SCRIPT_RESOLVE_MEMBERS" "$orig_sum"
    return 1
  fi
  mutate_lines "$SCRIPT_RESOLVE_MEMBERS" "$start" "$start" '      ROOT_OVERRIDE=""'
  mutated_sum="$(sha_of "$SCRIPT_RESOLVE_MEMBERS")"
  if [ "$mutated_sum" = "$orig_sum" ]; then
    echo "mutation did not change the file" >&2
    restore_file "$SCRIPT_RESOLVE_MEMBERS" "$orig_sum"
    return 1
  fi

  run_stdout_only bash "$SCRIPT_RESOLVE_MEMBERS" --root "$WT"
  { [ "$status" -eq 0 ] && [ "$output" = "$expected_set" ]; } || went_red=1

  restore_file "$SCRIPT_RESOLVE_MEMBERS" "$orig_sum"
  restored_sum="$(sha_of "$SCRIPT_RESOLVE_MEMBERS")"
  [ "$restored_sum" = "$orig_sum" ] || { echo "restore did not reproduce the original bytes" >&2; return 1; }
  [ "$went_red" -eq 1 ] || { echo "stage 1 stayed green under its mutation control; the assertion is vacuous" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# Stage 2: resolve-audit-spawn.sh (anchor: none -- takes no root argument).
# Instance 6. Phase 2's D-3.
# -----------------------------------------------------------------------------

@test "stage 2 (anchor: none) from OUTSIDE: fails closed to code-audit-frontend rather than answering nobody owed" {
  run_stdout_only bash "$SCRIPT_RESOLVE_SPAWN"
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "stage 2 non-vacuity (source mutation): restoring the pre-D-3 fail-open guard turns the assertion red; byte-identical restore verified" {
  local orig_sum start mutated_sum went_red=0 restored_sum
  orig_sum="$(backup_file "$SCRIPT_RESOLVE_SPAWN")"

  run_stdout_only bash "$SCRIPT_RESOLVE_SPAWN"
  if [ "$status" -ne 0 ] || [ "$output" != "code-audit-frontend" ]; then
    echo "baseline (unmutated) stage 2 check failed" >&2
    restore_file "$SCRIPT_RESOLVE_SPAWN" "$orig_sum"
    return 1
  fi

  start=$(grep -n '^if \[ -z "\$repo_root" \]; then$' "$SCRIPT_RESOLVE_SPAWN" | head -1 | cut -d: -f1)
  if [ -z "$start" ]; then
    echo "could not locate the not-a-repository guard" >&2
    restore_file "$SCRIPT_RESOLVE_SPAWN" "$orig_sum"
    return 1
  fi
  mutate_lines "$SCRIPT_RESOLVE_SPAWN" "$start" $((start + 4)) '[ -n "$repo_root" ] || exit 0'
  mutated_sum="$(sha_of "$SCRIPT_RESOLVE_SPAWN")"
  if [ "$mutated_sum" = "$orig_sum" ]; then
    echo "mutation did not change the file" >&2
    restore_file "$SCRIPT_RESOLVE_SPAWN" "$orig_sum"
    return 1
  fi

  run_stdout_only bash "$SCRIPT_RESOLVE_SPAWN"
  { [ "$status" -eq 0 ] && [ "$output" = "code-audit-frontend" ]; } || went_red=1

  restore_file "$SCRIPT_RESOLVE_SPAWN" "$orig_sum"
  restored_sum="$(sha_of "$SCRIPT_RESOLVE_SPAWN")"
  [ "$restored_sum" = "$orig_sum" ] || { echo "restore did not reproduce the original bytes" >&2; return 1; }
  [ "$went_red" -eq 1 ] || { echo "stage 2 stayed green under its mutation control; the assertion is vacuous" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# Stage 3: audit-member-digest.sh (flag: --root). Instance 2.
# -----------------------------------------------------------------------------

@test "stage 3 (flag: --root) supplied, from OUTSIDE: equals the ground-truth digest for WT and differs from --root MAIN" {
  local wt_ground_truth wt_out main_out
  wt_ground_truth="$(digest_of "$WT" code-audit-frontend)"

  run_stdout_only bash "$SCRIPT_MEMBER_DIGEST" --root "$WT" --member code-audit-frontend
  [ "$status" -eq 0 ]
  wt_out="$output"
  [ "$wt_out" = "$wt_ground_truth" ]

  run_stdout_only bash "$SCRIPT_MEMBER_DIGEST" --root "$MAIN" --member code-audit-frontend
  [ "$status" -eq 0 ]
  main_out="$output"

  [ "$wt_out" != "$main_out" ]
}

@test "stage 3 non-vacuity (source mutation): dropping --root forwarding in the digest call path turns the assertion red; byte-identical restore verified" {
  local orig_sum wt_ground_truth start mutated_sum went_red=0 restored_sum
  orig_sum="$(backup_file "$SCRIPT_MEMBER_DIGEST")"
  wt_ground_truth="$(digest_of "$WT" code-audit-frontend)"

  run_stdout_only bash "$SCRIPT_MEMBER_DIGEST" --root "$WT" --member code-audit-frontend
  if [ "$status" -ne 0 ] || [ "$output" != "$wt_ground_truth" ]; then
    echo "baseline (unmutated) stage 3 check failed" >&2
    restore_file "$SCRIPT_MEMBER_DIGEST" "$orig_sum"
    return 1
  fi

  start=$(grep -n '^      root="\${2:-}"$' "$SCRIPT_MEMBER_DIGEST" | head -1 | cut -d: -f1)
  if [ -z "$start" ]; then
    echo "could not locate the --root anchor" >&2
    restore_file "$SCRIPT_MEMBER_DIGEST" "$orig_sum"
    return 1
  fi
  mutate_lines "$SCRIPT_MEMBER_DIGEST" "$start" "$start" '      root=""'
  mutated_sum="$(sha_of "$SCRIPT_MEMBER_DIGEST")"
  if [ "$mutated_sum" = "$orig_sum" ]; then
    echo "mutation did not change the file" >&2
    restore_file "$SCRIPT_MEMBER_DIGEST" "$orig_sum"
    return 1
  fi

  run_stdout_only bash "$SCRIPT_MEMBER_DIGEST" --root "$WT" --member code-audit-frontend
  { [ "$status" -eq 0 ] && [ "$output" = "$wt_ground_truth" ]; } || went_red=1

  restore_file "$SCRIPT_MEMBER_DIGEST" "$orig_sum"
  restored_sum="$(sha_of "$SCRIPT_MEMBER_DIGEST")"
  [ "$restored_sum" = "$orig_sum" ] || { echo "restore did not reproduce the original bytes" >&2; return 1; }
  [ "$went_red" -eq 1 ] || { echo "stage 3 stayed green under its mutation control; the assertion is vacuous" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# Stage 4: audit-write-clearance.sh (flag: --root). Instance 2.
# -----------------------------------------------------------------------------

@test "stage 4 (flag: --root) supplied, from OUTSIDE: the marker's digest key matches WT's content" {
  local wt_ground_truth marker_path body_digest
  wt_ground_truth="$(digest_of "$WT" code-audit-frontend)"
  run_stdout_only bash "$SCRIPT_WRITE_CLEARANCE" --root "$WT" --member code-audit-frontend --provenance earned
  [ "$status" -eq 0 ]
  marker_path="$output"
  [ -f "$marker_path" ]
  body_digest="$(jq -r '.digest' "$marker_path")"
  [ "$body_digest" = "$wt_ground_truth" ]
}

@test "stage 4 (flag: --root) a subdirectory of WT, from OUTSIDE: exits 2 and writes nothing" {
  local subdir before_snapshot after_snapshot
  subdir="$WT/app"
  before_snapshot="$(pool_snapshot "$WT")"
  run_stdout_only bash "$SCRIPT_WRITE_CLEARANCE" --root "$subdir" --member code-audit-frontend --provenance earned
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  after_snapshot="$(pool_snapshot "$WT")"
  [ "$before_snapshot" = "$after_snapshot" ]
}

@test "stage 4 non-vacuity (source mutation): removing the toplevel-equals-ROOT validation turns the subdirectory-rejection assertion red; byte-identical restore verified" {
  local orig_sum subdir before_snapshot after_snapshot start mutated_sum went_red=0 restored_sum
  orig_sum="$(backup_file "$SCRIPT_WRITE_CLEARANCE")"
  subdir="$WT/app"

  before_snapshot="$(pool_snapshot "$WT")"
  run_stdout_only bash "$SCRIPT_WRITE_CLEARANCE" --root "$subdir" --member code-audit-frontend --provenance earned
  if [ "$status" -ne 2 ] || [ -n "$output" ]; then
    echo "baseline (unmutated) stage 4 check failed" >&2
    restore_file "$SCRIPT_WRITE_CLEARANCE" "$orig_sum"
    return 1
  fi
  after_snapshot="$(pool_snapshot "$WT")"
  if [ "$before_snapshot" != "$after_snapshot" ]; then
    echo "baseline (unmutated) stage 4 check wrote to the pool unexpectedly" >&2
    restore_file "$SCRIPT_WRITE_CLEARANCE" "$orig_sum"
    return 1
  fi

  start=$(grep -n '^_root_phys="\$(cd "\$ROOT"' "$SCRIPT_WRITE_CLEARANCE" | head -1 | cut -d: -f1)
  if [ -z "$start" ]; then
    echo "could not locate the toplevel-equals-ROOT validation" >&2
    restore_file "$SCRIPT_WRITE_CLEARANCE" "$orig_sum"
    return 1
  fi
  mutate_lines "$SCRIPT_WRITE_CLEARANCE" "$start" $((start + 5))
  mutated_sum="$(sha_of "$SCRIPT_WRITE_CLEARANCE")"
  if [ "$mutated_sum" = "$orig_sum" ]; then
    echo "mutation did not change the file" >&2
    restore_file "$SCRIPT_WRITE_CLEARANCE" "$orig_sum"
    return 1
  fi

  before_snapshot="$(pool_snapshot "$WT")"
  run_stdout_only bash "$SCRIPT_WRITE_CLEARANCE" --root "$subdir" --member code-audit-frontend --provenance earned
  { [ "$status" -eq 2 ] && [ -z "$output" ]; } || went_red=1

  restore_file "$SCRIPT_WRITE_CLEARANCE" "$orig_sum"
  restored_sum="$(sha_of "$SCRIPT_WRITE_CLEARANCE")"
  [ "$restored_sum" = "$orig_sum" ] || { echo "restore did not reproduce the original bytes" >&2; return 1; }
  [ "$went_red" -eq 1 ] || { echo "stage 4 stayed green under its mutation control; the assertion is vacuous" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# Stage 5: audit-stamp-trailer.sh (anchor: caller cd, no root argument at
# all). Instance 3. Non-vacuity is an INVOCATION control (no line to mutate;
# option C put the anchoring in the caller, not in this hook).
# -----------------------------------------------------------------------------

@test "stage 5 (anchor: caller cd) anchored on WT, from OUTSIDE: stamps or declines WT's own HEAD; MAIN's HEAD and branch are untouched" {
  local before_wt_tree before_main_sha before_main_branch wt_frontend_digest after_main_sha after_main_branch wt_trailer_digest
  provision_all_members "$WT"
  before_wt_tree=$(git -C "$WT" rev-parse "HEAD^{tree}")
  before_main_sha=$(git -C "$MAIN" rev-parse HEAD)
  before_main_branch=$(git -C "$MAIN" branch --show-current)
  wt_frontend_digest="$(digest_of "$WT" code-audit-frontend)"

  run bash -c '( cd "$1" && AUDIT_TREE_SHA="$2" AUDIT_SELF_HEALED=false bash "$3" )' \
    _ "$WT" "$before_wt_tree" "$HOOK_STAMP"
  [ "$status" -eq 0 ]
  case "$output" in
    "stamp: amended"*|"stamp: empty commit"*|"stamp: declined:"*) ;;
    *) echo "unexpected stamp output: $output" >&2; return 1 ;;
  esac

  after_main_sha=$(git -C "$MAIN" rev-parse HEAD)
  after_main_branch=$(git -C "$MAIN" branch --show-current)
  [ "$after_main_sha" = "$before_main_sha" ]
  [ "$after_main_branch" = "$before_main_branch" ]

  # When it stamped (the member-aware gate cleared), the trailer names WT's
  # own frontend digest, never MAIN's.
  wt_trailer_digest="$(trailer_digest_on "$WT")"
  if [ -n "$wt_trailer_digest" ]; then
    [ "$wt_trailer_digest" = "$wt_frontend_digest" ]
  fi
}

@test "stage 5 control A (invocation: anchored on MAIN instead of WT): the WT-shaped assertion goes red, naming MAIN instead" {
  local before_wt_sha before_main_tree main_frontend_digest wt_frontend_digest main_trailer_digest after_wt_sha wt_trailer_digest_after
  provision_all_members "$MAIN"
  provision_all_members "$WT"
  before_wt_sha=$(git -C "$WT" rev-parse HEAD)
  before_main_tree=$(git -C "$MAIN" rev-parse "HEAD^{tree}")
  main_frontend_digest="$(digest_of "$MAIN" code-audit-frontend)"
  wt_frontend_digest="$(digest_of "$WT" code-audit-frontend)"

  run bash -c '( cd "$1" && AUDIT_TREE_SHA="$2" AUDIT_SELF_HEALED=false bash "$3" )' \
    _ "$MAIN" "$before_main_tree" "$HOOK_STAMP"
  [ "$status" -eq 0 ]

  # Positive: anchored on MAIN, it names MAIN.
  main_trailer_digest="$(trailer_digest_on "$MAIN")"
  if [ -n "$main_trailer_digest" ]; then
    [ "$main_trailer_digest" = "$main_frontend_digest" ]
  fi

  # WT never moved.
  after_wt_sha=$(git -C "$WT" rev-parse HEAD)
  [ "$after_wt_sha" = "$before_wt_sha" ]

  # The main test's own assertion ("WT's trailer names WT's digest"),
  # re-applied here, is now FALSE: nothing ran against WT in this control.
  wt_trailer_digest_after="$(trailer_digest_on "$WT")"
  if [ "$wt_trailer_digest_after" = "$wt_frontend_digest" ] && [ -n "$wt_trailer_digest_after" ]; then
    echo "stage 5 control A: WT's trailer unexpectedly reflects WT's own digest; anchoring on MAIN had no effect" >&2
    return 1
  fi
}

@test "stage 5 control B (invocation: no anchor at all, from OUTSIDE): declines 'not in a git repo', writes nothing to MAIN or WT" {
  local before_wt_sha before_main_sha
  before_wt_sha=$(git -C "$WT" rev-parse HEAD)
  before_main_sha=$(git -C "$MAIN" rev-parse HEAD)

  run bash "$HOOK_STAMP"
  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: not in a git repo" ]

  [ "$(git -C "$WT" rev-parse HEAD)" = "$before_wt_sha" ]
  [ "$(git -C "$MAIN" rev-parse HEAD)" = "$before_main_sha" ]
}

# -----------------------------------------------------------------------------
# Stage 6: post-audit-status.sh (anchor: caller cd, no root argument at all).
# Instance 4. Non-vacuity is an INVOCATION control, same reason as stage 5.
# -----------------------------------------------------------------------------

@test "stage 6 (anchor: caller cd) anchored on WT, from OUTSIDE: every gh invocation ran with WT as its working directory" {
  local marker wt_phys pwd_col rest_col
  marker=$(bash "$SCRIPT_WRITE_CLEARANCE" --root "$WT" --member code-audit-frontend --provenance earned 2>/dev/null)
  chmod -x "$WT/.gaia/scripts/resolve-audit-members.sh"
  install_gh_stub

  run bash -c 'export PATH="$1:$PATH"; ( cd "$2" && bash "$3" "$4" )' \
    _ "$GH_BIN" "$WT" "$HOOK_POST" "$marker"
  [ "$status" -eq 0 ]
  [ -s "$GH_LOG" ]

  # Physically resolve BOTH sides: post-audit-status.sh anchors `gh auth
  # status` on whatever cwd the hook process inherited (unresolved, logical),
  # but `gh pr view` / `gh repo view` re-anchor via `git rev-parse
  # --show-toplevel`, which physically resolves. The two gh calls in one run
  # can therefore log different string forms of the SAME tree; phys() on both
  # sides normalizes that away rather than assuming one form throughout.
  wt_phys="$(phys "$WT")"
  while IFS=$'\t' read -r pwd_col rest_col; do
    [ -n "$pwd_col" ] || continue
    [ "$(phys "$pwd_col")" = "$wt_phys" ] || { echo "gh call ran with PWD=$pwd_col ($rest_col), expected $wt_phys" >&2; return 1; }
  done < "$GH_LOG"
}

@test "stage 6 control A (invocation: anchored on MAIN instead of WT): every gh call names MAIN; the WT-shaped assertion goes red" {
  local marker main_phys wt_phys pwd_col rest_col resolved found_wt=0
  marker=$(bash "$SCRIPT_WRITE_CLEARANCE" --root "$MAIN" --member code-audit-frontend --provenance earned 2>/dev/null)
  chmod -x "$MAIN/.gaia/scripts/resolve-audit-members.sh"
  install_gh_stub

  run bash -c 'export PATH="$1:$PATH"; ( cd "$2" && bash "$3" "$4" )' \
    _ "$GH_BIN" "$MAIN" "$HOOK_POST" "$marker"
  [ "$status" -eq 0 ]
  [ -s "$GH_LOG" ]

  main_phys="$(phys "$MAIN")"
  wt_phys="$(phys "$WT")"
  while IFS=$'\t' read -r pwd_col rest_col; do
    [ -n "$pwd_col" ] || continue
    resolved="$(phys "$pwd_col")"
    [ "$resolved" = "$main_phys" ] || { echo "gh call ran with PWD=$pwd_col ($rest_col), expected $main_phys" >&2; return 1; }
    [ "$resolved" = "$wt_phys" ] && found_wt=1
  done < "$GH_LOG"

  # The main test's own assertion ("every call names WT"), re-applied here,
  # is now FALSE: no logged call resolved to WT's cwd.
  if [ "$found_wt" -eq 1 ]; then
    echo "stage 6 control A: a gh call unexpectedly ran with WT's cwd; anchoring on MAIN had no effect" >&2
    return 1
  fi
}

@test "stage 6 control B (invocation: no anchor at all, from OUTSIDE): declines 'repo slug unresolved', posts nothing" {
  local marker
  marker=$(bash "$SCRIPT_WRITE_CLEARANCE" --root "$WT" --member code-audit-frontend --provenance earned 2>/dev/null)
  install_gh_stub

  run bash -c 'export PATH="$1:$PATH"; bash "$2" "$3"' _ "$GH_BIN" "$HOOK_POST" "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: repo slug unresolved" ]
}

# -----------------------------------------------------------------------------
# Stage 7: pr-merge-audit-check.sh (anchor: caller cd, no root argument at
# all). Instance 1. FC-4's two independent roots: main-anchored (WHERE a
# clearance lives) and acting-tree (WHAT it attests to). Asserted separately,
# per README.md FC-4 / task doc "Stage 7 in particular".
# -----------------------------------------------------------------------------

@test "stage 7 acting-tree root (digest), anchored on WT from OUTSIDE: the computed content digest is WT's, independent of where the store resolves" {
  local wt_frontend_digest main_frontend_digest payload
  wt_frontend_digest="$(digest_of "$WT" code-audit-frontend)"
  main_frontend_digest="$(digest_of "$MAIN" code-audit-frontend)"
  payload="$(write_merge_payload)"

  invoke_hook_in "$WT" "$(cat "$payload")" "$HOOK_MERGE"
  [ "$status" -eq 0 ]
  grep -qF -- "$wt_frontend_digest" <<<"$output" || { echo "deny output does not name WT's frontend digest ($wt_frontend_digest): $output" >&2; return 1; }
  grep -qF -- "$main_frontend_digest" <<<"$output" && { echo "deny output names MAIN's digest instead of WT's" >&2; return 1; }
  return 0
}

@test "stage 7 main-anchored root (store), anchored on WT from OUTSIDE: a marker in MAIN's separate store, keyed to WT's digest, clears the merge" {
  local m digest payload
  for m in "${ALL_MEMBERS[@]}"; do
    digest="$(write_marker_at "$MAIN" "$WT" "$m")"
    [ "$m" = "code-audit-frontend" ] && write_sidecar_at "$MAIN" "$digest"
  done
  payload="$(write_merge_payload)"

  invoke_hook_in "$WT" "$(cat "$payload")" "$HOOK_MERGE"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && { echo "expected allow, got deny: $output" >&2; return 1; }
  return 0
}

@test "stage 7 main-anchored root (store), negative isolation: a marker keyed to MAIN's own content does not clear the WT-anchored merge" {
  local m digest payload
  for m in "${ALL_MEMBERS[@]}"; do
    digest="$(write_marker_at "$MAIN" "$MAIN" "$m")"
    [ "$m" = "code-audit-frontend" ] && write_sidecar_at "$MAIN" "$digest"
  done
  payload="$(write_merge_payload)"

  invoke_hook_in "$WT" "$(cat "$payload")" "$HOOK_MERGE"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || { echo "expected deny (wrong-digest marker must not clear), got allow: $output" >&2; return 1; }
}

@test "stage 7 non-vacuity (source mutation): collapsing the main-anchored root onto the acting tree turns the store assertion red while the digest assertion stays green; byte-identical restore verified" {
  local orig_sum m digest payload start mutated_sum store_went_red=0 digest_stayed_green=0 restored_sum wt_frontend_digest
  orig_sum="$(backup_file "$HOOK_MERGE")"

  # Baseline (unmutated): the store assertion holds.
  for m in "${ALL_MEMBERS[@]}"; do
    digest="$(write_marker_at "$MAIN" "$WT" "$m")"
    [ "$m" = "code-audit-frontend" ] && write_sidecar_at "$MAIN" "$digest"
  done
  payload="$(write_merge_payload)"
  invoke_hook_in "$WT" "$(cat "$payload")" "$HOOK_MERGE"
  if grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
    echo "baseline (unmutated) stage 7 store assertion failed: $output" >&2
    restore_file "$HOOK_MERGE" "$orig_sum"
    return 1
  fi

  # Baseline (unmutated): the digest assertion holds, from a fresh empty
  # store (a deny naming WT's own digest).
  rm -rf "$MAIN/.gaia/local"
  wt_frontend_digest="$(digest_of "$WT" code-audit-frontend)"
  payload="$(write_merge_payload)"
  invoke_hook_in "$WT" "$(cat "$payload")" "$HOOK_MERGE"
  if ! grep -qF -- "$wt_frontend_digest" <<<"$output"; then
    echo "baseline (unmutated) stage 7 digest assertion failed: $output" >&2
    restore_file "$HOOK_MERGE" "$orig_sum"
    return 1
  fi

  # Mutation: collapse the main-anchored `root` derivation onto the
  # acting-tree toplevel query -- the exact simplification FC-4 forbids.
  start=$(grep -n '^root=""$' "$HOOK_MERGE" | head -1 | cut -d: -f1)
  if [ -z "$start" ]; then
    echo "could not locate the main-anchored root derivation" >&2
    restore_file "$HOOK_MERGE" "$orig_sum"
    return 1
  fi
  mutate_lines "$HOOK_MERGE" "$start" $((start + 4)) 'root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"'
  mutated_sum="$(sha_of "$HOOK_MERGE")"
  if [ "$mutated_sum" = "$orig_sum" ]; then
    echo "mutation did not change the file" >&2
    restore_file "$HOOK_MERGE" "$orig_sum"
    return 1
  fi

  # Store assertion, mutated: must now go red (deny), root collapses to WT's
  # own empty store instead of MAIN's populated one.
  rm -rf "$MAIN/.gaia/local"
  for m in "${ALL_MEMBERS[@]}"; do
    digest="$(write_marker_at "$MAIN" "$WT" "$m")"
    [ "$m" = "code-audit-frontend" ] && write_sidecar_at "$MAIN" "$digest"
  done
  payload="$(write_merge_payload)"
  invoke_hook_in "$WT" "$(cat "$payload")" "$HOOK_MERGE"
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && store_went_red=1

  # Digest assertion, mutated: must stay green -- tree_root's own derivation
  # is untouched by this mutation and still walks WT.
  rm -rf "$MAIN/.gaia/local"
  payload="$(write_merge_payload)"
  invoke_hook_in "$WT" "$(cat "$payload")" "$HOOK_MERGE"
  grep -qF -- "$wt_frontend_digest" <<<"$output" && digest_stayed_green=1

  restore_file "$HOOK_MERGE" "$orig_sum"
  restored_sum="$(sha_of "$HOOK_MERGE")"
  [ "$restored_sum" = "$orig_sum" ] || { echo "restore did not reproduce the original bytes" >&2; return 1; }

  [ "$store_went_red" -eq 1 ] || { echo "the store assertion did not go red under the mutation" >&2; return 1; }
  [ "$digest_stayed_green" -eq 1 ] || { echo "the digest assertion unexpectedly went red under the mutation (should stay green)" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# Stage 8: the extracted agent handshake block (AUDIT_ROOT derivation).
# Instances 2, 7. The block is byte-identical across every agent
# definition (FC-5), so the two positive tests drive every one of them
# rather than pinning the default member's copy and inferring the rest. The
# mutation control below stays on code-audit-frontend.md alone: it proves the
# assertion is non-vacuous, which one file establishes, and mutating the whole
# roster would cost a backup/restore cycle per member for the same signal.
# -----------------------------------------------------------------------------

@test "stage 8 (flag/anchor: AUDIT_ROOT supplied) from OUTSIDE: every definition resolves to WT, never MAIN" {
  local m block main_phys wt_phys
  wt_phys="$(phys "$WT")"
  main_phys="$(phys "$MAIN")"

  for m in "${ALL_MEMBERS[@]}"; do
    block="$(extract_audit_root_block "$MAIN/.claude/agents/${m}.md")"
    [ -n "$block" ] || { echo "$m: extractor found no fenced block containing the AUDIT_ROOT derivation" >&2; return 1; }

    run run_audit_root_block "$WT" "$OUTSIDE" "$block"
    [ "$status" -eq 0 ] || { echo "$m: the block exited $status" >&2; return 1; }
    [ "$output" = "$wt_phys" ] || { echo "$m: resolved '$output', expected the supplied root '$wt_phys'" >&2; return 1; }
    [ "$output" != "$main_phys" ] || { echo "$m: resolved MAIN, so the supplied root lost to the ambient fallback" >&2; return 1; }
  done
}

@test "stage 8 (flag/anchor: AUDIT_ROOT fallback) unset, run inside WT: every definition's fallback resolves WT, not MAIN" {
  local m block wt_phys main_phys
  wt_phys="$(phys "$WT")"
  main_phys="$(phys "$MAIN")"

  for m in "${ALL_MEMBERS[@]}"; do
    block="$(extract_audit_root_block "$MAIN/.claude/agents/${m}.md")"
    [ -n "$block" ] || { echo "$m: extractor found no fenced block containing the AUDIT_ROOT derivation" >&2; return 1; }

    run run_audit_root_block "" "$WT" "$block"
    [ "$status" -eq 0 ] || { echo "$m: the block exited $status" >&2; return 1; }
    [ "$output" = "$wt_phys" ] || { echo "$m: resolved '$output', expected the ambient tree '$wt_phys'" >&2; return 1; }
    [ "$output" != "$main_phys" ] || { echo "$m: resolved MAIN from inside WT" >&2; return 1; }
  done
}

@test "stage 8 non-vacuity (source mutation): restoring an ambient-cwd derivation in one agent file turns the supplied-AUDIT_ROOT assertion red; byte-identical restore verified" {
  local orig_sum wt_phys block start mutated_sum went_red=0 restored_sum
  orig_sum="$(backup_file "$AGENT_MD")"
  wt_phys="$(phys "$WT")"

  block="$(extract_audit_root_block "$AGENT_MD")"
  run run_audit_root_block "$WT" "$OUTSIDE" "$block"
  if [ "$status" -ne 0 ] || [ "$output" != "$wt_phys" ]; then
    echo "baseline (unmutated) stage 8 check failed" >&2
    restore_file "$AGENT_MD" "$orig_sum"
    return 1
  fi

  start=$(grep -n '^AUDIT_ROOT="\${AUDIT_ROOT:-' "$AGENT_MD" | head -1 | cut -d: -f1)
  if [ -z "$start" ]; then
    echo "could not locate the AUDIT_ROOT derivation to mutate" >&2
    restore_file "$AGENT_MD" "$orig_sum"
    return 1
  fi
  mutate_lines "$AGENT_MD" "$start" $((start + 1)) 'AUDIT_ROOT="$(git rev-parse --show-toplevel)"'
  mutated_sum="$(sha_of "$AGENT_MD")"
  if [ "$mutated_sum" = "$orig_sum" ]; then
    echo "mutation did not change the file" >&2
    restore_file "$AGENT_MD" "$orig_sum"
    return 1
  fi

  block="$(extract_audit_root_block "$AGENT_MD")"
  if [ -z "$block" ]; then
    echo "the mutated derivation is not extractable; this control would measure an empty block rather than a mutation" >&2
    restore_file "$AGENT_MD" "$orig_sum"
    return 1
  fi
  run run_audit_root_block "$WT" "$OUTSIDE" "$block"
  { [ "$status" -eq 0 ] && [ "$output" = "$wt_phys" ]; } || went_red=1

  restore_file "$AGENT_MD" "$orig_sum"
  restored_sum="$(sha_of "$AGENT_MD")"
  [ "$restored_sum" = "$orig_sum" ] || { echo "restore did not reproduce the original bytes" >&2; return 1; }
  [ "$went_red" -eq 1 ] || { echo "stage 8 stayed green under its mutation control; the assertion is vacuous" >&2; return 1; }
}
