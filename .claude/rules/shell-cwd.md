# Shell CWD

Do not `cd` in Bash tool calls. Use absolute paths for every command.

## Why

`.claude/settings.json` roots every hook registration at the tree the working directory is in, and `.gaia/scripts/check-hook-command-rooting.sh` holds it to that, so a `cd` to any depth *inside this repository* keeps the guard layer registered. The root is derived per invocation, not pinned, so it follows the working directory out of the repository too: a `cd` into a sibling checkout roots every hook at that checkout, the scripts are absent, `/bin/sh` exits 127, and because 127 neither blocks nor is reported, the whole `PreToolUse` layer fails open silently. Nothing at the registration site can close that, which is why this rule is a directive and not merely a convention. What a `cd` moves in every case is each *other* relative path: the working directory it sets persists for the rest of the session, so a later command written against the repo root resolves somewhere else.

## How to apply

- `rm /abs/path/file`, not `cd /abs/path && rm file`
- `git -C /abs/path status`, not `cd /abs/path && git status`
- `ls /abs/path`, not `cd /abs/path && ls`

If the user explicitly asks for `cd`, follow with an absolute `cd` back to the repo root in the same call.
