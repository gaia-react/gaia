#!/usr/bin/env bash
# Helpers shared by the data-layer scenarios (19, 20). Sourced after lib.sh.
#
# API:
#   hash_frontend ROOT          - prints "<sha256>  <path>" for every file under
#                                 ROOT/frontend (generated directories pruned)
#                                 plus ROOT/pnpm-lock.yaml, sorted by path
#   hash_file PATH              - prints PATH's sha256
#   run_logged LABEL LOG CMD... - runs CMD with all output in LOG; on failure
#                                 prints LOG's tail, then fails and exits 1
#   stage_adopter_tree NAME     - builds a staged release tree in a fresh git repo
#                                 and sets STAGING, SCAFFOLD, WORK, GAIA, FRONTEND
#   gaia_json LABEL ARGS...     - runs the staged CLI from SCAFFOLD, prints stdout
#   run_pnpm_steps LOG_PREFIX DESCRIPTION STEP...
#                               - runs each `pnpm STEP` in SCAFFOLD with logging
#   assert_scaffold_refused LABEL LEAKED... -- GAIA_ARGS...
#                               - fails unless the CLI refuses, with stderr, and
#                                 none of the LEAKED paths exist afterwards
#   assert_frontend_unchanged LABEL BEFORE_FILE
#                               - fails if hash_frontend differs from BEFORE_FILE
#   json_get JSON EXPRESSION    - evaluates a JS expression over `parsed` (the
#                                 parsed JSON) and prints the result
#   assert_stories_collect FRONTEND WORK STORY...
#                               - runs the storybook project over each STORY
#                                 (frontend-relative) and fails unless every
#                                 one contributes at least one passing test

# GNU coreutils names it sha256sum; macOS ships shasum. An array, not a
# function, because xargs runs a command and cannot reach a shell function.
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_TOOL=(sha256sum)
else
  SHA256_TOOL=(shasum -a 256)
fi

hash_file() {
  "${SHA256_TOOL[@]}" "$1" | cut -d ' ' -f 1
}

# Pruned: what pnpm install, typegen, the build, and coverage write. None of
# them is a file the template ships or the init subcommand edits.
hash_frontend() {
  local root="$1"
  (
    cd "$root" || exit 1
    find frontend \
      \( -name node_modules -o -name build -o -name .react-router \
         -o -name coverage -o -name .cache \) -prune \
      -o -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 "${SHA256_TOOL[@]}"
    "${SHA256_TOOL[@]}" pnpm-lock.yaml
  )
}

run_logged() {
  local label="$1" log_file="$2"
  shift 2
  if ! "$@" > "$log_file" 2>&1; then
    log "$label failed; last 80 lines of its output:"
    tail -n 80 "$log_file" >&2
    fail "$label failed"
    exit 1
  fi
}

json_get() {
  JSON_INPUT="$1" node -e '
    const parsed = JSON.parse(process.env.JSON_INPUT);
    const value = eval(process.argv[1]);
    process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
  ' "$2"
}

# A story file the storybook project fails to collect still lets test:ci pass,
# and test:ci's reporter names no files, so existence is no evidence it ran.
assert_stories_collect() {
  local frontend="$1" work="$2"
  shift 2
  run_logged "storybook story count" "$work/story-count.log" \
    pnpm -C "$frontend" exec vitest --run --project storybook \
    --reporter=json --outputFile="$work/story-count.json" "$@"
  local story collected
  for story in "$@"; do
    collected="$(node -e '
      const report = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      const match = report.testResults.find((result) => result.name.endsWith(process.argv[2]));
      const passed = match ? match.assertionResults.filter((test) => test.status === "passed") : [];
      process.stdout.write(String(passed.length));
    ' "$work/story-count.json" "$story")"
    [ "$collected" -gt 0 ] \
      || { fail "storybook project collected no passing tests from $story"; exit 1; }
  done
}

stage_adopter_tree() {
  local name="$1"
  STAGING="$(mktemp -d -t "gaia-dist-$name-stage-XXXXXX")"
  SCAFFOLD="$(mktemp -d -t "gaia-dist-$name-scaffold-XXXXXX")"
  WORK="$(mktemp -d -t "gaia-dist-$name-work-XXXXXX")"
  trap 'rm -rf "$STAGING" "$SCAFFOLD" "$WORK"' EXIT
  capture_cli_stderr "$WORK/cli-stderr.txt"

  "$HERE/lib/build-staging.sh" "$STAGING" > "$WORK/build-staging.log" 2>&1 \
    || { tail -n 40 "$WORK/build-staging.log" >&2; fail "build-staging failed"; exit 1; }
  rsync -a "$STAGING"/ "$SCAFFOLD"/
  # The scaffolders resolve their target through `git rev-parse`.
  git -C "$SCAFFOLD" init -q

  GAIA="$SCAFFOLD/.gaia/cli/gaia"
  # shellcheck disable=SC2034 # read by the scenario that sources this file
  FRONTEND="$SCAFFOLD/frontend"
  export GAIA_TELEMETRY_PING_DISABLE=1
}

gaia_json() {
  local label="$1"; shift
  (cd "$SCAFFOLD" && run_cli "$GAIA" "$@") \
    || fail_with_stderr "gaia $* exited non-zero (step: $label)"
}

# The description, when given, qualifies each step's log line and failure label.
run_pnpm_steps() {
  local log_prefix="$1" description="$2" step where
  shift 2
  where="${description:+ ($description)}"
  for step in "$@"; do
    log "pnpm $step$where"
    run_logged "pnpm $step$where" "$WORK/$log_prefix$step.log" pnpm -C "$SCAFFOLD" "$step"
  done
}

assert_scaffold_refused() {
  local label="$1" leaked
  local -a leaked_paths=()
  shift
  while [ "$1" != "--" ]; do
    leaked_paths+=("$1")
    shift
  done
  shift
  if (cd "$SCAFFOLD" && "$GAIA" "$@") > /dev/null 2> "$WORK/refusal-stderr.txt"; then
    fail "$label exited 0; it must be refused"
    exit 1
  fi
  [ -s "$WORK/refusal-stderr.txt" ] \
    || { fail "$label was refused with no stderr"; exit 1; }
  for leaked in "${leaked_paths[@]}"; do
    if [ -e "$leaked" ]; then
      fail "refused $label still wrote ${leaked#"$SCAFFOLD"/}"
      exit 1
    fi
  done
}

assert_frontend_unchanged() {
  local label="$1" before_file="$2"
  hash_frontend "$SCAFFOLD" > "$WORK/after-check.sha256"
  if ! diff "$before_file" "$WORK/after-check.sha256" >&2; then
    fail "$label changed a file under frontend/ or pnpm-lock.yaml"
    exit 1
  fi
}
