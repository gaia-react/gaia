---
type: concept
title: Usage Ledger
status: active
created: 2026-09-30
updated: 2026-10-09
tags: [concept, cost, usage, data-contract]
---

# Usage Ledger

The usage ledger records every assistant usage message in the repo's Claude Code transcripts (the main checkout and every worktree; sessions, sub-agent sidecars, and workflow sidecars) so what an idea cost, from first research to merged pull request, can be read back later. Transcripts are pruned after 30 days, so capture is incremental: spend is recorded while the transcript still exists, and the ledger outlives it.

It is the only cost store: every figure GAIA prints for a workflow run, a pull request, or an initiative is read from it. A retired `cost.jsonl` may remain on disk from an earlier release; nothing reads or writes it. `.gaia/scripts/usage-flush.sh` and `.gaia/scripts/usage.sh` are the source of truth for what is written and read; this page documents what they do, and where the two disagree the scripts win.

## Stores

Everything lives under `.gaia/local/telemetry/` of the main checkout, resolved through the shared main-root resolver (see [[Worktrees]]). The state registry (`.gaia/state-registry.json`) classifies each file; see [[Local Working State]].

| File | Holds |
| --- | --- |
| `usage.jsonl` | `segment`, `binding` (start, close, research, declare), and `cursor` rows |
| `links.jsonl` | `edge`, `unlink`, and `merge` rows |
| `usage-cursors.json` | A regenerable cache of the latest cursor per transcript file. Only the flusher writes it. |
| `token-rates.override.json` | The optional, hand-written price override; see [[Token Cost Readout]]. GAIA never writes it. |
| `usage-branch-memo.json` | A regenerable cache of branch-name derivations, the segment model list, and per-store read offsets. The readouts write it without the ledger lock (temp file then rename). Deleting it only costs the next readout time; it never holds an attribution decision. |

Row shapes, abridged:

```json
{"schema_version":1,"kind":"segment","key":"branch:fix/foo","session_id":"<sid>","inherit":false,
 "first_ts":"<iso>","last_ts":"<iso>","messages":12,
 "by_model":{"claude-opus-5-5":{"fresh_input":0,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":0}}}

{"schema_version":1,"kind":"binding","type":"research","session_id":"<sid>","ts":"<iso>",
 "ref":"research:<slug>","source":"transcript"}

{"schema_version":1,"kind":"binding","type":"close","session_id":"<sid>","ts":"<iso>",
 "ref":"spec:SPEC-NNN","workflow":"gaia-spec","source":"record-command"}

{"schema_version":1,"kind":"edge","child":"<ref>","parent":"<ref>","source":"link-command","ts":"<iso>","session_id":"<sid>|null","sidechain":false}

{"schema_version":1,"kind":"merge","pr":123,"key":"branch:fix/foo","merged_at":"<iso>","source":"gh-pr-merge","ts":"<iso>","session_id":"<sid>|null"}
```

A segment's `by_model` is the five-bucket shape the pricing lib reprices (`fresh_input`, `cache_write_5m`, `cache_write_1h`, `cache_read`, `output`). A `segment` carries raw facts only: no attribution is stored on it. A `cursor` row records how far a transcript file has been read and is appended in the same write as the rows it accounts for.

**Agent fields.** Every segment carries `agent_type`: `main` for the main transcript, the `agentType` string of the `agent-<id>.meta.json` beside a sub-agent sidecar, or `unknown` when that file is missing or lacks it. A sidecar's segment also carries `agent_id`, the `<id>` of its `agent-<id>.jsonl` file name. A segment written before these fields existed has no `agent_type` and is read as **unrecorded**: the Code Audit Team sum excludes it and the lower-bound marker counts it. Nothing backfills older segments.

**Evolution and writers.** The stores are append-only and never reaped. A row is never rewritten or deleted, and a later link never changes an earlier row; attribution is recomputed on every read. A new field is additive and never bumps `schema_version`; a change that removes or repurposes a field bumps it and is confirmed first, because external readers depend on the shape. A reader skips rows whose `schema_version` it does not know rather than failing. Every writer appends under the one ledger lock keyed on the main checkout's telemetry directory, so parallel worktree sessions never lose a row.

**Retention.** The ledger outlives everything that feeds it: transcripts are pruned after 30 days, and a merged SPEC or plan folder is reduced to its `SUMMARY.md`, so the ledger is where a run's cost is read back from afterward. The archive scripts reduce or delete a folder only when `usage.sh represented` finds the run's close row (see Recording a run).

## How capture works

`.claude/hooks/usage-capture.sh` runs on `Stop` and on `SessionStart` (`startup|resume`). It does a cheap gate, launches the flusher detached, and returns; it reads no transcript itself. A Stop flushes that session; a SessionStart runs a bounded sweep over every candidate transcript whose size has grown past its cursor, which also backfills transcripts from before the hooks existed.

The flusher parses outside the ledger lock, then takes the lock for a short commit that re-checks the cursor before appending (compare-and-swap), so two flushers racing over one file count each message once. A close binding that lands after the flusher prepared is a conflict too: the flusher re-prepares, so no committed segment straddles a close. On a lock timeout it appends nothing and leaves the file due for the next run; there is no unlocked fallback. The trailing, possibly still-growing group of a live transcript is held back until it is quiet, and a finished session is flushed whole.

The merge hook and `usage.sh record` each add a capped synchronous flush of their own session (see Recording a run and Readouts). Nothing runs in CI (`GITHUB_ACTIONS` set), and nothing runs without `jq`.

## Keys and attribution

Each usage message gets a raw key when it is written, from that line's own branch:

- A branch that is not the repo's default branch becomes `branch:<normalized branch>` (a branch name outside the key grammar becomes a hashed form).
- The default branch, an empty branch, and a detached `HEAD` become `session:<session id>`.
- An agent-isolation worktree's lines become `session:<session id>` flagged `inherit`, and resolve to the same session's own non-inherit key at read time.

Three things bind a session to a named effort rather than leaving it on its session key. A `Write` to a file under `.gaia/local/research/` of the main checkout binds the session to `research:<slug>`. `usage.sh declare` binds a session to `research:<slug>` or `init:<slug>` by hand. A `/gaia-spec`, `/gaia-plan`, or maintenance-command invocation writes a `start` binding when the flusher sees the skill invoked or its slash command typed in the transcript, and `usage.sh record` writes the matching `close` binding; the spend between them binds to the close's `spec:`, `plan:`, or `command:` ref.

**Pairing is latest-start-wins.** `usage_intervals` in `.gaia/scripts/usage-resolve-lib.sh` is the only implementation, per session and workflow:

1. A close carrying `start_ts` claims the start whose `ts` equals it. These pairs settle first and leave the candidate set, so a recovery never claims or supersedes a live run's start.
2. Each remaining close, in time order, claims the latest unclaimed start at or before it. A newer start supersedes an older unclaimed one, which is then never claimed. A close whose latest start is already claimed pairs with nothing and opens no interval.
3. The interval runs from the start's `ts` to the close's `ts`, keyed by the close's ref. It is half-open: a segment that begins at the close instant falls after it.

Resolution happens at read time: the latest research or declare binding at or before a segment's first timestamp wins (a declare wins a same-instant tie), a segment earlier than a session's first binding takes that first binding, and a branch key is never overridden by a spec or plan interval. The precedence is implemented in `.gaia/scripts/usage-resolve-lib.sh`.

**`unattributed` means spend no binding reached**: a segment still resolving to its `session:` key.

## Initiatives

An initiative is a tree of refs (`research:`, `init:`, `issue:`, `spec:`, `plan:`, `pr:`, `branch:`) joined by lineage edges. Edges come from two places:

- **Derived** at read time from naming conventions alone (a debt branch to its issue, `<type>/spec-<n>` to its SPEC, legacy `plan/spec-<n>` too, a branch named for an issue).
- **Explicit**, recorded by `usage.sh link`, by `usage.sh lineage` from a SPEC's `lineage:` frontmatter, by the PR-create hook (a `pr:` to its branch), by `usage.sh record --pr` or `--issue` (a `pr:` or `issue:` to a command run), and by the orchestrator when it links a plan's branch to its SPEC.

`usage.sh unlink` writes a tombstone that suppresses a pair, derived or explicit, from then on. `link` refuses a link that would close a cycle.

Two figures come out of the graph and are kept apart. The **per-PR figure** is the spend on one pull request's branch between the previous merge and this one. The **initiative figure** is the spend of every node under a root, counting each segment once. Initiative figures overlap across roots (a PR sits under its SPEC and under its research), so they are never summed.

## Research location

`.gaia/local/research/<topic>/` (a directory per effort) or a loose `.md` file there is where GAIA looks for research. A `Write` to either binds the session's default-branch spend to `research:<topic>`. Research kept anywhere else is bound by running `usage.sh declare`. Only the main checkout's research directory binds; a worktree's own copy does not.

## Commands

`bash .gaia/scripts/usage.sh` is the adopter-facing command. With no arguments it prints its usage, which is the list of subcommands and flags; this page does not repeat it. Writes refuse invalid refs and cycles without writing anything. Readouts always exit 0 and degrade to a marked figure instead of failing.

A SPEC's `lineage:` frontmatter is the authoring-time link: `usage.sh lineage <path-to-SPEC.md>` turns each entry into an edge. The wiki page for authoring a SPEC is [[GAIA Spec]].

## Recording a run

`bash .gaia/scripts/usage.sh record <ref> --workflow <w> [--pr <N>] [--issue <N>] [--start <iso>] [--json]` ends a `/gaia-spec`, `/gaia-plan`, or maintenance-command run and prints its Cost line. `<ref>` is `spec:SPEC-NNN` (workflow `gaia-spec` or `gaia-plan`), `plan:PLAN-NNN` (`gaia-plan`), or `command:<workflow>` for a maintenance command, which is written under a unique run ref `command:<workflow>-<UTC stamp>-<4 hex>`. `--pr` and `--issue` are accepted on a command ref only and write an edge from that number to the run ref. The workflow set is `GAIA_USAGE_START_SET` in `.gaia/scripts/usage-lib.sh`, which the flusher's start detection reads too.

`record` flushes the current session (`CLAUDE_CODE_SESSION_ID`) whole under `GAIA_USAGE_MERGE_CAP_SECONDS`, then appends the close binding under the ledger lock, deciding the pairing with the lock held so two closes never claim one start. The last stdout line is `Cost: ~<tokens> tokens, $<dollars>, <elapsed>`, with ` (partial: flush incomplete)` when the cap cut the flush and ` (partial: lower bound)` when a model is unpriced; `--json` prints `{"tokens","dollars","elapsed_seconds"}` instead. Rendering is bounded by `GAIA_USAGE_RENDER_CAP_SECONDS`; past it a `! readout timed out` marker replaces the line, after the close is already written.

| Exit | Meaning |
| --- | --- |
| 0 | Recorded. |
| 1 | Refused with nothing written: no session id, no unclaimed start, already recorded, or the ledger lock timed out. One stderr line names the reason and the recovery command; no Cost line prints. |
| 2 | Usage error: bad ref, unknown flag, missing or disallowed `--workflow`, `--pr` or `--issue` on a non-command ref, `jq` absent, unreadable ledger. |

`record` and `represented` skip the other subcommands' `jq`-absent preamble, which prints the inactive line and exits 0, and exit 2 instead.

**Recovery.** After a `/clear` or a resumed session the run's start belongs to an earlier session id, so a bare `record` finds no unclaimed start and refuses. The refusal names the command that closes the run anyway: `bash .gaia/scripts/usage.sh record <ref> --workflow <w> --start <iso>`. It writes a start binding at `<iso>` and a close carrying `start_ts`, under one lock; the figure then covers only the current session's spend inside that interval, so a run split across sessions reads as a lower bound. A second call with the same `--start` reports already recorded.

**Cost of asking.** `record` waits at most the flush cap plus the render cap. A cold readout on a 14.5 MB ledger takes about 3.0 s, and the ledger grows about 0.38 MB a day.

`bash .gaia/scripts/usage.sh represented <ref> --workflow <w>` is the archive gate. It exits 0 when `usage.jsonl` holds a close with that ref and workflow (a `command:<workflow>` ref matches any of that workflow's run refs), 1 when it does not, and 2 on a usage error, `jq` absent, or a missing or unreadable ledger. It prints nothing, reads only close rows, and builds no keys, branch map, or memo. The archive scripts treat 1 and 2 the same way: keep the folder and print the `record` recovery command.

## Readouts and markers

- **Per-PR block.** A `gh pr merge` run as a Bash tool call prints `[PR cost]` for the merged branch (tokens by bucket, estimated dollars, sessions, span, the merge window), then one trailing `[initiative ...]` pair per root the branch sits under. The hook reads the pull request once with `gh pr view` to confirm the merge, and records the merge boundary only when GitHub says `MERGED`.
- **Code Audit Team line.** Under the dollar line the block carries `audit (Code Audit Team): tokens <n>  est. cost (USD): $X.XX`, summing the branch's in-window segments whose `agent_type` is a roster member. The roster is the `auditors:` list of `.gaia/audit-ci.yml`, read through `audit_roster_member_names`; when it is unreadable the line is omitted and `! audit line unavailable: no auditors roster in .gaia/audit-ci.yml` follows the block. Segments without `agent_type` are not summed and are counted in `! lower bound: <n> segment(s) predate agent fields`.
- **Initiative readout.** `usage.sh initiative <ref>` prints the spend of each node under each root of a ref. With `--line` it treats `<ref>` itself as the root and prints one full-cycle line, `Cost: ~<tokens> tokens, $<dollars>, <elapsed> (<node> $X.XX + ...)`, with ` (partial: lower bound)` when a model is unpriced; `--json` (only with `--line`) prints the same figures as `{"tokens","dollars","elapsed_seconds"}`. The plan orchestrator prints it for the SPEC or plan root before it merges. `record` and `initiative --line` share one formatter, so the two lines read alike.
- **Reconcile.** `usage.sh reconcile` prints attributed against unattributed spend.
- **Coverage start.** Every readout prints the earliest recorded timestamp. Spend before it was never captured.
- **Dollars** are repriced at read time from the raw buckets through the shared pricing lib (see [[Token Cost Readout]]), so a later rate-table change moves the figure.

A readout never shows a silently lower figure. Each of these markers appears when it applies:

| Marker | Meaning |
| --- | --- |
| `usage tracking inactive: jq not found` | `jq` is absent; nothing is read or written |
| `capture hooks not registered` | `usage-capture.sh` is not registered under both Stop and SessionStart, so the figure is withheld |
| `unflushed: <n> file(s), <bytes> bytes not yet recorded` | Some transcript has bytes the ledger has not folded in yet |
| `partial: flush incomplete` | The merge hook's capped flush did not finish before the figure was read |
| `merge not confirmed; boundary not recorded (record it: ...)` | No confirmed merge, or the merge row's write timed out; the marker carries the rerun command |
| `lower bound: branch spend may predate coverage start` | The branch's earliest spend is within a day of coverage start |
| `lower bound: unpriced model(s) <names>` | The rate table had no window for a model |
| `rate override ignored (unparseable): <path>` | The local price override exists but is not a JSON object with a `models` object; the distributed table prices alone |
| `lower bound: <n> segment(s) predate agent fields` | The audit line cannot place those segments |
| `readout timed out after <n>s; rerun: ...` | The merge-time render hit its cap |

The merge hook bounds itself. `GAIA_USAGE_MERGE_CAP_SECONDS` caps the flush and the `gh` read, and `GAIA_USAGE_RENDER_CAP_SECONDS` caps the render; the defaults and their measurements are in the header of `.gaia/scripts/usage-merge.sh`. When `usage-merge.sh` exits non-zero the hook prints `[PR cost] unavailable: ...` with the rerun command rather than going quiet. `GAIA_USAGE_HOOKS_DISABLE=1` turns the merge hook's usage work off, which the suites that run the real hooks use.

**Honest limits.** A merge that does not go through a Bash tool call (the CLI through `execFile`, an auto-merge that lands later, the web UI) prints no block. Its spend is still captured; `usage.sh link --merge` records the boundary afterward, and the marker above names the exact command. The per-PR window opens at the previous recorded merge of the same branch, so a missing boundary widens the next window rather than losing spend.

## Privacy

No usage data leaves the machine, and pricing opens no network connection. The only network reach is the one `gh pr view` read at merge.

## Pairs with

- [[Token Cost Readout]]: the rate table, the local override, and the Cost line the readouts and `record` print.
- [[Claude Hooks]]: `usage-capture.sh`, the merge hook, and the PR-create hook.
- [[Local Working State]]: where the stores and the research directory sit under `.gaia/local/`.
