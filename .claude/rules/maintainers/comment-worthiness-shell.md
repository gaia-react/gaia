---
paths:
  - '.gaia/scripts/**/*.sh'
  - '.gaia/statusline/**/*.sh'
  - '.specify/extensions/gaia/lib/**/*.sh'
  - '.claude/hooks/**/*.sh'
  - '.gaia/tests/**/*.bats'
  - '.gaia/tests/**/*.sh'
  - '.gaia/scripts/**/*.bats'
  - '.github/**/*.bats'
  - '.github/**/*.sh'
---

# Comment worthiness on shell and bats (maintainer-only)

**Maintainer-repo only.** This rule never ships (`.claude/rules/maintainers/` is release-excluded). It carries the hazard inventory for editing a comment in GAIA's own bash and bats; an adopter runs GAIA's shell but never authors it, so an adopter clone has neither the surface nor the hazards and this is out of scope there.

The judgment this file supports lives in `.claude/rules/wiki-style.md`, section `## Comment worthiness`: **a comment must be about something the file does not contain.** That section decides whether a comment earns its place, in any language. This file decides something prior and narrower: whether the line you are about to touch is commentary at all, and what breaks when you are wrong. Nothing here relaxes that standard, and nothing here is a licence to shorten a comment into a cryptic one.

Every count below names the command that produces it, because a hardcoded count is exactly the kind of comment content this repo's own standard distrusts. Re-run the command rather than trusting the number.

## 1. Comments that are data, not commentary

A tool parses the **content or shape** of every line below. None of them is judged on worthiness, and none of them is reworded. A mechanical sweep that touches one breaks a build or corrupts a ledger with no merge-conflict warning to catch it.

**The shell marker form is the one most likely to be missed.** A sweeper reading a `.sh` file sees `#` lines and reads them as prose. Two of those `#` lines per block are a release transform's delimiters, and they look exactly like a section header.

| Shape | Inventory | Consumer | Failure mode |
|---|---|---|---|
| `<!-- gaia:maintainer-only:start -->` / `:end` in markdown | 33 files carrying 61 blocks | the release marker-strip transform | build fails on an unbalanced pair, or maintainer content leaks to adopters |
| `# gaia:maintainer-only:start` / `:end` in `**/*.sh`, `**/*.yml.tmpl`, `.gaia/audit-ci.yml`, `.prettierignore` | 14 shell files carrying 25 balanced pairs | a **second, separate** transform | the same, plus audit-roster and gate-machinery corruption |
| both forms together, all file types | 71 files | | |
| `<!-- gaia:audit-remit:start -->` / `:end` | 19 files | the region registry and the update-time region markers | build-time failure; an adopter's update degrades to whole-file conflicts |
| `<!-- gaia-harden: promoted from recurring finding_class … -->` | | the harden covered-classes reader | silently un-suppresses a finding class in the tally |
| `<!-- gaia-debt-key: … -->`, `<!-- gaia-debt-origin: … -->` | | the debt-origin and debt-count helpers; both tokens are owned by `.claude/skills/file-tech-debt/SKILL.md` | dedup breaks and duplicate issues get filed; provenance is lost |
| `<!-- gaia-audit:gradings: … -->` | | the harden severity map | severity mapping breaks |
| `# shellcheck disable=` / `shell=` / `source=` | 321 directives across 157 files on this rule's activation surface (115 across 63 of them on the 78 shell files of section 6, and the 40 inner-script `SC1090` directives section 5 step 1 depends on) | shellcheck, via the shell-lint gate | CI red, or a file silently unlinted |
| `#` lines inside the `AUDIT_MACHINERY_PATHS` heredoc | four marker pairs, eight lines | the machinery-completeness script itself | see section 2 |
| `uses: …@<sha> # vN` pin glosses | | Dependabot **writes** them and a CLI test **parses** them as a typed `tag` field | a parsed field disappears |

Reproduce the first three rows with:

```bash
# `:!.claude/rules/maintainers` keeps this directory's prose ABOUT the markers
# out of an inventory OF them. Nothing here is release-excluded by accident:
# these rules never ship, so a marker mention in one is documentation, never a
# delimiter, and counting it inflates every row above.
ex=':!.claude/rules/maintainers'
git grep -l '<!-- gaia:maintainer-only:start -->' -- '*.md' "$ex" | wc -l
git grep -c '<!-- gaia:maintainer-only:start -->' -- '*.md' "$ex" | awk -F: '{s+=$NF} END {print s}'
git ls-files '*.sh' | xargs grep -lE '^[[:space:]]*# gaia:maintainer-only:start$' | wc -l
git grep -l 'gaia:maintainer-only' -- "$ex" | wc -l
```

### The anchoring trap

A substring match for the start marker is **red on a clean tree**, and it is the likeliest way a reader gets a false alarm from this very inventory. `.gaia/tests/distribution/03-marker-strip.sh` contains `grep -q '^[[:space:]]*# gaia:maintainer-only:start' "$src"`. That is a grep *pattern* inside a test, not a marker, and an unanchored count reads it as a start with no matching end.

**Anchor the balance check on the whole line:**

```bash
grep -cE '^[[:space:]]*# gaia:maintainer-only:start$' "$f"
```

The **line anchor** is what does the work; the trailing `$` is belt and braces. Dropping only the `$` while keeping `^[[:space:]]*#` stays clean, so anyone testing this claim with that half-anchored variant concludes the trap is imaginary. It is not. Use the fully anchored form as canonical, and never "fix" the distribution-test fixture by adding an end marker to it: the fixture is correct and the unanchored grep is wrong.

## 2. Deletions that pass every test and still break something

Four hazards. Each is stated with enough mechanism to recognize a new instance, because the inventory above cannot be exhaustive.

**Markers inside a heredoc are data.** `.gaia/scripts/audit-machinery-complete.sh` holds a quoted heredoc containing a data list of gate-machinery file paths, with four marker pairs interleaved in that data. They do three jobs at once: release-build control (the marked lines are stripped from the shipped copy, which is what keeps release-excluded files out of an adopter's list), leak-check compliance (`.gaia/scripts/**` sits inside the leak-check scope and one of those lines names a release-excluded path that would otherwise fail the build), and a runtime skip (a `case` arm treats a leading `#` as a comment and skips it). Delete them and the maintainer's own run still passes, every bats suite passes, shellcheck passes, and the release build fails. A line-based marker stripper cannot tell a real marker from one inside a heredoc, and here that ambiguity is deliberate and load-bearing.

**A full-line comment must never become a trailing comment.** The release leak scanner strips only line-leading `#`, deliberately, because a mid-line `#` is ambiguous in shell. A full-line comment is therefore invisible to the scan and a trailing comment is not. Condensing a header line onto the end of a code line, which is the natural "shorten this" move, converts a safe path reference into a scanned one. The shipped scan globs carry full-line comments that name paths the scanner reads as runtime dependencies, including invented example paths that name nothing on disk, which are the ones a scanner is least able to forgive and a human is least likely to suspect. **Shorten in place or delete outright; never merge a full-line comment onto a code line.**

**Some shipped comments sit inside markers only because of the path they name.** Remove the marker pair, or move the comment out of the block, and the leak check fails the release build. Count them with:

```bash
leak_pat='\.gaia/cli/src/|\.gaia/cli/test-fixtures/|\.gaia/cli/__tests__/|\.gaia/cli/health/|\.gaia/cli/gaia-maintainer|\.specify/extensions/gaia/test/|\.specify/specs/|\.gaia/tests/|\.gaia/scripts/tests/|\.github/audit/tests/|\.github/forensics/|\.claude/rules/maintainers/'
git ls-files '*.sh' | xargs awk -v pat="$leak_pat" '
  /^[[:space:]]*# gaia:maintainer-only:start$/ { inblk=1; next }
  /^[[:space:]]*# gaia:maintainer-only:end$/   { inblk=0; next }
  inblk && /^[[:space:]]*#/ && $0 ~ pat { print FILENAME }
' | sort | uniq -c
```

Twelve such comment lines across nine files today. The mirror-image set is worth knowing so nobody "fixes" it: similar references sit **outside** markers in release-excluded files, are never scanned, and need no marker. Adding one there is noise. This class already regressed once in this repo, when a comment cross-referencing a maintainer-only workflow leaked onto adopters.

**Embedded awk programs carry their own comments.** They live inside single-quoted shell strings, so they are awk comments rather than shell comments: genuinely deletable as commentary, but a sweep that treats them as shell lines risks disturbing the surrounding quoting. They concentrate in the awk-densest scripts, which today are `verify-audit-roster.sh`, `.specify/extensions/gaia/lib/uat-write.sh`, `write-audit-remits.sh`, and `audit-respawn-prune.sh`. Hand-reviewed pass only.

## 3. Two shape hazards a rewording creates

**A comment whose first word is `shellcheck` is parsed as a directive.** A malformed one raises SC1072 or SC1073, and this fires even on `# shellcheck-ish` with a hyphen. Rewording is therefore as dangerous as deleting: condensing "The shellcheck binary treats…" to "shellcheck treats…" breaks the parse. Correct the folklore while you are here, because the danger is usually described backwards: this is **not** silent on the gate. Those codes are `error` severity and `.gaia/tests/shell-lint.sh` holds `*.sh` at the `style` floor, so the gate fails loudly. It is silent only for someone running shellcheck ad hoc without checking the exit code.

**Seven library files have no shebang at all** and depend entirely on `# shellcheck shell=bash` as line 1, with a bare `#` on line 2 opening the prose header. The directive *looks like* the first line of that header block, and it is precisely the line a "delete the whole header block" edit takes first. Removing it raises SC2148. Find them with:

```bash
git ls-files '.gaia/scripts/*.sh' '.gaia/statusline/*.sh' '.specify/extensions/gaia/lib/*.sh' |
  while IFS= read -r f; do head -1 "$f" | grep -qE '^#!' || echo "$f"; done
```

## 4. The shell verification oracle

**Shell has no automated comment oracle and one must never be improvised.** Across every tracked `.sh` and `.bats` there are 473 heredoc openers and 1,164 lines carrying a `#` that is not the first non-space character; hundreds of lines inside heredoc bodies begin with `#` and are pure data; and `.gaia/tests/hooks/block-rm-rf.bats` holds a test whose *payload* is heredoc-shaped text inside a single-quoted string, which would fool even a heredoc-aware scanner. **Never regex-sweep shell.**

The discipline, per file, in this order:

1. Compute a heredoc-body line-range map for the file and a directive-line set (`#!`, `# shellcheck …`, the maintainer-only markers), plus the line ranges of any embedded awk or jq program inside a single-quoted string.
2. Compute a line allowlist **before** editing: the exact lines to be deleted or rewritten, every one asserted outside all three sets from step 1.
3. Edit only those lines.
4. **Diff-scope assertion.** A delete-only change has zero `+` lines and every `-` line in the allowlist. A condense change has every `-` line in the allowlist and every `+` line itself a comment line or blank. Anything else is a stop condition.
5. Never merge a full-line comment onto a code line (section 2).

### The five commands

Capture all five green **before** a sweep and again after every shell commit. A comment-only change that flips any of them green to red has broken something real.

```bash
source .gaia/scripts/bats5.sh

# 1. shellcheck over every tracked *.sh and *.bats. Catches comment-SHAPE damage.
bash .gaia/tests/shell-lint.sh

# 2. Every bats suite the runner's six-row table covers.
bash .gaia/tests/run-bats-parallel.sh

# 3. Release leak oracle for shipped shell. Covers .gaia/statusline, .gaia/cli/templates,
#    .gaia/scripts, .claude/hooks, .github/actions, .github/audit, .specify/extensions/gaia/lib.
#    It does NOT read markdown or .claude/rules/**; the grep below is the oracle there.
.gaia/cli/gaia-maintainer release runtime-deps

# 4. Release CLI unit tests, including marker-strip and the distribution guards.
pnpm -C .gaia/cli test --run

# 5. Marker balance. The pattern is ANCHORED, and that is load-bearing.
for f in $(git ls-files '*.sh'); do
  s=$(grep -cE '^[[:space:]]*# gaia:maintainer-only:start$' "$f")
  e=$(grep -cE '^[[:space:]]*# gaia:maintainer-only:end$' "$f")
  [ "$s" -eq "$e" ] || echo "UNBALANCED $s/$e $f"
done
```

**Verified baselines.** Command 3 reports `scanned 128 manifest-backed script(s) … runtime-dependency leaks: none`. Command 5 prints no `UNBALANCED` line, across 14 files carrying 25 balanced pairs. If command 5 names `.gaia/tests/distribution/03-marker-strip.sh`, the pattern lost its anchor; fix the pattern, not the file (section 1).

**Source `bats5.sh` before any bats invocation.** On stock macOS bash 3.2 a `[[ ]]` assertion can skip silently under `set -e`, which is exactly the wrong failure mode for a verification pass. The reasoning lives in `.claude/rules/bats-assertions.md`.

### What each command does and does not cover

- **`gaia-maintainer release runtime-deps`** walks shipped `.sh` files under seven scan globs (`.gaia/statusline`, `.gaia/cli/templates`, `.gaia/scripts`, `.claude/hooks`, `.github/actions`, `.github/audit`, `.specify/extensions/gaia/lib`) looking for runtime path constants. **It never reads markdown and never reads `.claude/rules/**`**, so on a markdown edit it is a guaranteed-green no-op that proves nothing about the `maintainer-paths` constraint. Reaching for it there is the classic wrong-gate mistake.
- **The `maintainer-paths` leak check** lives in `gaia-maintainer release scrub <staging-dir>`, a different verb that needs a staging tree, which is why it is not a cheap mid-work gate.
- **For markdown, the cheap equivalent** is a marker-aware grep over the twelve-prefix `maintainer-paths` pattern that `.gaia/release-scrub.yml` defines:

  ```bash
  leak_pat='\.gaia/cli/src/|\.gaia/cli/test-fixtures/|\.gaia/cli/__tests__/|\.gaia/cli/health/|\.gaia/cli/gaia-maintainer|\.specify/extensions/gaia/test/|\.specify/specs/|\.gaia/tests/|\.gaia/scripts/tests/|\.github/audit/tests/|\.github/forensics/|\.claude/rules/maintainers/'
  for f in .claude/rules/wiki-style.md .claude/agents/code-audit-frontend.md; do
    awk -v pat="$leak_pat" '
      /<!-- gaia:maintainer-only:start -->/ { inblk=1; next }
      /<!-- gaia:maintainer-only:end -->/   { inblk=0; next }
      !inblk && $0 ~ pat { printf "LEAK %s line %d %s\n", FILENAME, FNR, $0 }
    ' "$f"
  done
  ```

  Pair it with a markdown balance check on every file edited:

  ```bash
  test "$(grep -c 'gaia:maintainer-only:start' "$f")" = "$(grep -c 'gaia:maintainer-only:end' "$f")"
  ```

  **One deliberate divergence from the config's pattern, in the fail-loud direction.** The config writes its twelfth alternative as `\.gaia/cli/gaia-maintainer\b`. This grep omits the `\b` on purpose: the check runs through `awk`, whose POSIX ERE has no word-boundary escape, so the anchored form matches nothing and that alternative goes dark. The unanchored form errs toward more matches than the release build flags, so it can raise a false alarm but can never green a real leak. Do not "fix" it to match the config byte for byte.

### What no command catches

Factual staleness of every kind: a citation into an artifact that no longer exists, a hardcoded count that has moved, a "five members" that breaks on the sixth. The loss of a load-bearing gotcha comment. A rewording that keeps a fact but drops the reason it was recorded. There is no test for lost knowledge, which is why the standard's bar is a subject test rather than a volume target, and why a comment that survives review at full length is a better outcome than a shorter one that has stopped saying anything.

## 5. The bats oracle chain

A green suite proves the tests still pass, not that they still test the same things. The class of mistake this chain exists for leaves everything green while testing less, and only the combination of diff-scope, stripped-byte-diff, and sorted name-list catches it deterministically.

**Steps 1 to 6 are static and file-scoped, so an editing agent runs them itself. Step 7 is repo-wide and belongs to whoever coordinates a wave of parallel edits**, because a repo-wide suite run over a sibling's half-finished edits proves nothing in either direction.

1. **Line-scope allowlist computed before editing**, excluding every heredoc-body line, every directive line, **and every line inside a multi-line quoted string**. The quoted-string exclusion is the reason this chain has the shape it does: a heredoc-aware scanner does not see quoted-string payload at all, and `.gaia/scripts/tests/` carries 40 line-leading `# shellcheck disable=SC1090` directives that belong to an *inner* script inside a `bash -c '…'` body and sit at line start.
2. **A short hard-exclusion list, applied unconditionally on top of any computed exclusion.** Two comment lines in `.gaia/scripts/tests/check-hook-scope-manifest.bats` and one in `.gaia/scripts/tests/read-audit-ci-config.bats` are comment-shaped **test payload**, and all four of this chain's other checks go green on all three. The two in the first file are the payload of tests proving that a comment mentioning a guarded path does *not* trip a check; delete one and the check passes while proving nothing, because its fixture no longer mentions the path. The third is the second line of a two-line comments-only config fixture. Nothing but an explicit exclusion catches these.
3. **Do not build a generic quote-state machine.** Prose comments on that surface are dense with apostrophes, so a naive quote tracker false-positives by the thousand, and a corrected one still misreads deliberate quote-and-backslash torture cases. Use an exclusion list, not a smarter scanner, and where a file's mapping is ambiguous, skip the file and say so.
4. **Diff-scope assertion** per section 4 step 4, plus a comment-and-blank-stripped byte diff of the file before against after, using a pattern that already excludes the step 1 ranges. It must be empty.
5. **Sorted `@test` name-list diff, computed from the FILES, never from runner output.** `grep -oE '@test "[^"]+"' <file> | sort` before and after; identical. The from-the-files requirement is load-bearing; see the coverage map below.
6. **Directive inventory diff, with three tightened greps.**
   - **Two shebang inventories, counted separately.** Line-1 shebangs and heredoc-body stub shebangs are different populations. A bare `^#!` count returns 100 against 79 real file shebangs on `.gaia/scripts/tests/`, 27 against 14 on `.github/audit/tests/`, and 11 against 6 on `.github/forensics/tests/`. A combined count reports no change while a file shebang was deleted and a heredoc stub shebang was added. All 108 `.bats` files under `.gaia/tests/` carry a line-1 shebang.
   - **The bats-tag grep must anchor.** The repo uses **zero** bats-native tagging: no `# bats file_tags=` or `# bats test_tags=` anywhere on any of the four bats surfaces, so no comment deletion can silently drop a test from a tag-filtered run. Do not create one. But the obvious grep is wrong: `^[[:space:]]*#[[:space:]]*bats` returns 8 hits on `.gaia/scripts/tests/` and 2 more on `.gaia/tests/`, every one an ordinary comment beginning with the word "bats". Ten phantom directives would mask a real delta. Anchor on `^[[:space:]]*#[[:space:]]*bats[[:space:]]+(file_tags|test_tags)=`, which returns 0 everywhere.
   - `# shellcheck` directive count and content unchanged. This is the check that catches the inner-script `SC1090` directives, but only if the two greps above are clean.
7. **(Coordinator, once per wave)** `bash .gaia/tests/run-bats-parallel.sh` and `bash .gaia/tests/shell-lint.sh`.

### Comment-shaped payload that is not commentary

Beyond the quoted-string case, heredoc bodies carry line-leading `#` lines that would satisfy a naive `^[[:space:]]*#` sweep while being pure data: golden fixture content compared byte for byte, markdown section headers a parser under test is required to recognise, and stub-script shebangs for `PATH`-shadowing binaries. Map them before editing rather than counting them after:

```bash
git ls-files '*.bats' | xargs awk '
  FNR==1 { inbody=0; delim="" }
  inbody { line=$0; sub(/^[ \t]+/, "", line)
           if (line == delim) { inbody=0; next }
           if ($0 ~ /^[[:space:]]*#/) print FILENAME; next }
  match($0, /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*/) {
    tok=substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", tok)
    gsub(/['"'"'"]/, "", tok); delim=tok; inbody=1 }
' | sort | uniq -c | sort -rn | head
```

That tracker over-reads, because it treats a `<<` inside a string as an opener, which is the point: it is a candidate map to review by hand, never an allowlist to act on. **The dangerous compound mistake is editing both a heredoc and the golden fixture it is compared against**, which passes while silently testing a different value than the fixture's own name promises.

### The coverage map, for all four bats directories

`run-bats-parallel.sh`'s `builtin_table` enumerates exactly six directories: `.github/audit/tests/`, `.gaia/scripts/tests/`, `.gaia/tests/forensics/`, `.gaia/tests/hooks/`, `.gaia/tests/lib/`, and `.gaia/tests/statusline/`.

- It therefore reaches **neither `.gaia/tests/sandbox/` nor `.gaia/tests/concurrency/`**, which run only through their own scripts under a CI workflow, nor `.gaia/tests/prose-audit/`, which appears in no paths-filter and has **no CI oracle at all**. An edit in any of those three needs its own direct run under `bats5`, and a sweep should simply not go there. Two of the sandbox tests also self-skip in CI by design, so a comment edit inside them is exercised by nothing but a correctly configured local run.
- **`.gaia/scripts/tests/` is fully covered**: all 79 files sit flat in one directory and the runner invokes a non-recursive `bats <dir>`, so every one runs. The latent hazard worth recording is that a `.bats` file added under a `fixtures/` subdirectory would silently not run. None exists today.
- **`.github/audit/tests/` and `.github/forensics/tests/` are both covered too**, the second only transitively: `.gaia/tests/forensics/unit.bats` delegates the whole directory through **one** `@test`. So 176 test names collapse into a single line of runner output. **Build a `@test` name list from the files, never from a runner.**
- On `.gaia/scripts/tests/` the residual gap is its 79 `skip` guards: 6 behind an absent zsh and 6 behind an absent shellcheck self-skip where the tool is missing, so a green CI run is not proof that every touched test body executed.

### Two cross-surface interlocks

Both cross a directory boundary, and neither is discoverable from the file that would break.

- **`.gaia/scripts/tests/check-worktree-reap-suite-preserved.bats` pins 17 verbatim `@test "…" {` lines from `.gaia/tests/hooks/local-janitor-worktree-reap.bats`** and asserts that file's `^@test` count stays at or above a floor of 38; it carries 46 today. Comment-only edits cannot break it, because neither check reads comment lines, but anyone editing the hooks suite can red a guard in a directory they never opened.
- **Three `.github/audit/tests/` assertions read the CONTENT of `.github/workflows/code-review-audit.yml`, and the extraction does not strip `#` lines.** A comment in that workflow containing the maintainer-only marker string reds one; a comment containing the literal `specify|wiki` reds another; and a comment inside a workflow `run:` block containing `bash .github/audit/cra-status-upsert.sh` satisfies a per-step assertion **vacuously**, leaving the test green while the step it checks no longer calls the script. **Anyone editing a workflow file runs `bats .github/audit/tests/` as part of their own verification**, because that is where the blast radius lands.

## 6. Coverage gaps on the shell surface

The fail-quiet shape this repo hardens against does not apply here. 75 of the 78 shell files are named by at least one bats suite, and a comment-only change to this surface does arm its own tests: `.gaia/audit-ci.yml`'s `code-audit-maintainer-shell` member globs the executable surface as `.gaia/**/*.sh`, `.gaia/**/*.bats`, `.claude/hooks/**/*.sh`, `.specify/extensions/gaia/lib/*.sh`, `.github/**/*.sh`, `.github/**/*.bats`, and `.husky/**`, and carries a further declarative surface beyond those (config, roster, and rule files), so read the roster rather than this list when the question is whether an edit arms the member. `shell-lint.yml` runs on every pull request with a `shell:` filter matching `**/*.sh` and `**/*.bats`, so any edit here arms shellcheck over the whole tree.

**The 78-file surface below is `.gaia/scripts` plus `.gaia/statusline` plus the spec-kit lib. This rule also activates on `.claude/hooks/**/*.sh`, a further 54 files**, so a hook is in scope for the rule while sitting outside the inventory that follows. Read the fourth bullet before concluding a hook is covered.

Four files are the real risk surface:

- **`.gaia/scripts/verify-cli-bundle-fresh.sh`**, the CLI-bundle freshness check. No bats suite, but two CI workflows execute it and it has its own paths-filter entry, so a comment edit does arm it.
- **`.specify/extensions/gaia/lib/uat-write.sh`**, the UAT writer. Around a hundred comment lines behind a smoke script only: not bats, not CI-gated. Exclude it from any mechanical sweep and hand-review instead.
- **`.gaia/statusline/preferred-base.sh`**, the statusline preferred-base helper. Genuinely zero automated coverage, nine `#` lines in total, release-excluded. The least interesting file on the surface.
- **`.claude/hooks/lib/gaia-ci-defer.sh`**, on the hooks half of this rule's activation scope. No bats suite names it, so it is the hook-side equivalent of the three above and the reason the inventory cannot stop at 78 files.

**The surface's real extent is 78 files**, and the arithmetic is worth stating because a plausible reading double-counts one file. `git ls-files '.gaia/scripts/*.sh'` returns 56, and that 56 **already includes** `.gaia/scripts/lib/serena-lang.sh`, because `*` in a git pathspec matches `/` where a shell glob would not. So the surface is 56 under `.gaia/scripts` (55 flat plus one nested) plus 2 under `.gaia/statusline` plus 20 under the spec-kit extension lib. Adding a separate `.gaia/scripts/lib/*.sh` glob to the first one counts `serena-lang.sh` twice; conversely, a plain shell glob in a `for` loop sees only 55 and misses it. Check with:

```bash
git ls-files -- .gaia/scripts | grep -c '\.sh$'
git ls-files -- .gaia/scripts | grep -cE '^\.gaia/scripts/[^/]+\.sh$'
```

## 7. The comment-density metric

The success measure that does not depend on taste, and the one claim this effort can make honestly.

**What it measures:** median comment-line density of **newly created** files, by file-creation month, per language. New files rather than the whole corpus, because a corpus cleanup buys one cleanup and then refills within weeks. The authoring rate is the thing under test.

**How to run it.** This command is the artifact. Do not turn it into a committed script: a new file under `.gaia/scripts/` would need a `.gaia/release-exclude` entry, which is a release-boundary change and its own distribution-audit question, and an untested new `.sh` is a silent-green liability.

```bash
git ls-files -- '*.ts' '*.tsx' '*.sh' '*.bats' | while IFS= read -r f; do
  [ -f "$f" ] || continue
  # -s suppresses the patch that --diff-merges would otherwise print into %as.
  created=$(git log --diff-merges=first-parent --follow --diff-filter=A --format=%as -1 -s -- "$f")
  [ -n "$created" ] || continue
  month=${created%-*}
  case "$month" in
    2026-0[5-9]|2026-1*|202[7-9]-*) bucket=$month ;;
    *) bucket='pre-2026-05' ;;
  esac
  total=$(grep -c '' "$f")
  [ "$total" -gt 0 ] || continue
  case "$f" in
    *.ts|*.tsx) lang=ts;   c=$(grep -cE '^[[:space:]]*(//|/\*|\*)' "$f") ;;
    *.sh)       lang=sh;   c=$(grep -cE '^[[:space:]]*#' "$f") ;;
    *.bats)     lang=bats; c=$(grep -cE '^[[:space:]]*#' "$f") ;;
  esac
  awk -v b="$bucket" -v l="$lang" -v c="$c" -v t="$total" \
    'BEGIN{printf "%s\t%s\t%.4f\n", b, l, 100*c/t}'
done | awk -F'\t' '
  { k=$1"\t"$2; v[k]=v[k]" "$3 }
  END {
    for (k in v) {
      m=0; split("", s); n=split(v[k], a, " ")
      for (i=1;i<=n;i++) if (a[i]!="") s[++m]=a[i]+0
      for (i=2;i<=m;i++) { x=s[i]; j=i-1; while (j>0 && s[j]>x) { s[j+1]=s[j]; j-- } s[j+1]=x }
      med = (m%2) ? s[(m+1)/2] : (s[m/2]+s[m/2+1])/2
      printf "%s\t%.1f%%\tn=%d\n", k, med, m
    }
  }' | sort
```

Three things about it are load-bearing:

- **`--follow --diff-filter=A` together** is what keeps renames from moving the numbers. Without the pair a renamed file dates from its rename rather than its birth. The pair shifts every cell by at most half a point and changes no ranking.
- **`-s` is required.** `--diff-merges` turns on patch output, which lands in the `%as` field and silently buckets every file into the oldest bucket. The failure is invisible: the command still prints a plausible table.
- **The raw `#` count over-reads shell** by roughly 4.4 points, because directives are about 2.7% of hash-prefixed lines. Read shell as directional, not exact.

**The honest limits, all four.** State them whenever the number is quoted, or the metric gets over-claimed the first time someone reads it.

- **TypeScript is the finding.** Shell and bats are weak directional support only: comparing the July-plus-August pair against the May-plus-June pair, neither clears significance (shell p=0.084, bats p=0.055). Do not claim "consistent across three languages".
- **Both confounds are dead.** Renames, per the `--follow --diff-filter=A` note above. And "small files are arithmetically denser": August is the highest month in **every** TS size bucket, including files over 250 lines, at 31.5% against 8 to 10 points for May through July.
- **The August cell rests on a very small n.** Re-measure before treating its magnitude as established.
- **File size is a real driver within a single surface** (a 3.7x gradient inside the CLI's non-test source), and some of the regression is single-symbol modules that exist so a constant can carry a docblock. Decomposition is a lever, not a confound that explains the number away.

**Cadence: monthly.** Append one row per month under `## Measurements` below. That heading is the ledger. It is the only durable record, and it lives here rather than in a wiki page because a shipped page would put GAIA's own numbers on an adopter's machine.

## Measurements

Median comment-line density by file-creation month, per language, with the count of files created in that month. Each row is a whole-month measurement taken once the month is complete; a mid-month re-run is a spot check, not a row.

| Created | TS/TSX | Shell | Bats |
|---|---|---|---|
| pre-2026-05 | 0.0% (n=79) | | |
| 2026-05 | 7.8% (n=182) | 32.8% (n=60) | 17.2% (n=27) |
| 2026-06 | 12.1% (n=58) | 46.5% (n=16) | 25.3% (n=19) |
| 2026-07 | 12.2% (n=58) | 40.2% (n=95) | 22.6% (n=128) |
| 2026-08 | 34.9% (n=14) | 52.8% (n=12) | 28.8% (n=25) |

The baseline row set is measured repo-wide across 782 files and independently replicated over 893 files by an adversarial pass landing within a point.
