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

# seed_audit_roster <sandbox_directory>
#   Appends the `auditors:` block of this repository's .gaia/audit-ci.yml to
#   <sandbox_directory>/.gaia/audit-ci.yml, creating the file when absent. Appends rather than
#   overwrites so a fixture that already wrote other config keys keeps them.
#   Only the `auditors:` block is copied: any other top-level key could change
#   behavior a suite does not expect. Returns
#   non-zero when the source block is missing, so a seed that copied nothing
#   fails the setup instead of leaving a roster-less sandbox.
seed_audit_roster() {
  local sandbox_directory="$1" root block
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  block="$(awk '
    /^auditors:/ { in_auditors_block = 1; print; next }
    in_auditors_block && /^[A-Za-z_]/ { exit }
    in_auditors_block { print }
  ' "$root/.gaia/audit-ci.yml")"
  case "$block" in
    *"- name:"*) ;;
    *)
      echo "seed_audit_roster: no auditors: block in $root/.gaia/audit-ci.yml" >&2
      return 1
      ;;
  esac
  mkdir -p "$sandbox_directory/.gaia"
  printf '%s\n' "$block" >> "$sandbox_directory/.gaia/audit-ci.yml"
}
