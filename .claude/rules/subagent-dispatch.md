# Subagent Dispatch

When a dispatched agent's output is something you will act on, do not ask for it in the reply. An absent report is indistinguishable from a clean result, and the likeliest reading of a missing one is "it found nothing", the conclusion you must not draw.

**Give it a file.** Pre-clear an output path (`rm -f`), have the agent write its result there and return only a thin digest, then classify the file:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <path> \
  [--report-key <key>] [--expect-count <n> | --min-count <n>]
```

Exit 0 real, 1 no-op, 2 usage error. On a no-op, re-dispatch **exactly once** against the re-cleared path; on a second, do the work inline.

**Pass a count when you know one.** A truncated write parses fine and reads as a real result, so existence-plus-parses alone reproduces the same collapse inside a file that exists.

**Poll the file, not the notification.** The artifact is on disk, so never block on a completion signal that may not arrive. Tear down each watch you arm the moment you hold its artifact: a report you end up reading somewhere else leaves the loop with no exit condition left to satisfy.

**Never classify at the moment the dispatch call returns.** An `Agent` call returns dispatch metadata immediately, before the agent has done anything, and the tool exposes no parameter that holds it open until the agent finishes. Classifying there hands the guard an empty path, reads a no-op on a dispatch that is still running correctly, and spends the one hardened re-dispatch on it. This is why the rule above is *poll the artifact*: the artifact's appearance is the completion signal, and it is the only one that cannot arrive early.

**Where a caller cannot name the path in advance, have the classifier resolve it.** A path a caller writes down before dispatch is a prediction, and a prediction about a key that moves is wrong from the round it moves onward. The pre-merge audit gate is the worked example: its findings sidecar keys on a base that advances every cleared round, so it passes `--findings-root` plus a wave stamp and lets `audit-noop-detect.sh` find the newest matching artifact (`wiki/concepts/PR Merge Workflow.md`, "No-op detection and retry for each dispatched member"). Pre-clearing a path is still right where the path is genuinely fixed, which is the `agent-report-file` case above.

Full contract, including the hardened retry prefix: the `No-op guard` section of `.claude/skills/gaia/references/spec.md`. Path-scoping this rule would break it: the decision happens while composing a dispatch, which no file edit announces.
