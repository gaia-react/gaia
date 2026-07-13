#!/usr/bin/env bash
# 06-claude-runs-staged.sh
#
# Layer 2: validates the Claude-in-Docker plumbing for distribution tests.
# Builds the gaia-dist-claude image, mounts a staged release tree at /work
# read-only, and runs `claude --print` with an OAuth token from the host env.
#
# What this DOES test:
#   - Docker image builds (Node + claude.ai/install.sh + correct PATH).
#   - `claude --version` runs inside the container (binary reachable).
#   - CLAUDE_CODE_OAUTH_TOKEN authenticates against Anthropic from the
#     container; `claude --print` returns a real model response.
#   - The staged tree is reachable as the container's working directory.
#
# What this does NOT test:
#   - Adopter flows like /gaia-init or /setup-gaia. Those exercise interactive
#     skills and live in follow-up scenarios; this is the harness smoke.
#   - Token-attribution to subscription vs. API. That is the diagnostic
#     runbook's job; see `diagnostic/claude-auth-in-docker.md` for the
#     verified $0/run finding on Claude Max hosts.
#
# Skipped automatically when Docker is unavailable OR
# CLAUDE_CODE_OAUTH_TOKEN is unset, so contributors without auth can still
# run Layers 0 + 1 via run-all.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/docker.sh"

if ! docker_available; then
  log "docker daemon not reachable; skipping (Layer 2 requires Docker)"
  pass "docker unavailable; Layer 2 scenario skipped"
  exit 0
fi

if ! docker_token_available; then
  log "CLAUDE_CODE_OAUTH_TOKEN unset; skipping (Layer 2 requires Claude auth)"
  pass "no Claude OAuth token; Layer 2 scenario skipped"
  exit 0
fi

STAGING="$(mktemp -d -t gaia-dist-claude-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

log "building $GAIA_DIST_IMAGE (cached after first run)"
if ! docker_build_image; then
  # Re-run the build with output unsuppressed to surface which layer
  # failed. The `fail; exit 1` below runs unconditionally; the diagnostic
  # build's exit code is intentionally ignored (`|| :`).
  log "docker build failed; rerunning with output for diagnosis:"
  docker build -t "$GAIA_DIST_IMAGE" - <<'DOCKERFILE' || :
FROM node:22-bullseye-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git \
  && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
WORKDIR /work
DOCKERFILE
  fail "docker build failed"
  exit 1
fi

# Sanity: the claude binary is on PATH and runnable inside the container.
if ! docker_run_claude "$STAGING" --version >/dev/null 2>&1; then
  log "claude --version failed inside container; rerunning with output:"
  docker_run_claude "$STAGING" --version || true
  fail "claude --version failed inside container"
  exit 1
fi

# Auth + reachability probe. Single-word reply keeps token spend minimal;
# `grep -i` tolerates trailing whitespace and case variation in the model's
# reply.
RESPONSE="$(docker_run_claude "$STAGING" --print "Reply with the single word: ok" 2>/dev/null || true)"
if ! printf '%s' "$RESPONSE" | grep -qi 'ok'; then
  log "claude --print did not return 'ok'; got:"
  printf '%s\n' "$RESPONSE" >&2
  fail "claude --print response did not contain 'ok' (auth failure or model unreachable?)"
  exit 1
fi

pass "Layer 2 plumbing green: image builds, claude --version runs, OAuth auth succeeds against staged tree"
