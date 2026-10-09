#!/usr/bin/env bats
# Citation check for the three audit-gate pages: the merge runbook
# (`wiki/concepts/PR Merge Workflow.md`), the round procedure
# (`wiki/concepts/Audit Round Procedure.md`) and the gate reference
# (`wiki/concepts/Audit Gate Reference.md`).
#
# Why this suite exists. Rules, skills, commands, agents, hook deny text, script
# error output and wiki pages cite a heading on one of these pages by wikilink
# (`[[Audit Round Procedure#Light routing]]`) or by repo path plus a heading
# (`wiki/concepts/PR Merge Workflow.md` followed by a backticked `#### ...`
# heading, a quoted `"### ..."`, a parenthesized `("...")`, or a bare
# `, #### ...`). Nothing else reads those citations, so a page split or a
# heading rename strands them silently: the citing text still reads fine and
# points at a heading that no longer exists. This suite derives every citation
# from the tracked files that carry them and fails on each one whose heading is
# not on the named page.
#
# What counts as a citation. The heading must follow the page path or the
# wikilink directly, so a path that is merely mentioned in a sentence that
# later quotes some other heading is not read as a citation. A citation split
# over two lines of a comment is not read either. Page-local `[[#Heading]]`
# links are out of scope: a page cannot strand a link to its own heading from
# outside.
#
# Honest limits. This proves each cited heading exists on the cited page, not
# that the page still says what the citing text claims; the doc-pin suites own
# the claims. The derivation reads tracked files only, so a new citing file or
# page must be staged before this suite sees it.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded and out of wiki-style.md's scope.

# bats file_tags=whole-tree

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE_NAMES='PR Merge Workflow|Audit Round Procedure|Audit Gate Reference'
  # The trees that carry citations. `.gaia/scripts/tests/` holds fixtures that
  # name the pages as data, not consumers that cite them.
  CITING_PATHSPEC=(.claude/rules .claude/skills .claude/commands .claude/agents .claude/hooks .gaia/scripts wiki
    ':!wiki/log.md' ':!wiki/meta' ':!.gaia/scripts/tests')
}

# citation_program: the perl program that prints `file TAB line TAB page TAB
# heading` for every citation in the files it is given.
citation_program() {
  cat <<'PERL'
BEGIN { $pages = $ENV{CITATION_PAGES}; exit 0 unless @ARGV; }
while (<>) {
  my $line = $_;
  chomp $line;
  while ($line =~ /\[\[($pages)#([^\]|]+)/g) {
    print "$ARGV\t$.\t$1\t$2\n";
  }
  my @starts;
  while ($line =~ /wiki\/concepts\/($pages)\.md/g) {
    push @starts, [ $1, pos($line), $-[0] ];
  }
  for my $index (0 .. $#starts) {
    my ($page, $after, $begin) = @{ $starts[$index] };
    my $limit = $index < $#starts ? $starts[$index + 1][2] : length($line);
    my $tail = substr($line, $after, $limit - $after);
    my $heading;
    if ($tail =~ /^[`\x27s ,:]{0,8}\(?`#{2,6} ([^`]+)`/) { $heading = $1; }
    elsif ($tail =~ /^[`\x27s ,:]{0,8}\(?"#{2,6} ([^"]+)"/) { $heading = $1; }
    elsif ($tail =~ /^[`\x27s ]{0,4}\("([^"]+)"\)/) { $heading = $1; }
    elsif ($tail =~ /^`?, #{2,6} ([^)]+)/) { $heading = $1; $heading =~ s/[.,;:]+$//; }
    next unless defined $heading;
    $heading =~ s/^\s+|\s+$//g;
    print "$ARGV\t$.\t$page\t$heading\n";
  }
} continue { close ARGV if eof; }
PERL
}

# extract_citations <root>: reads NUL-separated root-relative file paths on
# stdin; prints one `file TAB line TAB page TAB heading` row per citation.
extract_citations() {
  local program root="$1"
  program="$(citation_program)"
  (cd "$root" && xargs -0 env CITATION_PAGES="$PAGE_NAMES" perl -e "$program")
}

# page_headings <root> <page>: every heading text on the page, any level,
# fenced code excluded (a `# comment` inside a fence is not a heading).
page_headings() {
  awk '
    /^```/ { inside_fence = !inside_fence; next }
    !inside_fence && /^#{1,6} / { sub(/^#+ /, ""); sub(/[ \t]+$/, ""); print }
  ' "$1/wiki/concepts/$2.md"
}

# unresolved_citations <root>: reads the citation rows on stdin; prints
# `<file>:<line>: <page>#<heading>` for each whose heading is not on its page
# and exits 1 when any is printed. A missing page leaves every citation of it
# unresolved, so a deleted page is reported rather than skipped.
unresolved_citations() {
  local root="$1" file line page heading headings unresolved_count=0
  while IFS=$'\t' read -r file line page heading; do
    headings=""
    if [ -f "$root/wiki/concepts/$page.md" ]; then
      headings="$(page_headings "$root" "$page")"
    fi
    if ! grep -qxF -- "$heading" <<<"$headings"; then
      printf '%s:%s: %s#%s\n' "$file" "$line" "$page" "$heading"
      unresolved_count=$((unresolved_count + 1))
    fi
  done
  [ "$unresolved_count" -eq 0 ]
}

# tracked_citing_files: NUL-separated tracked files under the citing trees.
tracked_citing_files() {
  git -C "$ROOT" ls-files -z -- "${CITING_PATHSPEC[@]}"
}

# fixture_tree <name>: a scratch tree with one page and nothing else; prints
# its path. The page carries a fenced `# comment` that is not a heading.
fixture_tree() {
  local tree="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$tree/wiki/concepts" "$tree/.claude/rules"
  {
    printf '# Audit Round Procedure\n\n#### Real heading\n\n'
    printf '```bash\n# not a heading\n```\n\n'
    printf '### Heading, with: punctuation\n'
  } >"$tree/wiki/concepts/Audit Round Procedure.md"
  printf '# PR Merge Workflow\n\n## Real runbook heading\n' >"$tree/wiki/concepts/PR Merge Workflow.md"
  printf '# Audit Gate Reference\n\n#### Signals\n' >"$tree/wiki/concepts/Audit Gate Reference.md"
  printf '%s\n' "$tree"
}

# run_check <root> <relative-file>...: extract then resolve; prints the
# unresolved rows and returns the resolver's status.
run_check() {
  local root="$1"
  shift
  printf '%s\0' "$@" | extract_citations "$root" | unresolved_citations "$root"
}

@test "the three pages exist and carry headings" {
  local page
  for page in 'PR Merge Workflow' 'Audit Round Procedure' 'Audit Gate Reference'; do
    [ -n "$(page_headings "$ROOT" "$page")" ] || {
      echo "no headings read from wiki/concepts/$page.md" >&2
      return 1
    }
  done
}

@test "the derived citation set is non-empty and matches an independent wikilink count" {
  local derived_total independent_wikilinks path_form
  derived_total="$(tracked_citing_files | extract_citations "$ROOT" | grep -c . || true)"
  [ "$derived_total" -gt 0 ] || { echo "no citation derived from the tracked tree" >&2; return 1; }
  # Second, independent source: a literal grep over the same pathspec counts
  # every wikilink citation occurrence. Path-form citations are the difference.
  independent_wikilinks="$(git -C "$ROOT" grep -o -h -E "\[\[($PAGE_NAMES)#" -- "${CITING_PATHSPEC[@]}" | grep -c . || true)"
  path_form="$(git -C "$ROOT" grep -l -E "wiki/concepts/($PAGE_NAMES)\.md" -- "${CITING_PATHSPEC[@]}" | grep -c . || true)"
  [ "$independent_wikilinks" -gt 0 ] || { echo "the independent grep found no wikilink citation" >&2; return 1; }
  [ "$path_form" -gt 0 ] || { echo "the independent grep found no path-form file" >&2; return 1; }
  # Every independently counted wikilink is derived, and the path-form
  # citations add to it, so a derivation that read fewer than the grep saw is a
  # short read.
  [ "$derived_total" -ge "$independent_wikilinks" ] || {
    echo "derived $derived_total citations but the grep counts $independent_wikilinks wikilinks alone" >&2
    return 1
  }
}

@test "every citation of a heading on the three pages resolves to a heading on the named page" {
  local unresolved
  unresolved="$(tracked_citing_files | extract_citations "$ROOT" | unresolved_citations "$ROOT")" || {
    printf 'unresolved citations:\n%s\n' "$unresolved" >&2
    return 1
  }
  true
}

@test "seeded-broken fixture: a wikilink to a heading that is not on the page fails the check" {
  local tree
  tree="$(fixture_tree seeded-wikilink)"
  printf 'See [[Audit Round Procedure#Missing heading]] for the rule.\n' >"$tree/.claude/rules/citing.md"
  run run_check "$tree" .claude/rules/citing.md
  [ "$status" -eq 1 ] || return 1
  [ "$output" = '.claude/rules/citing.md:1: Audit Round Procedure#Missing heading' ]
}

@test "seeded-broken fixture: each path-form spelling to a missing heading fails the check" {
  local tree spelling
  tree="$(fixture_tree seeded-path)"
  while IFS= read -r spelling; do
    printf '%s\n' "$spelling" >"$tree/.claude/rules/citing.md"
    run run_check "$tree" .claude/rules/citing.md
    [ "$status" -eq 1 ] || { echo "did not fail for: $spelling" >&2; return 1; }
    grep -qF -- 'Missing heading' <<<"$output" || { echo "heading not reported for: $spelling" >&2; return 1; }
  done <<'SPELLINGS'
Read `wiki/concepts/PR Merge Workflow.md` `#### Missing heading` first.
Read `wiki/concepts/PR Merge Workflow.md`'s `#### Missing heading` section.
Read `wiki/concepts/Audit Round Procedure.md` (`#### Missing heading`) first.
Read `wiki/concepts/Audit Round Procedure.md` ("Missing heading") first.
Read wiki/concepts/Audit Gate Reference.md, "### Missing heading", then go on.
Deny text: see wiki/concepts/PR Merge Workflow.md, ## Missing heading) so it clears.
SPELLINGS
}

@test "fixture control: the same spellings pointing at real headings pass, so the failure above is the heading's" {
  local tree spelling
  tree="$(fixture_tree control)"
  while IFS= read -r spelling; do
    printf '%s\n' "$spelling" >"$tree/.claude/rules/citing.md"
    run run_check "$tree" .claude/rules/citing.md
    [ "$status" -eq 0 ] || { echo "failed for: $spelling ($output)" >&2; return 1; }
    [ -z "$output" ] || return 1
  done <<'SPELLINGS'
See [[Audit Round Procedure#Real heading]].
See [[Audit Round Procedure#Heading, with: punctuation|the rule]].
Read `wiki/concepts/PR Merge Workflow.md` `## Real runbook heading` first.
Read `wiki/concepts/Audit Round Procedure.md`'s `#### Real heading` section.
Read wiki/concepts/Audit Gate Reference.md, "#### Signals", then go on.
Deny text: see wiki/concepts/PR Merge Workflow.md, ## Real runbook heading) so it clears.
SPELLINGS
}

@test "fixture: a heading that exists only inside a code fence does not resolve" {
  local tree
  tree="$(fixture_tree fenced)"
  printf 'See [[Audit Round Procedure#not a heading]].\n' >"$tree/.claude/rules/citing.md"
  run run_check "$tree" .claude/rules/citing.md
  [ "$status" -eq 1 ]
}

@test "fixture: a citation to a deleted page is reported, not skipped" {
  local tree
  tree="$(fixture_tree deleted-page)"
  rm "$tree/wiki/concepts/Audit Gate Reference.md"
  printf 'See [[Audit Gate Reference#Signals]].\n' >"$tree/.claude/rules/citing.md"
  run run_check "$tree" .claude/rules/citing.md
  [ "$status" -eq 1 ] || return 1
  [ "$output" = '.claude/rules/citing.md:1: Audit Gate Reference#Signals' ]
}

@test "fixture: a path mention followed by an unrelated quoted heading is not read as a citation" {
  local tree
  tree="$(fixture_tree not-a-citation)"
  printf 'Per `wiki/concepts/PR Merge Workflow.md`: decide whether a `## [Unreleased]` entry is owed.\n' >"$tree/.claude/rules/citing.md"
  run run_check "$tree" .claude/rules/citing.md
  [ "$status" -eq 0 ]
}
