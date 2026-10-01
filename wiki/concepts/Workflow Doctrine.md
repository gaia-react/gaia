---
type: concept
status: active
created: 2026-10-01
updated: 2026-10-01
tags: [concept, claude, workflow, doctrine]
---

# Workflow Doctrine

The workflow doctrine is one set of working rules for GAIA sessions, split into two halves by the moment each applies. [`.claude/rules/context-discipline.md`](../../.claude/rules/context-discipline.md) is the always-loaded half: a short, mode-neutral rule about keeping the main thread lean, fanning reads out, choosing models by fit, and keeping research output small. [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md) is the execution half: it is never auto-loaded, and a hook injects it verbatim the moment a session is on a working branch or in a linked worktree. This page holds the reasoning and the depth behind both.

The halves are split because guidance about executing biases a session toward action. In a discussion that bias is the reactivity failure the project CLAUDE.md names under "Before responding": a stimulus becomes a response before the stimulus is characterized. So a discussion session carries only context discipline, and execution doctrine arrives only when a branch exists, which is the signal that the work has moved from deciding to doing.

## Roles

The doctrine names four roles because each failure it guards against has a different owner. Read-only advisors investigate and write plan JSON, so wide reading never lands in the thread that has to decide. The main thread decides, because decisions need the whole picture and the user. Executors edit files and nothing else: a sub-agent that stages or commits works from a partial view, and several executors share one working tree, so one stray state-changing git command silently discards a sibling's edits. A verifier checks executor output against the plan JSON before the gate, so the gate runs once on work already known to match intent, not as a repair loop.

The main thread alone owns git that changes state, and runs the Quality Gate once per commit. Running it per executor multiplies a slow gate by the number of dispatches and checks half-built states nobody will commit. The operative wording lives in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md). When a running command defines its own contract, such as a plan orchestrator's per-phase commits or a debt fix's inline flow, that contract governs where it differs from the doctrine.

## Inline floor

Delegation has a fixed cost: a brief to write, a result to read back, and a context the sub-agent does not share. Small work, tightly iterative edit-run-fix work, and anything that needs the user stay on the main thread because the cost exceeds the gain. Two platform limits make this a floor, not a preference: a sub-agent cannot prompt the user, and it cannot spawn further sub-agents, so delegation is depth-1 and a task that needs a question answered cannot be pushed down.

## Model table

Models are ranked by fit to the task class. Cost is a secondary note, never the selector: choosing by price alone trades quality for a saving the measurements show is small.

| Task class | Model | Why it fits | Cost note |
| --- | --- | --- | --- |
| sweep | Sonnet | Wide reads and mechanical extraction return a small result; reasoning depth adds little. | Cache reads are about 97.5% of debt-run tokens and are priced the same on both top models, so moving a whole run to the cheaper model saves at most about a quarter. The smaller model's cache-read price is derived from the rate table, not measured. |
| scoped implementation | Sonnet | A bounded change with a written plan and a verifier behind it; the plan carries the judgment. | Same cache-read dominance as the sweep row; the saving is bounded by it. |
| synthesis | Opus (Fable as the named alternative) | Wording, positioning, and design decisions where one weak choice propagates into everything after it. | Priced at the top-model rates. Cache reads dominate here too, so the cost difference never outranks fit. |

The table is the only text edited when a model ships, for the doctrine sources (the rule, `.claude/doctrine/execution.md`, and this page). Command-level pins, meaning the planner picker and the executor pin in the `/gaia-plan` command and the agent definitions' frontmatter, are separate sites that follow the table when it changes.

## Run folder and checkpoint

Each branch gets one folder under `.gaia/local/runs/<key>/`, with the `branch:` prefix of the usage key dropped. One folder per key keeps two branches from clobbering each other's state, and the key is derived from the branch, so a returning session finds its own folder without being told where it is.

`STATE.md` is small and rewritten in place because append-only state files grew past any context window: a checkpoint that has to be read to be trusted must stay cheap to read. It records what is known, what each dispatch was expected to return, and one next step. Each dispatch writes one JSON artifact with its expected count recorded in `STATE.md`, so a missing or truncated artifact is detectable by counting rather than by guessing. `log.md` is append-only and never read on resume: it is a trace for a human, and loading it would reintroduce the growth the checkpoint exists to avoid. The operative layout is in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md), and the registry entry for the folder is in `.gaia/state-registry.json`.

## Resume

A resumed session reads `STATE.md` and the artifact listing and nothing else. The checkpoint says where the run stands, and the listing says which dispatches finished, so the two together answer "what next" without replaying the history that produced them. Reading more than that spends the context the run folder was built to protect. The steps are in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md).

## Concurrency limits

Every worktree shares one `.gaia/local`, which resolves into the main checkout. That is why run folders are keyed by branch and never shared between keys, and why research binding works through a Write made to the main checkout's absolute path and not through a path relative to the worktree.

The injection hook decides from the session's own tree. Two spellings therefore do not trigger injection: `git -C <path>` aimed at another tree, and `git worktree add` followed by `cd`. Entering a worktree through EnterWorktree does trigger it, because that tool reports the tree the session now works in.

## Initiative linking

A branch's spend is tied to the initiative it serves with `bash .gaia/scripts/usage.sh link branch:<normalized> research:<topic>-<date>`, or with `issue:<n>` when an issue is the anchor. The link is made once per branch. Issue edges the branch name already derives need no link: `debt/<n>` and the `(fix|feat|chore|docs|refactor)/<n>-` forms. The key line the hook injects carries the concrete command for the current key. See [[Usage Ledger]].

## Research attribution

A research Write binds to its initiative only when it is made with the Write tool to the main checkout's absolute `.gaia/local/research/<topic>-<date>/...` path. A worktree-relative path or a symlinked path does not bind. Research done with Edit or Bash binds with `bash .gaia/scripts/usage.sh declare research:<topic>-<date>`. A binding re-keys only `session:` spend, so spend already attributed to a branch or an issue stays where it is. The research ref is the full folder name, date included.

## Injection hook

`.claude/hooks/workflow-doctrine-inject.sh` injects the execution doctrine through `hookSpecificOutput.additionalContext`. It fires at SessionStart for all four sources (`startup`, `resume`, `clear`, `compact`), after EnterWorktree, and after a Bash call that runs `git checkout`, `git switch`, or `gh pr checkout`. For Bash the command only decides whether to look; the decision is the branch checked out afterwards, in the session's own tree. The hook registrations are described in [[Claude Hooks]].

A per-session marker holds the last injected key. `startup` and PostToolUse skip when the key is unchanged, `compact` and `clear` re-inject because the context they follow is gone, and a new key injects. A resumed session always re-injects, because the platform replays injected text but does not guarantee a resumed session still holds it. The hook fails open: any error, a missing or oversized doctrine file, or a CI environment produces no output and exit 0. The key line is omitted, never rewritten, when a branch name falls outside the ledger's ref grammar. Without jq only SessionStart injects and no marker is kept.

What the platform documents, as current behavior: `startup`, `resume`, `clear`, and `compact` are all SessionStart sources, and compaction fires SessionStart. PostToolUse `additionalContext` is documented generally, but the documentation does not state it for Bash or EnterWorktree specifically, so the mid-session triggers are best-effort and the SessionStart triggers are the guaranteed path. Injected text is saved in the transcript and replayed on resume; whether a resumed session keeps its `session_id` is not documented, which is why resume always re-injects.

<!-- gaia:maintainer-only:start -->

## Measurements

Re-measured with `bash .gaia/tests/hooks/workflow-doctrine-timing.sh`.

| Metric | Value | Budget |
| --- | --- | --- |
| p50 SessionStart, default branch | 31.6 ms | 50 ms |
| p50 SessionStart, working branch | 40.2 ms | 50 ms |
| p50 PostToolUse Bash, non-arming | 25.1 ms | 50 ms |
| p50 PostToolUse Bash, arming | 46.9 ms | 50 ms |
| Injected bytes | 3,084 | 4,096 |
| Injected tokens (bytes / 4) | 771 | none |
| Payload with a 128-character branch | 3,314 bytes | 4,096 |
| Rule bytes | 542 | 1,200 |
| Rule tokens (bytes / 4) | 135 | none |
| Per-session hook cost estimate | 843.4 ms | none |
| Unattributed tokens at landing | 1,084,636,989 | none |
| All-segment tokens at landing | 11,655,381,581 | none |
| Unattributed share at landing | 0.093059 (about 9.3%) | none |

The per-session estimate uses the median session's 32 Bash calls and 0 compactions. The unattributed and all-segment totals are the cumulative figures `bash .gaia/scripts/usage.sh reconcile` prints at landing; the success check below forms a delta against them.

## Post-landing success check

The check asks two things: did `/gaia-debt` per-run cost hold, and did the main thread's dollar share fall. It runs maintainer-side, outside bats and CI.

### Baseline

The frozen baseline is `.gaia/local/research/debt-model-routing-2026-09-30/joined.json`. It covers `/gaia-debt` runs for pull requests through #2370, with difficulty taken from the closing issues' labels as they stood when the snapshot was taken. Each run is repriced at the synthesis row's rates, per million tokens: input $4, output $20, cache read $0.20, 5-minute cache write $5, 1-hour cache write $8. The command reads only the snapshot:

```bash
SNAP="$(bash .gaia/scripts/main-root-lib.sh)/.gaia/local/research/debt-model-routing-2026-09-30/joined.json"
jq -r 'def med: sort | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
  "runs \(length)", (group_by(.d)[] | "\(.[0].d) n=\(length) median_usd=\([.[].op] | med * 100 | round / 100) main_share=\([.[].cost_main] | med * 1000 | round / 10)%")' "$SNAP"
```

It prints `runs 310`, then `easy n=84 median_usd=7.21 main_share=70.6%`, `hard n=70 median_usd=16.99 main_share=64.5%`, and `medium n=156 median_usd=11.62 main_share=64.9%`. The main-thread share ranges from 64.5% to 70.6% by difficulty, 65% to 71% rounded.

### Unattributed share

`usage.sh reconcile` has no window flag, so a delta between two cumulative readings stands in for a window. Read it again later and compare the delta share with the landing share (1,084,636,989 and 11,655,381,581 from Measurements). The share fell when the delta share is below the landing share:

```bash
bash .gaia/scripts/usage.sh reconcile | awk -v ul=1084636989 -v al=11655381581 '
  /unattributed:/ { gsub(",", "", $3); u = $3 }
  /all segments:/ { gsub(",", "", $4); a = $4 }
  END { printf "delta_share %.6f landing_share %.6f\n", (u - ul) / (a - al), ul / al }'
```

### Post-landing verdict

One instrument decides it: the `/gaia-debt` records in `cost.jsonl` (`kind == "command"`, `command == "gaia-debt"`, `github.type == "pr"`) with `ts` at or after the window start. The window start is derived at run time as the commit that added this page, never a hard-coded date. Each record becomes a row by the same rules the baseline used, because the snapshot's derivation script is not kept:

1. Records with no pull request are dropped.
2. The pull request's closing issues come from `gh pr view <n> --json closingIssuesReferences`; a pull request with no closing issue is dropped.
3. Difficulty is read from each closing issue's `difficulty:<easy|medium|hard>` label. A pull request whose issues carry none is dropped, and a batch takes the maximum by rank easy < medium < hard.
4. `op`, the repriced run dollars, sums `fresh_input`, `output`, `cache_read`, `cache_write_5m`, and `cache_write_1h` across every `by_agent_type` entry, at $4, $20, $0.20, $5, and $8 per million tokens.
5. `cost_main` is the `main` entry's buckets priced the same way, divided by `op` (0 when `op` is 0).
6. Medians per difficulty are the middle value, or the mean of the two middle values for an even count, of `op` and of `cost_main`.

```bash
ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
LEDGER="$ROOT/.gaia/local/telemetry/cost.jsonl"
START="$(TZ=UTC git -C "$ROOT" log --diff-filter=A --date='format-local:%Y-%m-%dT%H:%M:%SZ' --format=%cd -- 'wiki/concepts/Workflow Doctrine.md' | tail -1)"
OUT="$(mktemp -d)"
jq -c --arg s "$START" 'select(.kind == "command" and .command == "gaia-debt" and .github.type == "pr" and .ts >= $s)' "$LEDGER" > "$OUT/records.jsonl"
jq -r '.github.number' "$OUT/records.jsonl" | sort -un | while read -r n; do
  d="$(gh pr view "$n" --repo gaia-react/gaia --json closingIssuesReferences --jq '.closingIssuesReferences[].number' \
    | while read -r i; do gh issue view "$i" --repo gaia-react/gaia --json labels --jq '.labels[].name'; done \
    | sed -n 's/^difficulty://p' \
    | awk 'BEGIN { r["easy"] = 1; r["medium"] = 2; r["hard"] = 3 } r[$1] > m { m = r[$1]; d = $1 } END { print d }')"
  [ -n "$d" ] && printf '%s %s\n' "$n" "$d"
done > "$OUT/grades.txt"
jq -rs --rawfile g "$OUT/grades.txt" '
  def price: ((.fresh_input // 0) * 4 + (.output // 0) * 20 + (.cache_read // 0) * 0.2
    + (.cache_write_5m // 0) * 5 + (.cache_write_1h // 0) * 8) / 1000000;
  def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
  ($g | split("\n") | map(select(length > 0) | split(" ") | {key: .[0], value: .[1]}) | from_entries) as $d
  | map(select($d[.github.number | tostring] != null)
      | ([.by_agent_type[] | price] | add // 0) as $op
      | {d: $d[.github.number | tostring], op: $op,
         cost_main: (if $op == 0 then 0 else ((.by_agent_type.main // {}) | price) / $op end)})
  | "graded \(length)",
    (group_by(.d)[] | "\(.[0].d) n=\(length) median_usd=\([.[].op] | med * 100 | round / 100) main_share=\([.[].cost_main] | med * 1000 | round / 10)%")' "$OUT/records.jsonl"
```

A verdict needs at least 30 graded runs with at least 8 in each difficulty; below that, report "not yet". Cost held when each difficulty's post median `op` is at most 1.10 times its baseline median. The main-thread share fell when each difficulty's post median `cost_main` is below its baseline. For a supplementary dollars-per-pull-request reading, `bash .gaia/scripts/usage.sh pr <n>` prints it; it does not decide the verdict.
<!-- gaia:maintainer-only:end -->

## See also

- [[Task Orchestration]]: the plan-specific case of this doctrine.
- [[Usage Ledger]]: the keys, links, and attribution the run folder and research rules rely on.
- [[Claude Hooks]]: how the injection hook is registered.
- [[Quality Gate]]: the gate the main thread runs once per commit.
- [[GAIA Plan]]: the command that applies the doctrine to a planned run.
