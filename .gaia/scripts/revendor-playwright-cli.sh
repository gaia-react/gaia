#!/usr/bin/env bash
# revendor-playwright-cli.sh: replace the vendored playwright-cli skill with the
# published @playwright/cli package's skills/playwright-cli folder, byte for
# byte, and rewrite the marker that verify-vendored-skills.sh checks.
#
# Usage: revendor-playwright-cli.sh --version <semver>
#          [--tarball <path> --integrity <sri>] [--root <repo_root>]
#
# Without --tarball it runs `npm pack` in a scratch directory and reads the
# registry's dist.integrity. The tarball's own sha512 must equal that integrity
# before anything is written, so a corrupted or substituted download changes
# nothing. --tarball and --integrity together skip the network (tests).
#
# Exit 0 on success. Non-zero, with nothing written, on a usage error, an npm
# failure, an integrity mismatch, or a tarball without the skills folder.
#
# Maintainer-only and release-excluded: adopters receive the vendored folder and
# its marker, never the means to replace it.
set -euo pipefail

package_name="@playwright/cli"
marker_relative=".gaia/vendor/playwright-cli.json"
source_relative="skills/playwright-cli"
target_relative="frontend/.claude/skills/playwright-cli"

version=""
tarball=""
integrity=""
root="."
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version | --tarball | --integrity | --root)
      [ "$#" -ge 2 ] || { echo "revendor-playwright-cli: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --version) version="$2" ;;
        --tarball) tarball="$2" ;;
        --integrity) integrity="$2" ;;
        --root) root="$2" ;;
      esac
      shift 2
      ;;
    *)
      echo "revendor-playwright-cli: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "${version}" ]; then
  echo "revendor-playwright-cli: --version is required" >&2
  exit 2
fi
if [ -n "${tarball}" ] && [ -z "${integrity}" ]; then
  echo "revendor-playwright-cli: --tarball requires --integrity" >&2
  exit 2
fi
if [ -z "${tarball}" ] && [ -n "${integrity}" ]; then
  echo "revendor-playwright-cli: --integrity requires --tarball" >&2
  exit 2
fi
for tool in jq openssl base64 tar; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "revendor-playwright-cli: ${tool} is required" >&2; exit 2; }
done
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "revendor-playwright-cli: neither sha256sum nor shasum was found" >&2
  exit 2
fi

work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT

if [ -z "${tarball}" ]; then
  command -v npm >/dev/null 2>&1 || { echo "revendor-playwright-cli: npm is required without --tarball" >&2; exit 2; }
  integrity="$(npm view "${package_name}@${version}" dist.integrity)"
  packed_name="$(cd "${work_directory}" && npm pack "${package_name}@${version}" --silent | tail -n 1)"
  tarball="${work_directory}/${packed_name}"
fi

computed="sha512-$(openssl dgst -sha512 -binary "${tarball}" | base64 | tr -d '\n')"
if [ "${computed}" != "${integrity}" ]; then
  echo "revendor-playwright-cli: integrity mismatch, nothing written" >&2
  echo "  expected ${integrity}" >&2
  echo "  computed ${computed}" >&2
  exit 1
fi

extract_directory="${work_directory}/extract"
mkdir -p "${extract_directory}"
tar -xzf "${tarball}" -C "${extract_directory}"
source_directory="${extract_directory}/package/${source_relative}"
if [ ! -d "${source_directory}" ]; then
  echo "revendor-playwright-cli: package/${source_relative} not found in the tarball, nothing written" >&2
  exit 1
fi

target_directory="${root}/${target_relative}"
rm -rf "${target_directory}"
mkdir -p "$(dirname "${target_directory}")"
cp -R "${source_directory}" "${target_directory}"

hashes_file="${work_directory}/hashes.tsv"
: >"${hashes_file}"
while IFS= read -r relative_path; do
  printf '%s\t%s\n' "${relative_path}" "$(sha256_of "${target_directory}/${relative_path}")" >>"${hashes_file}"
done < <(find "${target_directory}" -type f | sed "s|^${target_directory}/||" | LC_ALL=C sort)

mkdir -p "${root}/.gaia/vendor"
files_json="$(jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' <"${hashes_file}")"
jq -n \
  --arg package "${package_name}" \
  --arg version "${version}" \
  --arg integrity "${integrity}" \
  --arg source "${source_relative}" \
  --arg target "${target_relative}" \
  --argjson files "${files_json}" \
  '{package: $package, version: $version, integrity: $integrity, source: $source, target: $target, files: $files}' \
  >"${root}/${marker_relative}"

echo "vendored ${package_name}@${version} into ${target_relative}"
