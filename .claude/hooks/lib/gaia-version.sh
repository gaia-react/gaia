#!/usr/bin/env bash
# gaia-version.sh: the one .gaia/VERSION read-and-normalize point. Sourced,
# never executed; does no work at source time.
#
# The literal this produces is the first field of the GAIA-Audit trailer and of
# the GAIA-Audit commit-status description, and every reader compares it for
# EQUALITY to decide whether a standing clearance still applies. Producers and
# readers live in three trees (.github/audit, .gaia/scripts, .claude/hooks), so
# the normalization has to be one function rather than one idiom: correct a
# producer without correcting a reader and the two disagree forever, the audit
# re-runs on every push, and no component reports an error because each is
# behaving exactly as written (gaia-react/gaia#1297).
#
# The absent-file policy belongs to the CALLER, deliberately. The call sites
# disagree on what a missing file means -- some treat it as empty and let a
# later guard decide, one declines outright, one falls back to a ref -- and
# answering for them here would flatten three live policies into one. So a
# missing, unreadable, or blank file all yield the empty string and exit 0.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

# gaia_read_version <version-file> -> the normalized version literal on stdout,
# with no trailing newline, or the empty string when the file is absent,
# unreadable, or holds no non-blank line. Always exits 0.
gaia_read_version() {
  local file="${1:-}"
  local v=""

  if [ -n "$file" ] && [ -f "$file" ]; then
    # Strip CR, take the first non-blank line, trim surrounding whitespace.
    v=$(tr -d '\r' < "$file" | awk 'NF{print; exit}') || v=""
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
  fi

  printf '%s' "$v"
}
