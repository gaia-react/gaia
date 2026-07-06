---
type: concept
title: Telemetry
status: active
created: 2026-05-07
updated: 2026-07-04
tags: [concept, cli, telemetry, mentorship]
---

# Telemetry

GAIA's telemetry system captures structured events across the dev workflow to power mentorship feedback and aggregated analytics. Adopters receive a single self-contained bundled binary at `.gaia/cli/gaia`, invoked by hooks and slash-command emits.

## Three-stream architecture

Events flow into one of three independent streams:

| Stream               | Location                           | Permissions | Purpose                                                                   |
| -------------------- | ---------------------------------- | ----------- | ------------------------------------------------------------------------- |
| **Mentorship**       | machine-local, off-project         | `700/600`   | Full identity; in-session adaptation.                                     |
| **Cloud projection** | `.gaia/local/telemetry/cloud/`     | `755/644`   | Strict whitelist + denylist sweep. No user paths, text, or identity.      |
| **Analytics**        | `.gaia/local/telemetry/analytics/` | `755/644`   | Daily aggregate reports; auto-attested (audit-attest.ts throws on drift). |

Mentorship data stays off-project. Cloud + analytics live in `.gaia/local/telemetry/` (gitignored). The displayable aggregate is `profile.md`.

## Token ledger

A fourth, independent stream lives alongside the three above: `.gaia/local/telemetry/cost.jsonl`, the per-action token-cost ledger `.gaia/scripts/token-tally.sh` appends to at the end of each `/gaia-spec`, `/gaia-plan`, and KICKOFF execution run. It is resolved to the main checkout (not a linked worktree's own `.gaia/local/`), so a worktree-run execution's tally consolidates with the rest of the project's history. This stream is cost accounting, not mentorship or analytics; it carries no user text or identity, only token-bucket counts and timing. It is a versioned data contract, not just an internal log, see [[Cost Data Contract]] for the full record schema and [[Token Cost Readout]] for the pricing surfaces and hooks built on top of it.

## CLI workspace

`.gaia/cli/` houses the CLI workspace. Maintainer source lives at `.gaia/cli/src/`; `pnpm bundle` runs `bundle:adopter` then `bundle:maintainer` (esbuild, ESM). The adopter build emits a self-contained `.gaia/cli/gaia` binary (~1.1MB) with `#!/usr/bin/env node` shebang; the maintainer build emits a separate `.gaia/cli/gaia-maintainer` (from `src/index.maintainer.ts`) that adds the release namespace and is excluded from the adopter tarball. Adopters receive only the `gaia` binary; source, tests, and fixtures are excluded from the release tarball. Subcommand router uses a static handler map (no switch; project's `no-switch` rule).

Top-level subcommands:

- `telemetry emit <event_type> [--field value …]`: universal emit; writes to mentorship + cloud streams based on config
- `telemetry compute-profile`: regenerates `profile.md` from mentorship events via three pattern detectors
- `mentorship enable|disable|purge|status`: opt-in lifecycle; state machine in `src/mentorship/config.ts`
- `mentorship analytics enable|disable|dry-run`: analytics stream opt-in
- `_internal-fetch-coaching`: reads `profile.md`, writes `.gaia/local/cache/shared/coaching-active.txt` if active adaptations match; consumed by `/gaia-spec` at session start

## Universal envelope

Every emit writes an `Envelope` (Zod `EnvelopeSchema` in `src/schemas/envelope.ts`): `event_id` (content-derived ULID), `event_type`, `agent_type`, `project_id`, `session_hash`, `schema_version` (literal 1), `timestamp`, plus an event-specific `payload`. A `superRefine` cross-validates the payload against `event_type` for known mentorship types. Cloud projection applies a strict field whitelist and a denylist sweep that exits 12 on drift: any new field that reaches the cloud without explicit allow is a build break.

`MentorshipPayloadByType` (`src/schemas/mentorship-payloads.ts`) defines the eight canonical mentorship event types: `blocked_returned`, `code_review_audit_finding`, `needs_context_returned`, `plan_revised`, `spec_amended`, `time_to_resolved_spec`, `uat_fail`, `uat_pass`. The PostToolUse trailer parser produces a subset (`uat_pass`, `needs_context_returned`, `blocked_returned`, `code_review_audit_finding`); the rest are emitted by their respective slash-command hooks.

## Storage paths

`src/storage/paths.ts` resolves `StorageRoots` from repo root + home dir:

- `cloudDir` = `.gaia/local/telemetry/cloud/` (mode 755)
- `analyticsDir` = `.gaia/local/telemetry/analytics/` (mode 755)
- `projectIdPath` = `.gaia/local/.project-id`
- Mentorship + per-project Claude state resolve into machine-local paths off-project (mode 700/600 for mentorship, 644 for displayable aggregates).

## Mentorship opt-in

`/setup-gaia`'s Phase 2 presents a verbatim privacy explainer and a three-option `AskUserQuestion`, writing the decision to the machine-local `.gaia/local/mentorship.json`. Opt-in state is machine-local. Mentorship is disabled by default; emits that target the mentorship stream short-circuit when `enabled === false`.

`setup finalize` stamps `completed_at` without requiring a mentorship decision artifact. `/setup-gaia`'s Phase 2 surfaces the opt-in whenever `mentorship.json` is absent or `enabled` is `null`, so the decision is recorded once and re-surfaces if an earlier run was interrupted. `mentorship.json` is part of the worktree shared-state set, so a decision recorded in a linked worktree is visible from the main worktree root, and vice versa.

## Profile computation

`gaia telemetry compute-profile` runs three pattern detectors over mentorship events:

- **articulation-gap**: detects spec sessions where clarify-loop question counts spike
- **knowledge-gap**: detects recurring research-agent dispatch on the same topic cluster
- **intent-clarity-gap**: detects gate-2 revision cycles

Detectors are wired-but-inert at v1.0.0: production behavior requires N ≥ 10 events above threshold. Strength + fade helpers use `FLAKE_DOWNWEIGHT=0.25` to discount single-occurrence spikes. Output: `profile.md` with `DO-NOT-EDIT` header and atomic write.

## Emit wiring

| Hook / skill                                                                         | Event emitted                                                                                          |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `PostToolUse Task` hook (`telemetry-task-postuse.sh` → `gaia telemetry parse-stdin`) | `uat_pass`, `needs_context_returned`, `blocked_returned`, `code_review_audit_finding` (TS trailer parser in `src/telemetry/parse-trailer.ts`) |
| `/gaia-spec` Gate 2                                                                  | `time_to_resolved_spec`                                                                                |
| `/gaia-spec` abandoned-exit                                                          | `time_to_resolved_spec` (abandoned)                                                                    |
| `/gaia-plan` revision detection                                                      | `plan_revised`                                                                                         |
| `spec-close` Step 5                                                                  | chains `compute-profile` after pacing append                                                           |

Statusline shows a compass segment when mentorship is enabled (wired in `.gaia/statusline/gaia-statusline.sh`). Session-start clears `.gaia/local/cache/shared/coaching-active.txt` so stale injections never persist.

## Pairs with

- [[GAIA Spec]]: emits time_to_resolved_spec; receives coaching injection via `_internal-fetch-coaching`
- [[GAIA Plan]]: emits plan_revised on slug collision
- [[Claude Hooks]]: PostToolUse Task hook backstops engineer-return signals (uat-pass, needs-context, blocked-return) and code-review-audit-finding events
- [[Token Cost Readout]]: prices the token ledger's `by_model` field into a dollar estimate
- [[Cost Data Contract]]: the token ledger's full record schema
