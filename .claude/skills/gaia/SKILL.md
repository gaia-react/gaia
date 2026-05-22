---
name: gaia
description: GAIA workflow router. Dispatches to the user-invoked GAIA workflows - plan (task orchestration), spec (Socratic SPEC artifact), handoff (session handoff doc), pickup (resume from handoff), audit (knowledge audit), forensics (bug report bridge), wiki (sync/consolidate/lint chain), fitness (Claude-integration health check + auto-heal). Trigger on `/gaia <subcommand>` or natural-language asks like "kick off a plan", "write a handoff", "pick up where we left off", "audit the knowledge stores", "sync the wiki", "check my Claude integration", "run a fitness check".
---

# GAIA Router

User-invoked GAIA workflows. The first argument selects the sub-command.

## Routing

Parse the first whitespace-separated token of `$ARGUMENTS`:

| First arg                        | Action                                        |
| -------------------------------- | --------------------------------------------- |
| `plan`                           | Read `references/plan.md` and follow it.      |
| `spec`                           | Read `references/spec.md` and follow it.      |
| `handoff`                        | Read `references/handoff.md` and follow it.   |
| `pickup`                         | Read `references/pickup.md` and follow it.    |
| `audit`                          | Read `references/audit.md` and follow it.     |
| `fitness`                        | Read `references/fitness.md` and follow it.   |
| `forensics`                      | Read `references/forensics.md` and follow it. |
| `wiki`                           | Read `references/wiki.md` and follow it.      |
| (anything else, including empty) | print help                                    |

Reference paths are relative to this skill (`.claude/skills/gaia/`). Strip the first arg before passing the remainder; inside the reference, `$ARGUMENTS` semantically refers to whatever followed the sub-command (e.g. `--apply` for audit, `sync` for wiki).

Help message format:

    Usage: /gaia <subcommand> [args]

      plan [description]   Plan a feature using task orchestration
      spec [description]        Socratic discovery to author an immutable SPEC artifact
      spec auto [description]   Non-interactive: agent answers Socratic questions, mirrors to GitHub issue, chains to /gaia plan
      handoff [notes]      Generate a session handoff document
      pickup               Restore context from the most recent handoff
      audit [--apply]      Audit memory + wiki and apply changes (--apply: re-apply existing report only)
      fitness              Check + auto-heal this project's Claude integration (triage/heal/verify, F-to-A+ grade)
      forensics [description]   Capture a redacted, classified, file-able bug report
      wiki [sync|consolidate|lint]   Wiki maintenance (full chain if no sub-arg)
