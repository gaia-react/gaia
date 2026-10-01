#!/usr/bin/env bash
# audit-selfheal-paths.sh: the one self-heal refusal set for the Code Audit
# Team's repair boundary. Sourced, never executed; does no work at source
# time.
#
# Exports exactly one thing: AUDIT_SELFHEAL_REFUSE_ERE, an anchored ERE
# matching every path a self-healing member must never touch -- the tests
# that would catch its own bad repair, the whole .github/ tree, the gate
# machinery and roster under .gaia/, the instruction/convention surfaces, and
# root-level build/lint/test/typecheck configuration. A repair reaching any
# of these is confined by the member's instructions and by the orchestrator
# owning every commit, not by a deterministic gate (see the note below on who
# reads this set).
#
# .github/ is refused WHOLE, not narrowed to .github/workflows/. The workflow
# YAML is not the only thing there that decides a gate outcome:
# .github/audit/ holds the base-resolution executables the audit and CI
# scripts run to decide what a diff covers, and a member that can edit one of
# them can change what the gate reviews. .github/ carries no legitimate
# self-heal target to trade away for that -- a member repairs app source, and
# every other .github/ resident (the composite actions, the forensics triage
# scripts, CODEOWNERS, the issue and PR templates) decides what CI does rather
# than what the app does. Refusing the tree whole also covers a sibling
# directory added later on the day it lands, instead of on the day an audit
# notices it.
#
# "The tests" is EVERY test surface, not just test/. .playwright/ holds the
# e2e specs, the a11y assertions, and the react-perf harness. .storybook/
# holds the config and decorators that shape what Chromatic snapshots, and
# Chromatic is a required merge check -- a member that may edit them may
# suppress the visual regression its own repair caused. Both are refused
# whole, the same way test/ is refused whole rather than narrowed to its
# assertion files: the cost of over-refusing is that a member reports a
# finding instead of repairing it, and the cost of under-refusing is a
# silently weakened gate.
#
# The rest of that surface sits INSIDE app/, and app/ cannot be refused by a
# top-level prefix the way the trees above are: it is code-audit-frontend's
# own repair surface and has to stay repairable. So this half is refused per
# shape, and each shape is taken from the collector that decides what gates a
# merge rather than from the directory convention, because a collector keying
# on a suffix reaches a file the convention does not put in a tests/ folder:
#
#   app/**/*.test.ts, app/**/*.test.tsx -- vitest.config.ts `test.include`
#   app/**/*.stories.tsx                -- .storybook/main.ts `stories`, the
#                                          glob Chromatic snapshots
#
# A tests/ directory anywhere under app/ is refused whole on top of those,
# carrying test/'s own reason: a fixture or a shared helper beside the
# assertions weakens the suite as surely as the assertions do. Without this
# half a member can delete the vitest suite and the story that would catch
# its own bad app/ repair in the same self-heal commit, which is the exact
# failure the paragraph above refuses .storybook/ and test/ to prevent.
#
# `app/**/*.stories.ts` is deliberately NOT refused: the Storybook glob is
# .tsx only, so a file by that name snapshots nothing and gates nothing.
#
# .gaia/local/ is deliberately NOT refused. It is the members' own gitignored
# working and output directory -- clearance markers, findings sidecars,
# the re-run ledger -- not gate-machinery source. A
# member writing there is emitting its own audit record, not repairing a
# tracked file, and being gitignored it never appears in any diff. Refusing it
# would block the very sidecars this team writes.
# Everything else under .gaia/ (including a sibling like .gaia/localfoo/)
# stays refused.
#
# No script sources this ERE today: it is the one written refusal set the
# self-healing member's instructions cite (code-audit-frontend names it as the
# repair boundary), and nobody writes a second copy of it.
#
# The BUILD-CONFIG half of this ERE is the `package.json` / lockfile /
# workspace, `tsconfig*.json`, and root `*.config.*` alternatives below, plus
# the root-tooling alternative after them. Naming them rather than their
# positions is what survives an arm being inserted ahead of them, which is how
# a reader verifying the no-drift contract ends up counting to the wrong
# alternative.
#
# The ROOT-TOOLING half, the `.npmrc` / `.lintstagedrc.json` / `.prettierignore`
# / `Dockerfile` / `.dockerignore` / `.env.example` / `.nvmrc` / `.node-version`
# alternative, is refused for this reason: the files below are granted to
# `code-audit-frontend`, the roster's only `push_fixes: true` member, so a diff
# touching one of them dispatches the member that could then rewrite it in its
# own self-heal commit.
# Each decides what the gates check rather than what the app does:
# `.lintstagedrc.json` is the command `.husky/pre-commit` runs through `pnpm
# exec lint-staged`, so a member free to edit it can narrow the Quality Gate
# floor in the same commit as its repair; `.npmrc` is the registry and install
# policy; `.prettierignore` decides what formatting skips; `Dockerfile` builds
# the image and `.dockerignore` decides what its build context carries;
# `.env.example` is the environment contract; `.nvmrc` and
# `.node-version` decide the Node that CI and local must agree on. Every SIBLING
# root config the same member owns is already refused by the mirrored half, so
# refusing these restores the consistency the grant broke rather than inventing
# a new rule.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

# shellcheck disable=SC2034 # read by whoever sources this file
AUDIT_SELFHEAL_REFUSE_ERE='^(\.claude|\.specify|wiki|test|\.playwright|\.storybook|\.github)/|^app/(.*/)?tests/|^app/.*\.test\.tsx?$|^app/.*\.stories\.tsx$|^\.gaia/(local[^/]|loca[^l]|loc[^a]|lo[^c]|l[^o]|[^l])|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$|^tsconfig[^/]*\.json$|^[^/]*\.config\.(ts|mts|mjs|cjs|js)$|^(\.npmrc|\.lintstagedrc\.json|\.prettierignore|Dockerfile|\.dockerignore|\.env\.example|\.nvmrc|\.node-version)$'
