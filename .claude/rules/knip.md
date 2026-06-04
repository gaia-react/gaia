# Knip — Dead Code Detection

`pnpm knip` reports unused files, exports, types, and dependencies. Configured at `knip.config.ts`.

Auto-runs pre-merge inside the `code-review-audit` agent (parallel with `react-doctor`). Suggest running manually after a refactor that removes/restructures modules, deletion of a feature, replacing a dependency, or before a release-candidate PR. Do **not** run mid-task or as part of the Quality Gate — in-progress exports flag as false positives.

## Reference

Bucket recipe + acting-on-output: `.claude/agents/code-review-audit.md` (Knip findings). Docs: https://knip.dev.

See also `.claude/rules/dep-audit.md`: the sibling advisory-tool pointer rule for the `pnpm audit` dependency-CVE oracle.
