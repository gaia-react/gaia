# /gaia-serena-sync

The on-demand reconcile surface for Serena language drift. When an adopter's Serena-registered project grows a language Serena is not indexing, `/gaia-serena-sync` reports the missing languages, prints a literal in-place edit instruction, and presents **one** consent prompt covering the whole drifted set. On an explicit yes it appends the missing tokens to the `languages:` list in `.serena/project.yml` via the shared library, reusing the list's exact indentation and style, keeping every other line byte-identical, then tells the adopter to restart Serena. With no drift it reports in sync and writes nothing. Any config form it cannot edit safely routes to a prompt-only fallback. It never runs `serena project create`.

## Execution model, READ FIRST

Execute the playbook yourself in the current conversation. It is short and human-gated: the single write is gated behind one `AskUserQuestion`, and nothing mutates `.serena/project.yml` until the adopter explicitly says yes. Steps 0 and 1 are inert exits for adopters who do not run Serena or whose project is already in sync; run them first and stop early when they apply.

All work goes through the shared library `.gaia/scripts/lib/serena-lang.sh` (Phase 1). Drive it via its executable subcommands; do not reimplement any of its detection or append logic here.

## Step 0: Preconditions and inert exit

Resolve the project root:

```bash
ROOT="$(git rev-parse --show-toplevel)"
```

- If the library is missing (`.gaia/scripts/lib/serena-lang.sh` absent), report that Serena sync is unavailable in this project and stop. Nothing else runs.
- Otherwise check that Serena is active for this project:

  ```bash
  bash .gaia/scripts/lib/serena-lang.sh registered "$ROOT"
  ```

  If this exits **non-zero** (Serena is not a registered MCP server), OR `.serena/project.yml` is **absent**, report clearly that **Serena is not active for this project** and stop. The command is inert for non-Serena adopters.

Use the `registered` subcommand here rather than inferring inertness from an empty `drift`. An unregistered (or unconfigured) project and a genuinely-in-sync project are different states and must read differently to the adopter: "Serena is not active" here versus "Serena is in sync" in Step 1.

## Step 1: Recompute current drift (the cache may be stale)

The statusline nudge reads a TTL-cached value that can lag reality, so recompute drift live:

```bash
bash .gaia/scripts/lib/serena-lang.sh drift "$ROOT"
```

This prints a compact JSON array of missing base-language tokens (e.g. `["go"]`, `["python","go"]`) or `[]`. It already gates on Serena being registered and `.serena/project.yml` being present, so an empty array here means "nothing to do" for any reason.

- If the array is **empty** (`[]`): report that **Serena is in sync; no missing languages**, and stop. Write nothing.

Keep the drifted token array from this step; the later steps operate on it.

## Step 2: Report the drift and classify the config form

- Name the missing tokens in plain language, e.g. "Serena is not indexing: `go`".
- Print a **literal, in-place edit instruction** that names the file and the list, so the adopter always has a manual path even if the automated apply is declined or unavailable. For example:

  > Add `go` to the `languages:` list in `.serena/project.yml`.

  For multiple missing tokens, name each one in the same instruction. This literal manual instruction is always shown, in every path from here on.

- Classify the file's `languages:` form:

  ```bash
  bash .gaia/scripts/lib/serena-lang.sh classify .serena/project.yml
  ```

  - If it prints `unsafe:<reason>` (exits non-zero): go to **Step 4** (prompt-only fallback).
  - If it prints `block:<indent>` or `flow` (exits 0): go to **Step 3** (offer the apply).

## Step 3: One consent prompt covering the whole drifted set

Present exactly **one** `AskUserQuestion` for the entire drifted set (never one prompt per language):

- **header:** `"Serena sync"`
- **question:** name the whole drifted set, e.g. `"Append the missing language(s) to .serena/project.yml? Missing: go"`
- **options (this exact order):**
  1. `{ label: "Apply", description: "Append all missing languages to .serena/project.yml now." }`
  2. `{ label: "Skip", description: "Show the manual instruction; write nothing." }`

**Write nothing before the adopter answers.** The manual instruction from Step 2 already stands regardless of the answer.

### On Apply

Append every drifted token in one call (pass the whole set):

```bash
bash .gaia/scripts/lib/serena-lang.sh append .serena/project.yml <tok1> [tok2 ...]
```

- **If it exits 0:** confirm the append and **instruct the adopter to restart Serena** (or restart their Claude session) so the newly added language is indexed. Serena reads `.serena/project.yml` once at startup and never re-detects, so the language is not indexed until a restart.

  **Then clear the stale statusline nudge (loop closure).** The statusline reads `serenaLangDrift` from the TTL-cached `.gaia/local/cache/shared/update-check.json`, which does not recompute on the 6h TTL early-exit. Without this step the nudge persists for up to 6h after the adopter has already synced. Recompute drift and rewrite just that one field, preserving every other cache field, when the cache file exists:

  ```bash
  CACHE=".gaia/local/cache/shared/update-check.json"
  if [ -f "$CACHE" ] && command -v jq >/dev/null 2>&1; then
    NEW_DRIFT="$(bash .gaia/scripts/lib/serena-lang.sh drift "$ROOT")"   # now [] (or any remaining set)
    TMP="$(mktemp)"
    jq --argjson d "$NEW_DRIFT" '.serenaLangDrift = $d' "$CACHE" > "$TMP" && mv "$TMP" "$CACHE"
  fi
  ```

  Update only `serenaLangDrift`; do not stamp `checkedAt` and leave every other field untouched. This is the resolving-command half of the cache-field contract: peer cache-busts must not drop the field, and this command must update it once the drift is resolved.

- **If it prints `FALLBACK:<reason>` and exits non-zero** (a form that looked safe to `classify` but failed a check at append time, or a race): fall through to **Step 4**.

### On Skip

Leave `.serena/project.yml` unchanged. The literal manual instruction from Step 2 stands; the adopter can apply it by hand. Never invoke `serena project create`.

If the command otherwise completes without an explicit yes, treat it as Skip: no write.

## Step 4: Prompt-only fallback (unsafe form)

Reached when the config form cannot be edited safely (from `classify` in Step 2, or a `FALLBACK:<reason>` from the append in Step 3).

- Report that GAIA will not edit this config form automatically, and name the reason category in plain language (e.g. "the `languages:` block uses YAML anchors GAIA will not rewrite", "there is no `languages:` list to append to", "more than one `languages:` key is present").
- Show the literal manual instruction from Step 2, and make a "show me the manual instruction" affordance available so the adopter can re-request it.
- **Write nothing.** Never invoke `serena project create`.

## Guardrails

- **Never mutate `.serena/project.yml` without explicit consent.** Default posture: show the instruction, do not write.
- **One `AskUserQuestion` for the whole drifted set.** Apply all on yes, none on no. A subset is only reachable via the manual path, never by prompting per language.
- **Never run `serena project create`.** It may regenerate the file and clobber `.serena/project.local.yml` customizations. This command only ever appends to an existing list, never regenerates the file.
- **Never remove or reorder existing entries, never rewrite unrelated fields, never leave the file invalid YAML.** Any unsafe form routes to the Step 4 prompt-only fallback. The library owns byte-identity; this command only decides whether to invoke it.
- **Always instruct a Serena or session restart on a successful apply.** The appended language is not indexed until Serena restarts.
- **Always show the literal manual instruction** naming `.serena/project.yml` and the `languages:` list, in every path once drift is found.
- Use repo-relative paths only.
