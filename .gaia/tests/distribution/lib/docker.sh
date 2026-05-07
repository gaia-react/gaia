#!/usr/bin/env bash
# Docker primitives for Layer 2 distribution scenarios.
#
# Sourced by Layer 2 scenarios after lib.sh:
#   source "$HERE/lib/lib.sh"
#   source "$HERE/lib/docker.sh"
#
# Convention matches lib.sh: this file does NOT enable `set -e` — the caller
# scenario sets `set -euo pipefail` and inherits it.
#
# API:
#   GAIA_DIST_IMAGE             - tag of the test image (override via env)
#   docker_available            - 0 if `docker` runs and the daemon is reachable
#   docker_token_available      - 0 if CLAUDE_CODE_OAUTH_TOKEN is set + non-empty
#   docker_build_image          - builds GAIA_DIST_IMAGE; uses Docker layer cache
#   docker_run_claude STAGING -- ARGS...
#                                runs `claude ARGS...` inside GAIA_DIST_IMAGE
#                                with STAGING bind-mounted at /work read-only
#                                and CLAUDE_CODE_OAUTH_TOKEN passed through

GAIA_DIST_IMAGE="${GAIA_DIST_IMAGE:-gaia-dist-claude:latest}"

docker_available() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  return 0
}

docker_token_available() {
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]
}

# Builds the GAIA distribution-test Claude image. The Dockerfile lives in a
# scratch dir so the image build context stays minimal — no repo files leak
# into the image. Pinned to the verified pattern from
# `diagnostic/claude-auth-in-docker.md`: `claude.ai/install.sh` lands the
# binary at `/root/.local/bin/claude`, which we put on PATH.
docker_build_image() {
  local dockerfile_dir
  dockerfile_dir="$(mktemp -d -t gaia-dist-dockerfile-XXXXXX)"
  # Local EXIT trap so the temp dir is cleaned even if the function is
  # killed mid-build (SIGTERM from a CI timeout, OOM, runner preemption).
  # Subshell scope keeps it from clobbering the calling scenario's own
  # EXIT trap.
  (
    trap 'rm -rf "$dockerfile_dir"' EXIT
    cat > "$dockerfile_dir/Dockerfile" <<'DOCKERFILE'
FROM node:22-bullseye-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl ca-certificates git \
  && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
WORKDIR /work
DOCKERFILE
    docker build -t "$GAIA_DIST_IMAGE" "$dockerfile_dir" >/dev/null 2>&1
  )
}

# `-e CLAUDE_CODE_OAUTH_TOKEN` (no `=value`) reads from the host env, so the
# token is never on the command line where it could land in `ps` or shell
# history. The bind mount is read-only — the Layer 2 contract is "Claude can
# read the staged tree", not "Claude can mutate the staged tree".
docker_run_claude() {
  local staging="$1"; shift
  docker run --rm \
    -v "$staging:/work:ro" \
    -e CLAUDE_CODE_OAUTH_TOKEN \
    "$GAIA_DIST_IMAGE" \
    claude "$@"
}
