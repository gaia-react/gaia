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
  # The absent-from-lockfile arm is asserted by its own wording. Without this,
  # disabling that arm lets the key fall through to the version-mismatch arm,
  # which prints the same package with an empty locked version and still
  # matches both greps above, so the arm can be removed with the suite green.
  grep -qF -- 'absent from the lockfile' <<<"$output"
}

@test "a lockfile override with no entry in the workspace config is reported" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6" "  morgan: 1.11.0"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'morgan' <<<"$output"
  # Asserted as a PRESENCE. The sibling test that pins the clean path asserts
  # this wording only as an absence, and an absence assertion alone leaves the
  # wording free to be reworded away without reddening anything.
  grep -qF -- 'UNDECLARED OVERRIDE' <<<"$output"
}

@test "a floor pinned at one version and locked at another is reported" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.4"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- '3.1.6' <<<"$output"
  grep -qF -- '3.1.4' <<<"$output"
  grep -qF -- 'and locked at' <<<"$output"
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
  # The cause is asserted, not only the status. Without it the root-missing
  # branch can be deleted and the pnpm-workspace.yaml check below it fires
  # instead, still exiting 2 while reporting a missing file inside a directory
  # that does not exist. That also keeps the negative assertion in the
  # unenterable-root test from going vacuous.
  run bash "$CHECK" --no-audit "$TMP/absent"
  [ "$status" -eq 2 ]
  grep -qF -- "the root itself is missing under $TMP/absent" <<<"$output"
}

# Both of these assert the CAUSE, not only the status. The readability checks
# below return 2 for an absent file as well, so a status-only assertion here
# survives deleting the -f check it is named for while the run reports a file
# that "cannot be read" for a file that is not there at all.
@test "a workspace root with no pnpm-workspace.yaml is an environment error" {
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- "pnpm-workspace.yaml is missing under $WS" <<<"$output"
}

@test "a workspace root with no lockfile is an environment error" {
  write_workspace "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- "pnpm-lock.yaml is missing under $WS" <<<"$output"
}

# A subject that EXISTS and cannot be read is the fail-open case, and it is not
# covered by the two tests above: -f passes, so the run goes on to read files it
# cannot open. Both readers below then fail in the same direction at once -- awk
# yields nothing, and the declared-block grep cannot fire because its own read
# fails and grep exit 2 reads as "no match" inside `if grep -q` -- so empty
# agrees with empty and the run prints the clean line over declared floors it
# never saw. Each arm gets its own fixture, because a single both-unreadable
# fixture would stay green if either -r check were deleted.
@test "an unreadable pnpm-workspace.yaml is refused rather than read as no floors" {
  [ "$(id -u)" -ne 0 ] || skip "chmod 000 is not a read barrier for root"
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.5"
  chmod 000 "$WS/pnpm-workspace.yaml"
  run bash "$CHECK" --no-audit "$WS"
  chmod 644 "$WS/pnpm-workspace.yaml"
  [ "$status" -eq 2 ]
  grep -qF -- "pnpm-workspace.yaml exists under $WS but cannot be read" <<<"$output"
}

@test "an unreadable pnpm-lock.yaml is refused rather than read as no floors" {
  [ "$(id -u)" -ne 0 ] || skip "chmod 000 is not a read barrier for root"
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.5"
  chmod 000 "$WS/pnpm-lock.yaml"
  run bash "$CHECK" --no-audit "$WS"
  chmod 644 "$WS/pnpm-lock.yaml"
  [ "$status" -eq 2 ]
  grep -qF -- "pnpm-lock.yaml exists under $WS but cannot be read" <<<"$output"
}

@test "two unreadable subjects do not agree with each other into a clean run" {
  [ "$(id -u)" -ne 0 ] || skip "chmod 000 is not a read barrier for root"
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.5"
  chmod 000 "$WS/pnpm-workspace.yaml" "$WS/pnpm-lock.yaml"
  run bash "$CHECK" --no-audit "$WS"
  chmod 644 "$WS/pnpm-workspace.yaml" "$WS/pnpm-lock.yaml"
  [ "$status" -eq 2 ]
  # The exact shape this fixture exists for: before the -r checks, this run
  # exited 0 on the clean line while the workspace declared a floor the lockfile
  # contradicts.
  # Written as the bad case plus an explicit return, not as a !-negation:
  # set -e exempts a !-inverted status, so a !-negated absence assertion off the
  # final line greens even when its bad case is true
  # (.claude/rules/bats-assertions.md).
  grep -qF -- "no overrides declared; no floors to check" <<<"$output" && return 1
  grep -qF -- "cannot be read" <<<"$output"
}

@test "an unknown flag is refused rather than silently treated as the root" {
  write_workspace
  write_lock
  run bash "$CHECK" --audit-everything "$WS"
  [ "$status" -eq 2 ]
  # The cause is asserted, not only the status, on the same standard the
  # root-missing test above states. Exit 2 alone cannot tell the unknown-flag
  # arm from the more-than-one-root guard beside it: delete either one and the
  # other answers with the same status for the wrong reason, so a status-only
  # assertion here survives both deletions and pins neither.
  grep -qF -- "unknown flag --audit-everything" <<<"$output"
}

@test "a second positional root is refused rather than silently replacing the first" {
  write_workspace
  write_lock
  run bash "$CHECK" --no-audit "$WS" "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- "more than one workspace root given" <<<"$output"
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

@test "a pnpm audit that could not run is reported as unread, never as clean" {
  # The failure this wording exists for is the reassuring one: an audit that
  # never happened printing the same line as a closure with nothing wrong.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf 'ERR_PNPM_AUDIT  registry unreachable\n' >&2
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "an error payload that parses as JSON is unread, not clean" {
  # An unreachable registry writes a well-formed object carrying `error` and no
  # `advisories`, so a gate that only asks whether stdout parses lets it
  # through and the empty advisory set reads as a clean scan.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":23,"message":"The operation was aborted due to timeout"}}\n'
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "a non-zero pnpm carrying a real report still reports its advisories" {
  # The regression pin for the fix above, and the case that makes the exit
  # status useless as a discriminator: `pnpm audit` exits non-zero precisely
  # when it finds something. A gate keyed on the status would silence exactly
  # the runs that matter.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{"1098765":{"id":1098765,"module_name":"fast-uri","severity":"high","title":"host confusion via a backslash authority introducer"}}}
JSON
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'ADVISORY (high' <<<"$output"
  grep -qF -- 'NOT audited' <<<"$output" && return 1
  true
}

@test "an entry naming none of the fields this reader reads is unread, not clean" {
  # A combined-shape regression pin, NOT a gate isolator: this entry is
  # missing severity and module_name together, so either term alone still
  # rejects it and no single-term deletion reds this test. The three
  # single-term isolators below do that job. This one stays because the
  # all-fields-renamed payload is the shape pnpm would actually produce if it
  # renamed its schema, and it is worth one test of its own. The zero metadata
  # keeps the cross-check from being what rejects it.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{"1098765":{"sev":"critical","mod":"fast-uri","title":"renamed entry fields"}},"metadata":{"vulnerabilities":{"high":0,"critical":0}}}
JSON
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "an advisories value that is not an object is unread, not clean" {
  # `to_entries` errors on a scalar and the filter's status was discarded, so
  # the empty result read as a clean scan.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '{"advisories":5}\n'
exit 0
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "a report whose own counts contradict an empty parse is unread, not clean" {
  # The shape a future pnpm produces by moving its findings out of `advisories`
  # while leaving the key behind as an empty stub. Every gate above passes it,
  # and only the report's own second statement of the same fact catches it.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{},"metadata":{"vulnerabilities":{"critical":1,"high":0,"low":0}}}
JSON
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "a report whose own counts agree with an empty parse is clean" {
  # The regression pin for the cross-check above: a genuine clean scan still
  # reports clean, and low-severity findings do not make it inconclusive.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{},"metadata":{"vulnerabilities":{"critical":0,"high":0,"low":3}}}
JSON
exit 0
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'no high or critical advisories' <<<"$output"
  grep -qF -- 'NOT audited' <<<"$output" && return 1
  true
}

@test "a count stated in a type this reader cannot read is unread, not clean" {
  # The cross-check is only worth having if it fails closed. A count pnpm
  # states as a string, or a `vulnerabilities` this reader cannot index at all,
  # is the same fact from here as a count above zero: the report said something
  # this reader did not read, so the clean line must not print.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{},"metadata":{"vulnerabilities":{"high":"3","critical":0}}}
JSON
exit 0
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "a vulnerabilities block that is not an object is unread, not clean" {
  # `jq` errors rather than returning a value here, and the status of that call
  # used to be discarded straight onto the clean arm.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{},"metadata":{"vulnerabilities":[{"high":3}]}}
JSON
exit 0
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "a report that states no count at all is unread, not clean" {
  # The cross-check is worth having only if the report itself states the zero.
  # Defaulting an absent count to 0 supplies the very answer being asked for,
  # so a payload that says nothing about high or critical advisories would buy
  # the clean line by saying nothing. `jq`'s `//` also replaces `false`, so it
  # is not only absence that would slip through.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '{"advisories":{}}\n'
exit 0
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "a count typed as a string beside an absent one is unread, not clean" {
  # Pins the cross-check failing CLOSED on a count it cannot read, which is
  # the contract. It does not isolate the `all(type == "number")` term itself:
  # with the term gone, `add` over a string and a null makes `jq` exit
  # non-zero, and that lands on the same not-audited arm. The isolator for the
  # term is the non-object-vulnerabilities fixture below.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{},"metadata":{"vulnerabilities":{"high":"0","critical":null}}}
JSON
exit 0
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "an advisory entry missing the title the line interpolates is unread, not clean" {
  # Isolates the `has("title")` half of the entry-shape gate. Without it the
  # entry passes and the advisory line prints a literal null where the title
  # should be.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{"1":{"severity":"high","module_name":"fast-uri"}},"metadata":{"vulnerabilities":{"high":0,"critical":0}}}
JSON
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'ADVISORY' <<<"$output" && return 1
  true
}

@test "a root that exists and cannot be entered is named, not reported missing" {
  # `cd` fails on a directory with no execute bit, and an unguarded command
  # substitution then assigns the empty string, so the error blames the root
  # for being absent and names no path at all.
  #
  # Asserting merely that the path appears in $output does NOT pin this: bash
  # prints its own `cd: ...: Permission denied` naming that same path, `run`
  # folds stderr into $output, and the assertion passes on the broken code.
  # Assert the message itself instead.
  local locked="$TMP/locked"
  mkdir -p "$locked"
  chmod 000 "$locked"
  run bash "$CHECK" --no-audit "$locked"
  chmod 755 "$locked"
  [ "$status" -eq 2 ]
  grep -qF -- "pnpm-workspace.yaml is missing under $locked" <<<"$output"
  grep -qF -- 'the root itself is missing under' <<<"$output" && return 1
  true
}

@test "an entry missing only severity is unread, not clean" {
  # Splits what one fixture used to cover as a pair. The old entry named its
  # fields sev and mod, so it was missing severity AND module_name and either
  # term alone still failed the gate: `has("severity")` could be deleted with
  # the suite green. An entry carrying module_name and title but no severity
  # would then pass, filter out of the extraction on a null severity, and let
  # the cross-check print the clean line over an advisory never read. The zero
  # metadata is what makes the entry-shape gate the only thing left.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{"1":{"module_name":"fast-uri","title":"no severity"}},"metadata":{"vulnerabilities":{"high":0,"critical":0}}}
JSON
exit 0
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "an entry missing only module_name is unread, not clean" {
  # The other half of the same pair. Without `has("module_name")` this entry
  # passes the gate, selects on its high severity, and prints an advisory line
  # naming a literal null module.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{"1":{"severity":"high","title":"no module name"}},"metadata":{"vulnerabilities":{"high":0,"critical":0}}}
JSON
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'ADVISORY' <<<"$output" && return 1
  true
}

@test "a payload carrying advisories AND an error is unread, not clean" {
  # Pins the `has("error") | not` half of the container gate, which nothing
  # else reaches: the error-only fixture carries no advisories key, so
  # has("advisories") already fails it there. A partial result reported beside
  # an error object is the only payload this term decides, and without it that
  # payload reads as a completed scan.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{},"error":{"code":23,"message":"partial"},"metadata":{"vulnerabilities":{"high":0,"critical":0}}}
JSON
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'NOT audited' <<<"$output"
  grep -qF -- 'no high or critical advisories' <<<"$output" && return 1
  true
}

@test "an unreadable audit does not swallow a floor that is not applied" {
  # The advisory arm has three exits and only the fall-through was driven by
  # any test, so either early return could be changed to `return 0` with the
  # whole suite green while the program reported success over a floor it had
  # just printed FLOOR NOT APPLIED for. This drives the container-gate exit.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.4"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":23,"message":"aborted"}}\n'
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output"
  grep -qF -- 'NOT audited' <<<"$output"
}

@test "an unreadable advisory shape does not swallow a floor that is not applied" {
  # The same contract on the entry-shape gate's own exit.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.4"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"advisories":{"1":{"sev":"critical","mod":"fast-uri"}}}
JSON
exit 1
STUB
  chmod +x "$TMP/bin/pnpm"
  PATH="$TMP/bin:$PATH" run bash "$CHECK" "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output"
  grep -qF -- 'shape this reader cannot read' <<<"$output"
}

@test "a comment carrying a colon is not read as an override" {
  # The comment skip in the block parser is load-bearing, not tidiness: a
  # retirement note is exactly where a colon shows up, and without the skip it
  # parses as a key whose value is the rest of the sentence, reporting a floor
  # that is not applied on a correct tree and failing the CI-gating arm.
  write_workspace "  # retired by hand: see the note above
  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri' <<<"$output"
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output" && return 1
  true
}

@test "a key containing a colon parses the same quoted and bare" {
  # A plain YAML key ends at a colon followed by whitespace, not at the first
  # colon. An alias spelling carries one inside the key, and the two files
  # quote differently -- the same asymmetry the quoting test above pins -- so
  # splitting on the first colon makes the quoted side parse the whole key and
  # the bare side parse a prefix. The run then reports the declared floor
  # absent AND invents an undeclared override, on a tree that agrees.
  write_workspace "  'foo@npm:bar': 1.2.3"
  write_lock "  foo@npm:bar: 1.2.3"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: foo@npm:bar at 1.2.3' <<<"$output"
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output" && return 1
  grep -qF -- 'UNDECLARED OVERRIDE' <<<"$output" && return 1
  true
}

@test "a declared overrides block yielding no entries is refused, not called clean" {
  # The discovery-stage failure: if the reader stops matching the shape pnpm
  # emits, both files parse to nothing, empty agrees with empty, and the gate
  # reports clean over a workspace carrying live floors. Every fixture test
  # here would stay green on its own hand-written shape.
  printf 'overrides:\n  # the map pnpm would write is not in a shape this reader knows\n' \
    > "$WS/pnpm-workspace.yaml"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'no entries' <<<"$output"
}

@test "a declared overrides block yielding no entries is refused on the LOCKFILE side too" {
  # Mirror of the test above, and it is not redundant with it: the guard has an
  # arm per file, and the workspace fixture alone leaves the lockfile arm free
  # to be turned into an unconditional continue with the suite green. The
  # lockfile is the side pnpm actually generates, so it is the likelier of the
  # two to change shape.
  write_workspace "  fast-uri: 3.1.6"
  printf 'overrides:\n  # the map pnpm would write is not in a shape this reader knows\n' \
    > "$WS/pnpm-lock.yaml"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'no entries' <<<"$output"
}

# THE STRICT RECOGNIZER. Every shape below used to be skipped silently, which
# dropped a declared floor out of the comparison and let the comparison agree
# with itself. Each now refuses at 2 and names the line. These fixtures are what
# make that a contract rather than an intention.
@test "an override line annotated with a YAML comment parses as its version alone" {
  # The phantom mismatch on a CORRECT tree, and the reason the reader is strict.
  # Annotating an override in the natural place used to fold the comment into
  # the pinned version, so the parity arm printed FLOOR NOT APPLIED and exited 1
  # over a workspace whose floors were all applied. That is the failure this
  # suite header names as the one that gets the gate switched off.
  write_workspace "  fast-uri: 3.1.6 # GHSA-7p8r-x3mc-p8w7"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at 3.1.6' <<<"$output"
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output" && return 1
  true
}

@test "a quoted key carrying an annotated version parses as its version alone" {
  write_workspace "  'cosmiconfig>js-yaml': 4.3.1  # GHSA-5p4m-2wfm-xmqj"
  write_lock "  cosmiconfig>js-yaml: 4.3.1"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: cosmiconfig>js-yaml at 4.3.1' <<<"$output"
}

@test "a quoted value carrying a hash keeps it, because the quotes protect it" {
  # Pins the quoted arm of the comment stripper. Without it the plain arm cuts
  # at the space-hash, leaving a value with an opening quote and no closing one,
  # which then refuses rather than reading a legal scalar.
  write_workspace "  fast-uri: '3.1.6 # not a comment'"
  write_lock "  fast-uri: '3.1.6 # not a comment'"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at 3.1.6 # not a comment' <<<"$output"
}

@test "a space before the key-terminating colon is not taken as part of the key" {
  write_workspace "  fast-uri : 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at 3.1.6' <<<"$output"
}

@test "a hash with no space before it stays part of the version, as YAML says" {
  write_workspace "  fast-uri: 3.1.6#notacomment"
  write_lock "  fast-uri: 3.1.6#notacomment"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at 3.1.6#notacomment' <<<"$output"
}

@test "a quoted version may carry whitespace, because the quotes make it unambiguous" {
  write_workspace "  fast-uri: '>=1.2.3 <2.0.0'"
  write_lock "  fast-uri: '>=1.2.3 <2.0.0'"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at >=1.2.3 <2.0.0' <<<"$output"
}

@test "a value opening with a YAML indicator is refused rather than read as a version" {
  # `>=1.2.3 <2.0.0` unquoted is not a plain scalar at all: `>` opens a folded
  # block scalar, and js-yaml errors on this input. Refusing it is reading YAML
  # correctly, not being conservative.
  write_workspace "  fast-uri: >=1.2.3 <2.0.0"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'is not readable as YAML' <<<"$output"
}

@test "a YAML alias as a version is refused rather than compared as a literal token" {
  write_workspace "  fast-uri: *alias"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'unidentified alias' <<<"$output"
}

# THE LINE BETWEEN STRICT AND PERMISSIVE. A plain scalar carrying whitespace is
# a legal multi-range semver that js-yaml writes UNQUOTED into the lockfile, so
# refusing it fails the gate on a correct tree and quoting the workspace side
# cannot repair it: the next resolve rewrites the lockfile value unquoted again.
@test "a multi-range semver with an or-operator is read, not refused" {
  write_workspace "  fast-uri: ^1.0.0 || ^2.0.0"
  write_lock "  fast-uri: ^1.0.0 || ^2.0.0"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at ^1.0.0 || ^2.0.0' <<<"$output"
}

@test "a hyphenated semver range is read, not refused" {
  write_workspace "  fast-uri: 1.2.3 - 2.0.0"
  write_lock "  fast-uri: 1.2.3 - 2.0.0"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at 1.2.3 - 2.0.0' <<<"$output"
}

@test "a range that differs between the two files is still reported, not passed" {
  # The arm above must not be a hole: accepting whitespace in a value cannot
  # become accepting any two values as equal.
  write_workspace "  fast-uri: ^1.0.0 || ^2.0.0"
  write_lock "  fast-uri: ^1.0.0"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output"
}

@test "a quoted value that never closes is refused rather than compared with its quote" {
  write_workspace "  fast-uri: 'unterminated"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'is not readable as YAML' <<<"$output"
}

@test "a quoted value with trailing junk after the closing quote is refused" {
  write_workspace "  fast-uri: 'ok' junk"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'is not readable as YAML' <<<"$output"
}

@test "a key declared twice is refused rather than resolved against the YAML rule" {
  # YAML resolves a duplicate mapping key to the LAST in document order; this
  # reader sorts by value and would keep the lexically greatest, so the two
  # disagree. Refusing is the reading consistent with the rest of this parser,
  # and YAML itself treats a duplicate key as an error.
  write_workspace "  fast-uri: 0.25.0" "  fast-uri: 0.24.0"
  write_lock "  fast-uri: 0.24.0"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  # YAML itself treats a duplicate mapping key as an error, and the reader
  # reports the parser's own diagnosis rather than inventing one.
  grep -qF -- 'duplicated mapping key' <<<"$output"
}

@test "an overrides header carrying a YAML comment is read, not treated as no block" {
  # Legal YAML: js-yaml loads this header and returns the override intact.
  # Skipping it read the file as declaring no overrides, which printed the clean
  # line at exit 0 over a floor the lockfile does not apply. Both sides matter:
  # the lockfile must declare NOTHING, or an undeclared-override row exits 1
  # anyway and the fixture pins nothing.
  printf 'overrides: # security floors\n  fast-uri: 3.1.6\n' > "$WS/pnpm-workspace.yaml"
  write_lock
  run bash "$CHECK" --no-audit "$WS"
  grep -qF -- 'no overrides declared; no floors to check' <<<"$output" && return 1
  [ "$status" -eq 1 ]
}

# NO SILENT DEGRADATION. The reader is the whole correctness argument, so its
# absence must be loud. A skip, a fallback to a weaker parser, or a clean exit
# here would reinstate exactly the failure this reader replaced: a verdict
# reported by something that could not read the file.
@test "a missing node is refused loudly, never degraded to a clean run" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.4"
  mkdir -p "$TMP/emptybin"
  # `/bin/bash` by absolute path: with PATH emptied, `bash` itself would not
  # resolve and the run would fail at 127 before reaching the reader check,
  # which passes the status assertion for the wrong reason.
  PATH="$TMP/emptybin" run /bin/bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'node is required' <<<"$output"
  grep -qF -- 'no overrides declared; no floors to check' <<<"$output" && return 1
  true
}

@test "a missing js-yaml is refused loudly and names how to install it" {
  # The script resolves js-yaml relative to its own location, so a copy placed
  # outside this repository has no workspace to find it in.
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.4"
  mkdir -p "$TMP/elsewhere"
  cp "$CHECK" "$TMP/elsewhere/check-cli-workspace-floors.sh"
  run bash "$TMP/elsewhere/check-cli-workspace-floors.sh" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'js-yaml was not found' <<<"$output"
  grep -qF -- 'pnpm -C .gaia/cli install' <<<"$output"
  grep -qF -- 'no overrides declared; no floors to check' <<<"$output" && return 1
  true
}

# THE LINE CONTRACT. The reader emits one key<TAB>value LINE per entry, so a
# newline inside either half breaks the downstream split exactly as a tab does.
@test "a multi-line block scalar value is refused, not split into two entries" {
  # js-yaml reads this correctly as ONE entry whose value spans two lines. Before
  # the guard covered newlines, sort and awk read it as two records and the run
  # printed `floor applied: 2.0.0 at ` alongside the real row, at exit 0: a
  # package the files do not contain, at an empty version.
  printf 'overrides:\n  fast-uri: |\n    3.1.6\n    2.0.0\n' > "$WS/pnpm-workspace.yaml"
  printf 'overrides:\n  fast-uri: |\n    3.1.6\n    2.0.0\n' > "$WS/pnpm-lock.yaml"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'newline inside an override key or value' <<<"$output"
  grep -qF -- '2.0.0 at' <<<"$output" && return 1
  true
}

# THE COMPARISON IS TEXTUAL, NOT NUMERIC. awk gives a field-derived value the
# strnum attribute, so a bare `!=` compares two versions as NUMBERS whenever both
# look like numbers. Every fixture in this suite used three-component semvers,
# which are not numeric, which is why this went unseen for the whole life of the
# check and outlived the reader that used to feed the comparator.
@test "a two-component floor bumped to 3.10 is not equal to 3.1" {
  # The reachable shape: bumping a two-component floor from .1 to .10 without
  # re-running pnpm dedupe. This reported `floor applied: fast-uri at 3.10` at
  # exit 0 over a genuine drift.
  write_workspace '  fast-uri: "3.10"'
  write_lock '  fast-uri: "3.1"'
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output"
  grep -qF -- 'floor applied:' <<<"$output" && return 1
  true
}

@test "a trailing-zero floor is not equal to its shorter twin" {
  write_workspace '  fast-uri: "4"'
  write_lock '  fast-uri: "4.0"'
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output"
}

@test "an exponent-shaped version is not equal to its expanded value" {
  write_workspace '  fast-uri: "1e2"'
  write_lock '  fast-uri: "100"'
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- 'FLOOR NOT APPLIED' <<<"$output"
}

@test "a NUL inside a version is refused, not collapsed into a matching one" {
  # The worst of the transport shapes and the least visible. js-yaml reads this
  # correctly; bash then discards the NUL in the command substitution that
  # captures the reader output, so `3.1<NUL>6` collapsed to `3.16` and compared
  # EQUAL to a lockfile pinning `3.16`. That is a false clean over two files
  # pinning different values, at exit 0, whose only trace was a bash warning the
  # script neither owns nor reads.
  printf 'overrides:\n  fast-uri: "3.1\\x006"\n' > "$WS/pnpm-workspace.yaml"
  printf 'overrides:\n  fast-uri: "3.16"\n' > "$WS/pnpm-lock.yaml"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'has a NUL, tab, carriage return or newline' <<<"$output"
  grep -qF -- 'floor applied' <<<"$output" && return 1
  true
}

@test "an override keyed to the empty string is refused, not dropped by the comparator" {
  # The reader emitted this as a real row and the comparator blank-line term
  # removed it from both lists before any comparison, so it was never compared
  # and the run reported clean. The retired reader refused the same file.
  printf 'overrides:\n  "": 3.1.6\n  fast-uri: 3.1.6\n' > "$WS/pnpm-workspace.yaml"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'maps an empty key, which names no package' <<<"$output"
}

@test "an empty key in the LOCKFILE is refused, not a suppressed undeclared override" {
  # The other side of the same hole: the UNDECLARED OVERRIDE row this check
  # exists to emit was suppressed at exit 0.
  write_workspace "  fast-uri: 3.1.6"
  printf 'overrides:\n  "": 9.9.9\n  fast-uri: 3.1.6\n' > "$WS/pnpm-lock.yaml"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'maps an empty key, which names no package' <<<"$output"
}

@test "an explicitly empty version is refused rather than reported as applied" {
  # `""` is a string, so the not-a-scalar guard passes it. Both sides empty
  # compared equal and printed `floor applied: fast-uri at ` over an override
  # that pins nothing. The retired reader refused this shape, so accepting it
  # would have been a silent narrowing of the refusal set.
  write_workspace '  fast-uri: ""'
  write_lock '  fast-uri: ""'
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'an empty version, which pins nothing' <<<"$output"
}

@test "a flow-mapping overrides block is read, not refused" {
  # A flow mapping is legal YAML and the previous hand-rolled reader could only
  # refuse it. Reading with the serializer means the spelling stops mattering.
  printf 'overrides: {fast-uri: 3.1.6}\n' > "$WS/pnpm-workspace.yaml"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at 3.1.6' <<<"$output"
}

@test "a refusal names its own cause and not the no-entries cause as well" {
  # The entry counter used to share a name with the plain-branch line length, so
  # a quoted-key refusal left the counter at zero and the END rule fired too,
  # telling the operator the map was empty or the reader had drifted, over a
  # file where neither was true.
  write_workspace "  'unterminated: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'is not readable as YAML' <<<"$output"
  grep -qF -- 'yielding no entries' <<<"$output" && return 1
  true
}

@test "a UTF-8 BOM does not turn a declared block into a clean run" {
  # This was a SILENT FALSE CLEAN that appeared only in CI. The BOM defeated
  # both the block-open match and the separate grep that used to guard it, and
  # the two disagreed by platform: macOS grep strips a BOM, GNU grep does not.
  # The LOCKFILE must declare nothing here. With an entry on the other side the
  # run reports an undeclared override and exits 1 either way, so the fixture
  # would pass with the BOM handling deleted and pin nothing. Both sides empty
  # is the only shape where losing the BOM produces the clean line.
  printf '\357\273\277overrides:\n  fast-uri: 3.1.6\n' > "$WS/pnpm-workspace.yaml"
  write_lock
  run bash "$CHECK" --no-audit "$WS"
  grep -qF -- 'no overrides declared; no floors to check' <<<"$output" && return 1
  [ "$status" -eq 1 ]
}

@test "CRLF line endings are read as the same map as LF endings" {
  printf 'overrides:\r\n  fast-uri: 3.1.6\r\n' > "$WS/pnpm-workspace.yaml"
  printf 'overrides:\r\n  fast-uri: 3.1.6\r\n' > "$WS/pnpm-lock.yaml"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: fast-uri at 3.1.6' <<<"$output"
}

@test "a column-zero comment does not close the block and drop every entry below it" {
  printf 'overrides:\n  fast-uri: 3.1.6\n# a comment at column zero\n  morgan: 1.11.0\n' \
    > "$WS/pnpm-workspace.yaml"
  write_lock "  fast-uri: 3.1.6" "  morgan: 1.11.0"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: morgan at 1.11.0' <<<"$output"
}

@test "a key with no version is refused rather than read as an empty pin" {
  write_workspace "  fast-uri:"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'maps fast-uri to a value that is not a scalar' <<<"$output"
}

@test "a YAML null key inside the block is refused rather than dropped" {
  write_workspace "  :"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'is not readable as YAML' <<<"$output"
}

@test "a quoted key with no closing quote is refused rather than skipped" {
  write_workspace "  'unterminated: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'is not readable as YAML' <<<"$output"
}

@test "a quoted key not followed by a colon is refused rather than guessed at" {
  # Without this arm the reader drops the missing colon and takes the rest of
  # the line as the version, which is a guess that happens to look right on the
  # simplest spelling and is a guess either way.
  write_workspace "  'fast-uri' 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'is not readable as YAML' <<<"$output"
}

@test "an entry line with no key-terminating colon is refused" {
  # A valid entry first, then a bare scalar. That is not a mapping pair and
  # js-yaml says so; the reader passes its reason through rather than inventing
  # one of its own.
  write_workspace "  fast-uri: 3.1.6" "  broken"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'is not readable as YAML' <<<"$output"
}

@test "an overrides block that is a bare scalar is refused as not a mapping" {
  write_workspace "  fast-uri"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'declares an overrides block that is not a mapping' <<<"$output"
}

@test "an overrides block that is a sequence is refused as not a mapping" {
  printf 'overrides:\n  - fast-uri\n' > "$WS/pnpm-workspace.yaml"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- 'declares an overrides block that is not a mapping' <<<"$output"
}

@test "the refusal names the file and the line number, not just the line" {
  # write_workspace emits minimumReleaseAge, a blank line, then `overrides:`,
  # so the first entry is line 4 and the broken one is line 5.
  write_workspace "  fast-uri: 3.1.6" "  broken"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 2 ]
  grep -qF -- "$WS/pnpm-workspace.yaml" <<<"$output"
  # The LINE, not merely some line reference. Asserting any parenthesised
  # line:column pair passes on a reader that names the wrong line, which is the
  # half this test is named for.
  grep -qE -- '\(5:[0-9]+\)' <<<"$output"
}

@test "a hand-edited map grouping its entries with a blank line keeps every entry" {
  # This is the real reason the block closes on a column-zero key rather than on
  # a blank line. A blank-line rule would stop at the gap and silently drop
  # every entry below it, reporting the lockfile keys as undeclared overrides.
  write_workspace "  fast-uri: 3.1.6" "" "  morgan: 1.11.0"
  write_lock "  fast-uri: 3.1.6" "  morgan: 1.11.0"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- 'floor applied: morgan at 1.11.0' <<<"$output"
  grep -qF -- 'UNDECLARED OVERRIDE' <<<"$output" && return 1
  true
}

@test "a lockfile with no overrides block emits no phantom row for the empty map" {
  # The blank-line term in the report awk. Each list reaches that pass through
  # printf on a shell variable, so an empty map arrives as ONE BLANK LINE, and
  # without that term this run prints a row naming a package that does not
  # exist while the exit status stays exactly the same.
  write_workspace "  fast-uri: 3.1.6"
  write_lock
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 1 ]
  grep -qF -- '(empty)' <<<"$output" && return 1
  grep -qF -- 'UNDECLARED OVERRIDE:  is locked at' <<<"$output" && return 1
  grep -qF -- 'fast-uri' <<<"$output"
}

@test "the workspace root line names the root it actually read" {
  write_workspace "  fast-uri: 3.1.6"
  write_lock "  fast-uri: 3.1.6"
  run bash "$CHECK" --no-audit "$WS"
  [ "$status" -eq 0 ]
  grep -qF -- "workspace root: $WS" <<<"$output"
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
  # Both phrases are unique to the honest-limits paragraph. A bare 'cap' is
  # not: it also matches the advisory-arm paragraph's "whose own cap it
  # competes for", so deleting the paragraph this test names would leave that
  # assertion passing and only the dedupe one red.
  grep -qiF -- 'becomes a cap' "$CHECK"
  grep -qiF -- 'dedupe' "$CHECK"
}

@test "the repository's own CLI workspace reports its floors, not merely exit 0" {
  # Asserting only the status lets a reader that has stopped parsing the live
  # files satisfy this test while reading nothing. The floors it names are the
  # ones this workspace declares, so the assertion fails exactly when the parser
  # stops recognizing them.
  run bash "$CHECK" --no-audit "$REPO_ROOT/.gaia/cli"
  [ "$status" -eq 0 ]
  local key seen=0 applied
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    seen=$((seen + 1))
    grep -qF -- "floor applied: $key" <<<"$output" || return 1
  done < <(awk '
    /^overrides:[[:space:]]*$/ { in_block = 1; next }
    in_block && /^[^[:space:]#]/ { in_block = 0 }
    in_block {
      sub(/^[[:space:]]+/, "", $0)
      if ($0 == "" || substr($0, 1, 1) == "#") next
      i = index($0, ":")
      if (i == 0) next
      k = substr($0, 1, i - 1)
      gsub(/^['"'"'"]|['"'"'"]$/, "", k)
      print k
    }
  ' "$REPO_ROOT/.gaia/cli/pnpm-workspace.yaml")
  # Without this the loop body running zero times greens the test on the status
  # alone, which is the assertion the comment above calls insufficient. Compared
  # against the script's own count rather than a literal, so the two parsers
  # have to agree and adding a floor does not red this on a cardinal.
  applied="$(grep -c '^floor applied: ' <<<"$output")"
  [ "$seen" -gt 0 ]
  [ "$seen" -eq "$applied" ]
}

@test "the default root is the CLI workspace, so CI needs no path argument" {
  cd "$REPO_ROOT"
  run bash "$CHECK" --no-audit
  [ "$status" -eq 0 ]
  grep -qF -- '.gaia/cli' <<<"$output"
}
