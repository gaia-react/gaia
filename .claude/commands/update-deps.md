---
name: update-deps
description: Deprecated alias for /sharpen. Prints a one-line deprecation notice and dispatches to /sharpen. Hard-cut on the next minor release.
---

This command is the deprecation alias for `/sharpen`. Adopters with `/update-deps` muscle memory land here; the assistant prints a deprecation line and dispatches to the renamed skill.

Print the following line to the user, exactly as written:

> Renamed to `/sharpen` — dispatching there now.

Then invoke the `sharpen` skill via the Skill tool with no arguments. Let the skill run end-to-end. Do NOT duplicate any of its phases (override audit, outdated discovery, waves, quality gate) here — the skill owns all of that.

This alias is kept for one minor release window so existing adopters' muscle memory keeps working, then is hard-cut on the next minor GAIA release.
