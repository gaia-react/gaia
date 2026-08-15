# Subagent Dispatch

When a dispatched agent's output is something you will act on, do not ask for it in the reply. An absent report is indistinguishable from a clean result, and the likeliest reading of a missing one is "it found nothing", the conclusion you must not draw.

**Give it a file.** Pre-clear an output path (`rm -f`), have the agent write its result there and return only a thin digest, then classify the file:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <path> \
  [--report-key <key>] [--expect-count <n> | --min-count <n>]
```

Exit 0 real, 1 no-op, 2 usage error. On a no-op, re-dispatch **exactly once** against the re-cleared path; on a second, do the work inline.

**Pass a count when you know one.** A truncated write parses fine and reads as a real result, so existence-plus-parses alone reproduces the same collapse inside a file that exists.

**Poll the file, not the notification.** The artifact is on disk, so never block on a completion signal that may not arrive. Tear down each watch you arm the moment you hold its artifact: a report you end up reading somewhere else leaves the loop with no exit condition left to satisfy, and it spins until a human notices.

Full contract, including the hardened retry prefix: the `No-op guard` section of `.claude/skills/gaia/references/spec.md`. This rule is deliberately not path-scoped; the decision happens while composing a dispatch, which no file edit announces.
