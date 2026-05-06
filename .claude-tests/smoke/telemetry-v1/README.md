# telemetry-v1 smoke

Release-gate harness for SPEC-001 telemetry-v1. Six deterministic tests covering the integration surface of the three-stream architecture (cloud / mentorship / analytics). Maps to UAT-046 (smoke test) plus the structural subset of UATs across the SPEC.

The walk-through narrative for the full 47-UAT surface (with maintainer-judgment-allowed steps such as the `Tell me more` Q&A loop in UAT-007) lives at `.specify/extensions/gaia/test/smoke-telemetry-v1.md`. Per `.claude/rules/_internal/smoke.md`, classification is by *shape*: this harness is fully procedural; the runbook accommodates judgment.

## Scope

What this smoke covers (all deterministic, all machine-checkable):

1. **Envelope correctness end-to-end.** Emit a `uat_pass` event with mentorship enabled. Assert exactly one mentorship line written with `_local` present, exactly one cloud line written with `_local` absent and no forbidden identity-bearing keys, and the universal envelope keys (`event_id`, `schema_version`, `timestamp`, `event_type`, `project_id`, `session_hash`, `agent_type`, `payload`) are all present. Re-emit the same content within the dedup window: still exactly one line in each stream (UAT-012 idempotency).
2. **Cloud-projection drift.** Construct a malformed envelope with an unexpected payload field. Invoke `projectToCloud` directly via a `tsx`-loaded ESM eval (no new `_internal-test-projection` subcommand needed — the eval keeps the test surface small). Assert exit `EXIT_CODES.CLOUD_PROJECTION_DRIFT (12)` and `code: cloud_projection_drift` in the result; assert no cloud file is created (UAT-014 fail-loud, UAT-013 forbidden-field absence).
3. **File modes.** After a mentorship + cloud emit, assert mentorship dir is `700`, mentorship JSONL is `600`, cloud dir is `755`, cloud JSONL is `644` (UAT-001, UAT-003 contract).
4. **Idempotent compute-profile.** Drop `articulation-fire.jsonl` into the scratch mentorship dir. Run `gaia telemetry compute-profile` twice. Assert `profile.md` exists with the `DO NOT EDIT` header (UAT-036), mode `600`, and the second-run content is identical to the first run modulo the embedded `Generated:` ISO timestamp (UAT-035 atomic-write contract).
5. **Analytics dry-run audit attestation.** Drop the same fixture, run `compute-profile` (which writes `report-YYYY-MM-DD.json` because `analytics.enabled === true`), then run `gaia mentorship analytics dry-run`. Assert each of the four audit booleans literally equals `true` and that `audit.fields_present` matches the actual top-level keys (UAT-043).
6. **Mentorship-disabled short-circuit.** With `mentorship.enabled === false`, emit a `uat_pass`. Assert the cloud line lands (cloud is independent of mentorship opt-in — UAT-009) and the mentorship file is absent. Run `compute-profile`. Assert exit 0, no `profile.md` written, no stdout output (UAT-026 chain-trigger contract relies on the silent-success short-circuit; UAT-040 disable contract).

What this smoke does NOT cover:

- Live `/gaia spec` → `/gaia plan` → UAT cycle. That is the maintainer-judgment walk-through in `.specify/extensions/gaia/test/smoke-telemetry-v1.md`.
- The `gaia-init` `AskUserQuestion` three-option opt-in flow (UAT-004 / 005 / 006 / 007). UAT-007 in particular ("does the Q&A loop feel natural?") is inherently maintainer-judgment.
- Statusline 🧭 rendering. The visual indicator is a maintainer-eyes assertion in the runbook.
- Pattern detection firing on real-usage data. Pattern detection ships wired-but-inert at v1.0.0 per the SPEC intent paragraph; the harness exercises the code paths against synthetic fixtures, not live accumulation.
- The `.claude/rules/mentorship-display.md` enforcement (UAT-047) — that is a Claude-behavior assertion, not a CLI assertion.

## Run

```bash
bash .claude-tests/smoke/telemetry-v1/run.sh
```

Exit `0` when every check passes; `1` on the first failure (continues all tests so the report shows the full surface). Pre-flight failure (missing `bin/gaia`, missing fixture, missing `node_modules/.bin/tsx`) exits `2`.

The harness creates one `mktemp -d` scratch tree per run with six per-test subdirectories underneath. Cleanup runs unconditionally on every exit path via a single `trap … EXIT`. The harness never reads or writes the user's real `~/.claude/projects/...` tree — every test runs under `HOME=<scratch>` with the scratch dir as `cwd` so `paths.ts` resolves storage roots into the scratch.

## How the scratch isolation works

The CLI binary `bin/gaia` is a thin bash shim that `exec`s the Node entrypoint. Node inherits the caller's `cwd` and `HOME` env. Two facts make the harness work:

1. **`process.cwd()` falls through.** `paths.ts::resolveRepoRoot` calls `git rev-parse --show-toplevel`. The scratch dir is not a git repo, so that throws and the `catch` falls back to `process.cwd()`. We invoke `bin/gaia` from a sub-shell with `cd "$WORK"` so `process.cwd()` is the scratch.
2. **`os.homedir()` reads the env.** Node's `os.homedir()` returns `$HOME` when set. We pass `HOME=<scratch>/home` to every CLI invocation. The mentorship subtree at `~/.claude/projects/<slug>/gaia/...` lands under the scratch home.

`pwd -P` is used to canonicalize both scratch paths because macOS exposes `/tmp` and `/var/folders/...` as symlinks to `/private/...` — `process.cwd()` returns the resolved variant, so the harness has to mirror it to look up the file the CLI writes.

Sub-shell `(cd "$WORK" && …)` is allowed per `.claude/rules/shell-cwd.md` (the rule's concern is hooks polluting shell state across calls, not test harnesses with scoped sub-shells).

## Files

- `run.sh` — the executable harness. `set -euo pipefail`, `pass()`/`fail()` helpers, exit-code summary. Six tests, 28 individual assertions at last count.
- `README.md` — this file.

## Companion fixture

The harness reads `gaia-cli/test-fixtures/profile/articulation-fire.jsonl` from the real repo (no copy — the file is checked in alongside the other Phase 5 fixtures). Phase 5's fixture catalog is at `gaia-cli/test-fixtures/profile/README.md`.

## Projection-drift test strategy

Test 2 invokes `projectToCloud` directly via a `tsx`-loaded ESM eval script written into the scratch dir. The script imports the projection module from the real repo (absolute path), constructs a malformed envelope with an unexpected payload field, calls `projectToCloud`, and exits `12` if the result is `{ ok: false }`. The harness asserts that exit code and the `code: cloud_projection_drift` token in stdout.

This avoids adding a new `_internal-test-projection` subcommand to maintain. The flag-parsed `gaia telemetry emit` surface only accepts known flags, so a "drift" payload cannot be constructed via the CLI surface alone — direct module invocation is the cleanest path.

## See also

- `.specify/extensions/gaia/test/smoke-telemetry-v1.md` — UAT runbook (47-UAT walk-through, maintainer-judgment-allowed).
- `.claude/rules/_internal/smoke.md` — convention this harness implements.
- `.gaia/local/plans/spec-001-telemetry-v1/task-smoke.md` — task brief.
- `.gaia/local/specs/SPEC-001.md` — source SPEC.
