#!/usr/bin/env bash
# SLOT - Playwright UAT auto-write phase. Implementation is a separate SPEC.
#
# This hook is intentionally a no-op in SPEC-001. The slot is reserved on the
# spec-kit hook bus so a future SPEC can populate it without touching the
# extension manifest. Manifest declares optional: true.
#
# Reads JSON payload from stdin (or $SPECKIT_HOOK_PAYLOAD env var) per
# .specify/extensions/gaia/lib/hook-payload.md, then immediately proceeds.
set -euo pipefail

# Drain payload from stdin if present so spec-kit's hook bus does not see a
# broken pipe. Env var is the documented fallback.
if [ -z "${SPECKIT_HOOK_PAYLOAD:-}" ] && [ ! -t 0 ]; then
  cat > /dev/null
fi

printf '{"action":"proceed"}\n'
exit 0
