# Cost record (run end), shared record recipe

Shared run-end cost record for the interactive GAIA command skills. A skill applies it from its own `## Cost record (run end)` section, substituting `{{COMMAND}}` with the command name (e.g. `gaia-debt`, `gaia-harden`). The skill keeps its own `## Cost record (run end)` heading and its run-ending-paths bullets inline (those are command-specific and anchor the `(Run ends here; see \`## Cost record (run end)\`.)` callbacks); this reference owns only the record call and the reporting rules below.

Standalone final step, one call:

```bash
bash .gaia/scripts/usage.sh record command:{{COMMAND}} --workflow {{COMMAND}}
```

**Artifact pass-through.** When this run opened a pull request and the URL `gh pr create` printed appeared in this run's own Bash tool result, and the pull request is on the current repo, append:

```bash
  --pr <N>
```

Never look the number up (`gh pr list`, `gh pr view`), never reuse a number from an earlier run, a different branch, or a `gh` command run outside this workflow, and never guess. A ref carries no repo, so pass `--pr` only for a pull request on the current repo. If this run did not itself print a creation URL, pass no `--pr` at all; the record correctly carries no artifact, and that is not an error.

**Report the line verbatim.** On exit 0 the last stdout line is the Cost line, e.g. `Cost: ~5.2M tokens, $4.12, 6m39s`. Relay it as the last line of the run's report; do not reassemble, reformat, or re-derive it. On a non-zero exit nothing was recorded and no Cost line prints: relay the one stderr line in its place.

The record never blocks and never turns a failed run into a successful one: a non-zero exit is reported, not retried, and does not change the run's outcome. On a path that ends in an error (a rejected push, a blocked merge), record the cost, then report the failure exactly as before; recording the cost never implies success.
