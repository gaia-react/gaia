#!/usr/bin/env bash
# Stop and SessionStart hook: launches the usage flusher detached and returns,
# so spend is recorded while transcripts still exist. Stop fires every turn, so
# the synchronous path is a cheap gate plus a fork; it reads no transcript byte
# and never parses the flusher. Always exits 0, prints nothing, decides nothing.

set -uo pipefail
trap 'exit 0' ERR

[ -n "${GITHUB_ACTIONS:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
fields=$(jq -r '[.hook_event_name // "", .session_id // "", .transcript_path // "", (.stop_hook_active // false | tostring)] | join("\u001f")' <<<"$payload") || exit 0
IFS=$'\037' read -r event sid tp active <<<"$fields"
[ -n "$sid" ] || exit 0
[ "$event" = "Stop" ] && [ "$active" = "true" ] && exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
flusher="$here/../../.gaia/scripts/usage-flush.sh"
[ -f "$flusher" ] || exit 0

# String work only: the flusher's projects root is two levels above the
# transcript, and reading the file here would put a turn-synchronous read on
# every Stop.
root_args=()
case "$tp" in
  */*/*)
    pr="${tp%/*}"
    pr="${pr%/*}"
    [ -n "$pr" ] && root_args=(--projects-root "$pr")
    ;;
esac

# The redirects are what release the hook's pipes; without them the harness
# waits for the flusher to exit.
if [ "$event" = "Stop" ]; then
  "${BASH:-bash}" "$flusher" --session "$sid" --transcript "$tp" --finished-main \
    ${root_args[@]+"${root_args[@]}"} </dev/null >/dev/null 2>&1 &
else
  "${BASH:-bash}" "$flusher" --sweep --self-session "$sid" \
    ${root_args[@]+"${root_args[@]}"} </dev/null >/dev/null 2>&1 &
fi
disown "$!" 2>/dev/null || true
exit 0
