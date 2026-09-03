---
paths:
  - '.claude/hooks/**/*.sh'
  - '.claude/rules/**/*.md'
  - '.claude/settings.json'
---

# Hook and Rule Registration

Adding a `.sh` file under `.claude/hooks/**`, adding a `.md` file under `.claude/rules/**`, or registering a hook in `.claude/settings.json` carries registration obligations that no line of the diff shows. Whole-set checkers enforce them in CI, and none of them belongs to the Quality Gate or any agent's stated oracle set, so a change can pass every local check and every audit round and red afterward on a file nobody was told to touch.

## Rule

**Every `.sh` under `.claude/hooks/**` needs an entry in `.gaia/hook-scopes.json`.** The entry declares the tree the hook's state belongs to (`scope`: `main-only`, `per-tree`, or `any`), its `state` tokens, and a `why`. A missing entry fails the manifest's coverage assertion:

```bash
bash .gaia/scripts/check-hook-scope-manifest.sh
```

**A file under `.claude/hooks/lib/**` additionally needs a tier.** That prefix is gate machinery, and every machinery file must land in exactly one tier of the reset-predicate partition. Two of the three tiers are reachable for a hook library:

- **merely-shared**, the ordinary answer: add the path to `AUDIT_MERELY_SHARED_PATHS` in `.gaia/scripts/audit-rules-changed-complete.sh`.
- **global**, only for a library whose every change must reset every member's incremental review anchor: add it to `AUDIT_GLOBAL_RULES_PATHS` in `.claude/hooks/lib/audit-rules-changed.sh` **and** to the lockstep `GLOBAL_RULES_FILES` copy in `.gaia/scripts/audit-rules-changed-complete.sh`. Edit both by hand rather than leaning on the check to catch a half-edit: the lockstep assertion reds when the list names a path the predicate does not match, but not the reverse, so adding to the predicate alone reports green and leaves the copy silently drifted. Choose this tier deliberately: a merely-shared library mis-tiered as global discards every member's anchor on every later change to it.

**A file under `.claude/rules/**` needs a tier for the same reason.** That prefix is machinery too, so a new rule file lands in the same partition, and the same two tiers are reachable. Answer it the way the tier's generating rule reads: global is for scope and belief, never for criteria. A rule that decides what the gate does with a clearance is global (`quality-gate.md` and `pr-merge.md` are the two, and they are the whole list); a rule that decides how code should be written is a coding convention and is merely-shared, which is the answer for nearly every rule file. Getting this wrong toward global is what makes a one-word convention edit re-scope every dispatched member.

The third tier, `member`, matches only `.claude/agents/<member>.md` and never applies to a hook or a rule. A file in no tier fails the partition assertion:

```bash
bash .gaia/scripts/audit-rules-changed-complete.sh
```

Run both before opening the pull request. The second walks tracked files, so `git add` the new file first or it reports green on one it cannot see. The first walks the directory itself and catches an untracked hook either way.

## Capability obligation

**Every hook the `hooks` block of `.claude/settings.json` registers needs an entry in `.gaia/hook-capabilities.json`.** The entry declares every capability the hook reaches for beyond itself and a `why`. The obligated set is derived from the registration at run time, so a newly registered hook carries a new obligation the moment it is registered, with no second list to remember to edit. A registration with no entry, an entry no registration names, and two entries naming one hook are each a finding:

```bash
bash .gaia/scripts/check-hook-capabilities.sh
```

The same check also finds a registration whose command names a `.sh` path in a form it cannot reduce to a repo-relative path, or names no shell script at all; the fix is rewriting the registration to name a script file in the rooted form below.

## Rooting obligation

**Every command in `.claude/settings.json` must name its script by a path that resolves independently of the shell's working directory.** `/bin/sh` runs the command string against the Bash tool's working directory, which persists for the whole session, so a bare relative registration is unfindable after a single `cd`: the script exits 127, 127 neither blocks nor is reported, and the guard layer fails open silently (#1740). Naming a script file is therefore necessary but **not** sufficient, and this is the half a reader of the previous section would otherwise get wrong.

The sanctioned form, which resolves to the current tree at any depth inside the repository:

```
bash "$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")/.claude/hooks/<name>.sh"
```

`$CLAUDE_PROJECT_DIR` is deliberately the fallback and not the root: it holds the session's original project directory and does not follow entry into a linked worktree, so using it alone would make a worktree session run the main checkout's hooks.

```bash
bash .gaia/scripts/check-hook-command-rooting.sh .
```

It runs inside `.gaia/tests/whole-tree-invariants.sh`, so an unrooted registration reds there too. It reads `.claude/settings.json` only; `.claude/settings.local.json` is a live registration layer that no tracked check can hold, so hold your own local registrations to the same form by hand.

It needs bash 5. On stock macOS `/bin/bash`, which is 3.2, the closure walk loses whole files' records and reports a clean tree as `SURPLUS`, and the reach it drops can never surface as `UNDECLARED`. The check re-execs itself under a Homebrew bash 5 when it finds one and refuses with a message when it does not, so this command cannot quietly disagree with CI; if it refuses, install a bash 5 rather than reading the run that got that far.

`.gaia/hook-scopes.json` and `.gaia/hook-capabilities.json` cover different sets and declare different things. `.gaia/hook-scopes.json` covers every `.sh` under `.claude/hooks/**` and declares which tree the hook's state belongs to. `.gaia/hook-capabilities.json` covers only the registered hooks and declares what the hook reaches for beyond itself. Neither manifest derives its coverage from the other.

The check catches these at review time; nothing mediates a registered hook at run time.

## Why

The defect is an *absence* rather than a diff line. No reviewer reading the change can see a manifest entry that was never written, and only a checker enumerating the whole directory can. Nothing in the change under review hints that either obligation exists, so the miss survives per-phase gates and pre-merge audit rounds alike and surfaces only in CI, costing a full round plus a re-audit of every dispatched member once the repair commit moves HEAD.

Guards of that shape need an instruction surface pointing at them, which is what this rule is.
