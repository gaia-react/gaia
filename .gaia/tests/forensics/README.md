# Forensics UAT harness

Maintainer-only fixture suite for the `/gaia forensics` skill. Excluded from the release bundle via `.gaia/release-exclude` (category `.gaia/tests/`). Every test is hermetic — no network, no real Claude Code calls, no real `gh` invocations.

## Coverage

| File | UATs covered |
|------|-------------|
| `01-redaction-roundtrip.bats` | UAT-003, UAT-010 |
| `02-classification-evidence.bats` | UAT-009, UAT-011 |
| `03-strict-schema.bats` | UAT-007, UAT-010 |
| `04-write-surface.bats` | UAT-008 |
| `05-gh-invocation-shape.bats` | UAT-012, UAT-006 |
| `06-gh-decline-saves-locally.bats` | UAT-005 |
| `07-gh-not-installed.bats` | UAT-013 |
| `08-user-config-no-gh.bats` | UAT-004 |
| `09-other-class-offers-gh.bats` | UAT-011 |

Every UAT from UAT-001 through UAT-013 has at least one binding assertion. UAT-001 and UAT-002 are covered through the fixture inputs and golden files (the init/update classification and schema tests exercise these end-to-end scenarios).

## What the harness covers

- **Redaction roundtrip** (`01`): feeds synthetic inputs through `lib/redact.sh` and asserts output matches golden files byte-for-byte. Runs the fragment's regex set in declared order. Tests path conversion (Rule A + Rule B), all token patterns (GitHub, Anthropic, OpenAI, GitLab, Slack, AWS, generic fallback), and env-var value scrub. Also verifies idempotency.
- **Classification + evidence** (`02`): verifies the classifier table lookup in `lib/classify.sh` for all eight taxonomy classes. Confirms evidence cite shape.
- **Strict schema** (`03`): asserts golden files carry the four required sections (`## Symptom`, `## Classification`, `## Capture`, `## Reproduction context`) in declared order, with no extra top-level headers. Verifies frontmatter field presence.
- **Write surface** (`04`): snapshots working-tree mtimes via a marker file, runs the runbook surrogate, asserts no writes outside `.gaia/local/forensics/` and `.gaia/local/telemetry/`. Also includes a negative test that confirms the detection logic catches violations.
- **gh invocation shape** (`05`): stubs `gh` via `lib/stub-gh.sh` (argv-capture), asserts captured argv contains `--repo gaia-react/gaia`, `--label gaia-forensics`, `--title "forensics: <class> — <one-line>"`, and `--body-file`. Also tests the failure path (UAT-006): a failing-gh stub exits non-zero; the local report is left in place and gh's stderr is surfaced verbatim.
- **Decline saves locally** (`06`): confirms the "No, save locally only" branch writes the report file and does not call `gh`.
- **gh not installed** (`07`): removes `gh` from `$PATH`, asserts exit-zero plus one-line note, report file present.
- **User-config no-gh** (`08`): diagnoses user-config signals (dirty tree, wrong Node, missing env var); confirms surrogate saves locally, prints remediation, never calls `gh`.
- **Other class offers gh** (`09`): confirms `other` class is treated as probable bug (offers gh, no remediation), evidence = "no taxonomy class matched", golden matches strict schema.

## Library

| File | Purpose |
|------|---------|
| `lib/redact.sh` | Shell implementation of the redaction algorithm from `forensics/redaction.md`. Source of truth for the regex set is the fragment; this file copies it with a pointer comment. |
| `lib/classify.sh` | Shell implementation of the classifier table lookup from `forensics/taxonomy.md`. |
| `lib/stub-gh.sh` | argv-capture stub for `gh`. Placed on `$PATH` ahead of the real `gh`; writes each argv token to `$STUB_GH_CAPTURE_FILE`, one per line. Emits a synthetic issue URL on `issue create`. |

## Fixtures

| File | Scenario |
|------|---------|
| `fixtures/input-init-failure.txt` | UAT-001 input — clean init failure (no secrets) |
| `fixtures/input-update-conflict.txt` | UAT-002 input — update conflict with arg |
| `fixtures/input-with-secrets.txt` | UAT-003 input — absolute paths + placeholder env-var entries |
| `fixtures/golden-init-redacted.md` | UAT-001 expected body (byte-identical post-redaction) |
| `fixtures/golden-update-redacted.md` | UAT-002 expected body |
| `fixtures/golden-secrets-redacted.md` | UAT-003 expected body (paths stripped, env-var values scrubbed) |
| `fixtures/golden-other-class.md` | UAT-011 expected body (`other` class, no taxonomy match) |

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
  - Any platform: `npx -y bats-core@latest` (the run-all.sh entrypoint falls back to this)
- `git` on `$PATH` (used in write-surface and redaction tests for `git init`/`git rev-parse`)
- `python3` on `$PATH` (used for synthetic token generation in redaction tests — falls back to `printf` if absent)

## CI integration

Add this step to any workflow that gates on forensics skill correctness:

```yaml
- name: Run forensics UAT harness
  run: |
    apt-get install -y bats 2>/dev/null || true
    bash .gaia/tests/forensics/run-all.sh
```

The actual CI YAML edit lives in the wider release-CI plan.
