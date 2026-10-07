#!/usr/bin/env bats
#
# Static contract for the frontend image (SPEC-092 Docker contract, SEC-004,
# CG-014). The real build and the "image serves home, no environment file
# inside" run belong to the verification phase; this suite pins the files that
# make them possible.
#
#   - frontend/Dockerfile builds from the repo root, installs from the root
#     lockfile, deploys the frontend package, and keeps `pnpm start`.
#   - frontend/Dockerfile.dockerignore keeps every dotenv file out of the
#     context. The ignore rules are evaluated with git's matcher
#     (`git check-ignore --no-index` over a temp repo whose .gitignore is a
#     copy of the patterns). That approximates Docker's matcher, and is exact
#     for the `**/` and literal patterns the dotenv checks depend on. The guard
#     test proves the evaluation can report a dotenv file as included.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOCKERFILE="$REPO_ROOT/frontend/Dockerfile"
  IGNORE_FILE="$REPO_ROOT/frontend/Dockerfile.dockerignore"
  DOTENV=".env"
  DOTENV_STAR=".env.*"
}

# Exit 0 when git would ignore path $2 under the ignore patterns in file $1.
ignored_by_patterns() {
  local patterns="$1" path="$2" repo
  repo="$(mktemp -d "$BATS_TEST_TMPDIR/ignore-repo.XXXXXX")"
  git -C "$repo" init -q
  cp "$patterns" "$repo/.gitignore"
  git -C "$repo" check-ignore --no-index -q -- "$path"
}

# Dockerfile text with comment lines dropped.
dockerfile_instructions() {
  grep -vE '^[[:space:]]*#' "$DOCKERFILE"
}

# Succeeds when stdin holds a COPY of the whole context (a bare `.` source).
copies_whole_context() {
  grep -qE '^COPY (--[a-z]+=[^ ]+ )*\. '
}

@test "Dockerfile deploys the frontend package from the root install" {
  run dockerfile_instructions
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm deploy --filter frontend"* ]]
}

@test "Dockerfile copies the root lockfile and workspace file and installs frozen" {
  run dockerfile_instructions
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm-lock.yaml"* ]]
  [[ "$output" == *"pnpm-workspace.yaml"* ]]
  [[ "$output" == *"pnpm install --frozen-lockfile"* ]]
}

@test "Dockerfile ends with CMD pnpm start in the deployed package dir" {
  local instructions last_cmd last_workdir last_line
  instructions="$(dockerfile_instructions)"
  last_line="$(printf '%s\n' "$instructions" | grep -vE '^[[:space:]]*$' | tail -n 1)"
  [ "$last_line" = 'CMD ["pnpm", "start"]' ]
  last_cmd="$(printf '%s\n' "$instructions" | grep -E '^CMD ' | tail -n 1)"
  [ "$last_cmd" = 'CMD ["pnpm", "start"]' ]
  last_workdir="$(printf '%s\n' "$instructions" | grep -E '^WORKDIR ' | tail -n 1)"
  [ "$last_workdir" = "WORKDIR /app" ]
}

@test "Dockerfile never copies the whole context into the final stage" {
  local final_stage
  final_stage="$(dockerfile_instructions | awk '/^FROM /{buf=""} {buf = buf $0 "\n"} END{printf "%s", buf}')"
  [[ "$final_stage" == "FROM "* ]]
  run copies_whole_context <<<"$final_stage"
  [ "$status" -eq 1 ]
}

@test "guard: the whole-context check refuses a final stage that copies the context" {
  local final_stage
  final_stage=$'FROM node:22-alpine\nCOPY . /app/\nCMD ["pnpm", "start"]'
  run copies_whole_context <<<"$final_stage"
  [ "$status" -eq 0 ]
}

@test "dockerignore excludes the dotenv files but includes frontend/app/root.tsx" {
  run ignored_by_patterns "$IGNORE_FILE" "$DOTENV"
  [ "$status" -eq 0 ]
  run ignored_by_patterns "$IGNORE_FILE" "frontend/$DOTENV"
  [ "$status" -eq 0 ]
  run ignored_by_patterns "$IGNORE_FILE" "frontend/${DOTENV}.local"
  [ "$status" -eq 0 ]
  run ignored_by_patterns "$IGNORE_FILE" "frontend/app/root.tsx"
  [ "$status" -eq 1 ]
}

@test "dockerignore lists the dotenv patterns literally" {
  run grep -Fxc "**/$DOTENV" "$IGNORE_FILE"
  [ "$output" -ge 1 ]
  run grep -Fxc "**/$DOTENV_STAR" "$IGNORE_FILE"
  [ "$output" -ge 1 ]
}

@test "guard: without the dotenv lines the evaluation reports frontend/.env as included" {
  local stripped="$BATS_TEST_TMPDIR/stripped.dockerignore"
  grep -Fvx -e "**/$DOTENV" -e "**/$DOTENV_STAR" "$IGNORE_FILE" >"$stripped"
  run ignored_by_patterns "$stripped" "frontend/$DOTENV"
  [ "$status" -eq 1 ]
  run ignored_by_patterns "$stripped" "$DOTENV"
  [ "$status" -eq 1 ]
}

@test "no root Dockerfile or .dockerignore remains tracked" {
  local tracked=0 path
  while IFS= read -r -d '' path; do
    tracked=$((tracked + 1))
  done < <(git -C "$REPO_ROOT" ls-files -z -- .dockerignore Dockerfile)
  [ "$tracked" -eq 0 ]
}

# Prints the "version" value of package manifest $1, empty when absent.
manifest_version() {
  sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$1" | head -n 1
}

# The app reads npm_package_version, which pnpm sets only from the running
# package's own manifest, so the frontend manifest must carry the root version.
@test "frontend/package.json carries a non-empty version equal to the root version" {
  local root_version frontend_version
  root_version="$(manifest_version "$REPO_ROOT/package.json")"
  frontend_version="$(manifest_version "$REPO_ROOT/frontend/package.json")"
  [ -n "$root_version" ]
  [ -n "$frontend_version" ]
  [ "$frontend_version" = "$root_version" ]
}

@test "guard: a frontend manifest without a version, or with a different one, is refused" {
  local without="$BATS_TEST_TMPDIR/without.json" differing="$BATS_TEST_TMPDIR/differing.json"
  grep -v '"version"' "$REPO_ROOT/frontend/package.json" >"$without"
  [ -z "$(manifest_version "$without")" ]
  sed -E 's/("version"[[:space:]]*:[[:space:]]*")[^"]*/\10.0.0-other/' "$REPO_ROOT/frontend/package.json" >"$differing"
  [ -n "$(manifest_version "$differing")" ]
  [ "$(manifest_version "$differing")" != "$(manifest_version "$REPO_ROOT/package.json")" ]
}
