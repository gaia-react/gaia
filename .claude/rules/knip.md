# Knip, Dead Code Detection

`pnpm knip` reports unused files, exports, types, and dependencies. Config, when-to-run guidance, and acting-on-output buckets: `wiki/dependencies/knip.md`.

Auto-runs pre-merge inside the `code-audit-frontend` agent (parallel with `react-doctor`). Do **not** run mid-task or as part of the Quality Gate, in-progress exports flag as false positives.

## Reference

Bucket recipe + acting-on-output (optional deep-dive): `.claude/agents/code-audit-frontend.md` (Knip findings). Docs: https://knip.dev.

Sibling advisory rule: `.claude/rules/dep-audit.md`
