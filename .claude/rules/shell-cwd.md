# Shell CWD

Do not `cd` in Bash tool calls. Use absolute paths for every command.

## Why

`.claude/settings.json` roots every hook registration at the current tree, so a hook command resolves independently of the shell's working directory, and `.gaia/scripts/check-hook-command-rooting.sh` holds it to that. What a `cd` still moves is every *other* relative path: the working directory it sets persists for the rest of the session, so a later command written against the repo root resolves somewhere else.

## How to apply

- `rm /abs/path/file`, not `cd /abs/path && rm file`
- `git -C /abs/path status`, not `cd /abs/path && git status`
- `ls /abs/path`, not `cd /abs/path && ls`

If the user explicitly asks for `cd`, follow with an absolute `cd` back to the repo root in the same call.
