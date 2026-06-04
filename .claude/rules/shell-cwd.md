# Shell CWD

Do not `cd` in Bash tool calls. Use absolute paths for every command.

## Why

`.claude/settings.json` registers Stop and PreToolUse hooks with **relative** command paths (e.g. `.claude/hooks/wiki-session-stop.sh`). They resolve from the shell's current directory. A single `cd` inside a Bash call persists for the rest of the session and makes every relative-path hook fail with `No such file or directory` until the shell returns to the repo root.

## How to apply

- `rm /abs/path/file`, not `cd /abs/path && rm file`
- `git -C /abs/path status`, not `cd /abs/path && git status`
- `ls /abs/path`, not `cd /abs/path && ls`

If the user explicitly asks for `cd`, follow with an absolute `cd` back to the repo root in the same call.
