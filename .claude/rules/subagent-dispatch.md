# Subagent Dispatch

When a dispatched agent's output is something you will act on, do not ask for it in the reply.

**Give it a file.** Pre-clear an output path (`rm -f`), instruct the agent to write its full result there and return only a thin digest, then classify the file after the dispatch:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <path> \
  [--report-key <key>] [--expect-count <n> | --min-count <n>]
```

Exit 0 is a real result, 1 is a no-op, 2 is a usage error. On a no-op, re-dispatch **exactly once** against the re-cleared path; on a second no-op, do the work inline rather than proceeding as though the agent found nothing.

**Assert your own denominator.** Pass `--expect-count` (or `--min-count`) whenever you know how many entries the report should hold. Existence-plus-parses is not enough on its own: a truncated write parses fine and reads as a real result, which reproduces the same collapse inside a file that exists.

**Poll the file, not the notification.** Because the artifact is on disk, read it on your own schedule instead of blocking on a completion signal that may never arrive.

`.claude/skills/gaia/references/spec.md` step 7a is the worked reference for the whole contract, including the hardened retry prefix. Read it there rather than reconstructing it from here.

## Why

An absent report is indistinguishable from a clean result. A caller that dispatched three agents and received nothing knows something broke; a caller that dispatched eight and silently lost one does not, and the likeliest reading of the gap is "that agent found nothing" — the one conclusion the caller must not draw. The failure is biased toward false confidence, which is why the fallback is an artifact on disk rather than a more carefully worded prompt.

The flows that already do this get it from their own step-level instructions, so a dispatch composed on the fly inherits none of it. That is the case this rule covers, and it is why the rule carries no `paths:` glob: the decision is made while composing a dispatch, which no file edit announces, so a path-scoped rule would be absent from context at exactly the moment it is needed.
