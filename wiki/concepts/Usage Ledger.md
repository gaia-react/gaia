---
type: concept
title: Usage Ledger
status: active
created: 2026-09-30
updated: 2026-10-04
tags: [concept, cost, usage, data-contract]
---

# Usage Ledger

The usage ledger records every assistant usage message in the repo's Claude Code transcripts (the main checkout and every worktree; sessions, sub-agent sidecars, and workflow sidecars) so what an idea cost, from first research to merged pull request, can be read back later. Transcripts are pruned after 30 days, so capture is incremental: spend is recorded while the transcript still exists, and the ledger outlives it.

It is separate from `cost.jsonl` and never touches it. `cost.jsonl` keeps one row per workflow run (see [[Cost Data Contract]]); the usage ledger keeps raw spend per message run and attributes it at read time. `.gaia/scripts/usage-flush.sh` and `.gaia/scripts/usage.sh` are the source of truth for what is written and read; this page documents what they do, and where the two disagree the scripts win.

## Stores

Everything lives under `.gaia/local/telemetry/` of the main checkout, resolved through the shared main-root resolver (see [[Worktrees]]). The state registry (`.gaia/state-registry.json`) classifies each file; see [[Local Working State]].

| File | Holds |
| --- | --- |
| `usage.jsonl` | `segment`, `binding`, and `cursor` rows |
| `links.jsonl` | `edge`, `unlink`, and `merge` rows |
| `usage-cursors.json` | A regenerable cache of the latest cursor per transcript file. Only the flusher writes it. |
| `usage-branch-memo.json` | A regenerable cache of branch-name derivations, the segment model list, and per-store read offsets. The readouts write it without the ledger lock (temp file then rename). Deleting it only costs the next readout time; it never holds an attribution decision. |

Row shapes, abridged:

```json
{"schema_version":1,"kind":"segment","key":"branch:fix/foo","session_id":"<sid>","inherit":false,
 "first_ts":"<iso>","last_ts":"<iso>","messages":12,
 "by_model":{"claude-opus-5-5":{"fresh_input":0,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":0}}}

{"schema_version":1,"kind":"binding","type":"research","session_id":"<sid>","ts":"<iso>",
 "ref":"research:<slug>","source":"transcript"}

{"schema_version":1,"kind":"edge","child":"<ref>","parent":"<ref>","source":"link-command","ts":"<iso>","session_id":"<sid>|null","sidechain":false}

{"schema_version":1,"kind":"merge","pr":123,"key":"branch:fix/foo","merged_at":"<iso>","source":"gh-pr-merge","ts":"<iso>","session_id":"<sid>|null"}
```

A segment's `by_model` is exactly the five-bucket shape `cost.jsonl` uses, so the same pricing lib reprices it. A `segment` carries raw facts only: no attribution is stored on it. A `cursor` row records how far a transcript file has been read and is appended in the same write as the rows it accounts for.

The stores are append-only and never reaped. A row is never rewritten or deleted, and a later link never changes an earlier row; attribution is recomputed on every read. The evolution rule is the Cost Data Contract's: a new field never bumps `schema_version`, and a reader skips rows whose `schema_version` it does not know rather than failing.

## How capture works

`.claude/hooks/usage-capture.sh` runs on `Stop` and on `SessionStart` (`startup|resume`). It does a cheap gate, launches the flusher detached, and returns; it reads no transcript itself. A Stop flushes that session; a SessionStart runs a bounded sweep over every candidate transcript whose size has grown past its cursor, which also backfills transcripts from before the hooks existed.

The flusher parses outside the shared cost mutex, then takes the mutex for a short commit that re-checks the cursor before appending (compare-and-swap), so two flushers racing over one file count each message once. On a lock timeout it appends nothing and leaves the file due for the next run; there is no unlocked fallback. The trailing, possibly still-growing group of a live transcript is held back until it is quiet, and a finished session is flushed whole.

The merge hook adds a capped synchronous flush of the merging session (see Readouts). Nothing runs in CI (`GITHUB_ACTIONS` set), and nothing runs without `jq`.

## Keys and attribution

Each usage message gets a raw key when it is written, from that line's own branch:

- A branch that is not the repo's default branch becomes `branch:<normalized branch>` (a branch name outside the key grammar becomes a hashed form).
- The default branch, an empty branch, and a detached `HEAD` become `session:<session id>`.
- An agent-isolation worktree's lines become `session:<session id>` flagged `inherit`, and resolve to the same session's own non-inherit key at read time.

Three things bind a session to a named effort rather than leaving it on its session key. A `Write` to a file under `.gaia/local/research/` of the main checkout binds the session to `research:<slug>`. `usage.sh declare` binds a session to `research:<slug>` or `init:<slug>` by hand. A `/gaia-spec`, `/gaia-plan`, or maintenance-command invocation opens an interval that closes at the matching `cost.jsonl` row and binds the spend in between to that row's `spec:`, `plan:`, or `command:` ref.

Resolution happens at read time: the latest research or declare binding at or before a segment's first timestamp wins (a declare wins a same-instant tie), a segment earlier than a session's first binding takes that first binding, and a branch key is never overridden by a spec or plan interval. The precedence is implemented in `.gaia/scripts/usage-resolve-lib.sh`.

**`unattributed` here means spend no binding reached**: a segment still resolving to its `session:` key. It is a different thing from the Cost Data Contract's use of the word, which describes `cost.jsonl` command rows carrying no spec or plan id. The two never share a denominator.

## Initiatives

An initiative is a tree of refs (`research:`, `init:`, `issue:`, `spec:`, `plan:`, `pr:`, `branch:`) joined by lineage edges. Edges come from two places:

- **Derived** at read time from naming conventions (a debt branch to its issue, `<type>/spec-<n>` to its SPEC, legacy `plan/spec-<n>` too, a branch named for an issue) and from `cost.jsonl` rows: one naming both a SPEC or plan and a branch, and a command row's pull request.
- **Explicit**, recorded by `usage.sh link`, by `usage.sh lineage` from a SPEC's `lineage:` frontmatter, and by the PR-create hook (a `pr:` to its branch).

`usage.sh unlink` writes a tombstone that suppresses a pair, derived or explicit, from then on. `link` refuses a link that would close a cycle.

Two figures come out of the graph and are kept apart. The **per-PR figure** is the spend on one pull request's branch between the previous merge and this one. The **initiative figure** is the spend of every node under a root, counting each segment once. Initiative figures overlap across roots (a PR sits under its SPEC and under its research), so they are never summed.

## Research location

`.gaia/local/research/<topic>/` (a directory per effort) or a loose `.md` file there is where GAIA looks for research. A `Write` to either binds the session's default-branch spend to `research:<topic>`. Research kept anywhere else is bound by running `usage.sh declare`. Only the main checkout's research directory binds; a worktree's own copy does not.

## Commands

`bash .gaia/scripts/usage.sh` is the adopter-facing command. With no arguments it prints its usage, which is the list of subcommands and flags; this page does not repeat it. Writes refuse invalid refs and cycles without writing anything. Readouts always exit 0 and degrade to a marked figure instead of failing.

A SPEC's `lineage:` frontmatter is the authoring-time link: `usage.sh lineage <path-to-SPEC.md>` turns each entry into an edge. The wiki page for authoring a SPEC is [[GAIA Spec]].

## Readouts and markers

- **Per-PR block.** A `gh pr merge` run as a Bash tool call prints `[PR cost]` for the merged branch (tokens by bucket, estimated dollars, sessions, span, the merge window), then one trailing `[initiative ...]` pair per root the branch sits under, then the existing roll-up from [[Token Cost Readout]]. The hook reads the pull request once with `gh pr view` to confirm the merge, and records the merge boundary only when GitHub says `MERGED`.
- **Initiative readout.** `usage.sh initiative <ref>` prints the spend of each node under each root of a ref.
- **Reconcile.** `usage.sh reconcile` prints attributed against unattributed spend.
- **Coverage start.** Every readout prints the earliest recorded timestamp. Spend before it was never captured.
- **Dollars** are repriced at read time from the raw buckets through the same shared pricing lib as the roll-up (see [[Token Cost Readout]]), so a later rate-table change moves the figure.

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
| `readout timed out after <n>s; rerun: ...` | The merge-time render hit its cap; the roll-up still prints |

The merge hook bounds itself. `GAIA_USAGE_MERGE_CAP_SECONDS` caps the flush and the `gh` read, and `GAIA_USAGE_RENDER_CAP_SECONDS` caps the render; the defaults and their measurements are in the header of `.gaia/scripts/usage-merge.sh`. `GAIA_USAGE_HOOKS_DISABLE=1` turns the merge hook's usage work off, which the suites that run the real hooks use.

**Honest limits.** A merge that does not go through a Bash tool call (the CLI through `execFile`, an auto-merge that lands later, the web UI) prints no block. Its spend is still captured; `usage.sh link --merge` records the boundary afterward, and the marker above names the exact command. The per-PR window opens at the previous recorded merge of the same branch, so a missing boundary widens the next window rather than losing spend.

## Privacy

No usage data leaves the machine. The only network reach is the rate-feed heal the pricing lib already makes (see [[Token Cost Readout]]) and the one `gh pr view` read at merge.

## Pairs with

- [[Cost Data Contract]]: the `cost.jsonl` schema this ledger leaves unchanged, and the source of the five-bucket `by_model` shape.
- [[Token Cost Readout]]: the pricing surfaces the readouts reuse and the roll-up printed after the per-PR block.
- [[Claude Hooks]]: `usage-capture.sh`, the merge hook, and the PR-create hook.
- [[Local Working State]]: where the stores and the research directory sit under `.gaia/local/`.
