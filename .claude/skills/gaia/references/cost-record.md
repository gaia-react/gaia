# Cost record (run end), shared tally machinery

Shared token-tally machinery for the interactive GAIA command skills. A skill applies it from its own `## Cost record (run end)` section, substituting `{{COMMAND}}` with the command name (e.g. `gaia-debt`, `gaia-harden`). The skill keeps its own `## Cost record (run end)` heading and its run-ending-paths bullets inline (those are command-specific and anchor the `(Run ends here; see \`## Cost record (run end)\`.)` callbacks); this reference owns only the tally call and the reporting rules below.

Standalone final step, one call:

```bash
bash .gaia/scripts/token-tally.sh --action command --command {{COMMAND}}
```

**Capture the branch before cleanup; tally after it.** Left to itself, the tally reads the run's branch from whatever checkout it runs in, and every step that moves HEAD (`git checkout main`) or leaves the working copy (`ExitWorktree`) changes that answer. Both isolation modes prescribe such a step on the merge path, so a tally run after cleanup attributes the run to what the cleanup left behind, usually `main`, and a wrong branch is indistinguishable from a right one in the ledger. The tally cannot simply move ahead of cleanup either: from inside a worktree session the Claude Code runtime refuses this call outright, and after cleanup it runs in the main checkout, where that refusal does not apply.

So on any path that cleans up, before the first cleanup step, run `git branch --show-current` as its own plain call and keep the literal branch name it prints. Clean up, then run the tally as the run's last step with that literal appended:

```bash
  --branch-name '<branch>'
```

The tally records the passed branch instead of resolving one. Write the name out as a literal, never as `$(git branch --show-current)` or a shell variable: keep the call a single plain command. On a path that cleans up nothing, or when the capture printed nothing, pass no `--branch-name`; the tally's own lookup answers for the tree the work is in.

**Artifact pass-through.** When this run opened a pull request and the URL `gh pr create` printed appeared in this run's own Bash tool result, append:

```bash
  --github-type pr --github-number <N> --github-repo '<owner>/<name>'
```

Never look the number up (`gh pr list`, `gh pr view`), never reuse a number from an earlier run, a different branch, or a `gh` command run outside this workflow, and never guess. If this run did not itself print a creation URL, pass no `--github-*` flags at all; the record correctly carries no artifact, and that is not an error.

**Report the line verbatim.** The tally prints exactly one line on stdout, e.g. `Cost: ~5.2M tokens, $4.12, 6m39s`. Relay it as the last line of the run's report; do not reassemble, reformat, or re-derive it.

The tally never blocks, never fails, and never turns a failed run into a successful one: it runs as a bare call with no exit-status ceremony around it. On a path that ends in an error (a rejected push, a blocked merge), record the cost, then report the failure exactly as before; recording the cost never implies success.
