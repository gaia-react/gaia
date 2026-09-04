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

# Print the path of every committed file whose `"sandbox"` object carries an
# `enabled` key, and return non-zero when there is one. A line-oriented grep
# cannot answer this: in the JSON spelling the two keys sit on separate lines.
#
# The scan is STRING-AWARE. Flattening whitespace and counting braces blindly
# would let a `}` inside a JSON string value drop the depth to zero and end the
# walk before it reached the key, so an enable spelled with a brace in a
# neighbouring string value would be missed. Each character is therefore
# classified as inside or outside a string literal, whitespace is dropped only
# outside one, and only an unquoted brace moves the depth.
#
# Two stages, and the first one is what makes the second affordable. The careful
# walk builds its normalized copy a character at a time, which is quadratic in
# the file's length and unbearable over this tree's larger Markdown. A file that
# does not contain the literal `"sandbox"` anywhere cannot hold a sandbox
# object, so `git grep -l` narrows the list to the few that can before any
# character-wise work happens. One awk then covers that whole shortlist, rather
# than a process per file.
#
# What it deliberately does not narrow: an `enabled` key anywhere inside the
# sandbox object counts, not only one at the top of it. A nested enable is not a
# spelling anything here needs, and treating the object as a whole is the
# fail-closed direction for a policy guard.
sandbox_enables_in_committed_files() {
  local candidates hits
  # `|| true` because git grep exits 1 on no match, which is the healthy case
  # here rather than an error, and the caller runs under bats' errexit.
  candidates=$(git grep -z -l -F '"sandbox"' -- '*.json' '*.md' '*.yml' '*.yaml' || true)
  # Guarded rather than piped straight through: BSD xargs runs its command once
  # with no arguments on empty input, and an awk with no file operands reads
  # stdin and hangs the suite.
  [ -n "$candidates" ] || return 0
  hits=$(printf '%s' "$candidates" | xargs -0 awk '
    function scan(   n, i, c, inq, esc, norm, mask, pos, at, j, depth, body, m) {
      if (curfile == "") return
      n = length(doc); inq = 0; esc = 0; norm = ""; mask = ""
      for (i = 1; i <= n; i++) {
        c = substr(doc, i, 1)
        if (inq) {
          norm = norm c; mask = mask "1"
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { inq = 0 }
        } else if (c == " " || c == "\t" || c == "\r" || c == "\n") {
          continue
        } else {
          norm = norm c
          if (c == "\"") { inq = 1; mask = mask "1" } else { mask = mask "0" }
        }
      }
      pos = 1
      while ((i = index(substr(norm, pos), "\"sandbox\":{")) > 0) {
        j = pos + i - 1 + 11
        depth = 1; body = ""
        while (j <= length(norm) && depth > 0) {
          c = substr(norm, j, 1); m = substr(mask, j, 1)
          if (m == "0") {
            if (c == "{") depth++
            else if (c == "}") depth--
          }
          if (depth > 0) body = body c
          j++
        }
        if (body ~ /"enabled":/) print curfile
        pos = j
      }
    }
    FNR == 1 { scan(); curfile = FILENAME; doc = "" }
    { doc = doc $0 "\n" }
    END { scan() }
  ')
  [ -z "$hits" ] || { printf '%s\n' "$hits"; return 1; }
  return 0
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
  # .claude/settings.local.json where the real enable belongs is never read, and
  # it is NUL-delimited because a path carrying a non-ASCII byte comes back
  # C-quoted from a plain `git ls-files` and the quoted form names no file the
  # reader can open, so the scan would skip exactly the file it was handed.
  sandbox_enables_in_committed_files || return 1

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
