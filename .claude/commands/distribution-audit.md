---
name: distribution-audit
description: Maintainer-only. Find every file that would newly ship to adopters, classify each one against the written distribution-boundary categories, default to withhold on no clean match, and ask the maintainer only where the taxonomy does not settle it. Drives the release CLI, which refuses to produce a manifest until every shipping file has an answer.
---

# /distribution-audit

Maintainer-only. Thin orchestrator over `.gaia/cli/gaia-maintainer`, which owns every deterministic step. This command supplies the one thing the CLI cannot: a classification of each newly-shipping file against the written distribution boundary, and a maintainer's answer on the few the taxonomy does not settle.

`.gaia/release-exclude` is the distribution boundary: a file ships to adopters if and only if git tracks it and no line in that file masks it. `.gaia/manifest.json` is the update policy `/update-gaia` consumes, and incidentally the ledger of which shipping files a maintainer has acknowledged. A file that git tracks, that no exclude line masks, and that the manifest does not yet list is "unanswered": it would ship, but nobody has said so on purpose.

## Step 1. Find the unanswered files

```bash
.gaia/cli/gaia-maintainer release manifest --check --json
```

`--check` is read-only. It exits non-zero whenever it finds any of six conditions, so capture stdout and parse it as JSON regardless of the exit code; a non-zero exit here is not a failure, it is the normal signal that something needs attention. The payload shape is:

```json
{"missing": [{"expected": "owned", "file": ".gaia/statusline/example.sh"}], "extra": [], "drift": [], "versionDrift": null, "classifierOverlaps": [], "scanScopeGaps": []}
```

`missing` is an array of objects, not of path strings: the path lives in `.file`, and `.expected` is the update class the classifier would assign. Extract paths with:

```bash
jq -r '.missing[].file'
```

Treating `missing`'s entries as if they were bare strings prints JSON blobs instead of paths and silently breaks Step 3's classification.

`missing` is not "everything that ships." Four paths, `.gaia/manifest.json`, `.gaia/VERSION`, `wiki/hot.md`, and `wiki/log.md`, are permanent adopter-owned fixtures that ship with baseline content but are never classified, so they never enter `missing` and this command never asks about them. That is correct, not a gap.

## Step 2. Decide which path applies

- **Nothing outstanding.** `missing` is empty and the other five conditions (`extra`, `drift`, `versionDrift`, `classifierOverlaps`, `scanScopeGaps`) are all empty: report that the boundary is current, write nothing, regenerate nothing, and stop. Regenerating here would rewrite the manifest's timestamp for no reason. `git status --porcelain` for `.gaia/manifest.json` and `.gaia/release-exclude` must stay empty.
- **Bookkeeping only.** `missing` is empty but at least one of the other five conditions is not: this is accounting drift, not a boundary question, nobody needs to decide whether a file ships. Name the condition(s) that fired and list their entries, then ask the maintainer via `AskUserQuestion` whether to regenerate now to absorb them. Do not regenerate unprompted.
- **Files await an answer.** `missing` is non-empty: continue to Step 3.

## Step 3. Classify against the categories, then ask only what needs asking

`.gaia/release-exclude` carries twelve numbered categories, each with a rationale paragraph, and `wiki/concepts/Release Workflow.md` (Distribution Boundary) opens by calling them authoritative. Most of `missing` is already answered there: category 3 settles a shipped script's verification rig in one line, category 4 settles everything under `.gaia/cli/src/`, category 1 settles the `/gaia-*` command split and names the adopter-useful exceptions.

So classify first and ask second. This is not "use judgment": it is matching each file against a written taxonomy and saying which entry it matched and why. A wrong decision then surfaces as a wrong **citation**, which a reader can check against the category's own text, instead of as a verdict they would have to re-derive from scratch.

### 3a. Classify every path

Read the categories out of `.gaia/release-exclude`: the number, the title, and the rationale paragraph under each header. The rationale is what a path is matched against; the title alone is not enough to match on.

Then record three things for each path in `missing`:

- the **decision**, ship or withhold;
- the **category** it matched, by number, or `none`;
- a **one-line reason** naming what in that category's rationale the path satisfies.

Match on the rationale a category states, never on the shape of a path's neighbours. "Its siblings are excluded" is a guess that looks like a match.

The categories are **exclusion** categories, so a match is a withhold and a ship has to come from somewhere else. Three arms, and every path takes exactly one:

- A category's rationale **covers** the path: **withhold**, citing that category.
- A category's rationale **exempts** the path: **ship**, citing that category and the clause that exempts it. Several categories carry such a clause, and it is written inside the rationale rather than beside the paths: a `DOES ship` note, or an "adopters receive only" sentence that names what the exclusion spares. Category 1's "Other `/gaia-*` commands (plan, handoff, pickup, audit) are adopter-useful and must NOT be added here" is the worked case. Read a category's whole rationale for such a clause before taking the first arm; a category that excludes a directory often ships something inside it.
- **No rationale reaches the path in either direction**: record `none`, and send it to 3b's first class, the genuinely novel one.

**A path in that third arm is recorded as a withhold**, and surfaced in 3b. It is never shipped on a silent default. The asymmetry is the whole reason:

- A wrong **ship** is corrected by an upstream deletion, and the Update Workflow's deletion table prompts the adopter rather than auto-deleting. One prompt on every adopter's next update, forever after it is noticed.
- A wrong **withhold** costs nothing. Ship it next release; it lands as an ordinary addition.

That default settles the **classification**, not the answer. It never becomes an answer on its own: a file whose question goes unanswered stays unanswered, and Step 4 cannot proceed for it.

Rule for this step:

- **Supply the classification, never the answer.** Every file gets a citation and a reason from this command; every question this command asks gets its answer from the maintainer. State no answer the maintainer has not actually given.

### 3b. Ask about three classes only

Ask the maintainer about these, and about nothing else:

1. **No category matched.** One question per file. This is the genuinely novel case, and the human gate belongs here.
2. **Two categories were close.** One question per file, naming both. Ask only when they point in different directions or rest on different rationales; two categories that withhold the same file for the same reason is not a question.
3. **Every ship.** Ships are the irreversible direction, so each is confirmed. Group them by shared rationale, one question per group, every file in the group named in the body.

A withhold that matched a category cleanly is not asked about. Its category and reason are recorded, and Step 4 lands them in `.gaia/release-exclude` where the diff carries them. This is what turns a forty-question pass into a handful of real ones, which is a thing a human can actually review.

When a maintainer answers "keep internal" for a file that matched **no** category, the CLI still needs a category number and rejects one that names no numbered category, so ask a follow-up offering the numbered list. If none of the twelve fits, the file stays unanswered: extending the taxonomy is a separate, deliberate edit to `.gaia/release-exclude` and this command does not make it.

### 3c. How every question is written

**Option order is fixed here, once, rather than chosen per question.** `AskUserQuestion`'s own contract assigns meaning to the first position: a recommended option goes first and carries `(Recommended)`. A prohibition on recommending that says nothing about order leaks through order, and a consistently-first "ship" reads as advice to any reasonable person. So:

- `Keep internal` is always the first option.
- `Ship to adopters` is always the second.

It leads because it is the reversible direction, which is a standing property of the two answers and not a judgment about any one file. Never append `(Recommended)` to either label, and state in the body of every question: *Neither option is recommended; the order is the same in every question this command asks.*

**Write the question in plain language.** The questions that survive 3b are the ones where the maintainer's judgment is actually needed, so they have to be answerable by someone who does not hold the repo's internals in their head. State the consequence for a real adopter, not the file's classification metadata.

Stop writing this:

> `.gaia/scripts/check-hook-scope-manifest.sh`: Check D, hook state-root conformance (INV-5). Siblings under `.gaia/scripts/` are mixed: 53 of 93 appear in `.gaia/manifest.json`. Ship (manifest entry, class `owned`) or withhold (category N)?

Write this:

> **`check-hook-scope-manifest.sh`** checks that every hook in `.claude/hooks/` reaches `.gaia/local` only through a resolved root, never a bare literal.
>
> **Keep it internal:** adopters never see it, and nothing in their project checks this.
> **Ship it:** adopters who add their own hook get a script that catches a hook building a `.gaia/local` path from a bare literal.

The rules:

- Lead with what the file does, in one sentence, carrying no internal identifiers: no check letters, no invariant numbers, no classifier class names, no category numbers.
- Say what an adopter gains or loses each way. That is the thing being decided.
- Name files by basename in the prose; keep the full path available, out of the sentence.
- Option labels are plain: `Keep internal` and `Ship to adopters`, never `withhold` and `ship`.
- Mention a category only when the maintainer needs it to answer, and then say what it means rather than citing its number alone.

This is the ordering leak one level up: a question that is hard to parse gets answered by position rather than on its merits. Plain language is part of what lets the gate go red.

### 3d. Record every decision, ship as well as withhold

A withhold's citation is durable already: Step 4's CLI writes its `--category` and `--reason` into `.gaia/release-exclude` as the comment above the path.

A ship has nowhere to go. `--ship <path>` carries no category and no reason, a manifest entry holds neither, and Step 4's CLI contract does not change. So record the ship side in the **body of the manifest-answer commit**, one line per shipped path:

```
ship <path> | considered category <N>, or none | <one-line reason it ships>
```

Step 4 makes that commit, out of the writes the CLI has just produced, so both halves of the decision set land together and one `git show` prints every ship line beside the `.gaia/release-exclude` diff holding every withhold's category and reason.

## Step 4. Apply every answer in one call

Once every path in `missing` has an answer, hand the whole set to the CLI in a single invocation:

```bash
.gaia/cli/gaia-maintainer release manifest \
  --ship <path> \
  --ship <path> \
  --withhold <path> --category <N> --reason "<one-line reason>"
```

`--ship <path>` repeats for each shipped answer. `--withhold <path>` opens a record that must be immediately closed by exactly one `--category <N>` and exactly one `--reason <text>` before the next `--withhold` or the end of the command. In the bookkeeping-only branch of Step 2, once the maintainer agreed to regenerate, call the same command with no `--ship` / `--withhold` flags at all.

The CLI snapshots the unanswered set once, validates the whole answer set against that snapshot, and only then writes: it appends the withheld entries to `.gaia/release-exclude` itself and regenerates the manifest. If it exits non-zero, surface its stderr verbatim and stop, do not retry with a different flag shape, and do not work around it by any other means.

The CLI is the sole writer of `.gaia/release-exclude`. This command never edits that file itself: no direct file write, no in-place edit, no shell redirect into it. Every withheld entry is written by the CLI's own answer machinery, which is the only place the literal-path rule is enforced and under test. If this command hand-edited the boundary instead, that rule would be enforced by nothing at all, no code would own the write, and it would be exactly the kind of unenforced promise this feature exists to eliminate.

Commit what the CLI wrote, `.gaia/manifest.json` plus any `.gaia/release-exclude` change, as the **manifest-answer commit**, carrying one ship line per shipped path in its body in the format 3d gives. Land it before starting a PR's Code Audit Team pre-merge audit handshake, not after; see `wiki/concepts/PR Merge Workflow.md` for why the ordering matters.

## What this command never does

- **Never take the CLI's undecided escape hatch.** That flag waives the answer requirement entirely and exists for the release path, where relitigating what a file is for is out of scope on release day. This command exists precisely to not take it.
- **Never regenerate through the command that cuts a release.** That command carries the escape hatch above by design; routing through it here is the same violation as using it directly, a single sentence pointing there would need no flag and no new file, so there is no reason to.
- **Never mutate the git index or the ignore file to change what the CLI sees.** The unanswered set comes from what git already tracks; changing that set to make the accounting trivially satisfiable defeats the point of asking.
- **Never use a manifest-write bypass marker.** This command needs none; the CLI's own gate is what stands between an unanswered file and a produced manifest, and nothing here should route around it.

## Coverage note

Step 3 still has no automated test: its actor is a conversation, and nothing can run a conversation as a unit test. What changed is that the prose is no longer the only thing standing behind it.

Every decision now carries a citation, so a wrong decision is a **wrong citation** rather than an unexaminable verdict, and checking one is bounded: read the named category's rationale in `.gaia/release-exclude` and compare it to the file. Nobody re-derives the decision from scratch. That is what the old gate asked for and never got, which is how months of first-option answers accumulated without anyone able to spot a bad one.

Both halves of the record land in the same commit (3d), and a later pass over the accumulated ledger reads that record rather than the files alone.

Prose remains the only enforcement for two things: that the questions in 3b get asked at all, and that they are written the way 3c requires. Follow it as written rather than treating it as a suggestion.

The clean-tree stop and the bookkeeping-only confirmation in Step 2 are unchanged, and have no automated test for the same reason.
