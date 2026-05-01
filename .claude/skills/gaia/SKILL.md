---
name: gaia
description: GAIA workflow router. Dispatches to the four user-invoked GAIA workflows - plan (task orchestration), handoff (session handoff doc), pickup (resume from handoff), audit (knowledge audit). Trigger on `/gaia <subcommand>` or natural-language asks like "kick off a plan", "write a handoff", "pick up where we left off", "audit the knowledge stores".
---

# GAIA Router

User-invoked GAIA workflows. The first argument selects the sub-command.

## Routing

Parse the first whitespace-separated token of `$ARGUMENTS`:

| First arg                        | Action                                      |
| -------------------------------- | ------------------------------------------- |
| `plan`                           | Read `references/plan.md` and follow it.    |
| `handoff`                        | Read `references/handoff.md` and follow it. |
| `pickup`                         | Read `references/pickup.md` and follow it.  |
| `audit`                          | Read `references/audit.md` and follow it.   |
| (anything else, including empty) | print help                                  |

Reference paths are relative to this skill (`.claude/skills/gaia/`). Strip the first arg before passing the remainder; inside the reference, `$ARGUMENTS` semantically refers to whatever followed the sub-command (e.g. `--apply` for audit).

Help message format:

    Usage: /gaia <subcommand> [args]

      plan [description]   Plan a feature using task orchestration
      handoff [notes]      Generate a session handoff document
      pickup               Restore context from the most recent handoff
      audit [--apply]      Audit memory + wiki for duplication and load cost
