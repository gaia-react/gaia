#!/usr/bin/env bash
# verify-vendored-skills.sh: assert every vendored third-party skill folder is
# still byte-identical to the copy its marker recorded.
#
# A marker under .gaia/vendor/*.json names a target folder and a sha256 per
# file. The folder is an unmodified upstream copy, so a hand edit, a stray added
# file, or a deleted file is drift this check names. Marker and folder both live
# in the tree, so the check is offline: it never runs npm or curl.
#
# Usage: verify-vendored-skills.sh [--root <repo_root>]
#
# Exit 0: every marker's target matches. Exit 1: drift, one line per path
# prefixed MODIFIED, UNEXPECTED, or MISSING. Exit 2: usage error, no jq, no
# sha256 tool, or no markers (a scan of nothing never reports clean).
#
# Maintainer-only and release-excluded: it guards the maintainer's re-vendor
# workflow, and an adopter clone has no re-vendor script to restore a drifted
# folder from. The markers themselves ship.
set -euo pipefail

root="."
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "verify-vendored-skills: --root needs a value" >&2; exit 2; }
      root="$2"
      shift 2
      ;;
    *)
      echo "verify-vendored-skills: unknown argument: $1" >&2
      echo "usage: verify-vendored-skills.sh [--root <repo_root>]" >&2
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "verify-vendored-skills: jq is required and was not found" >&2
  exit 2
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "verify-vendored-skills: neither sha256sum nor shasum was found" >&2
  exit 2
fi

markers=()
for marker in "${root}"/.gaia/vendor/*.json; do
  if [ -f "${marker}" ]; then
    markers+=("${marker}")
  fi
done
if [ "${#markers[@]}" -eq 0 ]; then
  echo "verify-vendored-skills: no markers under ${root}/.gaia/vendor, nothing to verify" >&2
  exit 2
fi

drift=0
for marker in ${markers[@]+"${markers[@]}"}; do
  target="$(jq -r '.target // empty' "${marker}")"
  if [ -z "${target}" ]; then
    echo "verify-vendored-skills: ${marker} has no target" >&2
    exit 2
  fi
  target_directory="${root}/${target}"

  recorded="$(jq -r '.files | to_entries[] | "\(.key)\t\(.value)"' "${marker}")"
  if [ -z "${recorded}" ]; then
    echo "verify-vendored-skills: ${marker} records no files" >&2
    exit 2
  fi

  recorded_paths="$(printf '%s\n' "${recorded}" | cut -f1)"
  actual_paths=""
  if [ -d "${target_directory}" ]; then
    actual_paths="$(find "${target_directory}" -type f | sed "s|^${target_directory}/||" | LC_ALL=C sort)"
  fi

  while IFS=$'\t' read -r relative_path expected_hash; do
    file_path="${target_directory}/${relative_path}"
    if [ ! -f "${file_path}" ]; then
      echo "MISSING ${target}/${relative_path}"
      drift=1
    elif [ "$(sha256_of "${file_path}")" != "${expected_hash}" ]; then
      echo "MODIFIED ${target}/${relative_path}"
      drift=1
    fi
  done <<<"${recorded}"

  while IFS= read -r relative_path; do
    if [ -n "${relative_path}" ] && ! grep -qxF -- "${relative_path}" <<<"${recorded_paths}"; then
      echo "UNEXPECTED ${target}/${relative_path}"
      drift=1
    fi
  done <<<"${actual_paths}"
done

exit "${drift}"
