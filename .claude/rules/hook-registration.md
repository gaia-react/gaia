---
paths:
  - '.claude/hooks/**/*.sh'
---

# Hook Registration

Adding a `.sh` file under `.claude/hooks/**` carries registration obligations that no line of the diff shows. Whole-directory checkers enforce them in CI, and neither checker is part of the Quality Gate or any agent's stated oracle set, so a change can pass every local check and every audit round and red afterward on a file nobody was told to touch.

## Rule

**Every `.sh` under `.claude/hooks/**` needs an entry in `.gaia/hook-scopes.json`.** The entry declares the tree the hook's state belongs to (`scope`: `main-only`, `per-tree`, or `any`), its `state` tokens, and a `why`. A missing entry fails the manifest's coverage assertion:

```bash
bash .gaia/scripts/check-hook-scope-manifest.sh
```

**A file under `.claude/hooks/lib/**` additionally needs a tier.** That prefix is gate machinery, so every file in it must be classified global, member, or merely-shared in `.claude/hooks/lib/audit-rules-changed.sh`. An unclassified file fails the partition assertion:

```bash
bash .gaia/scripts/audit-rules-changed-complete.sh
```

Run both before opening the pull request. The second one walks tracked files, so `git add` the new hook first or it reports green on a file it cannot see. The first one walks the directory itself and catches an untracked file either way.

## Why

The defect is an *absence* rather than a diff line. No reviewer reading the change can see a manifest entry that was never written, and only a checker enumerating the whole directory can. Nothing in the change under review hints that either obligation exists, so the miss survives per-phase gates and pre-merge audit rounds alike and surfaces only in CI, costing a full round plus a re-audit of every dispatched member once the repair commit moves HEAD.

Guards of that shape need an instruction surface pointing at them, which is what this rule is.
