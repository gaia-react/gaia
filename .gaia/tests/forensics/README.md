# Forensics UAT harness

Maintainer-only fixture suite for the `/gaia-forensics` skill. Excluded from the release bundle via `.gaia/release-exclude` (category `.gaia/tests/`). Every test is hermetic; no network, no real Claude Code calls, no real `gh` invocations.

## Coverage

Each `*.bats` file's header comment names the UAT or TST ids it binds and what it asserts; this page does not restate them.

Every UAT from UAT-001 through UAT-013 has at least one binding assertion. UAT-001 and UAT-002 are covered through the fixture inputs and golden files (the init/update classification and schema tests exercise these end-to-end scenarios).

## Library

| File              | Purpose                                                                                                                                                                               |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/redact.sh`   | Shell implementation of the redaction algorithm from `forensics/redaction.md`. Source of truth for the regex set is the fragment; this file copies it with a pointer comment.         |
| `lib/classify.sh` | Shell implementation of the classifier table lookup from `forensics/taxonomy.md`.                                                                                                     |
| `lib/stub-gh.sh`  | argv-capture stub for `gh`. Placed on `$PATH` ahead of the real `gh`; writes each argv token to `$STUB_GH_CAPTURE_FILE`, one per line. Emits a synthetic issue URL on `issue create`. |

## Fixtures

| File                                  | Scenario                                                        |
| ------------------------------------- | --------------------------------------------------------------- |
| `fixtures/input-init-failure.txt`     | UAT-001 input; clean init failure (no secrets)                  |
| `fixtures/input-update-conflict.txt`  | UAT-002 input; update conflict with arg                         |
| `fixtures/input-with-secrets.txt`     | UAT-003 input; absolute paths + placeholder env-var entries     |
| `fixtures/golden-init-redacted.md`    | UAT-001 expected body (byte-identical post-redaction)           |
| `fixtures/golden-update-redacted.md`  | UAT-002 expected body                                           |
| `fixtures/golden-secrets-redacted.md` | UAT-003 expected body (paths stripped, env-var values scrubbed) |
| `fixtures/golden-other-class.md`      | UAT-011 expected body (`other` class, no taxonomy match)        |

Golden files are written once and treated as the contract. When the harness fails with an "actual vs golden mismatch", re-author the golden only if the runbook intentionally changed. Goldens are never auto-updated.

All fixture and golden files use placeholder secret strings (e.g. `<gha-token-placeholder>`) rather than real-shaped credential values. The redaction roundtrip tests construct synthetic token-shaped values at runtime so no real-shaped token appears in committed files.

## Running

```bash
bash .gaia/tests/forensics/run-all.sh
```

Individual test files:

```bash
bats .gaia/tests/forensics/01-redaction-roundtrip.bats
```

## Prerequisites

- `bats-core` on `$PATH`. Install via:
  - macOS: `brew install bats-core`
  - Debian/Ubuntu CI: `apt-get install -y bats`
  - Any platform: `npx -y bats@latest` (the run-all.sh entrypoint falls back to this)
- `git` on `$PATH` (used in write-surface and redaction tests for `git init`/`git rev-parse`)
- `python3` on `$PATH` (used for synthetic token generation in redaction tests; falls back to `printf` if absent)

The npm package is `bats`, not `bats-core`. The project is bats-core and the
Homebrew formula is bats-core, but no `bats-core` package is published to npm,
so that spelling resolves to an E404 rather than to a fallback.

## CI integration

Add this step to any workflow that gates on forensics skill correctness:

```yaml
- name: Run forensics UAT harness
  run: |
    apt-get install -y bats 2>/dev/null || true
    bash .gaia/tests/forensics/run-all.sh
```

The actual CI YAML edit lives in the wider release-CI plan.
