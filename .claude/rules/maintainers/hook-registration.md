---
paths:
  - '.claude/hooks/**/*.sh'
  - '.claude/rules/**/*.md'
  - '.claude/settings.json'
---

# Hook and Rule Registration

Adding a `.sh` under `.claude/hooks/**`, a `.md` under `.claude/rules/**`, or a hook registration in `.claude/settings.json` carries obligations no diff line shows. Whole-set checkers enforce them in CI, outside the Quality Gate, so run each one that applies before opening the pull request. Rationale: `.claude/rules/file-placement.md` for hook state paths, [[Code Audit Team]] for tiers, [[Claude Hooks]] for jq, Monitor and rooting.

- **Hook state paths.** A hook reaches `.gaia/local` only by joining a root from `main-root-lib.sh` (or a caller-supplied root, in a lib under `.claude/hooks/lib/`), never by a bare literal: `bash .gaia/scripts/check-hook-scope-manifest.sh`.
- **Hook library tier.** A file under `.claude/hooks/lib/**` goes in exactly one tier. The usual answer is merely-shared, which needs no entry. Global is only for a library whose every change must reset every member's review anchor: add it to `AUDIT_GLOBAL_RULES_PATHS` in `.claude/hooks/lib/audit-rules-changed.sh`.
- **Rule tier.** A file under `.claude/rules/**` needs a tier the same way. Global is for rules that decide what the gate does with a clearance (`quality-gate.md` and `pr-merge.md`, the whole list); every other rule is merely-shared. The `member` tier matches only `.claude/agents/<member>.md`.
- **jq availability.** A `PreToolUse` hook that parses its payload with `jq` needs the jq-availability arm from `.claude/hooks/lib/jq-availability.sh`: `bash .gaia/scripts/lint-hook-jq-availability.sh`.
- **Monitor arming.** A `PreToolUse` registration whose matcher reaches `Bash` and whose hook can stop the call must also name `Monitor` in the matcher, and the hook's own `tool_name` test must admit it: `bash .gaia/scripts/lint-hook-monitor-arming.sh`.
- **Capabilities.** Every hook the `hooks` block registers needs an entry in `.gaia/hook-capabilities.json` declaring each capability it reaches for beyond itself, plus a `why`: `bash .gaia/scripts/check-hook-capabilities.sh`. It needs bash 5 and refuses without one; install one rather than reading a partial run.
- **Rooting.** Every `.claude/settings.json` command names its script as `"$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")/.claude/hooks/<name>.sh"`, with no leading interpreter word, since `bash ` reds the capability check as `BAD-REGISTRATION`: `bash .gaia/scripts/check-hook-command-rooting.sh .`. It does not read `.claude/settings.local.json`; hold local registrations to the same form by hand.
