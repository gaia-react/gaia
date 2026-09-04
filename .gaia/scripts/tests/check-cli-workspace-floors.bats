#!/usr/bin/env bats
#
# Tests for .gaia/scripts/check-cli-workspace-floors.sh: the gate that reports a
# security floor which has stopped being applied in a pnpm workspace root the
# repository's dependency machinery never opens.
#
# The parity arm is what these tests mostly exercise, because it is the arm that
# can be proved offline. The advisory arm shells out to `pnpm audit` against a
# real registry, so the suite pins the contract around it -- that it is
# skippable on request, that its absence is reported rather than swallowed --
# and leaves the network behaviour to CI.
#
# The quoting fixtures are not defensive padding. Both sides of the comparison
# exist in the live tree today and they disagree on spelling: the workspace file
# writes `'cosmiconfig>js-yaml'` quoted, because the key contains a `>`, while
# the lockfile pnpm generates writes the same key bare. A comparison that comes
# out of this file byte-wise reports a phantom mismatch on a tree that is
# correct, which fails in the noisy direction and gets the gate switched off.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  CHECK="$REPO_ROOT/.gaia/scripts/check-cli-workspace-floors.sh"
  TMP="$(mktemp -d)"
  WS="$TMP/ws"
  mkdir -p "$WS"
}

teardown() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# write_workspace / write_lock take the body of the `overrides:` block, already
# indented, so each fixture reads as the file it stands in for.
write_workspace() {
  {
    printf 'minimumReleaseAge: 10080\n\n'
    if [ "$#" -gt 0 ]; then
      printf 'overrides:\n'
      printf '%s\n' "$@"
    fi
  } > "$WS/pnpm-workspace.yaml"
}

write_lock() {
  {
    printf "lockfileVersion: '9.0'\n\nsettings:\n  autoInstallPeers: true\n\n"
    if [ "$#" -gt 0 ]; then
      printf 'overrides:\n'
      printf '%s\n' "$@"
    fi
    printf '\nimporters:\n\n  .:\n    dependencies:\n      zod:\n        specifier: 4.4.3\n'
  } > "$WS/pnpm-lock.yaml"
}

@test "a workspace whose floors are all applied is clean" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'fast-uri' <<<"$output"
}

@test "quoting that differs across the two files is not a mismatch" {
  # The live shape. pnpm quotes a key it must, and does not quote the same key
  # in the lockfile it writes; neither spelling is drift.
  write_workspace "  'cosmiconfig>js-yaml': 4.3.1" "  '@eslint/eslintrc>js-yaml': 4.3.1"
  write_lock "  cosmiconfig>js-yaml: 4.3.1" "  '@eslint/eslintrc>js-yaml': 4.3.1"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
}

@test "double-quoted spellings normalize the same way single-quoted ones do" {
  write_workspace '  "fast-uri": "3.1.6"'
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
}

@test "a configured floor missing from the lockfile is reported as unapplied" {
  write_workspace "  fast-uri: 3.1.6" "  morgan: 1.11.0"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'morgan' <<<"$output"
  grep -qiF -- 'not applied' <<<"$output"
}

@test "a lockfile override with no entry in the workspace config is reported" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6" "  morgan: 1.11.0"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'morgan' <<<"$output"
}

@test "a floor pinned at one version and locked at another is reported" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.4"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- '3.1.6' <<<"$output"
  grep -qF -- '3.1.4' <<<"$output"
}

@test "an overrides map with no lockfile block at all is reported, not passed" {
  # The whole-block-missing case fails the same way one missing key does. A
  # lockfile that lost its overrides block is the loudest form of the defect
  # this gate exists for, so it must not fall through an empty-set comparison.
  write_workspace "  fast-uri: 3.1.6"
  write_lock
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'fast-uri' <<<"$output"
}

@test "a workspace declaring no overrides is clean and says there is nothing to check" {
  write_workspace
  write_lock
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qiF -- 'no overrides' <<<"$output"
}

@test "the key that follows the overrides block does not get read as an override" {
  # `importers:` sits at column zero directly after the block in a real
  # lockfile. A parser that stops only at a blank line swallows it and every
  # nested key under it.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'importers' <<<"$output" && return 1
  grep -qF -- 'specifier' <<<"$output" && return 1
  true
}

@test "a missing workspace root is an environment error, not a clean result" {
  run bash "$CHECK" --no-audit "$TMP/absent"
  [ "$status" -eq 2 ]
}

@test "a workspace root with no pnpm-workspace.yaml is an environment error" {
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
}

@test "a workspace root with no lockfile is an environment error" {
  write_workspace "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
}

@test "an unknown flag is refused rather than silently treated as the root" {
  write_workspace
  write_lock
  run bash "$CHECK" --audit-everything "$WS"
  [ "$status" -eq 2 ]
}

@test "the advisory arm reports that it was skipped rather than staying silent" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qiF -- 'advisory' <<<"$output"
  grep -qiF -- 'skipped' <<<"$output"
}

@test "the advisory arm surfaces a high advisory without changing the exit status" {
  # Stub pnpm so the arm has something to parse. Proving it can report is worth
  # a fixture: an arm that has only ever been observed returning nothing is
  # indistinguishable from one whose filter never matches.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{"1098765":{"id":1098765,"module_name":"fast-uri","severity":"high","title":"host confusion via a backslash authority introducer"},"22":{"module_name":"quiet-dep","severity":"low","title":"ignored"}}}
JSON
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'ADVISORY (high' <<<"$output"
  grep -qF -- 'fast-uri' <<<"$output"
  grep -qF -- 'quiet-dep' <<<"$output" && return 1
  true
}

@test "an advisory does not mask a floor that is not applied" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.4"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '{"advisories":{}}\n'
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 1 ]
}

@test "the header states the decay this check does not catch" {
  # An honest-limits line is load-bearing here rather than decorative: the issue
  # this gate closes is classed holistic/overclaimed-guarantee, and a floor that
  # has quietly become a cap passes the parity arm. A reader who takes a green
  # run as "the floors are current" has been misled by the gate itself.
  grep -qiF -- 'cap' "$CHECK"
  grep -qiF -- 'dedupe' "$CHECK"
}

@test "the repository's own CLI workspace is clean" {
  run bash "$CHECK" --no-audit "$REPO_ROOT/.gaia/cli"
  [ "$status" -eq 0 ]
}

@test "the default root is the CLI workspace, so CI needs no path argument" {
  cd "$REPO_ROOT"
  run bash "$CHECK" --no-audit
  [ "$status" -eq 0 ]
  grep -qF -- '.gaia/cli' <<<"$output"
}
