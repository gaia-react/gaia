#!/usr/bin/env bats
# UAT-013: no committed file carries a raw sandbox enable; the real enable only
# lands in the gitignored .claude/settings.local.json at runtime.
#
# WHAT THIS BANS AND WHAT IT DOES NOT. The stance in wiki/concepts/OS Sandbox.md
# bans a committed ENABLE, and names the harm: baking in a hard "on" degrades
# silently to unsandboxed the moment a machine cannot back it, and forces
# friction on every clone that did not choose it. A committed BOUNDARY carries
# none of that. `sandbox.filesystem.denyRead` grants no capability, cannot
# degrade a machine, and is inert until something else enables the sandbox, so
# it is sanctioned and this test must not fire on it. The distinguishing key is
# `enabled`, and that is what the checks below read.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
}

# Print the path of a file whose `"sandbox"` object carries an `enabled` key,
# and return non-zero. A line-oriented grep cannot answer this: in the JSON
# spelling the two keys sit on separate lines. The document is flattened and
# walked with a brace counter, so an `enabled` belonging to a later, unrelated
# object is never attributed to the sandbox one.
sandbox_object_carries_enable() {
  awk '
    { doc = doc $0 }
    END {
      gsub(/[ \t\r\n]/, "", doc)
      rest = doc
      while ((i = index(rest, "\"sandbox\":{")) > 0) {
        rest = substr(rest, i + 11)
        depth = 1
        body = ""
        for (j = 1; j <= length(rest) && depth > 0; j++) {
          c = substr(rest, j, 1)
          if (c == "{") depth++
          else if (c == "}") depth--
          if (depth > 0) body = body c
        }
        if (body ~ /"enabled":/) { print FILENAME; exit 1 }
      }
    }
  ' "$1"
}

@test "UAT-013: no committed .json/.md/.yml/.yaml file carries a raw sandbox enable" {
  cd "$REPO_ROOT"
  # A raw `git grep sandbox\.enabled` also matches TS source/test files that
  # legitimately reference the property (e.g. `expect(written.sandbox.enabled)`)
  # and the two generated CLI binaries. Scoping to committed config/doc file
  # types excludes that source-level noise and pins the precise, honest form:
  # no config surface carries a real top-level enable.
  #
  # The dotted spelling, which covers prose and YAML.
  git grep -nF 'sandbox.enabled: true' -- '*.json' '*.md' '*.yml' '*.yaml' && return 1

  # The JSON spelling, in any committed config or doc, including one quoted
  # inside a fenced block. The file list comes from git, so the gitignored
  # .claude/settings.local.json where the real enable belongs is never read.
  # NUL-delimited: a path carrying a non-ASCII byte comes back C-quoted from a
  # plain `git ls-files`, and the quoted form names no file the reader can open,
  # so the scan would skip exactly the file it was handed.
  local f
  while IFS= read -r -d '' f; do
    sandbox_object_carries_enable "$f" || return 1
  done < <(git ls-files -z -- '*.json' '*.md' '*.yml' '*.yaml')

  return 0
}

# A second test here asserted that the diff vs main never touched
# .gaia/manifest.json. It is deliberately gone rather than repaired. It held on
# the one feature branch that introduced it and nowhere since: the manifest is
# release-generated and ordinary feature work regenerates it, so the assertion
# is false as a repo-wide invariant. It also contradicted the Distribution
# Audit (PR) required check, which instructs the author to commit exactly the
# regenerated manifest it forbade. The durable half of that intent already has
# an owner in that workflow; the test above keeps the half this file is for.
