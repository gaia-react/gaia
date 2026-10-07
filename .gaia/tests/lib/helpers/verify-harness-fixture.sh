#!/usr/bin/env bash
# File-wide: the single-quoted `$` text is suite source written into fixture
# files, and the VHF_ variables are read by the sourcing suites.
# shellcheck disable=SC2016,SC2034
# Shared fixture for the verify-harness suites: a repository with a bare
# `origin`, `main` pushed to it, refs/remotes/origin/main fetched, and a
# feature branch checked out. It carries:
#
#   - stub checks at the real relative paths (shell-lint, build-staging, 01,
#     03). Each resolves its root from the working directory, logs
#     "<name>|<toplevel>" to $VERIFY_FIXTURE_LOG, and fails, printing the
#     file's content as its diagnostic, when the tracked control/<name> file is
#     non-empty. A commit flips a result and the merge base keeps its own, and
#     a runner that runs a check from the wrong directory logs the wrong root.
#   - real copies of the runner, its helpers and the scripts it loads, from
#     the working tree. VERIFY_HARNESS_SOURCE_DIRECTORY swaps in a scratch
#     copy of the runner and its helpers, which is how a mutant runs.
#   - fixture suites logging "bats|<suite>|<test>|<root>" per test run: a
#     whole-tree-marked suite, and suites naming src/x-input.txt,
#     src/s1-input.txt and .claude/rules/s2-rule.md.
#
# Only .gaia/local/ is ignored, so every stub, control file and suite is
# tracked. Everything lands under $BATS_TEST_TMPDIR.
#
# Variables set: VHF_ROOT (physical root), VHF_ORIGIN, VHF_SHIM (a stub
# linter and a logging bats), VERIFY_FIXTURE_LOG (exported), VHF_RECORD
# (the feature branch's pass record path).
#
# vhf_init leaves the feature branch feat/verify checked out; with
# --no-branch it stops on main's root commit, and vhf_branch cuts the branch
# after main has been given its own commits.

# vhf_git <args...>: git in the fixture with a fixed identity.
vhf_git() {
  git -C "$VHF_ROOT" -c user.email=gaia-test@example.com -c user.name="GAIA Test" -c commit.gpgsign=false "$@"
}

# vhf_write_stub <relative path> <control name>
vhf_write_stub() {
  local stub_path="$VHF_ROOT/$1" control_name="$2"
  mkdir -p "${stub_path%/*}"
  cat >"$stub_path" <<EOF
#!/usr/bin/env bash
toplevel="\$(git rev-parse --show-toplevel)"
printf '%s|%s\n' "$control_name" "\$toplevel" >>"\${VERIFY_FIXTURE_LOG:?}"
if [ "$control_name" = build-staging ]; then
  if [ "\$#" -ne 1 ] || [ ! -d "\$1" ] || [ -n "\$(ls -A "\$1")" ]; then
    printf 'Output dir does not exist or is not empty: %s\n' "\${1:-}" >&2
    exit 1
  fi
fi
if [ -s "\$toplevel/control/$control_name" ]; then
  cat "\$toplevel/control/$control_name" >&2
  exit 1
fi
printf '%s passed\n' "$control_name"
EOF
  chmod +x "$stub_path"
}

# vhf_write_suite <relative path> <mark: yes|no> <names...>: a suite whose
# tests each fail while control/<test file stem>-<test slug> is non-empty.
# The mark line is assembled at run time, so it never sits at column 0 here.
vhf_write_suite() {
  local relative_path="$1" suite_path="$VHF_ROOT/$1" marked="$2" stem test_slug
  shift 2
  stem="${suite_path##*/}"
  stem="${stem%.bats}"
  mkdir -p "${suite_path%/*}"
  {
    printf '#!/usr/bin/env bats\n'
    [ "$marked" = yes ] && printf '# bats %s\n' 'file_tags=whole-tree'
    printf 'setup() {\n'
    printf '  fixture_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"\n'
    printf '  printf "bats|%%s|%%s|%%s\\n" "%s" "$BATS_TEST_DESCRIPTION" "$fixture_root" >>"${VERIFY_FIXTURE_LOG:?}"\n' "$relative_path"
    printf '}\n'
    for test_slug in "$@"; do
      printf '@test "%s %s" {\n  [ ! -s "$fixture_root/control/%s-%s" ]\n}\n' "$stem" "$test_slug" "$stem" "$test_slug"
    done
  } >"$suite_path"
}

# vhf_add_test <relative suite path> <slug>: append one control-file test.
vhf_add_test() {
  local suite_path="$VHF_ROOT/$1" stem
  stem="${suite_path##*/}"
  stem="${stem%.bats}"
  printf '@test "%s %s" {\n  [ ! -s "$fixture_root/control/%s-%s" ]\n}\n' "$stem" "$2" "$stem" "$2" >>"$suite_path"
}

# vhf_control <name> <diagnostic text|"">: set a control file (not committed).
vhf_control() {
  mkdir -p "$VHF_ROOT/control"
  printf '%s' "$2" >"$VHF_ROOT/control/$1"
  [ -z "$2" ] || printf '\n' >>"$VHF_ROOT/control/$1"
}

# vhf_commit [message]: commit everything.
vhf_commit() {
  vhf_git add -A && vhf_git commit -q -m "${1:-change}"
}

# vhf_main_change <path> <text> [message]: land a commit on origin's main and
# fetch it, leaving the feature branch where it was.
vhf_main_change() {
  local branch
  branch="$(vhf_git branch --show-current)"
  vhf_git checkout -q main || return 1
  mkdir -p "$(dirname "$VHF_ROOT/$1")"
  printf '%s\n' "$2" >"$VHF_ROOT/$1"
  vhf_commit "${3:-main change}" && vhf_git push -q origin main 2>/dev/null || return 1
  vhf_git fetch -q origin && vhf_git checkout -q "$branch"
}

# vhf_init [--no-branch]: build the fixture; a feature branch unless asked not.
vhf_init() {
  [ -n "${BATS_TEST_TMPDIR:-}" ] || { printf 'vhf_init: BATS_TEST_TMPDIR is unset\n' >&2; return 1; }
  local source_root source_tests repository script_name real_bats
  source_root="$(cd "${BASH_SOURCE[0]%/*}/../../../.." && pwd -P)" || return 1
  source_tests="${VERIFY_HARNESS_SOURCE_DIRECTORY:-$source_root/.gaia/tests}"
  repository="$BATS_TEST_TMPDIR/repo"
  VHF_ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  VERIFY_FIXTURE_LOG="$BATS_TEST_TMPDIR/checks.log"
  export VERIFY_FIXTURE_LOG
  : >"$VERIFY_FIXTURE_LOG"
  git init -q --bare -b main "$VHF_ORIGIN" || return 1
  git init -q -b main "$repository" || return 1
  VHF_ROOT="$(cd "$repository" && pwd -P)" || return 1
  printf '.gaia/local/\n' >"$VHF_ROOT/.gitignore"

  mkdir -p "$VHF_ROOT/.gaia/scripts" "$VHF_ROOT/.gaia/tests/helpers" "$VHF_ROOT/.gaia/cli" || return 1
  for script_name in bats-suites-for-change.sh bats5.sh audit-loop-state-lib.sh branch-name-lib.sh \
    main-root-lib.sh audit-key-lib.sh; do
    cp "$source_root/.gaia/scripts/$script_name" "$VHF_ROOT/.gaia/scripts/$script_name" || return 1
  done
  cp "$source_tests/verify-harness.sh" "$VHF_ROOT/.gaia/tests/verify-harness.sh" || return 1
  cp "$source_tests/helpers/verify-harness-lib.sh" "$VHF_ROOT/.gaia/tests/helpers/verify-harness-lib.sh" || return 1
  cp "$source_tests/helpers/verify-harness-bats-lib.sh" "$VHF_ROOT/.gaia/tests/helpers/verify-harness-bats-lib.sh" || return 1
  cp "$source_tests/helpers/verify-pass-record.sh" "$VHF_ROOT/.gaia/tests/helpers/verify-pass-record.sh" || return 1

  vhf_write_stub .gaia/tests/shell-lint.sh shell-lint
  vhf_write_stub .gaia/tests/distribution/lib/build-staging.sh build-staging
  vhf_write_stub .gaia/tests/distribution/01-files-present.sh 01-files-present
  vhf_write_stub .gaia/tests/distribution/03-marker-strip.sh 03-marker-strip
  printf '#!/bin/sh\nexit 0\n' >"$VHF_ROOT/.gaia/cli/gaia-maintainer"
  chmod +x "$VHF_ROOT/.gaia/cli/gaia-maintainer"

  vhf_write_suite suites/whole.bats yes zero one
  # The whole-tree behavior: an outcome that depends on files no suite names.
  printf '@test "whole content" {\n  run grep -rlF FORBIDDEN "$fixture_root/content"\n  [ "$status" -ne 0 ]\n}\n' \
    >>"$VHF_ROOT/suites/whole.bats"
  vhf_write_suite suites/x.bats no input
  vhf_write_suite suites/s1.bats no input
  vhf_write_suite suites/s2.bats no rule
  # The selector picks a suite by the basename it names.
  printf '# reads src/x-input.txt\n' >>"$VHF_ROOT/suites/x.bats"
  printf '# reads src/s1-input.txt\n' >>"$VHF_ROOT/suites/s1.bats"
  printf '# reads .claude/rules/s2-rule.md\n' >>"$VHF_ROOT/suites/s2.bats"
  mkdir -p "$VHF_ROOT/src" "$VHF_ROOT/.claude/rules" "$VHF_ROOT/frontend/app" "$VHF_ROOT/control"
  printf 'x\n' >"$VHF_ROOT/src/x-input.txt"
  printf 's1\n' >"$VHF_ROOT/src/s1-input.txt"
  printf 's2\n' >"$VHF_ROOT/.claude/rules/s2-rule.md"
  printf 'page\n' >"$VHF_ROOT/frontend/app/page.txt"
  # Tracked and empty, so a test's uncommitted edit to one is a tracked change.
  for script_name in shell-lint build-staging 01-files-present 03-marker-strip; do
    : >"$VHF_ROOT/control/$script_name"
  done

  VHF_SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$VHF_SHIM"
  printf '#!/bin/sh\nexit 0\n' >"$VHF_SHIM/shellcheck"
  real_bats="$(command -v bats)" || return 1
  cat >"$VHF_SHIM/bats" <<EOF
#!/usr/bin/env bash
printf 'bats-process|%s\n' "\$*" >>"\${VERIFY_FIXTURE_LOG:?}"
exec "$real_bats" "\$@"
EOF
  chmod +x "$VHF_SHIM/shellcheck" "$VHF_SHIM/bats"

  vhf_commit base || return 1
  vhf_git remote add origin "$VHF_ORIGIN" && vhf_git push -q origin main 2>/dev/null || return 1
  vhf_git fetch -q origin || return 1
  VHF_RECORD="$VHF_ROOT/.gaia/local/protected/verify-pass/feat/verify.json"
  [ "${1:-}" = --no-branch ] && return 0
  vhf_git checkout -q -b feat/verify
}

# vhf_branch: push main as it stands, fetch it, and cut the feature branch.
vhf_branch() {
  vhf_git push -q origin main 2>/dev/null && vhf_git fetch -q origin && vhf_git checkout -q -b feat/verify
}

# vhf_empty_candidates: make the fixture's bats5.sh copy prefer no Homebrew
# bash, so a PATH shim decides which bash and which parallel runner it sees.
vhf_empty_candidates() {
  sed 's#^  for candidate_directory in /opt/homebrew/bin /usr/local/bin; do#  for candidate_directory in ; do#' \
    "$VHF_ROOT/.gaia/scripts/bats5.sh" >"$VHF_ROOT/.gaia/scripts/bats5.sh.edit" \
    && mv "$VHF_ROOT/.gaia/scripts/bats5.sh.edit" "$VHF_ROOT/.gaia/scripts/bats5.sh"
  grep -q '^  for candidate_directory in ; do' "$VHF_ROOT/.gaia/scripts/bats5.sh"
}

# vhf_path_without <tool...>: print a PATH directory holding every command of
# the current PATH except the named ones. The linter is always the stub, and
# naming it removes even that.
vhf_path_without() {
  local farm="$BATS_TEST_TMPDIR/farm" path_directory omitted
  local saved_ifs="$IFS"
  rm -rf "$farm"
  mkdir -p "$farm"
  IFS=:
  for path_directory in $PATH; do
    IFS="$saved_ifs"
    [ "$path_directory" = "$VHF_SHIM" ] && continue
    [ -d "$path_directory" ] || continue
    ln -s "$path_directory"/* "$farm"/ 2>/dev/null
  done
  IFS="$saved_ifs"
  rm -f "$farm/shellcheck"
  cp "$VHF_SHIM/shellcheck" "$farm/shellcheck"
  for omitted in "$@"; do
    rm -f "${farm:?}/$omitted"
  done
  printf '%s\n' "$farm"
}

# vhf_log_entries <name>: the toplevels a stub logged, one per line.
vhf_log_entries() {
  awk -F'|' -v name="$1" '$1 == name { print $2 }' "$VERIFY_FIXTURE_LOG"
}

# vhf_suite_runs <suite> <root>: test names that ran in <suite> at <root>.
vhf_suite_runs() {
  awk -F'|' -v suite="$1" -v root="$2" '$1 == "bats" && $2 == suite && $4 == root { print $3 }' "$VERIFY_FIXTURE_LOG"
}

# vhf_suite_runs_elsewhere <suite> <root>: test names that ran in <suite>
# anywhere but <root>.
vhf_suite_runs_elsewhere() {
  awk -F'|' -v suite="$1" -v root="$2" '$1 == "bats" && $2 == suite && $4 != root { print $3 }' "$VERIFY_FIXTURE_LOG"
}
