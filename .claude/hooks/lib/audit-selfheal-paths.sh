#!/usr/bin/env bash
# audit-selfheal-paths.sh: the one self-heal refusal set for the Code Audit
# Team's repair boundary. Sourced, never executed; does no work at source
# time except one load: sourcing reads the package registry and descriptors
# (`gaia-packages.sh`) to build the package arms; see the next block.
#
# Exports two things: AUDIT_SELFHEAL_REFUSE_ERE, an anchored ERE
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
#   app/**/*.test.ts, app/**/*.test.tsx -- the `node` and `browser` projects'
#                                          `include` in vitest.config.ts
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
# The ROOT-TOOLING half, the `.npmrc` / `.prettierignore` / `.nvmrc` /
# `.node-version` alternative, is refused for this reason: the files below are
# granted to `code-audit-frontend`, the roster's only `push_fixes: true` member,
# so a diff touching one of them dispatches the member that could then rewrite
# it in its own self-heal commit.
# Each decides what the gates check rather than what the app does: `.npmrc` is
# the registry and install policy; `.prettierignore` decides what formatting
# skips; `.nvmrc` and `.node-version` decide the Node that CI and local must
# agree on. Every SIBLING root config the same member owns is already refused
# by the mirrored half, so refusing these restores the consistency the grant
# broke rather than inventing a new rule. The package's own copies of the
# frontend-only files (`frontend/.lintstagedrc.json`, `frontend/Dockerfile`,
# `frontend/Dockerfile.dockerignore`, `frontend/.env.example`) are refused by
# the package arms below.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

#
# THE PACKAGE ARMS. The app's own paths (test/, .playwright/, .storybook/,
# and the app/ shapes described above) are not literals here any more: they
# are the `selfHealRefuse` globs of each registered package's descriptor
# (`<package path>/gaia.package.json`, registry `.gaia/packages.json`), joined
# with the package path, so after the move `frontend/app/x.test.ts` and
# `frontend/vite.config.ts` are refused and a retired root `app/x.test.ts` is
# not. The descriptor set is ADDED to the root arms and never replaces one.
# The root arms add `.gaia/packages.json` so a member cannot rewrite the
# registry that scopes its own refusals. Every sentence above that says `test/`, `.playwright/`,
# `.storybook/` or `app/` describes the package arms.
#
# The sourced repo root is the one three directories above this file
# (`.claude/hooks/lib/`), never the launch directory: `CLAUDE_PROJECT_DIR` is
# the launch dir, which is `frontend/` for a package launch.
#
# FAIL CLOSED. A malformed registry, an invalid or missing descriptor, or
# a missing jq makes the ERE `.` (refuse every path) and sets
# AUDIT_SELFHEAL_PACKAGES_ERROR to the one-line `gaia-packages:` message, so a
# consumer can say why every path was refused. On success the variable is empty.
# An absent registry is the built-in default (frontend at `frontend/`), never
# "nothing refused".
#
# Consumers read the variable and never source this file for anything else.
# `code-audit-frontend` names the ERE as its repair boundary and
# `code-audit-github-workflows` repeats it; no script enforces it.
#
# Bash 3.2 compatible (macOS default). Never `cd` in a caller; the one `cd`
# below runs in a command substitution to resolve this file's own directory.

_audit_selfheal_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_audit_selfheal_dir/gaia-packages.sh"

# shellcheck disable=SC2034 # read by whoever sources this file
AUDIT_SELFHEAL_PACKAGES_ERROR=''
# shellcheck disable=SC2034 # read by whoever sources this file
AUDIT_SELFHEAL_REFUSE_ERE=''

# shellcheck disable=SC2034 # both variables are read by whoever sources this file
_audit_selfheal_build() {
  local root_arms status=0 package_arm
  root_arms='^(\.claude|\.specify|wiki|\.github)/|^\.gaia/(local[^/]|loca[^l]|loc[^a]|lo[^c]|l[^o]|[^l])|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$|^tsconfig[^/]*\.json$|^[^/]*\.config\.(ts|mts|mjs|cjs|js)$|^(\.npmrc|\.prettierignore|\.nvmrc|\.node-version)$|^\.gaia/packages\.json$'
  AUDIT_SELFHEAL_PACKAGES_ERROR=''
  gaia_packages_load "$(cd "$_audit_selfheal_dir/../../.." && pwd)" || status=$?
  if [ "$status" -ne 0 ]; then
    AUDIT_SELFHEAL_PACKAGES_ERROR="$GAIA_PACKAGES_ERROR"
    AUDIT_SELFHEAL_REFUSE_ERE='.'
    return 0
  fi
  package_arm="$(gaia_package_globs_ere selfHealRefuse)"
  if [ -n "$package_arm" ]; then
    AUDIT_SELFHEAL_REFUSE_ERE="$root_arms|$package_arm"
  else
    AUDIT_SELFHEAL_REFUSE_ERE="$root_arms"
  fi
}
_audit_selfheal_build
