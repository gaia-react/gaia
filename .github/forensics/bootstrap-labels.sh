#!/usr/bin/env bash
# bootstrap-labels.sh: assert the forensics triage label vocabulary on the upstream
# repo. Idempotent. Operator-wins on existing labels (color/description drift is
# logged, never overwritten). Run-once by the maintainer before the triage
# workflow ships; not invoked by CI.
#
# Usage:
#   bootstrap-labels.sh [--dry-run] [--repo gaia-react/gaia]
#
# Prerequisites: `gh` authenticated against the target repo with `repo` scope.
#
# Frozen contract: the forensics triage labels (5) plus the `gaia-forensics`
# trigger label.

set -euo pipefail

DRY_RUN=0
REPO="gaia-react/gaia"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --repo)
      REPO="${2:-}"
      if [[ -z "$REPO" ]]; then
        echo "error: --repo requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Frozen label contract, name|color|description.
LABELS=(
  "gaia-forensics|5319e7|End-user bug report routed via /gaia-forensics. Triggers autonomous triage."
  "gaia-triaged|0e8a16|Forensics triage workflow has processed this issue. Idempotency key; re-firing is a no-op."
  "non-issue|cccccc|Triaged: not a bug. User-config issue, missing prerequisite, or duplicate. Issue closed."
  "needs-human|d93f0b|Triaged: out of autofix scope, malformed body, or ambiguous verdict. Maintainer review required."
  "auto-fixable|1d76db|Triaged: classifier proposed a fix in allowlisted scope. See linked draft PR."
  "gaia-bug-confirmed|b60205|Quality Gate passed on the auto-fix branch. Draft PR open and ready for human review."
)

# Snapshot existing labels on the target repo (single API call).
if ! existing="$(gh label list --repo "$REPO" --limit 200 --json name,color,description 2>&1)"; then
  echo "error: gh label list failed for $REPO:" >&2
  echo "$existing" >&2
  exit 1
fi

created=0
exists=0
drift=0
declare -a summary=()

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color description <<<"$entry"

  current="$(printf '%s' "$existing" | jq -r --arg n "$name" '.[] | select(.name == $n) | "\(.color)|\(.description)"')"

  if [[ -z "$current" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "would create: $name (color=$color)"
    else
      if ! gh label create "$name" --color "$color" --description "$description" --repo "$REPO" >/dev/null; then
        echo "error: gh label create failed for $name" >&2
        exit 1
      fi
      echo "created: $name"
    fi
    created=$((created + 1))
    summary+=("$name|created")
  else
    cur_color="${current%%|*}"
    cur_desc="${current#*|}"
    if [[ "$cur_color" != "$color" || "$cur_desc" != "$description" ]]; then
      echo "::notice::label '$name' exists with drifted color/description, operator wins, not overwriting"
      drift=$((drift + 1))
      summary+=("$name|exists (drift)")
    else
      summary+=("$name|exists")
    fi
    exists=$((exists + 1))
  fi
done

echo
echo "Summary (repo: $REPO):"
printf '  %-22s %s\n' "LABEL" "STATE"
for line in "${summary[@]}"; do
  IFS='|' read -r name state <<<"$line"
  printf '  %-22s %s\n' "$name" "$state"
done
echo

if [[ $created -eq 0 ]]; then
  if [[ $DRY_RUN -eq 1 && $exists -eq ${#LABELS[@]} ]]; then
    echo "no-op: all labels present"
  elif [[ $DRY_RUN -eq 0 ]]; then
    echo "no-op: all labels present"
  fi
fi

exit 0
