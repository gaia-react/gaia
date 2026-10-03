# Build from the repo root so the root lockfile and supply-chain settings apply:
#   docker build -f frontend/Dockerfile .
# BuildKit reads frontend/Dockerfile.dockerignore beside this file, which keeps
# every .env out of the context.

FROM node:22.23-alpine AS build-env
RUN corepack enable
WORKDIR /repo
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY frontend/package.json ./frontend/package.json
RUN pnpm install --frozen-lockfile
COPY frontend ./frontend
RUN pnpm --filter frontend build
RUN pnpm deploy --filter frontend --prod /app

FROM node:22.23-alpine
RUN corepack enable
# Resolve the pinned pnpm and its native binary now, so `pnpm start` needs no registry at run time.
# The deployed package carries no packageManager field, so pin from the root manifest.
WORKDIR /pin
COPY package.json ./
RUN corepack prepare --activate && pnpm --version
WORKDIR /app
# Deployed at /app in the build stage so pnpm's recorded install state still matches this path;
# otherwise `pnpm start` sees a stale install and reaches for the registry.
COPY --from=build-env /app/package.json /app/pnpm-lock.yaml /app/pnpm-workspace.yaml ./
COPY --from=build-env /app/node_modules ./node_modules
COPY --from=build-env /repo/frontend/build ./build
# The install was verified at build time; never reinstall at start.
ENV pnpm_config_verify_deps_before_run=false
CMD ["pnpm", "start"]
