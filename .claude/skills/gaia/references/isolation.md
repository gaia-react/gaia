# Isolation: branch vs worktree

The shared branch-vs-worktree decision. Two callers read this file and apply it: `/gaia-plan` (through the
`ORCHESTRATOR.md` it generates) and `/gaia-debt`. This is the only definition of the decision order, the
prompt, and the worktree-creation call. No caller restates any of it.

## Slots the caller supplies

The caller's pointer binds four slots. There is no fifth.

| Slot | What it names | `/gaia-plan` | `/gaia-debt` |
|---|---|---|---|
| `{{SUBJECT}}` | the work being isolated | `this plan's work` | `this debt fix` |
| `{{WORKER}}` | who works in the current checkout | `the orchestrator` | `the fix` |
| `{{OWNER}}` | who owns the separate working copy | `this plan` | `this fix` |
| `{{SIBLING}}` | what else could run at the same time | `another plan` | `another task` |

Substitute every slot before any of this text reaches the user.

The **branch name** is the caller's, not this reference's. Each caller has its own naming convention and
this file never restates it: take the name the caller resolved.

## Decide, in this order

Walk the arms top to bottom and stop at the first one that matches. The order is load-bearing.

### Already inside a linked worktree

Detect it the way `.gaia/scripts/link-worktree.sh` does, by comparing the current toplevel against the
directory that holds the common git dir:

```bash
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$COMMON_DIR" in /*) ABS="$COMMON_DIR" ;; *) ABS="$PWD/$COMMON_DIR" ;; esac
MAIN_ROOT="$(cd "$(dirname "$ABS")" 2>/dev/null && pwd)"
CURRENT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
```

If `MAIN_ROOT` and `CURRENT_ROOT` differ, the session is already inside a linked worktree. **Stay in it**:
do not nest a second worktree inside it, and do not cut a branch. Set `RESOLVED_MODE=worktree` and skip
every arm below.

### HEAD is not on `main`/`master`

Forced worktree. Work already sitting on a branch must not get tangled with a second branch's work in one
checkout, so this is a correctness rule, not a preference. Do not offer the feature-branch-in-place option
and do not prompt: this arm never asks the user anything. State the reason to the user in one line, set
`RESOLVED_MODE=worktree`, and go straight to **Worktree creation** below.

### Policy read

Reserved. The team's isolation policy is read here: after the forced-worktree arm above, so no policy value
can reach an arm that is a correctness rule rather than a preference, and before the question below, so the
policy can steer it. Nothing is read today, and the question below always runs when HEAD is on
`main`/`master`.

### The isolation question

HEAD is on `main`/`master`, so the choice is genuinely open. Ask it with `AskUserQuestion`, using the
literals below verbatim (after slot substitution). Do not silently default: the prompt is the decision
point.

If the user picks **Other** with custom text, treat it as a request for an alternative isolation mode and
surface a clarifying question rather than guessing. Feature-branch and worktree are the two supported modes.

On the feature-branch answer, cut the branch of the caller's name from HEAD, work in the current checkout,
and set `RESOLVED_MODE=feature-branch`. On the worktree answer, set `RESOLVED_MODE=worktree` and go to
**Worktree creation** below.

#### The prompt literals

- question: `On main. How should {{SUBJECT}} be isolated?`
- header: `Branch mode`
- option `branch`, label: `Create a feature branch in place`
- option `branch`, description: `Default. Branch is cut from HEAD and {{WORKER}} works in the current checkout. Simple, predictable, safe.`
- option `worktree`, label: `Create a git worktree`
- option `worktree`, description: `Gives {{OWNER}} its own separate working copy, cut from main under .claude/worktrees/. You can keep working on your current branch, or run {{SIBLING}}, at the same time without the two colliding.`

#### Option order and the recommendation marker

- order: `branch`, `worktree`
- lead: `branch`

Present the options in `order`. Append the marker ` (Recommended)` to the **lead** option's label, and to
no other option's. This is the one and only site that applies the marker; it is never baked into a label
literal, so which option leads can change without editing a literal.

## Worktree creation

Create the worktree with the runtime tool, passing the caller's branch name as the worktree name:

```
EnterWorktree({name: "<branch-name>"})
```

The `WorktreeCreate` hook (`.gaia/scripts/create-worktree.sh`) owns creation: it cuts a new branch of that
name fresh from the remote default branch (`main`), else local HEAD, lands it under
`.claude/worktrees/<branch-name>/`, and switches the session into it. The branch is already cut, so the
caller runs no manual `git checkout -b`. Everything the caller does after this point runs from inside the
worktree.

## Export: `RESOLVED_MODE`

This reference exports the isolation mode it resolved as `RESOLVED_MODE`, with exactly two values:

| `RESOLVED_MODE` | Meaning |
|---|---|
| `feature-branch` | the branch is cut from HEAD and the caller works in the current checkout |
| `worktree` | the caller works inside a linked worktree under `.claude/worktrees/` |

Every arm above sets it, including the two that never prompt, so it is always defined by the time the caller
resumes. A caller that has no use for it ignores it.
