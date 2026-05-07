---
type: concept
title: Telemetry
status: active
created: 2026-05-07
updated: 2026-05-07
tags: [concept, cli, telemetry, mentorship]
---

# Telemetry

GAIA's telemetry system captures structured events across the dev workflow to power mentorship feedback and aggregated analytics. It ships as a single self-contained bundled binary at `.gaia/cli/gaia` — invoked by hooks and slash-command emits.

## Three-stream architecture

Events flow into one of three independent streams:

| Stream | Location | Permissions | Purpose |
|---|---|---|---|
| **Mentorship** | `~/.claude/projects/<slug>/gaia/telemetry/mentorship/events-*.jsonl` | `700/600` | Full identity; in-session adaptation. Off-project, machine-local. |
| **Cloud projection** | `.gaia/local/telemetry/cloud/` | `755/644` | Strict whitelist + denylist sweep. No user paths, text, or identity. |
| **Analytics** | `.gaia/local/telemetry/analytics/` | `755/644` | Daily aggregate reports; auto-attested (audit-attest.ts throws on drift). |

Mentorship data stays off-project. Cloud + analytics live in `.gaia/local/telemetry/` (gitignored). The displayable aggregate is `profile.md`.

## CLI workspace

`.gaia/cli/` houses the CLI workspace. Maintainer source lives at `.gaia/cli/src/`; `pnpm bundle` (esbuild, ESM, ~630KB) emits a self-contained `.gaia/cli/gaia` binary with `#!/usr/bin/env node` shebang. Adopters receive only the bundled binary — source, tests, and fixtures are excluded from the release tarball. Subcommand router uses a static handler map (no switch; project's `no-switch` rule).

Top-level subcommands:
- `telemetry emit <event_type> [--field value …]` — universal emit; writes to mentorship + cloud streams based on config
- `telemetry compute-profile` — regenerates `profile.md` from mentorship events via three pattern detectors
- `mentorship enable|disable|purge|status` — opt-in lifecycle; state machine in `src/mentorship/config.ts`
- `mentorship analytics enable|disable|dry-run` — analytics stream opt-in
- `_internal-fetch-coaching` — reads `profile.md`, writes `.gaia/cache/coaching-active.txt` if active adaptations match; consumed by `/gaia spec` at session start

## Universal envelope

Every emit writes a `UniversalEnvelope` (Zod schema in `src/schemas/envelope.ts`): `event_id` (content-derived ULID), `event_type`, `install_id`, `project_id`, `timestamp`, plus event-specific payload fields. Cloud projection applies a strict field whitelist and a denylist sweep that exits 12 on drift — any new field that reaches the cloud without explicit allow is a build break.

## Storage paths

`src/storage/paths.ts` resolves `StorageRoots` from repo root + home dir:

- `cloudDir` = `.gaia/local/telemetry/cloud/` (mode 755)
- `analyticsDir` = `.gaia/local/telemetry/analytics/` (mode 755)
- `mentorshipDir` = `~/.claude/projects/<slug>/gaia/telemetry/mentorship/` (mode 700)
- `profilePath` = `~/.claude/projects/<slug>/gaia/profile.md`
- `installIdPath` = `~/.claude/projects/<slug>/gaia/install-id.txt`
- `projectIdPath` = `.gaia/local/.project-id`

`<slug>` = repo root path with `/` replaced by `-`.

## Mentorship opt-in

`gaia-init` Step 10 presents a verbatim privacy explainer and a three-option `AskUserQuestion`. Opt-in state lives in `~/.claude/projects/<slug>/gaia/telemetry/mentorship/config.json`. Mentorship is disabled by default; emits that target the mentorship stream short-circuit when `enabled === false`.

## Profile computation

`gaia telemetry compute-profile` runs three pattern detectors over mentorship events:

- **articulation-gap** — detects spec sessions where clarify-loop question counts spike
- **knowledge-gap** — detects recurring research-agent dispatch on the same topic cluster
- **intent-clarity-gap** — detects gate-2 revision cycles

Detectors are wired-but-inert at v1.0.0: production behavior requires N ≥ 10 events above threshold. Strength + fade helpers use `FLAKE_DOWNWEIGHT=0.25` to discount single-occurrence spikes. Output: `profile.md` with `DO-NOT-EDIT` header and atomic write.

## Emit wiring

| Hook / skill | Event emitted |
|---|---|
| `PostToolUse Task` hook (`telemetry-task-postuse.sh` → `gaia telemetry parse-stdin`) | `engineer_return`, `code_review_audit_finding` (TS trailer parser in `src/telemetry/parse-trailer.ts`) |
| `/gaia spec` Gate 2 | `time_to_resolved_spec` |
| `/gaia spec` abandoned-exit | `time_to_resolved_spec` (abandoned) |
| `/gaia plan` revision detection | `plan_revised` |
| `spec-close` Step 5 | chains `compute-profile` after pacing append |

Statusline shows a compass segment when mentorship is enabled (wired in `.gaia/statusline/gaia-statusline.sh`). Session-start clears `.gaia/cache/coaching-active.txt` so stale injections never persist.

## Release-gate harness

`.claude-tests/smoke/telemetry-v1/run.sh` — 6 tests, 28 deterministic assertions: envelope correctness + idempotency, cloud-projection drift exit 12, file modes, compute-profile idempotency + DO-NOT-EDIT header, analytics audit attestation, mentorship-disabled short-circuit.

## Pairs with

- [[GAIA Spec]] — emits time_to_resolved_spec; receives coaching injection via `_internal-fetch-coaching`
- [[GAIA Plan]] — emits plan_revised on slug collision
- [[Claude Hooks]] — PostToolUse Task hook backstops engineer-return and code-review-audit events
- [[Release Workflow]] — mentorship dirs + project identity excluded from adopter bundle via `.gaia/release-exclude`
