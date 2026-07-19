#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit hook: deny a YAML-bearing write (a
# .yml/.yaml file, or Markdown --- frontmatter) that newly breaks the YAML
# region it targets, valid before this call, invalid after.
#
# tech-debt #867: Claude repeatedly authors invalid YAML plain scalars, most
# often a mid-sentence ": " (read as a mapping-key separator) or a stray " #"
# (read as a comment, silently truncating the value), and only discovers it
# when a downstream parser or lint fails, sometimes on an already-saved
# immutable artifact. .specify/extensions/gaia/lib/lint.sh catches the same
# class in SPEC frontmatter, but only at save-time, after the round trip this
# hook exists to prevent, and only for one surface; this hook is structural
# (any .yml/.yaml, any .md carrying --- frontmatter) rather than a directory
# allowlist, since the highest-frequency case (frontmatter inside .md) is
# exactly what a naive extension-only scope misses.
#
# Regression-only, never a blanket validity gate: this hook compares the
# region's state before and after the call and denies only a valid -> invalid
# transition this call itself causes. A repo scan while authoring this hook
# found pre-existing broken frontmatter already sitting in several tracked
# files; a "the resulting file must be valid" rule would have permanently
# locked out any further, unrelated edit to those files. Regression-only
# means the hook never blocks a file already broken by prior debt.
#
# Detect and pinpoint only, never auto-heal: a malformed scalar's intended
# form (quote it vs. it was meant to be a mapping key) is not provable from
# the parse failure alone, so the agent repairs it; this hook only says where
# and why.
#
# Fail-open, matching the other block-*.sh guards: no python3+pyyaml, an
# Edit/MultiEdit target that doesn't exist yet, or an old_string this hook
# can't locate in the current file all allow the call rather than blocking a
# legitimate edit on a heuristic miss.
set -euo pipefail

payload=$(cat)
tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

case "$tool_name" in
  Edit | Write | MultiEdit) ;;
  *) exit 0 ;;
esac

file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[[ -n "$file_path" ]] || exit 0

case "$file_path" in
  *.yml | *.yaml | *.md) ;;
  *) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1 || exit 0

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Reconstructs the file's content before and after this call (Write's content
# is already the full "after"; Edit/MultiEdit apply their old_string ->
# new_string replacement(s) against the current on-disk "before", mirroring
# what the real tool is about to do), extracts each side's YAML region, and
# compares. Prints a message and exits 1 only on a valid -> invalid
# transition; exits 0 (silently) otherwise, including when the region was
# already invalid before this call (see the regression-only note above).
PY_SCRIPT=$(cat <<'PYEOF'
import json
import re
import sys

import yaml


def apply_edit(current, old, new, replace_all):
    if old not in current:
        return None
    if replace_all:
        return current.replace(old, new)
    return current.replace(old, new, 1)


def yaml_region(file_path, text):
    if file_path.endswith((".yml", ".yaml")):
        return text
    if file_path.endswith(".md"):
        m = re.match(r"^---\r?\n(.*?\r?\n)---\r?\n", text, re.DOTALL)
        return m.group(1) if m else None
    return None


# A YAML comment must be preceded by whitespace, so `key: value #trailing`
# parses cleanly and yaml.safe_load never raises: it just silently drops
# everything from the ` #` onward. This is the second footgun tech-debt #867
# names ("sweep #9" -> "sweep"), and a successful parse can't surface it, so
# it needs its own scan rather than living inside the try/except below.
# Skips quoted/flow/block-scalar values (already immune by construction) and
# tracks block-scalar bodies by indentation so literal `#` characters inside
# a `|`/`>` block never false-positive.
KEY_LINE_RE = re.compile(r"^(?P<indent>[ \t]*)(?:-\s+)?[\w.\-]+:[ \t]+(?P<value>.+?)\s*$")
BLOCK_START_RE = re.compile(r":[ \t]*[|>][+-]?\d*[ \t]*$")


def find_space_hash_truncations(region):
    problems = []
    block_indent = None
    for line in region.split("\n"):
        if block_indent is not None:
            stripped = line.strip()
            indent = len(line) - len(line.lstrip(" \t"))
            if stripped == "" or indent > block_indent:
                continue
            block_indent = None
        if BLOCK_START_RE.search(line):
            block_indent = len(line) - len(line.lstrip(" \t"))
            continue
        m = KEY_LINE_RE.match(line)
        if not m:
            continue
        value = m.group("value")
        if value[:1] in ('"', "'", "[", "{", "|", ">"):
            continue
        if " #" in value:
            problems.append(line.strip())
    return problems


def check_region(region):
    """(parse_ok, parse_err, set-of-truncation-lines). A missing region
    (no frontmatter yet, or the file didn't exist) counts as valid: there is
    nothing prior to regress from."""
    if region is None:
        return True, "", set()
    try:
        yaml.safe_load(region)
        parse_ok, parse_err = True, ""
    except yaml.YAMLError as exc:
        parse_ok, parse_err = False, str(exc).replace("\n", " ")
    return parse_ok, parse_err, set(find_space_hash_truncations(region))


# Returns a deny message on a genuine, newly-introduced regression, or None
# to allow. Any exception escaping here (not just a missing file: a
# non-UTF-8 read is UnicodeDecodeError, a ValueError subclass, not OSError)
# is caught by the top-level call below and treated as None, matching the
# hook's own fail-open contract: an internal bug must never turn into a
# surprise deny.
def main():
    payload = json.load(sys.stdin)
    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input", {})
    file_path = tool_input.get("file_path", "")

    if tool_name == "Write":
        after_text = tool_input.get("content", "")
        try:
            with open(file_path, "r", encoding="utf-8") as fh:
                before_text = fh.read()
        except OSError:
            before_text = None
    elif tool_name in ("Edit", "MultiEdit"):
        try:
            with open(file_path, "r", encoding="utf-8") as fh:
                before_text = fh.read()
        except OSError:
            return None
        after_text = before_text
        edits = [tool_input] if tool_name == "Edit" else tool_input.get("edits", [])
        for edit in edits:
            nxt = apply_edit(
                after_text,
                edit.get("old_string", ""),
                edit.get("new_string", ""),
                bool(edit.get("replace_all", False)),
            )
            if nxt is None:
                return None
            after_text = nxt
    else:
        return None

    after_region = yaml_region(file_path, after_text)
    if after_region is None:
        return None

    before_region = yaml_region(file_path, before_text) if before_text is not None else None

    before_ok, _before_err, before_trunc = check_region(before_region)
    after_ok, after_err, after_trunc = check_region(after_region)

    if before_ok and not after_ok:
        return after_err

    new_trunc = after_trunc - before_trunc
    if new_trunc:
        example = sorted(new_trunc)[0]
        return f"unquoted ' #' in a plain scalar silently truncates the value as a comment: \"{example}\""

    return None


try:
    deny_reason = main()
except Exception:
    deny_reason = None

if deny_reason is not None:
    print(deny_reason)
    sys.exit(1)
PYEOF
)

yaml_err=""
yaml_parse_failed=0
if ! yaml_err=$(printf '%s' "$payload" | python3 -c "$PY_SCRIPT" 2>&1); then
  yaml_parse_failed=1
fi

if [[ "$yaml_parse_failed" -eq 1 ]]; then
  deny "BLOCKED: '$file_path' would newly produce broken YAML: $yaml_err. This is the plain-scalar footgun from tech-debt #867: a bare ': ' or ' #' inside prose, or a value starting with a YAML indicator character, reads as structural YAML, not text (the ' #' case parses fine and silently drops everything after it). Quote the value, or use a block scalar (| or >-), then re-check."
fi

exit 0
