#!/usr/bin/env bash
# append-audit-author.sh: write a single `login=mode` pair into the
# `audit_authors` knob of `.gaia/audit-ci.yml` without clobbering other
# developers' entries.
#
# Invocation:
#   append-audit-author.sh <login> <mode>
#
# Behavior:
#   - Reads the existing space-separated `audit_authors` value via the
#     reader's argument-less emit (`read-audit-ci-config.sh`), so this helper
#     and the resolver agree on exactly what the current value is.
#   - Appends `<login>=<mode>`. If the login already has an entry (case-
#     insensitive on the login side), that entry is replaced in place rather
#     than duplicated, so a developer re-running `/setup-cloned-gaia-project`
#     flips their own mode instead of stacking a second pair. Other
#     developers' entries are preserved verbatim, in order.
#   - Writes the result back as a flat single-line `audit_authors: "<value>"`
#     string. If the key is already present in the file, the line is rewritten
#     in place; otherwise it is appended at the end of the file.
#
# The output format is exactly what `read-audit-ci-config.sh --resolve-author`
# consumes: a single space-separated string of `login=mode` pairs.
#
# Bash 3.2 compatible (macOS default). No `cd` (per
# `.claude/rules/shell-cwd.md`); paths resolve against the repo root.
#
# Exit codes:
#   0  success (value written)
#   2  usage error (missing/empty arguments)

set -euo pipefail

login="${1:-}"
mode="${2:-}"

if [ -z "$login" ] || [ -z "$mode" ]; then
  echo "append-audit-author: usage: append-audit-author.sh <login> <mode>" >&2
  exit 2
fi

# --- Resolve the config file path (mirror read-audit-ci-config.sh) ------------

script_dir="$(cd "$(dirname "$0")" && pwd)"

config_file=""
if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  config_file="$repo_root/.gaia/audit-ci.yml"
else
  config_file="./.gaia/audit-ci.yml"
fi

# --- Read the existing audit_authors value -----------------------------------
#
# Use the reader so the parse of the current value is identical to what the
# resolver sees. The reader always emits an `audit_authors=` line; strip the
# key prefix to recover the raw value (possibly empty).

existing=""
if [ -x "$script_dir/read-audit-ci-config.sh" ]; then
  existing=$(
    "$script_dir/read-audit-ci-config.sh" 2>/dev/null \
      | awk -F= '/^audit_authors=/ { sub(/^audit_authors=/, ""); print; exit }'
  )
fi

# --- Build the new value: drop any existing pair for this login, then append --

login_lc=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')

new_value=""
# shellcheck disable=SC2086
set -- $existing
for pair in "$@"; do
  case "$pair" in
    *=*)
      pair_login=${pair%%=*}
      pair_login_lc=$(printf '%s' "$pair_login" | tr '[:upper:]' '[:lower:]')
      # Drop the prior entry for this same login (case-insensitive); keep
      # everyone else verbatim.
      [ "$pair_login_lc" = "$login_lc" ] && continue
      ;;
  esac
  if [ -z "$new_value" ]; then
    new_value="$pair"
  else
    new_value="$new_value $pair"
  fi
done

if [ -z "$new_value" ]; then
  new_value="$login=$mode"
else
  new_value="$new_value $login=$mode"
fi

# --- Write the value back as a flat single-line quoted string ----------------

new_line="audit_authors: \"$new_value\""

mkdir -p "$(dirname "$config_file")"

if [ -f "$config_file" ] && grep -Eq '^[[:space:]]*audit_authors[[:space:]]*:' "$config_file"; then
  # Rewrite the existing key line in place. awk avoids sed's delimiter
  # collisions with arbitrary login/mode characters.
  tmp="$config_file.tmp.$$"
  awk -v repl="$new_line" '
    !done && $0 ~ /^[[:space:]]*audit_authors[[:space:]]*:/ {
      print repl
      done = 1
      next
    }
    { print }
  ' "$config_file" > "$tmp"
  mv "$tmp" "$config_file"
else
  # Key absent: append at end of file (create the file if missing).
  printf '%s\n' "$new_line" >> "$config_file"
fi

printf '%s\n' "$new_value"
