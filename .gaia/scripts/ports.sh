#!/usr/bin/env bash
# shellcheck shell=bash
#
# Prints this tree's dev, Storybook, and app URL ports.
#
#   bash .gaia/scripts/ports.sh [--tree <directory>] [--field slot|dev|storybook|site-url]
#
# Exit codes: 0 success, 2 usage, 3 linked worktree with no port file (nothing
# on stdout), 4 malformed port file, 5 no package with a react-router config.
#
# site_url precedence: an exported SITE_URL, then the port file, then (slot 0)
# the port package's .env, then http://localhost:<dev>.

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree-ports-lib.sh
source "$script_directory/worktree-ports-lib.sh"

usage() {
  printf 'usage: ports.sh [--tree <directory>] [--field slot|dev|storybook|site-url]\n' >&2
  exit 2
}

tree_argument="$PWD"
field=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tree)
      [ "$#" -ge 2 ] || usage
      tree_argument="$2"
      shift 2
      ;;
    --field)
      [ "$#" -ge 2 ] || usage
      field="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
case "$field" in
  '' | slot | dev | storybook | site-url) ;;
  *) usage ;;
esac

tree_root="$(gaia_resolve_tree_root "$tree_argument" 2>/dev/null)" || {
  printf 'GAIA: %s is not inside a git checkout.\n' "$tree_argument" >&2
  exit 2
}

package_directory="$(gaia_ports_package_directory "$tree_root")" || {
  printf 'GAIA: no package under %s has a react-router.config.* file, so there is no port package to read ports for.\n' "$tree_root" >&2
  exit 5
}
port_file="$package_directory/$GAIA_PORTS_FILE_NAME"

if [ -e "$port_file" ]; then
  record="$(gaia_ports_read_file "$port_file")" || {
    printf 'GAIA: the port file %s is malformed. Run: bash .claude/hooks/provision-worktree.sh %s\n' "$port_file" "$tree_root" >&2
    exit 4
  }
  IFS=$'\t' read -r slot dev_port storybook_port site_url <<<"$record"
elif gaia_is_linked_worktree "$tree_root"; then
  gaia_ports_missing_file_message "$tree_root" "$port_file" >&2
  exit 3
else
  slot=0
  dev_port="$(gaia_ports_dev_base_port)"
  storybook_port="$(gaia_ports_storybook_base_port)"
  site_url="$(gaia_ports_site_url "$tree_root" "$dev_port")"
fi

if [ -n "${SITE_URL:-}" ]; then
  site_url="$SITE_URL"
fi

case "$field" in
  slot) printf '%s\n' "$slot" ;;
  dev) printf '%s\n' "$dev_port" ;;
  storybook) printf '%s\n' "$storybook_port" ;;
  site-url) printf '%s\n' "$site_url" ;;
  *) printf 'slot=%s\ndev=%s\nstorybook=%s\nsite_url=%s\n' "$slot" "$dev_port" "$storybook_port" "$site_url" ;;
esac
exit 0
