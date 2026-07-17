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
#     .github/workflows/code-review-audit.yml (and its two template mirrors,
#     .gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl
#     and .gaia/cli/templates/workflows/code-review-audit.yml.tmpl)
#   - the local producer's PreToolUse hook,
#     .claude/hooks/block-selfheal-paths.sh
#
# The root-config half of this ERE is the workflow's own `has_source` file
# pattern (code-review-audit.yml's "Detect in-scope source changes" step),
# reused verbatim, so the two sets can never drift apart.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

# shellcheck disable=SC2034 # consumed by both sourcing consumers named above
AUDIT_SELFHEAL_REFUSE_ERE='^(\.claude|\.specify|wiki|test|\.github/workflows)/|^\.gaia/(local[^/]|loca[^l]|loc[^a]|lo[^c]|l[^o]|[^l])|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$|^tsconfig[^/]*\.json$|^[^/]*\.config\.(ts|mts|mjs|cjs|js)$'
