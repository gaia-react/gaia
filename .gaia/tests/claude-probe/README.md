# Claude probe

Maintainer-only (all of `.gaia/tests` is release-excluded). The probe observes how Claude Code loads GAIA's harness in the SPEC-092 layout (harness at the repository root, the app and its frontend-only harness under `frontend/`) and judges each observation against a committed expectation table. It is SPEC-092's Phase 0 gate (plan Phase 1) and the instrument behind UAT-001, UAT-017 and UAT-023.

It spends tokens and needs Claude auth, so it runs by hand on a maintainer machine under a cost cap. CI runs only the harness's own tests (`.gaia/tests/lib/claude-probe.bats`), which use a stub `claude`.

## Files

| File | Role |
|---|---|
| `expectations.json` | The expectation table, the fixed oracle. |
| `run-probe.sh` | Runs every scenario the table needs, per launch dir, `--reps` times; writes evidence; calls the comparator. |
| `compare.mjs` | Pure comparator: evidence dir plus table in, `MISMATCH` / `UNLISTED` / `EMPTY` / `UNCITED` lines and an exit code out. Also `--check-table`, `--floor-map`, `--plan`. |
| `lib/table.mjs` | Row schema, the floor items, `expand` resolution. |
| `lib/observe.mjs` | Raw evidence to observed state, per row kind. |
| `build-fixture-tree.sh` | Builds the synthetic target-layout repo for the spike run. |
| `inject-probe-fixtures.sh` | Lays the probe instrumentation over any target-layout tree (shared by the two scripts above). |
| `probe-hooks/*.sh` | The probe hooks; each appends one JSON line per event to `$GAIA_PROBE_LOG`. `if-gate.sh` is the one registered behind an `if` rule, for the `hook_if` rows. |
| `fixtures/mcp-probe-server.mjs` | Minimal stdio MCP server behind the temporary root `.mcp.json`. |

## Running it

Spike run (before any implementation phase), against the synthetic tree:

```bash
bash .gaia/tests/claude-probe/build-fixture-tree.sh "$(mktemp -d)/fixture"   # prints the tree path
bash .gaia/tests/claude-probe/run-probe.sh --target <fixture path> \
  --evidence .gaia/local/probe/<date>-spike --reps 3 --max-usd 15
```

Final run (after plan Phase 11), against a scratch clone of the finished branch with dependencies installed, so `.githooks/pre-commit` has a toolchain:

```bash
git clone --branch <branch> . "$(mktemp -d)/final" && pnpm -C <clone> install
bash .gaia/tests/claude-probe/run-probe.sh --target <clone> \
  --evidence .gaia/local/probe/<date>-final --reps 3 --max-usd 15
```

Flags: `--only <row-id-glob>` runs and judges only the matching rows (the floor and schema checks still read the whole table); `--launches` narrows the launch dirs (default `root,frontend,worktree`); `--model` defaults to `sonnet`; `--table-repo` names the checkout whose committed table is the oracle (default: the one holding the script).

`run-probe.sh` refuses (exit 2) without `--max-usd`, with a dirty or untracked `expectations.json`, with a table that fails `--check-table` against the target's root settings, with a non-empty evidence dir, and with a target that shares a git directory with this checkout. It rewrites the target while it runs and restores every file it touched on exit, including after a cost-cap stop. When the plan has a commit scenario it also switches the target to a `probe/run` branch at the same commit (GAIA's commit-to-main guard would otherwise deny every scripted commit before git runs) and switches back to the original branch, or detached commit, on exit. `build-fixture-tree.sh` leaves its fixture on `probe/fixture`, not `main`, for the same reason. Exit 3 means it stopped before the comparator: cumulative `total_cost_usd` passed `--max-usd`, or a stream's cost could not be read.

## Cost model

Every scenario is a fresh `claude -p` session: one call per scenario, plus a second (`--resume`) listing turn for an after-read scenario whose rows observe agents or MCP servers (skill rows read the first turn, below). One repetition is 10 `claude` calls from the root launch dir (9 scenarios plus one listing turn), 7 from `frontend/`, and 1 from the worktree. Each call's first turn pays for the system prompt, tool definitions, GAIA's root CLAUDE.md and always-loaded rules, and the skill and agent listings (roughly 50k tokens); later turns in the session mostly read that prefix from the cache.

Estimate for **2 launch dirs x 3 reps on Sonnet** (Sonnet 5.5: $2 / $10 per million input / output tokens, cache writes about $2.50 and reads $0.20 per million): 48 calls at about $0.125 for the first turn, plus about 110 follow-up turns at about $0.012, is **about $7.50**. The worktree launch adds about $0.40. The spike run (`20261003T020501Z-spike`, all three launch dirs, 3 reps) measured **$8.08**; splitting each scripted commit into its own `git add` and `git commit` calls adds about 12 follow-up turns per 3 reps (about $0.15), and once commits get past the commit-to-main guard, pre-commit output lands in the commit tool results (a few cents more), so plan on **about $8.50** for a 3-rep run. The `after_task:hook-if` scenario is one more root call per repetition carrying one Bash call per command in its list (about 20): about $0.125 for the first turn plus about 20 follow-up turns at $0.012, so **about $0.40 a repetition** and about $1.20 for 3 reps, which a full 3-rep run adds to the $8.50. Run alone (`--only 'root-if-*' --launches root --reps 3`), a cap of $3 covers it. A cap of **$15** leaves 2x headroom on a full run for retries the model makes inside a session. The real figure is in `spent-usd` in the evidence dir after each call; `--max-budget-usd` is also passed to every call with the remaining budget.

## How observations are made

Never from model text. A model saying a rule loaded is not evidence that it did. The sources are:

| Signal | Source | Kinds |
|---|---|---|
| `instructions_loaded` | `InstructionsLoaded` probe-hook lines (`file_path`, `load_reason`, `trigger_file_path`) | `claude_md`, `rule` |
| `session_start_probe` | `SessionStart` probe-hook lines: `CLAUDE_PROJECT_DIR`, the hook's `pwd`, its git toplevel, and the tag of the settings file that registered it | `env`, `settings_source`, `hook` |
| `stream_json_init` | the `system`/`init` event of `claude -p --output-format stream-json --verbose` (`skills`, `slash_commands`, `agents`, `mcp_servers`); for skills, also every later `system`/`commands_changed` event of the same turn | `skill`, `agent`, `mcp` |
| `post_tool_use` | `PostToolUse` probe lines (ran), the stream's `result.permission_denials`, and the structured `tool_use` / `tool_result` blocks | `permission`, component `task` |
| `probe_if` | the always-on `PreToolUse` / `PostToolUse` probe lines carrying a `probe-if-<marker>`, the `IfGate` lines `if-gate.sh` writes, and the root settings snapshot's gated handlers | `hook_if` |
| `git_log` | git's own records: `GIT_TRACE2_EVENT` hook-run events (`child_start`, `hook_name: pre-commit`) and whether a `git commit` process started; for the RED gate, also that hook's own deny reason (below) | commit `task` |
| `manual` | not observable under `-p`; carries its reason in `source` and is never compared | |

A hook row is `registered` when a probe line proves its settings file was a live source for the session and that file's snapshot holds the entry (event, matcher, command) byte for byte. The probe tags (`root-settings`, `root-local`, `frontend-settings`, `frontend-local`) also keep identical probe commands from being deduplicated across files.

A lazy-discovery row (`after_read:<path>`) is judged only once a `PostToolUse` line proves the Read happened; without that line every row of the scenario reports `read_not_verified`. How each kind is judged after the Read:

- `claude_md`: `loaded` on an `InstructionsLoaded` line for the file, **or** on a verified Read of exactly that file. A direct Read of a CLAUDE.md puts its content in context through the Read and emits no `InstructionsLoaded` for it; a Read of any other file under its directory does emit one, with `load_reason: nested_traversal` (spike run `20261003T020501Z-spike`). Rules stay `InstructionsLoaded`-only.
- `skill`: the first turn's `init` listing plus every `commands_changed` event after it. The `init` event is a session-start snapshot and never shows a nested `.claude/skills` directory discovered mid-session; Claude Code emits `commands_changed` with the full command list whenever the set changes, and the Read of `frontend/CLAUDE.md` drew one adding exactly the frontend skills.
- `agent`, `mcp`: the `init` event of a second, `--resume` turn. That is also a session-start snapshot; no structural mid-session agent listing has been observed yet.

Commit rows: the scenario issues four separate Bash calls, `git add` then `git commit` for each of the two scripted commits, because the RED gate runs at the commit's `PreToolUse` and reads the index: a combined `add && commit` call shows it nothing staged. `pre-commit` is `ran` when trace2 shows the commit process starting that hook. `red-gate` is the gate's own decision, never "some hook denied": `deny` when a deny reason opening with `TDD RED-verification:` reaches the commit's `tool_result`, or a `PreToolUse` `hook_response` carries one naming that commit's staged paths (recorded as `commit_paths` in `scenario.json`); `allow` when the commit process started; `blocked_before_git` when another hook or the permission layer stopped the call; `undetermined` when it was attempted with none of these; `not_reached` when it was never attempted.

### Hook `if` rows

A `hook_if` row asks whether Claude Code's hook handler `if` field (one permission rule per handler) spawned or skipped a handler for one scripted Bash call. Its subject is `<PreToolUse|PostToolUse>|<if rule>|<marker>`; its id is `root-if-<marker>-<pre|post>-<rule slug>`, so `--only 'root-if-*'` selects exactly these rows. `inject-probe-fixtures.sh` registers, in the root settings only, one `Bash` group per event holding an `if-gate.sh` handler behind each rule under test, plus two PostToolUse handlers with one identical command behind two different rules (`dedup`). The `after_task:hook-if` scenario runs the numbered command list in `run-probe.sh` (`--print-hook-if-commands <root>` prints it), one Bash call per command, each allowed by exact rules only.

How a row is judged, in order:

- `not_registered` when the root settings snapshot holds no matching gated handler; without this a `skip` row would pass on a run that never registered its handler.
- `not_attempted` when the always-on probe line **for the row's own event** carries no `<marker>`. A PreToolUse line never stands in for a PostToolUse attempt: a call denied at PreToolUse, or one that exited non-zero and fired PostToolUseFailure, has one and never reached PostToolUse, so its silent gate is not a skip. An `IfGate` line alone proves nothing either, being the thing under test. `not_attempted` matches neither `spawn` nor `skip`, so an unattempted call always fails.
- `spawn` when an `IfGate` line with the row's event, rule slug and marker exists, else `skip`.

The dedup row also prints `NOTE <row-id> rep=<n> spawn_count=<k>`, information that never changes the exit code: one spawn means the runtime dedups same-command handlers, two means it does not.

Every command is side-effect free: PR and issue verbs name a nonexistent PR in a nonexistent repository, the commit shapes use `git commit --dry-run` (no git hook, no write), and the rest are read-only. Every command ends in `|| true; : probe-if-<marker>`, so the call exits 0 and fires PostToolUse rather than PostToolUseFailure, and the probe hooks log the marker in place of the command. The fixture's own guards deny every scripted `gh pr merge` and `gh pr checkout` at PreToolUse, so those commands carry PreToolUse rows only; their PostToolUse behavior is inferred from the PreToolUse rows plus the PostToolUse `Bash(gh pr view *)` rows on the same shapes. Each row's `expect` is what the hooks documentation predicts; the live run decides.

Permission rows: an Edit row targets a path held absent for the scenario and asks for an Edit with an empty `old_string` (a file create), so the Edit tool's own read-before-edit validation cannot pre-empt the permission layer. One executed attempt makes the row `allow` even if another attempt was denied.

## The table

`expectations.json` holds `{"schemaVersion": 1, "rows": [...]}`. Every row carries every key: `id`, `launch` (`root`, `frontend`, or `worktree`: a root launch inside a `git worktree` of the target), `kind`, `subject`, `expand`, `trigger` (`session_start`, `after_read:<repo-relative path>`, `after_task:<component-write|commit|permissions-read|permissions-edit|hook-if>`), `expect`, `signal`, `floor`, `source`, `cited_run`.

`expand` turns one row into one row per match in the target, resolved at compare time from the evidence snapshot, so the same table serves the fixture and the final tree:

- a glob in the plan's C3 dialect over the launch's file list, for example `.claude/skills/*/SKILL.md`; a `#unscoped` or `#scoped` suffix keeps only rules without or with `paths:` frontmatter;
- `hooks:<settings path>`: one row per hook entry of that settings file, probe entries excluded.

A row whose expansion finds nothing fails as `EMPTY`; a claim over an empty set is not a pass. Subjects are repo-relative paths, except skills and agents (matched by name, derived from the path), MCP servers (by server name), permissions (`<Tool> <path>`), env (`CLAUDE_PROJECT_DIR`, `pwd`, `git_toplevel`, values relative to the launch's repo root) and commit tasks (`commit-<a|b>:<pre-commit|red-gate>`, `commit-parity`).

`UNLISTED` covers what the target owns: instruction files inside the launch's repo root, and skills, commands, agents and MCP servers the target defines. Ambient items (the user's own CLAUDE.md and auto memory, personal and built-in skills and agents, user MCP servers) are out of scope.

### Editing the table after the first run

The table was committed before the first probe run, and `run-probe.sh` records `expectations_commit` and `table_sha256` in each evidence dir's `meta.json` before its first Claude call. After that, **a row may change only with `cited_run` set to the tracked summary of the probe run that justified the change.** The evidence dir stays machine-local, so the summary is what a citation names: copy the run's `meta.json` (without the machine-local `table_repo` and `target` keys) and `compare.txt` into `cited-runs/<run-id>/` and cite that repo-relative path. `compare.mjs --first-run-commit <sha>` fails with `UNCITED <row-id>` on any row that differs from its form at that commit while `cited_run` is null; a deleted row always fails.

A contradiction of a **floor** row, or of constraint 2 (ancestor walk plus generated settings, no symlinks), is never resolved by editing the table: it stops the plan and reopens SPEC-092.

### The floor

`compare.mjs --check-table` fails with `MISSING_FLOOR <item>` unless every SPEC-092 Phase 0 floor item has a `floor: true` row, and, given `--root-settings`, unless every root `Edit(...)` deny is exercised by a floor row from both the root and `frontend/` launch dirs. The item list lives in `lib/table.mjs` (`FLOOR_ITEMS`); `--floor-map` prints which rows meet each.

## What the spike run is expected to show

The spike tree carries today's hooks and rule globs, moved but not yet rewritten. Non-floor rows whose `source` names a later plan phase are written for the finished tree and are expected to mismatch on the spike:

- the path-triggered rule rows (`*-tsx-*`, `*-pw-*`; source "plan C7"), until Phase 7 rewrites rule `paths:` from the probe decisions;
- `*-commit-b-red-gate` and `*-commit-b-pre-commit` (source "plan C5"), until Phase 3 makes the RED gate descriptor-driven.

The `*-glob-anchor-*` rows are the claude-mechanics Q2 experiment: their expectation is the launch-dir-anchor hypothesis, and whichever way they come out sets the C7 probe decisions. The floor rows, and the commit-parity row, must hold on the spike as well as on the final tree. The `SUMMARY` line splits mismatches into floor and other.

## Evidence layout

```
<evidence>/
  meta.json            expectations_commit, table_sha256, target, reps, model, launches, max_usd
  table-check.txt      compare.mjs --check-table output for this run
  spent-usd            cumulative total_cost_usd, rewritten after every call
  compare.txt          the comparator's verdict
  snapshot/<launch>/   tree.txt (the launch's file list) and files/ (settings, .mcp.json, every rule) as run
  rep-<n>/<launch>/<scenario>/
    scenario.json      launch, trigger, launch_root, launch_directory
    probe.jsonl        probe-hook lines
    stream-<turn>.jsonl, stderr-<turn>.log
    trace2.jsonl       commit scenario only
    files-after.json   component-write scenario only
```

A later table edit cites a run through its `cited-runs/` summary, never through the evidence dir itself.

## Assumptions the first run confirms

These are Claude Code behaviors the observation code relies on and no offline test can exercise. If the spike shows one wrong, fix the observation code (`lib/observe.mjs`, `run-probe.sh`), not the table:

- the stream-json `init` event carries `skills` (or skills inside `slash_commands`), `agents` and `mcp_servers`, and a mid-session change to the command set arrives as a `commands_changed` event carrying the full list (confirmed by the spike run);
- a `PreToolUse` hook's deny reason reaches the denied call's `tool_result` (`PreToolUse:Bash hook error: <reason>`; confirmed for a single denying hook by the spike run) and the hook's JSON stdout is in the `hook_response` event under `--include-hook-events`;
- a hook-denied tool call appears in `result.permission_denials`, or as an error `tool_result` naming the hook or the denial;
- an Edit with an empty `old_string` on an absent file reaches the permission check;
- hook processes and the Bash tool inherit `GAIA_PROBE_LOG` and `GIT_TRACE2_EVENT` from the `claude` process.
