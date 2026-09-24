# Subagent Dispatch

When a dispatched agent's output is something you will act on, do not ask for it in the reply: an absent report reads as "it found nothing", the conclusion you must not draw.

**Give it a file, and say in the dispatch prompt that the file is JSON.** Pre-clear the output path (`rm -f`), have the agent write its result there and return only a thin digest, then classify the file. The artifact must be a JSON **array**, either the top-level value or the value at the one top-level key `--report-key` names; a Markdown or plain-text report classifies NO-OP however complete it is.

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <path> \
  [--report-key <key>] [--expect-count <n> | --min-count <n>]
```

Exit 0 real, 1 no-op, 2 usage error. **Pass a count when you know one**: a truncated write parses fine and reads as real otherwise. On a no-op, re-dispatch **exactly once** against the re-cleared path; a second consecutive no-op means doing the work inline yourself and applying the result as if the agent had returned it.

**Poll the file, not the notification**, and **never classify at the moment the dispatch call returns**: the `Agent` call returns dispatch metadata immediately, before the agent has done anything, so classifying there reads a no-op on a dispatch still running correctly and spends the one hardened re-dispatch on it.

Full contract for this shape, including the moving-path (--findings-root) case and what the terminal action is: the `No-op guard against silent subagents` section of `wiki/concepts/Code Review Audit Agent.md`.
