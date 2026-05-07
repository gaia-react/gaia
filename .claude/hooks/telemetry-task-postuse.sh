#!/bin/bash
# PostToolUse Task hook: extract structured-trailer events from the agent's
# Task-tool output and dispatch `gaia telemetry emit` for each one.
#
# Thin pipe to the TS implementation. Trailer parsing, dispatch, and best-
# effort failure logging all live in `.gaia/cli/src/telemetry/parse-stdin.ts`
# (covered by `parse-trailer.test.ts`). Always exits 0 — telemetry must
# never block the user's flow.

set -uo pipefail

if [ ! -x .gaia/cli/gaia ]; then
  exit 0
fi

.gaia/cli/gaia telemetry parse-stdin || true
exit 0
