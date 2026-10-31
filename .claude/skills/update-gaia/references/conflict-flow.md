# update-gaia: conflict flow

The orchestrator reads this file at the "Conflict flow" step of `../SKILL.md`, after Step 4b, and follows it in full: dispatch, report check, judgment chunks, clean merges, questions, applied answers with the decision log, and the follow-ups. "The stop rule" below is the one in `../SKILL.md` Step 4, on Proceed. This file ends when the decisions are recorded and the follow-ups are done; `../SKILL.md` then continues at Step 9b.

Contents:

- Model selection and dispatch
- Questions
- Apply answers and record decisions
- Follow-ups

## Model selection and dispatch

From here on every command runs with the working directory at the acting tree. Scripts are called at `<main checkout path>/.gaia/scripts/`, because the merge walk may rewrite or remove the acting tree's copies and the orchestrator keeps following the text it already read. `<run dir>` is the typed literal `<main checkout path>/.gaia/local/cache/shared/update-gaia/run`; it sits under `.gaia/local`, so from a worktree every write to it goes through Bash, never Edit or Write.

Choose the model for the execution agent:

- Compare `LATEST` major vs `BASELINE` major (leading integer).
- **Major bump** → spawn an **Opus agent** (`model: "opus"`).
- **Minor or patch bump** → spawn a **Sonnet agent** (`model: "sonnet"`).
- Either way, pass no `effort` parameter: the agent runs at the session effort. Every judgment-only agent below takes the same model.

### Prepare the run directory

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-report.sh prepare --run-dir <main checkout path>/.gaia/local/cache/shared/update-gaia/run
```

It prints `PREPARED <path>` and leaves an empty run directory holding `candidates/` and `instructions/`; the report path, `<run dir>/report.json`, is clear. Any other result stops per the stop rule. This is the only `prepare` of the run: a re-dispatch clears single files instead, because `prepare` would delete the snapshot, the chunk lists and the candidates.

### Snapshot the instructions

Copy exactly these three files from the acting tree into the snapshot, one plain command each:

```bash
cp <acting tree>/.claude/skills/update-gaia/references/merge-execution.md <run dir>/instructions/merge-execution.md
```

```bash
cp <acting tree>/.claude/skills/update-gaia/references/merge-generated.md <run dir>/instructions/merge-generated.md
```

```bash
cp <acting tree>/.claude/skills/update-gaia/references/merge-report.md <run dir>/instructions/merge-report.md
```

The walk can overwrite the acting tree's copies partway through; every agent, and the inline fallback, reads the snapshot instead. A failed copy stops per the stop rule. Now read `<run dir>/instructions/merge-report.md` yourself, in full: it is the report contract every step below reads.

### Count the expected entries and split the judgment work

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-report.sh expect-count --baseline-dir <BASELINE_DIR> --latest-dir <LATEST_DIR> --decisions <acting tree>/.gaia/update-decisions.json
```

Persist the one integer as `<n>`, never a count made by hand. It is the size of the expected set: one `files[]` entry per path in keys(baseline manifest `.files`) ∪ keys(latest manifest `.files`) ∪ the path of every `deferred` decision-log entry. Exit 1 (a manifest does not parse) stops per the stop rule.

Then split the files both sides changed into chunks, adding one `--extra <tag>=<path>` per `EXTRA_DIR=<tag>:<path>` line:

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-report.sh chunk --tree <acting tree> --baseline-dir <BASELINE_DIR> --latest-dir <LATEST_DIR> --decisions <acting tree>/.gaia/update-decisions.json --run-dir <run dir> --size 25
```

It prints `CHUNKS <k> <total>` and writes `chunk-1.txt` to `chunk-<k>.txt` into the run directory. The size is 25 because each judged file needs both diffs read (baseline to the adopter's copy, baseline to GAIA's), and 25 keeps one agent well inside its context. When `<k>` is 0 or 1 one agent judges everything; when it is 2 or more, the execution agent judges chunk 1 and a judgment-only agent judges each later chunk.

### Dispatch the execution agent

Spawn the agent for Steps 6 to 9. Its prompt passes `BASELINE`, `LATEST`, `LATEST_TAG`, `BASELINE_TAG`, `BASELINE_DIR`, `LATEST_DIR`, every `EXTRA_DIR=<tag>:<path>` line as printed, the acting tree's absolute path, `<run dir>`, the decision log `<acting tree>/.gaia/update-decisions.json`, the CHANGELOG range file `.gaia/local/cache/shared/update-gaia/<LATEST_TAG>/changelog-range.md`, and, when `<k>` is 2 or more, `<run dir>/chunk-1.txt` as the only paths it judges. The prompt tells it:

- the acting tree is its working root: every path in the instructions is relative to it, and it runs nothing against any other checkout;
- to read `<run dir>/instructions/merge-execution.md`, `<run dir>/instructions/merge-generated.md` and `<run dir>/instructions/merge-report.md` in full before Step 6 (in chunks if the Read tool refuses the size, but every chunk before Step 6), and follow them exactly;
- that the report is a JSON file at `<run dir>/report.json`, an object whose `files` key is an array, written with Bash; that it asks the user nothing; and that it returns only a thin digest (counts per status, the open item count, the report path), never a summary table.

### Classify the report

Poll the report file rather than the agent's reply, and never classify at the moment the Agent call returns: the call returns dispatch metadata before the agent has done anything. Once the agent has finished:

```bash
bash <main checkout path>/.gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <run dir>/report.json --report-key files --expect-count <n>
```

Exit 0 is a real report. Exit 2 is a usage error in the call itself: fix the call and classify again. Exit 1 is a no-op: clear only the report, keeping `instructions/`, the chunk lists and `candidates/`,

```bash
rm -f <run dir>/report.json
```

then re-dispatch exactly once with the same prompt and classify the same way. A second consecutive no-op means the orchestrator runs the merge inline itself, reading the three snapshot files and following them as the agent would, writing the same report, and continues as if the agent had returned it. Neither the re-dispatch nor the inline merge resets the acting tree: the walk converges on a partially walked tree, since each write reads as already applied on a re-run.

### Judgment chunks

Only when `<k>` is 2 or more. For each later chunk `<c>` (2 to `<k>`), clear its output first:

```bash
rm -f <run dir>/judgment-<c>.json
```

Then dispatch a judgment-only agent, same model, the chunk agents in parallel with each other. Its prompt passes the execution agent's inputs plus `<run dir>/chunk-<c>.txt` as the only paths it judges, and tells it: read the three snapshot files in full and follow the snapshot `merge-execution.md`'s judgment-only agent section; write `<run dir>/judgment-<c>.json` with Bash as a top-level JSON array holding one entry per path in its chunk; write each clean merge to its `candidates/<path>.auto` file; never write the acting tree; ask nothing; return only a thin digest. Classify it once it has finished, with `<m>` the line count `wc -l <run dir>/chunk-<c>.txt` prints and no `--report-key`, since the file is a top-level array:

```bash
bash <main checkout path>/.gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <run dir>/judgment-<c>.json --expect-count <m>
```

The same rule applies: exit 1 clears only that file with `rm -f <run dir>/judgment-<c>.json` and re-dispatches exactly once; a second consecutive no-op means the orchestrator judges that chunk inline. Then fold every chunk's judgments into the report, naming each `judgment-<c>.json` after `--judgment`:

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-report.sh merge-judgments --report <run dir>/report.json --judgment <run dir>/judgment-2.json
```

It prints `MERGED <n>`; exit 1 stops per the stop rule.

### Validate and copy clean merges

Nothing from the run directory reaches the acting tree until the report validates:

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-report.sh validate --final --report <run dir>/report.json --run-dir <run dir> --baseline-dir <BASELINE_DIR> --latest-dir <LATEST_DIR> --decisions <acting tree>/.gaia/update-decisions.json
```

`REPORT_OK <n>`: continue. `REPORT_INVALID schemaVersion must be 1` is a report written against a different contract (for example by an agent from another release on a resume): clear `<run dir>/report.json` and each `<run dir>/judgment-<c>.json` with `rm -f`, run the merge inline once as above, judging every chunk, and validate again. Any other `REPORT_INVALID` line, or a second failure after the inline merge, stops: relay the lines, print the worktree notice on a worktree run, and copy nothing.

Then copy the clean merges a judgment-only agent wrote as candidates:

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-report.sh apply-auto --report <run dir>/report.json --run-dir <run dir> --tree <acting tree>
```

It prints `APPLIED_AUTO <n>`; exit 1 (a candidate escapes the run directory) stops per the stop rule before anything else is copied.

## Questions

Every `open` entry's `items` is a question for the user, and so is each conflict item of a `field-aware` entry. Ask every one, up to four per `AskUserQuestion` call; none is skipped and none is answered for the user. Until an answer is applied, the adopter's file stays exactly as the merge left it.

- **Options** follow the item's `options` array in order. The first is the recommended one: append " (Recommended)" to its label, and put the item's `reason` in its description when the recommendation is not obvious. A `combine` option's `preview` holds the combined lines from its candidate (its `preview` field, or the candidate file's content).
- **Wording.** A content item reads: `<path>: you changed <adopterChange>. GAIA <LATEST> changed <gaiaChange> because <changelogReason, or "no CHANGELOG entry names this file">. Combine them?` An item whose recommended option is not `combine` (a removal, a version pin, a field conflict, a class fallback) ends with its recommended action as a question instead ("Use 5.4.2, the higher version?", "Remove it?", "Keep yours?"). A field item names its `key` after the path. A same-concern item whose adopter's version covers more adds its `suggestion` line.
- **Earlier decisions.** An item with `earlierDecision` `{tag, decision}` starts with one context sentence, the tag's leading `v` dropped: for `keep`, "In 2.0.4 you kept yours over GAIA's; GAIA <LATEST> revised it again: <gaiaChange>."; for `blend`, "In 2.0.4 you combined yours with GAIA's; GAIA <LATEST> revised it again: <gaiaChange>."
- **A dismissed question is Decide later.** So is any question left unanswered when the user ends the prompt. A typed answer that names no option is discussed and that item asked again.

## Apply answers and record decisions

Apply each answer in the acting tree; every candidate path was validated inside the run directory before this point.

- **A candidate option** (`combine`, `gaia` and `higher` on a whole-file item): copy the candidate over the path, `cp <run dir>/candidates/<path>.<option id> <acting tree>/<path>`, one plain command per answer.
- **A field item** (`higher`, `gaia` or `keep` on a `field-aware` entry): write the option's `value` to the item's `key` with the Edit tool, preserving the file's formatting. `keep` leaves the file as it is.
- **Settings file**: when the path is `.claude/settings.json`, the `cp` or the Edit asks the human first, because GAIA guards that file in every permission mode. That prompt is expected: approve it when it is the answer just chosen. An unattended run cannot write the file through those routes.
- **Remove**: back the file up into the report's `backupDir` first (`mkdir -p <acting tree>/<backupDir>/<parent directory of path>`, then `cp <acting tree>/<path> <acting tree>/<backupDir>/<path>`), then `rm <acting tree>/<path>`.
- **Keep mine and Decide later**: leave the file unchanged.

Then bring the decision log in line with the tree, dropping entries whose file or key is back in line with GAIA's copy:

```bash
bash <main checkout path>/.gaia/scripts/update-decisions.sh reconcile --file <acting tree>/.gaia/update-decisions.json --tree <acting tree> --latest-dir <LATEST_DIR> --report <run dir>/report.json --latest-tag <LATEST_TAG>
```

A deferred path this run resolved without a question is rebased to the latest tag (`REBASED <path>[#<key>] <latest tag>`), so it stops pulling its old bundle. Then record one decision per answered item, as its own call:

```bash
bash <main checkout path>/.gaia/scripts/update-decisions.sh record --file <acting tree>/.gaia/update-decisions.json --path <path> --key <key> --decision <decision> --tag <LATEST_TAG> --baseline-tag <baselineTag>
```

`<decision>` is the chosen option's own `decision` from the report (Combine `blend`; Keep mine `keep`; Take GAIA's and Remove `gaia`; Higher `gaia` or `keep` by whose value it is; Decide later `deferred`), and `deferred` for a dismissed question. `--key` is the item's `key`, left out for a whole-file item; `<baselineTag>` is the file entry's `baselineTag`. Each call prints `RECORDED <path>[#<key>] <decision>`; `RECORD_REFUSED <error>` (exit 1) is relayed and stops per the stop rule. Both commands are idempotent, so a resumed run repeats them safely.

## Follow-ups

Run these in this order, each by rule, never as a question.

**Lockfile.** Decide the command from the answered tree:

```bash
<LATEST_DIR>/.gaia/cli/gaia update lockfile-command --root <acting tree>
```

`dedupe` runs `pnpm -C <acting tree> dedupe` once (an overrides, allowBuilds or resolution-setting change, where `pnpm install` would report "Already up to date" and leave the lockfile behind); `install` runs `pnpm -C <acting tree> install` once (a dependency or `packageManager` change); `none` runs nothing. A failed pnpm command is reported in the summary and the run continues to the gate, which shows what it broke.

**Regions.** When the report's `regions.unregeneratedPaths` names a path an answer resolved, or `regions.regen` skipped a region because of one, regenerate the declared regions with the `regen-regions` call `merge-generated.md` describes, resolved by merge-execution.md's command-resolution rules: the CLI from `<LATEST_DIR>`, the tree under `--root`. Pass no `--conflicted` flag for a path now resolved; a path still deferred keeps its `--conflicted <path>`, and a path the report lists as `removed` keeps its `--absent-path <path>`:

```bash
<LATEST_DIR>/.gaia/cli/gaia update regen-regions --manifest <LATEST_DIR>/.gaia/manifest.json --root <acting tree> --backup-dir <backupDir> --json
```

A failed or refused regeneration never fails the update; the summary names its command as a follow-up.

**Settings.** When an answer resolved `.claude/settings.json`, or the report's `settings.state` is not `regenerated`, run `./.gaia/cli/gaia packages sync-settings` and then `bash .gaia/scripts/check-settings-drift.sh` in the acting tree. Never hand-edit the regenerated `frontend/.claude/settings.json`.
