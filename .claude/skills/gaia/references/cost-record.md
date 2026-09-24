# Cost record (run end), shared tally machinery

Shared token-tally machinery for the interactive GAIA command skills. A skill applies it from its own `## Cost record (run end)` section, substituting `{{COMMAND}}` with the command name (e.g. `gaia-debt`, `gaia-harden`). The skill keeps its own `## Cost record (run end)` heading and its run-ending-paths bullets inline (those are command-specific and anchor the `(Run ends here; see \`## Cost record (run end)\`.)` callbacks); this reference owns only the tally call and the reporting rules below.

Standalone final step, one call:

```bash
bash .gaia/scripts/token-tally.sh --action command --command {{COMMAND}}
```

**Artifact pass-through.** When this run opened a pull request and the URL `gh pr create` printed appeared in this run's own Bash tool result, append:

```bash
  --github-type pr --github-number <N> --github-repo '<owner>/<name>'
```

Never look the number up (`gh pr list`, `gh pr view`), never reuse a number from an earlier run, a different branch, or a `gh` command run outside this workflow, and never guess. If this run did not itself print a creation URL, pass no `--github-*` flags at all; the record correctly carries no artifact, and that is not an error.

**Report the line verbatim.** The tally prints exactly one line on stdout, e.g. `Cost: ~5.2M tokens, $4.12, 6m39s`. Relay it as the last line of the run's report; do not reassemble, reformat, or re-derive it.

The tally never blocks, never fails, and never turns a failed run into a successful one: it runs as a bare call with no exit-status ceremony around it. On a path that ends in an error (a rejected push, a blocked merge), record the cost, then report the failure exactly as before; recording the cost never implies success.
