# UAT-write smoke

Structural smoke for the SPEC-003 `before_implement` Playwright UAT auto-write hook. Drives `.specify/extensions/gaia/lib/uat-write.sh` against a sandbox SPEC fixture (`SPEC-099`) and verifies the renderer's write/rewrite/delete branches, idempotency, fixme heuristic, cache mirror, and manifest declarations. Maps to UAT-001..UAT-008 of SPEC-003. Ported from the prior `.specify/extensions/gaia/test/smoke-uat-write.md` runbook per SPEC-005 §Resolutions Q4 (every step in that runbook is procedural-deterministic — release-gate-harness genre, not UAT-runbook genre).

## Scope

What this smoke covers:

- The renderer writes one Playwright spec per UAT under `.playwright/e2e/spec-099/`, each carrying the stable `UAT-NNN — SPEC-099` test name and the `@playwright/test` import line.
- Idempotency: re-running on an unchanged SPEC produces zero file diffs and byte-identical sha256 hashes.
- Selective rewrite: mutating one UAT's `then:` clause rewrites only that file; the other two stay byte-identical.
- Hard-delete: removing a UAT from the SPEC hard-deletes its rendered file (no `_archived/` directory).
- Manifest: `.specify/extensions/gaia/extension.yml` declares `speckit.gaia.uat-write` in `provides.commands[]` and registers it under `hooks.before_implement` with `optional: false`.
- Slash-command body: `.specify/extensions/gaia/commands/uat-write.md` documents the four-step SPEC resolution algorithm.
- Abstraction heuristic: a `then:` clause with no quoted UI surface and no URL/path fragment renders as `test.fixme()` with an abstraction-blocker comment; nothing is silently dropped.
- Cache mirror: `.gaia/local/cache/uat-write/SPEC-099.json` is byte-identical to the renderer's most recent stdout (modulo trailing newline).
- Red-state baseline: `pnpm pw .playwright/e2e/spec-099/` exits non-zero with assertion-style failures (skipped if `pnpm` is not on `PATH`).

What this smoke does NOT cover:

- Live `/speckit-implement` hook fire — that requires a real spec-kit invocation and is out of scope for the smoke layer (same caveat as `wiki-promote/run.sh`).
- The `EXECUTE_COMMAND: speckit.gaia.uat-write` directive emission on `/speckit-implement` — UI-driven, hand-verified.
- The full Playwright assertion-pass cycle once the implementer turns the harness green.
- The `AskUserQuestion` and explicit `$ARGUMENTS` branches of UAT-006 — UI-driven; only the documented algorithm is grep-checked.

## Run

```bash
bash .claude-tests/smoke/uat-write/run.sh
```

Exits `0` with `uat-write smoke: PASS (N/N checks)` on success, `1` with `uat-write smoke: FAIL (F/N checks failed)` on the first structural violation. Side effects (sandbox `SPEC-099.md`, rendered specs under `.playwright/e2e/spec-099/`, cache file under `.gaia/local/cache/uat-write/`) are cleaned up by an `EXIT` trap; pre-existing copies of those paths are restored.

## Files

- `run.sh` — the harness. Drives the renderer, asserts structural facts, cleans up.
- `fixture/SPEC-099.md` — the sandbox SPEC fixture (three concrete UATs, one per renderer branch). Copied to `.gaia/local/specs/SPEC-099.md` at run time, restored / removed on exit.
