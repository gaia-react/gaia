#!/usr/bin/env bash
# shellcheck shell=bash
#
# compose-release-body.sh -- build the GitHub release body from the extracted
# CHANGELOG section, so the body's FIRST line is the 1.6.1 routing line.
#
#   bash .gaia/scripts/compose-release-body.sh <tag> <notes-file> <sha256-file> <out-file>
#
# Why the first line matters: v1.6.1's /update-gaia shows the release body at
# its Proceed/Abort prompt. Choosing Proceed on 1.6.1 fails (the 2.x tarball
# has a name 1.6.1 cannot download) after creating a branch and pruning two
# cache dirs, so the body has to lead with the route that avoids it.
#
# The CHANGELOG entry carries the routing line as its own line. The body hoists
# that line above the version heading, states the Proceed side effects, prints
# the tarball sha256, then the rest of the notes with the hoisted line removed.
# A release that does not carry the routing line gets the notes unchanged plus
# the sha256 line.
#
# Fail-closed for v2.0.0: that release is the one 1.6.1 adopters meet, so a
# CHANGELOG section without the routing line, or an empty sha256 file, exits 1
# rather than publishing a body that omits the route.
#
# Exit 0 composed, 1 refused, 2 usage error.

set -euo pipefail

ROUTING_LINE='On GAIA 1.6.1? Choose Abort, then paste the prompt from https://gaiareact.com/migrate into a fresh session.'
PROCEED_LINE='Choosing Proceed on 1.6.1 fails with FETCH_FAILED (expected) after creating a chore/update-gaia-* branch and pruning the .gaia-backup and .gaia/cache tag directories; nothing else is written.'
FENCED_TAG='v2.0.0'

if [ "$#" -ne 4 ]; then
  echo "usage: compose-release-body.sh <tag> <notes-file> <sha256-file> <out-file>" >&2
  exit 2
fi

tag="$1"
notes_file="$2"
sha_file="$3"
out_file="$4"

if [ ! -s "$notes_file" ]; then
  echo "compose-release-body: notes file is missing or empty: $notes_file" >&2
  exit 1
fi
if [ ! -r "$sha_file" ]; then
  echo "compose-release-body: sha256 file is unreadable: $sha_file" >&2
  exit 1
fi

# `shasum -a 256` prints "<hex>  <name>"; keep the whole line as the record.
sha_line="$(head -n 1 "$sha_file")"
if [ -z "$sha_line" ]; then
  echo "compose-release-body: sha256 file is empty: $sha_file" >&2
  exit 1
fi

has_routing=false
if grep -qxF -- "$ROUTING_LINE" "$notes_file"; then
  has_routing=true
fi

if [ "$tag" = "$FENCED_TAG" ] && [ "$has_routing" = false ]; then
  echo "compose-release-body: $tag notes lack the routing line; add it to the CHANGELOG entry" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  if [ "$has_routing" = true ]; then
    printf '%s\n\n%s\n\n' "$ROUTING_LINE" "$PROCEED_LINE"
  fi
  printf 'sha256: %s\n\n' "$sha_line"
  if [ "$has_routing" = true ]; then
    grep -vxF -- "$ROUTING_LINE" "$notes_file" || [ "$?" -eq 1 ]
  else
    cat "$notes_file"
  fi
} > "$tmp"

mv "$tmp" "$out_file"
trap - EXIT
