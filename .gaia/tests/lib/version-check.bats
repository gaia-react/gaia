#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/version-check.sh`, the spec-kit
# version-pin check fired from the `before_specify` hook via
# commands/constitution-check.md.
#
# The script resolves the runtime spec-kit version two ways, in order:
#   1. a PATH-resident `specify` (a persistent install: `uv tool install`, pipx)
#   2. a uvx-mediated `specify`, pinned at the pin floor, which is the install
#      route GAIA documents and the only route that exists on most machines
#
# Each test builds a throwaway repo root holding just the extension manifest,
# and a stub bin dir prepended to PATH so `specify` / `uvx` presence and output
# are controlled per test. Stubs append their argv to $CALLS so a test can
# assert both that a resolver ran and the shape of its invocation.
#
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` and
# `grep -qF` for non-final assertions, `&& return 1` for absence checks.

setup() {
  SCRIPT=$(cd "$BATS_TEST_DIRNAME/../../../.specify/extensions/gaia/lib" && pwd)/version-check.sh
  ROOT="$BATS_TEST_TMPDIR/repo"
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  CACHE="$ROOT/.gaia/local/cache/version-check.lock"
  mkdir -p "$ROOT/.specify/extensions/gaia" "$BIN"
  : > "$CALLS"
  write_pin '">=0.8.5,<0.10.0"'
  PATH="$BIN:$PATH"
}

# write_pin <yaml-scalar>: write the extension manifest with the given pin.
write_pin() {
  cat > "$ROOT/.specify/extensions/gaia/extension.yml" <<EOF
requires:
  speckit_version: $1
EOF
}

# stub <name> <exit-code> [stdout-line]: put an argv-logging stub on PATH.
stub() {
  local name="$1" code="$2" out="${3:-}"
  cat > "$BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$CALLS"
[ -n "$out" ] && echo "$out"
exit $code
EOF
  chmod +x "$BIN/$name"
}

# stub_uvx_env <exit-code> <stdout-line>: a uvx stub that logs the network
# bounding env vars it was invoked with, so a test can assert the fetch is
# bounded rather than merely that uvx ran.
stub_uvx_env() {
  cat > "$BIN/uvx" <<EOF
#!/usr/bin/env bash
echo "uvx \$*" >> "$CALLS"
echo "env UV_HTTP_TIMEOUT=\${UV_HTTP_TIMEOUT:-unset} GIT_HTTP_LOW_SPEED_LIMIT=\${GIT_HTTP_LOW_SPEED_LIMIT:-unset} GIT_HTTP_LOW_SPEED_TIME=\${GIT_HTTP_LOW_SPEED_TIME:-unset}" >> "$CALLS"
[ -n "$2" ] && echo "$2"
exit $1
EOF
  chmod +x "$BIN/uvx"
}

# stub_uvx_no_dash_version <stdout-line>: a uvx whose `specify --version` yields
# nothing and whose `specify version` prints the version, the shape of a future
# spec-kit that exposes only the bare `version` subcommand.
stub_uvx_no_dash_version() {
  cat > "$BIN/uvx" <<EOF
#!/usr/bin/env bash
echo "uvx \$*" >> "$CALLS"
for a in "\$@"; do
  [ "\$a" = "--version" ] && exit 1
done
echo "$1"
EOF
  chmod +x "$BIN/uvx"
}

# no_stub <name>: guarantee <name> is absent from PATH for this test. A real
# `uvx` (or `specify`) may live further down a developer's PATH, so drop the
# stub and rebuild PATH from only the dirs that do not hold <name>.
no_stub() {
  rm -f "$BIN/$1"
  local clean="$BIN" dir
  while IFS= read -r dir; do
    if [ -z "$dir" ] || [ "$dir" = "$BIN" ] || [ -x "$dir/$1" ]; then
      continue
    fi
    clean="$clean:$dir"
  done <<EOF
$(printf '%s' "$PATH" | tr ':' '\n')
EOF
  PATH="$clean"
}

run_check() { run bash "$SCRIPT" "$ROOT"; }

@test "PATH-resident specify inside the pin passes and caches" {
  stub specify 0 "specify 0.9.1"
  no_stub uvx
  run_check
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  grep -qF '"installed":"0.9.1"' "$CACHE"
}

@test "PATH-resident specify below the pin floor is drift" {
  stub specify 0 "specify 0.8.4"
  run_check
  [ "$status" -eq 1 ]
  grep -qF "below pin floor" <<<"$output"
}

@test "PATH-resident specify at the exclusive ceiling is drift" {
  stub specify 0 "specify 0.10.0"
  run_check
  [ "$status" -eq 1 ]
  grep -qF "at or above exclusive pin ceiling" <<<"$output"
}

# The bug: the documented install route is uvx-mediated and never puts
# `specify` on PATH, so a correctly installed, in-pin spec-kit resolved as
# <unresolved> and the before_specify hook blocked /gaia-spec.
@test "no PATH specify: falls back to uvx and passes on an in-pin version" {
  no_stub specify
  stub uvx 0 "specify 0.8.5"
  run_check
  [ "$status" -eq 0 ]
  grep -qF "unresolved" <<<"$output" && return 1
  [ -f "$CACHE" ]
  grep -qF '"installed":"0.8.5"' "$CACHE"
}

@test "uvx fallback invokes specify from the pinned floor ref" {
  no_stub specify
  stub uvx 0 "specify 0.8.5"
  run_check
  [ "$status" -eq 0 ]
  grep -qF -- "--from git+https://github.com/github/spec-kit.git@v0.8.5 specify --version" "$CALLS"
}

# The uvx route is the only one that touches the network, and it sits inside the
# version check gating the before_specify hook. uv shells out to the system git
# for a `git+https://` ref, so uv's own HTTP timeout does not reach that fetch:
# both halves need bounding or a degraded network stalls /gaia-spec.
@test "uvx fallback bounds uv's HTTP reads and git's fetch" {
  no_stub specify
  stub_uvx_env 0 "specify 0.8.5"
  run_check
  [ "$status" -eq 0 ]
  # Every bound is a number, never `unset`. Asserted by shape, not by value, so
  # retuning a default does not break the test that guards the fetch is bounded.
  grep -qE "UV_HTTP_TIMEOUT=[0-9]+ GIT_HTTP_LOW_SPEED_LIMIT=[0-9]+ GIT_HTTP_LOW_SPEED_TIME=[0-9]+" "$CALLS"
}

@test "uvx fallback honors an operator-set UV_HTTP_TIMEOUT" {
  no_stub specify
  stub_uvx_env 0 "specify 0.8.5"
  UV_HTTP_TIMEOUT=90 run_check
  [ "$status" -eq 0 ]
  grep -qF "UV_HTTP_TIMEOUT=90" "$CALLS"
}

# Mirrors the PATH route's second chance: a future pinned spec-kit exposing only
# `specify version` must not resolve for a PATH-resident user while leaving the
# far more common uvx user at <unresolved> and blocked.
@test "uvx fallback second-chances a bare 'specify version'" {
  no_stub specify
  stub_uvx_no_dash_version "0.8.5"
  run_check
  [ "$status" -eq 0 ]
  grep -qF "Installed: <unresolved>" <<<"$output" && return 1
  grep -qF -- "specify version" "$CALLS"
  grep -qF '"installed":"0.8.5"' "$CACHE"
}

@test "uvx fallback still detects drift below the pin floor" {
  write_pin '">=0.9.0,<0.10.0"'
  no_stub specify
  stub uvx 0 "specify 0.8.5"
  run_check
  [ "$status" -eq 1 ]
  grep -qF "below pin floor" <<<"$output"
}

@test "PATH specify that yields no version falls through to uvx" {
  stub specify 0 ""
  stub uvx 0 "specify 0.8.5"
  run_check
  [ "$status" -eq 0 ]
  grep -qF "uvx" "$CALLS"
}

@test "uvx present but failing leaves the version unresolved" {
  no_stub specify
  stub uvx 1 ""
  run_check
  [ "$status" -eq 1 ]
  grep -qF "Installed: <unresolved>" <<<"$output"
}

@test "neither specify nor uvx leaves the version unresolved" {
  no_stub specify
  no_stub uvx
  run_check
  [ "$status" -eq 1 ]
  grep -qF "Installed: <unresolved>" <<<"$output"
}

@test "a PATH-resident specify is preferred and skips uvx entirely" {
  stub specify 0 "specify 0.9.1"
  stub uvx 0 "specify 0.8.5"
  run_check
  [ "$status" -eq 0 ]
  grep -qF "uvx" "$CALLS" && return 1
  grep -qF "specify --version" "$CALLS"
}

@test "a same-day cache for the same pin short-circuits every resolver" {
  mkdir -p "$(dirname "$CACHE")"
  today=$(date -u +%Y-%m-%d)
  printf '{"pinned":"%s","installed":"0.8.5","day":"%s","verified_at":"x"}\n' \
    '>=0.8.5,<0.10.0' "$today" > "$CACHE"
  stub specify 0 "specify 0.8.4"
  stub uvx 0 "specify 0.8.4"
  run_check
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}
