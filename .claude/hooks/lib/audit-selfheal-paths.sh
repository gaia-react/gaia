#!/usr/bin/env bash
# audit-selfheal-paths.sh: the one self-heal refusal set for the Code Audit
# Team's repair boundary. Sourced, never executed; does no work at source
# time.
#
# Exports exactly one thing: AUDIT_SELFHEAL_REFUSE_ERE, an anchored ERE
# matching every path a self-healing member must never touch -- the tests
# that would catch its own bad repair, the CI pipeline, the gate machinery
# and roster under .gaia/, the instruction/convention surfaces, and
# root-level build/lint/test/typecheck configuration. A repair reaching any
# of these is confined by a deterministic gate, not by an instruction alone,
# whether or not the member was told not to.
#
# "The tests" is EVERY test surface, not just test/. .playwright/ holds the
# e2e specs, the a11y assertions, and the react-perf harness. .storybook/
# holds no stories (they sit beside their components under app/**/tests/) but
# its config and decorators shape what Chromatic snapshots, and Chromatic is
# a required merge check -- a member that may edit them may suppress the
# visual regression its own repair caused. Both are refused whole, the same
# way test/ is refused whole rather than narrowed to its assertion files: the
# cost of over-refusing is that a member reports a finding instead of
# repairing it, and the cost of under-refusing is a silently weakened gate.
#
# .gaia/local/ is deliberately NOT refused. It is the members' own gitignored
# working and output directory -- clearance markers, findings sidecars,
# disposition sidecars, the re-run ledger -- not gate-machinery source. A
# member writing there is emitting its own audit record, not repairing a
# tracked file, and being gitignored it never appears in the CI push gate's
# diff, so the carve-out is a no-op on that consumer and only frees the local
# hook's per-attempt check. Refusing it would block the very sidecars this
# team writes and, via the disposition backstop, deadlock the merge gate.
# Everything else under .gaia/ (including a sibling like .gaia/localfoo/)
# stays refused.
#
# TWO consumers read this ERE. Neither writes a second copy of it, and a
# reader who finds one must not assume it is the only one:
#   - the CI producer's push gate, the "Commit and push self-heal" step of
#     .github/workflows/code-review-audit.yml (and its rendered template
#     mirror, .gaia/cli/templates/workflows/code-review-audit.yml.tmpl)
# gaia:maintainer-only:start
#     -- the maintainer source repo also carries the build source this
#     template is generated from,
#     .gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl
# gaia:maintainer-only:end
#   - the local producer's PreToolUse hook,
#     .claude/hooks/block-selfheal-paths.sh
#
# The BUILD-CONFIG half of this ERE is the workflow's own `has_source` file
# pattern (code-review-audit.yml's "Detect in-scope source changes" step),
# reused verbatim, so the two sets can never drift apart. It is the third,
# fourth and fifth alternatives below (`package.json` / lockfile / workspace,
# `tsconfig*.json`, root `*.config.*`).
#
# The ROOT-TOOLING half, the last alternative, is deliberately NOT part of that
# mirror, and the asymmetry is the point. `has_source` decides whether an audit
# RUNS; this ERE decides what a running member may REPAIR. The seven files below
# are granted to `code-audit-frontend`, the roster's only `push_fixes: true`
# member, so a diff touching one of them dispatches the member that could then
# rewrite it in its own self-heal commit. Each decides what the gates check
# rather than what the app does: `.lintstagedrc.json` is the command
# `.husky/pre-commit` runs through `pnpm exec lint-staged`, so a member free to
# edit it can narrow the Quality Gate floor in the same commit as its repair;
# `.npmrc` is the registry and install policy; `.prettierignore` decides what
# formatting skips; `Dockerfile` builds the image; `.env.example` is the
# environment contract; `.nvmrc` and `.node-version` decide the Node that CI and
# local must agree on. Every SIBLING root config the same member owns is already
# refused by the mirrored half, so refusing these restores the consistency the
# grant broke rather than inventing a new rule. Adding them to `has_source`
# instead would change when the audit runs, which is a different question.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

# shellcheck disable=SC2034 # consumed by both sourcing consumers named above
AUDIT_SELFHEAL_REFUSE_ERE='^(\.claude|\.specify|wiki|test|\.playwright|\.storybook|\.github/workflows)/|^\.gaia/(local[^/]|loca[^l]|loc[^a]|lo[^c]|l[^o]|[^l])|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$|^tsconfig[^/]*\.json$|^[^/]*\.config\.(ts|mts|mjs|cjs|js)$|^(\.npmrc|\.lintstagedrc\.json|\.prettierignore|Dockerfile|\.env\.example|\.nvmrc|\.node-version)$'
