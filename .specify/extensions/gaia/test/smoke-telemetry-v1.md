# SPEC-001 telemetry-v1 — UAT runbook

Walk-through narrative covering every one of the SPEC's 47 UATs. Maintainer-judgment-allowed throughout (the `Tell me more` Q&A loop in UAT-007 is the obvious example — assertions like "does the explainer copy read as intended?" cannot land in a deterministic harness). This is the document the maintainer reads during SPEC verification; the procedural-deterministic subset is the release-gate harness at `.claude-tests/smoke/telemetry-v1/run.sh`.

The two artifacts are siblings, not duplicates. Per `.claude/rules/_internal/smoke.md`, classification is by *shape*: this runbook accommodates judgment; the harness is fully procedural. Both ship with the SPEC.

## How to use this runbook

Walk it once start-to-finish during SPEC verification. Each cluster has a setup, an action, and an assertion. Where a step is mechanically deterministic and could equally land in a harness, the brief calls that out and points at the specific harness test that covers it — run that subset first via `bash .claude-tests/smoke/telemetry-v1/run.sh` to fast-fail if the regression is structural rather than experiential.

Pattern-detection clusters explicitly note "wired-but-inert; assertion is against synthetic fixture, not live data" — at v1.0.0 internal-testing scale, real-usage events have not accumulated past the 10-event sample threshold. UAT-029/030/031 verify the *code paths* against the Phase 5 fixtures at `.gaia/cli/test-fixtures/profile/*.jsonl`; production behavior is wired-but-inert by design.

## Prerequisites

- The implementation has landed (Phases 1–5 of `.gaia/local/plans/spec-001-telemetry-v1/`).
- `pnpm install` has run so `node_modules/.bin/tsx` is on disk.
- `.gaia/cli/gaia` is executable.
- The harness has passed at least once locally: `bash .claude-tests/smoke/telemetry-v1/run.sh` exits 0.
- A scratch dir for any per-step manual experiments: `WORK=$(mktemp -d)` — clean up at the end.

---

## Cluster 1 — Storage scaffolding (UATs 1, 2, 3)

**Setup.** Fresh repo with `gaia-init` not yet run, mentorship choice unset.

**Action.** Run `.gaia/cli/gaia telemetry emit pr_opened --pr-number 1` (any cloud-only event will do).

**Expected.**

- **UAT-001.** Cloud dir created at `.gaia/local/telemetry/cloud/` with mode 755. Mentorship dir is NOT created (mentorship is not yet enabled). If mentorship were enabled and the parent Claude project slug directory under `~/.claude/projects/<slug>/gaia/` did not yet exist, it would be created with mode 700 first, then the `telemetry/mentorship/` subdir, also 700. Verify by enabling mentorship in a scratch repo and re-running an emit.
- **UAT-002.** On the first mentorship event after enabling, `~/.claude/projects/<slug>/gaia/install-id.txt` is generated as a single-line ULID with mode 600; `.gaia/local/.project-id` is generated as a single-line UUID derived from `sha256(repo_root_path)` with mode 644.
- **UAT-003.** The mentorship JSONL line is at `~/.claude/projects/<slug>/gaia/telemetry/mentorship/events-YYYY-MM-DD.jsonl` with mode 600; the parent dir is mode 700; the line is valid NDJSON with the universal envelope including the `_local` namespace.

**Harness fast-path.** Tests 1 and 3 cover envelope shape and the file-mode contract end-to-end.

---

## Cluster 2 — Opt-in flow at gaia-init (UATs 4, 5, 6, 7)

**Setup.** Fresh repo, `gaia-init` not yet run.

**Action.** Run `/gaia-init`. Step through the mentorship opt-in checkpoint.

**Expected.**

- **UAT-004.** An `AskUserQuestion` is presented with exactly three options in this order — "Not now (you can enable later if you like)" (Recommended), "Yes, enable mentorship + anonymous analytics", "Tell me more before I decide" — preceded by the privacy explainer copy from the design note.
- **UAT-005.** Selecting "Not now" writes `mentorship.enabled = false` and `mentorship.analytics.enabled = false` to `.gaia/local/mentorship.json`; init proceeds; no telemetry directories under `~/.claude/projects/<slug>/gaia/` are created. Verify with `cat .gaia/local/mentorship.json` and `ls ~/.claude/projects/<slug>/gaia 2>&1` (expect "No such file or directory").
- **UAT-006.** Selecting "Yes, enable mentorship + anonymous analytics" writes both `mentorship.enabled = true` AND `mentorship.analytics.enabled = true` in a single decision; init proceeds; the mentorship directory tree is provisioned with chmod 700/600. Verify with `stat -f '%Lp' ~/.claude/projects/<slug>/gaia/telemetry/mentorship` (expect 700).
- **UAT-007.** Selecting "Tell me more before I decide" drops to a free-form Q&A loop where Claude answers questions about mentorship; on user signal of completion, the same structured three-option `AskUserQuestion` is re-presented; init does not proceed until either "Not now" or "Yes, enable" is selected. **Maintainer judgment.** Read three or four exchanges and judge: does the answer feel grounded? Does Claude refuse to claim things the SPEC does not promise (e.g., upload to PostHog, encryption, or the `--migrate` command)? Does the loop close gracefully on a vague "ok, continue" or does it require an explicit verbal cue?

**Harness fast-path.** None — UAT-007 is inherently maintainer-judgment; UATs 4–6 require live `AskUserQuestion` rendering, which the harness does not invoke.

---

## Cluster 3 — CLI emit (UATs 8, 9, 10, 11, 12)

**Setup.** A repo with mentorship enabled, an open SPEC `SPEC-014` with `UAT-007`.

**Action.** Run `.gaia/cli/gaia telemetry emit uat_pass --uat-id UAT-007 --spec-id SPEC-014 --task-id TASK-093 --attempts 1 --area-tags visual,react,form`.

**Expected.**

- **UAT-008.** Exactly one NDJSON line lands in today's mentorship events file with the full universal envelope plus `_local` namespace, and exactly one NDJSON line lands in today's cloud events file with `_local` absent and no forbidden field present; CLI exits 0 silently (no stdout writes on the happy path).
- **UAT-009.** Disable mentorship (`.gaia/cli/gaia mentorship disable --yes`) and re-run the same emit. Zero lines are written to mentorship or analytics files; one line is written to the cloud stream (cloud is independent of mentorship opt-in); CLI exits 0 silently.
- **UAT-010.** Run `.gaia/cli/gaia telemetry emit unknown_event_type --uat-id whatever`. The CLI exits non-zero with a structured error to stderr naming the unknown event type; no lines are written to any stream. Expected exit 10 (`UNKNOWN_EVENT_TYPE`).
- **UAT-011.** Run `.gaia/cli/gaia telemetry emit uat_pass --uat-id UAT-007` (missing required `spec-id`, `task-id`, `attempts`, `area-tags`). The Zod schema validator rejects the payload; the CLI exits non-zero (11, `PAYLOAD_VALIDATION_FAILED`); no lines are written; stderr names the missing fields.
- **UAT-012.** Run the original UAT-008 emit twice in succession. Exactly one NDJSON line exists in the mentorship file; the cloud file likewise contains exactly one line; the second emit detects the existing `event_id` and exits 0 without writing.

**Harness fast-path.** Test 1 covers UAT-008 and UAT-012; Test 6 covers UAT-009. UAT-010 and UAT-011 are deterministic but the harness focuses on the green path; verify manually here.

---

## Cluster 4 — Structural projection (UATs 13, 14, 15)

**Setup.** Cloud-stream files have been written across multiple events.

**Action.** Read any line from `.gaia/local/telemetry/cloud/*.jsonl`.

**Expected.**

- **UAT-013.** The line contains no `_local` key; contains none of the forbidden fields per `cloud-telemetry-scope` (`developer_id`, `email`, `username`, GitHub username, machine ID, hostname, IP); contains the five required cloud tags (`project_id`, `event_type`, `agent_type`, `session_hash`, `timestamp`).
- **UAT-014.** Construct an event payload with an unexpected field not declared in the cloud projection schema. The CLI fails loud with a non-zero exit (12, `CLOUD_PROJECTION_DRIFT`) and writes nothing to either stream; stderr names the unexpected field. (Strict-by-default; drift bugs surface immediately. May relax to silent-strip in v1.x after install-base hardening.)
- **UAT-015.** Parse any line in any stream. Assert `schema_version === 1`; `event_id` matches the ULID alphabet `[0-9A-HJKMNP-TV-Z]{26}`; `timestamp` is ISO-8601 UTC with millisecond precision (`/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/`); `agent_type` is one of `PO`, `Senior`, `Junior`, `Lead`, `Reviewer`, `Curator`, `Steward`, `Custodian`, or `human`.

**Harness fast-path.** Test 1 covers UAT-013 and UAT-015 (envelope keys + forbidden-field absence); Test 2 covers UAT-014 (drift fails loud, exit 12).

---

## Cluster 5 — Mentorship event catalog (UATs 16, 17, 18, 19, 20, 21, 22, 23)

**Setup.** Mentorship enabled. Walk through eight contrived scenarios — each emits one of the eight mentorship event types via the CLI and inspects the resulting NDJSON line.

**Expected.**

- **UAT-016.** A `uat_pass` event records `payload.uat_id`, `spec_id`, `task_id`, `attempts: 1`, `area_tags`. Run `.gaia/cli/gaia telemetry emit uat_pass --uat-id UAT-300 --spec-id SPEC-300 --task-id TASK-300 --attempts 1 --area-tags visual` and grep the mentorship line.
- **UAT-017.** A `uat_fail` event with `failure_class: exception` distinguishes from `assertion`, `timeout`, `setup`, or `flake_suspected`. `.gaia/cli/gaia telemetry emit uat_fail --uat-id UAT-300 --spec-id SPEC-300 --task-id TASK-300 --attempts 1 --area-tags visual --failure-class exception`.
- **UAT-018.** A `needs_context_returned` event with `context_request_class: unclear_acceptance_criteria`. `.gaia/cli/gaia telemetry emit needs_context_returned --spec-id SPEC-300 --task-id TASK-300 --area-tags visual --agent-type Senior --context-request-class unclear_acceptance_criteria`.
- **UAT-019.** A `blocked_returned` event with `classification: intent`. `.gaia/cli/gaia telemetry emit blocked_returned --spec-id SPEC-300 --task-id TASK-300 --area-tags visual --agent-type Senior --classification intent`. (Mentorship pattern detection weights `intent` and `spec` events; `code` is dropped from mentorship's pattern detection.)
- **UAT-020.** A `spec_amended` event with `fields_changed: ["uats"]`, `amendment_reason` quoted from the reopen rationale, `time_since_close_seconds ≈ 14400`. `.gaia/cli/gaia telemetry emit spec_amended --spec-id SPEC-300 --fields-changed uats --amendment-reason "missed empty-state UAT" --time-since-close-seconds 14400`.
- **UAT-021.** A `plan_revised` event with `revision_class: scope_change`, `items_added: 2`, `items_removed: 0`. `.gaia/cli/gaia telemetry emit plan_revised --spec-id SPEC-300 --plan-id PLAN-300 --revision-class scope_change --items-added 2 --items-removed 0`.
- **UAT-022.** A `time_to_resolved_spec` event with `question_count: 12`, `duration_seconds: 1850`, `abandoned: false`, `area_tags`. `.gaia/cli/gaia telemetry emit time_to_resolved_spec --spec-id SPEC-300 --area-tags visual --question-count 12 --duration-seconds 1850`.
- **UAT-023.** A `code_review_audit_finding` event with `finding_class: type_hole`, `severity: warning`, `pr_number`, `area_tags`. `.gaia/cli/gaia telemetry emit code_review_audit_finding --spec-id SPEC-300 --area-tags react --pr-number 88 --finding-class type_hole --severity warning --auditor-type code-review-audit`.

**Harness fast-path.** None — the harness exercises only `uat_pass`. The other seven event types are validated by the schemas' unit tests (`.gaia/cli/src/schemas/__tests__/`); this cluster is the integration sanity check.

---

## Cluster 6 — Soft + hard hook backstop (UATs 24, 25, 26)

**Setup.** Mentorship enabled. Two scratch SPECs to stress the engineer-return hook and the spec_close → compute-profile chain.

**Expected.**

- **UAT-024.** A Senior agent finishes a task but fails to inline-emit `uat_pass` despite verification succeeding. The PostToolUse `engineer-return` hook reads the agent's structured return payload, infers the missing event(s), and emits via `.gaia/cli/gaia telemetry emit`. The stream contains exactly one `uat_pass` event for the work item. Verify by inspecting the hook script (`.claude/hooks/`) and the resulting JSONL.
- **UAT-025.** A Senior agent inline-emits `uat_pass` AND the engineer-return hook subsequently attempts the same emit. Both invocations complete; idempotency by content-derived `event_id` ULID ensures exactly one event lands; the hook's second invocation detects the duplicate and exits without writing.
- **UAT-026.** A `/gaia spec` session canonically saves a SPEC. The save completes; a `spec_close` chain fires `.gaia/cli/gaia telemetry compute-profile`, regenerating `profile.md` with the 30-day rolling window applied. Verify the `compute-profile` invocation lands in the slash-command's `## Step 5 — Telemetry` block.

**Harness fast-path.** Test 6 covers the silent-success short-circuit that UAT-026's chain trigger depends on (compute-profile must exit 0 quietly when mentorship is disabled, otherwise spec_close would fail loudly on every disabled repo). UAT-024 / UAT-025 require a live agent dispatch; assert by reading the hook script + grepping for the inline-emit call site.

---

## Cluster 7 — Slash-command emits (UATs 27, 28)

**Setup.** Live `/gaia spec` and `/gaia plan` sessions.

**Expected.**

- **UAT-027.** Run `/gaia spec` end-to-end. When Gate-2 confirmation completes and the canonical save lands at `.gaia/local/specs/SPEC-NNN.md`, a `time_to_resolved_spec` mentorship event emits with the session's question count and elapsed time. Verify by grepping today's mentorship JSONL.
- **UAT-028.** Run `/gaia plan` against an existing SPEC. Mid-flow, request a revision (e.g. ask the planner to add two more dispatch artifacts). When the planner re-emits dispatch artifacts, a `plan_revised` mentorship event emits with the appropriate `revision_class` (`scope_change` for the example above; `sequencing_change` / `dispatch_artifact_refinement` / `bug_fix_added` for other shapes).

**Harness fast-path.** None — these require a live slash-command session.

---

## Cluster 8 — Pattern detection (UATs 29, 30, 31, 32) — fixture-driven

**Setup.** Wired-but-inert at v1.0.0; assertion is against synthetic fixture, not live data. Use the fixtures at `.gaia/cli/test-fixtures/profile/`.

**Expected.**

- **UAT-029.** Drop `below-threshold.jsonl` (10 events total, 4 `needs_context_returned` for `visual`) into the scratch mentorship dir as today's events file. Run `compute-profile`. No pattern fires for `visual`; `profile.md` records the area as "below sample threshold (N=4, min 10)" with no active adaptation injected.
- **UAT-030.** Drop `articulation-fire.jsonl` (50 events, 30 `needs_context_returned` for `visual`, rate 0.60). Run `compute-profile`. The articulation-gap pattern fires with strength ≥ threshold; `profile.md` lists `articulation_gap` under "Active patterns" with strength value, sample size, and area scope; the linked adaptation `po_socratic_depth_increased` is written under "Active adaptations".
- **UAT-031.** Drop `articulation-fade.jsonl` (two-segment fixture: rate 0.40 prior weeks, ~0.18 last week). Run `compute-profile`. The adaptation's strength scales down on the sliding-fade curve; effective strength falls below threshold; the adaptation moves to `## Faded adaptations` and ceases injection.
- **UAT-032.** Drop `flake-downweight.jsonl` (48 events, 16 `flake_suspected` failures). Run `compute-profile`. The flake-suspected events are downweighted by factor 0.25 relative to assertion/exception failures (effective failure count: `4 + 4 + (16 * 0.25) = 12`, not 24).

**Harness fast-path.** Test 4 drops `articulation-fire.jsonl` end-to-end and asserts `profile.md` writes correctly with the DO NOT EDIT header. The detector aggregations themselves are unit-tested at `.gaia/cli/src/profile/__tests__/`.

---

## Cluster 9 — Adaptation injection (UATs 33, 34) — fixture-driven

**Setup.** Use the same `articulation-fire.jsonl` from Cluster 8 to populate `profile.md` with an active adaptation.

**Expected.**

- **UAT-033.** With `profile.md` listing `po_socratic_depth_increased` as active, begin a `/gaia spec` session. The system prompt for the spec wrapper agent includes a `## Profile-driven coaching` section containing the adaptation text. The user-facing UX changes are observable: deeper Socratic depth on success criteria for the relevant area. **Maintainer judgment.** Walk a spec session and judge: does the wrapper actually apply the deeper depth? Does it stop applying it when you switch to a different area tag?
- **UAT-034.** Wipe `profile.md` (or use a scratch repo with no fixture). Begin any agent dispatch. No `## Profile-driven coaching` section is added to the system prompt; the prompt is byte-identical to the non-mentorship path. Verify by rendering the system prompt with a no-active-adaptation state vs. the non-mentorship state and diffing.

**Harness fast-path.** None — these require live agent dispatch and prompt comparison.

---

## Cluster 10 — profile.md (UATs 35, 36)

**Setup.** Mentorship enabled, fixture in place.

**Expected.**

- **UAT-035.** In two terminals, close two `/gaia spec` SPECs within 100ms of each other. Both `spec_close` chains fire `compute-profile` concurrently. `profile.md` is written atomically (write-temp-and-rename); the final file is well-formed; no half-written state observable; both sessions' contributing events are reflected in the next read. Verify by repeating the race a few times and reading `profile.md`.
- **UAT-036.** Manually edit `profile.md` (e.g., delete an adaptation block). Run `compute-profile`. The file is fully regenerated from event data; user edits are overwritten without warning. The regenerated file's top-of-file header reads exactly: ``> DO NOT EDIT — regenerated by `gaia telemetry compute-profile`. Use `gaia mentorship purge` or `disable` to change state.``

**Harness fast-path.** Test 4 covers UAT-035 (atomic write contract — `profile.md` exists with mode 600 after `compute-profile`, idempotent across re-runs) and UAT-036 (DO NOT EDIT header is the first line).

---

## Cluster 11 — Statusline (UATs 37, 38)

**Setup.** A GAIA-project session.

**Expected.**

- **UAT-037.** With at least one active adaptation in `profile.md`, render the statusline. `🧭` appears on the right side of the statusline (before any `Run /update-deps` or `Run /update-gaia` segments). Verify by populating `.gaia/cache/coaching-active.txt` with a single byte `1` and triggering a session refresh.
- **UAT-038.** With zero active adaptations, render the statusline. No `🧭` appears; the right side is unchanged from the pre-telemetry baseline. Verify with `.gaia/cache/coaching-active.txt` absent or containing `0`. **Maintainer judgment.** The "unchanged from baseline" assertion is by-eye comparison.

**Harness fast-path.** None — visual rendering is maintainer-judgment.

---

## Cluster 12 — CLI surface (UATs 39, 40, 41, 42, 43, 44, 45)

**Setup.** Mentorship state varied per test.

**Expected.**

- **UAT-039.** With mentorship currently disabled, run `.gaia/cli/gaia mentorship enable` interactively. An `AskUserQuestion` confirms; on confirm, `mentorship.enabled = true`; `.gaia/cli/gaia mentorship status` reflects the change immediately.
- **UAT-040.** With mentorship enabled and N event files on disk, run `.gaia/cli/gaia mentorship disable`. Subsequent emits no longer write mentorship events; existing files remain untouched; `compute-profile` short-circuits and `profile.md` is not regenerated.
- **UAT-041.** With mentorship accumulated event files plus an analytics report, run `.gaia/cli/gaia mentorship purge`. An `AskUserQuestion` requires explicit "Yes, delete all mentorship data" confirmation; on confirm, all files under `~/.claude/projects/<slug>/gaia/telemetry/mentorship/`, `profile.md`, and `.gaia/local/telemetry/analytics/*.json` are deleted; `install-id.txt` is regenerated as a fresh ULID; cloud stream files are NOT deleted.
- **UAT-042.** With mentorship enabled, run `.gaia/cli/gaia mentorship status`. stdout prints structured state: enabled flag, analytics flag, install-id, mentorship-dir absolute path, last-event timestamp, active-pattern count, active-adaptation count.
- **UAT-043.** Run `.gaia/cli/gaia mentorship analytics dry-run`. stdout prints the exact JSON payload that would be uploaded to the v1.x endpoint, with the `audit` block self-attesting (`no_event_data`, `no_user_paths`, `no_user_text`, `no_project_identifiers` all literally `true`) and `fields_present` matching actual top-level keys; dry-run does NOT perform any network call.
- **UAT-044.** With both mentorship and analytics enabled, run `.gaia/cli/gaia mentorship analytics disable`. `mentorship.enabled` remains `true`; `mentorship.analytics.enabled` becomes `false`; analytics report generation halts; mentorship JSONL writes continue.
- **UAT-045.** Run any of the five `.gaia/cli/gaia mentorship` subcommands in a non-interactive (CI / scripted) context with `--yes`. The `--yes` flag is honored; the command proceeds without prompting; structured stdout/stderr remains parseable.

**Harness fast-path.** Test 5 covers UAT-043 (audit attestation + fields_present match) end-to-end. Test 6 covers UAT-040 (disable short-circuit). The remaining UATs are mechanically deterministic but require interactive `AskUserQuestion` rendering or a populated mentorship-state to inspect; verify in this runbook against a scratch repo.

---

## Cluster 13 — Smoke test (UAT-046)

**Setup.** A throwaway feature description and a fresh repo with mentorship enabled.

**Action.** Run `/gaia spec`, then `/gaia plan`, then a UAT cycle (engineer dispatched, returns DONE, audit fires).

**Expected.** Events from each phase land in correct streams:

- mentorship has `time_to_resolved_spec` (from spec close), `plan_revised` (if the plan revised midway), `uat_pass` (from the engineer's verify cycle), and `code_review_audit_finding` (from the audit hook firing post-merge);
- cloud has the structurally-projected counterparts (the same event types, with `_local` stripped and unexpected-field guard intact);
- `profile.md` regenerates after `spec_close`;
- `.gaia/cli/gaia mentorship analytics dry-run` emits a payload whose `audit` block all-true assertions match the actual fields.

**Harness fast-path.** The deterministic *structural* subset of UAT-046 is the entirety of `.claude-tests/smoke/telemetry-v1/run.sh`. The live workflow walk-through above is the maintainer-judgment companion — the harness gates the structural surface; the runbook gates the experiential one.

---

## Cluster 14 — Claude display rule (UAT-047)

**Setup.** Mentorship enabled with at least one mentorship JSONL on disk.

**Action.** Ask Claude (via any skill or agent) to show, summarize, tail, or otherwise display the raw contents of files under `~/.claude/projects/<slug>/gaia/telemetry/mentorship/`. Try variants: "show me the latest mentorship event", "summarize today's mentorship JSONL", "tail the events file".

**Expected.**

- **UAT-047.** Claude refuses and points the user at `profile.md` (Claude-displayable aggregate) or `.gaia/cli/gaia mentorship --tail` (CLI surface). Enforcement: a project-wide rule lives at `.claude/rules/mentorship-display.md` stating the contract; the rule is loaded via `CLAUDE.md` like other GAIA rules; every GAIA skill that handles mentorship state references the rule.

**Harness fast-path.** None — this is a Claude-behavior assertion, not a CLI assertion. **Maintainer judgment.** Try three or four phrasings and judge: does Claude refuse cleanly? Does it suggest the right alternative?

---

## After the runbook

Once every cluster passes:

1. Confirm `bash .claude-tests/smoke/telemetry-v1/run.sh` still exits 0.
2. Confirm `pnpm typecheck && pnpm lint` still pass.
3. Note any maintainer-judgment "marginal pass" calls in your verification notes — the SPEC's evidence file (per `task-uat-verification` precedent at `.specify/extensions/gaia/test/uat-evidence.md`) is the canonical home for those.

The release-gate harness gates the mechanical regression; this runbook gates the experiential one. Both have to pass before SPEC-001 closes.
