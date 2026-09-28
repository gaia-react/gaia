#!/usr/bin/env bash
# Shared bats primitive for giving a sandbox repository the live audit roster.
#
# Sourced from a suite's `setup()`, from any bats directory, by the same
# repo-root-absolute path `path.sh` documents:
#
#   . "$REPO_ROOT/.gaia/tests/helpers/audit-roster.sh"
#
# audit_scope_init has no fallback roster: a root whose .gaia/audit-ci.yml
# carries no `auditors:` block fails closed. A sandbox that exercises the
# resolver, the digest engine, or the merge gate therefore needs the roster
# seeded, and seeding the committed one means the suite exercises the roster
# that ships rather than a mirror of it.

# seed_audit_roster <dir>
#   Appends the `auditors:` block of this repository's .gaia/audit-ci.yml to
#   <dir>/.gaia/audit-ci.yml, creating the file when absent. Appends rather than
#   overwrites so a fixture that already wrote other config keys keeps them.
#   Only the `auditors:` block is copied: the other keys (default_mode,
#   audit_authors, ...) change behavior a suite may not expect. Returns
#   non-zero when the source block is missing, so a seed that copied nothing
#   fails the setup instead of leaving a roster-less sandbox.
seed_audit_roster() {
  local dir="$1" root block
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  block="$(awk '
    /^auditors:/ { on = 1; print; next }
    on && /^[A-Za-z_]/ { exit }
    on { print }
  ' "$root/.gaia/audit-ci.yml")"
  case "$block" in
    *"- name:"*) ;;
    *)
      echo "seed_audit_roster: no auditors: block in $root/.gaia/audit-ci.yml" >&2
      return 1
      ;;
  esac
  mkdir -p "$dir/.gaia"
  printf '%s\n' "$block" >> "$dir/.gaia/audit-ci.yml"
}
