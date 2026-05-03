---
name: add-locale
description: Add a single locale to the GAIA i18n setup. Parameterized — substitute LOCALE_CODE / LANGUAGE_NAME_EN / LANGUAGE_NAME_NATIVE / IS_RTL before executing.
---

# add-locale instruction

## Variable substitution

Before executing any step, verify all four variables below have been replaced with real values. If any variable is still in `{{...}}` form, **refuse to proceed** and report which variables are unsubstituted.

| Variable                  | Expected form                                      |
| ------------------------- | -------------------------------------------------- |
| `{{LOCALE_CODE}}`         | ISO 639-1 lowercase, e.g. `pl`, `es`, `ja`, `ar`  |
| `{{LANGUAGE_NAME_EN}}`    | English display name, e.g. `Polish`                |
| `{{LANGUAGE_NAME_NATIVE}}`| Native display name, e.g. `Polski`, `العربية`      |
| `{{IS_RTL}}`              | `true` or `false`                                  |

---

## Step 1 — Mirror the English language tree

For each file under `/Users/stevensacks/Development/gaia-react/gaia/app/languages/en/`, create the same path under `/Users/stevensacks/Development/gaia-react/gaia/app/languages/{{LOCALE_CODE}}/` with the same TypeScript module shape (same keys, same exports).

Files to create (mirroring the `en/` tree):

- `/Users/stevensacks/Development/gaia-react/gaia/app/languages/{{LOCALE_CODE}}/common.ts`
- `/Users/stevensacks/Development/gaia-react/gaia/app/languages/{{LOCALE_CODE}}/errors.ts`
- `/Users/stevensacks/Development/gaia-react/gaia/app/languages/{{LOCALE_CODE}}/index.ts`
- `/Users/stevensacks/Development/gaia-react/gaia/app/languages/{{LOCALE_CODE}}/pages/_index.ts`
- `/Users/stevensacks/Development/gaia-react/gaia/app/languages/{{LOCALE_CODE}}/pages/index.ts`
- `/Users/stevensacks/Development/gaia-react/gaia/app/languages/{{LOCALE_CODE}}/pages/legal.ts`

Translation rules:

- Translate all user-visible string values from English to `{{LANGUAGE_NAME_EN}}`.
- If a confident translation cannot be produced for a key (proper noun, brand name, code identifier embedded in a string, placeholder like `{{count}}` or `{{name}}`), copy the English value verbatim — an English placeholder is better than a wrong translation.
- Keep all TypeScript structure, export shapes, key names, and template literals (`{{count}}`, `{{name}}`, `{{status}}`) identical to the `en/` source. Only string values change.

---

## Step 2 — Register the locale

Edit `/Users/stevensacks/Development/gaia-react/gaia/app/languages/index.ts`:

1. Add `import {{LOCALE_CODE}} from './{{LOCALE_CODE}}';` in alphabetical order among existing locale imports.
2. Append `'{{LOCALE_CODE}}'` to the `LANGUAGES` array, keeping the array alphabetically sorted.
3. Append `| '{{LOCALE_CODE}}'` to the `Language` union type, keeping the union alphabetically sorted.
4. Add `{{LOCALE_CODE}}` to the default export object in alphabetical order among existing keys.

---

## Step 3 — LanguageSelect

Edit `/Users/stevensacks/Development/gaia-react/gaia/app/components/LanguageSelect/index.tsx`:

Append `{label: '{{LANGUAGE_NAME_NATIVE}}', value: '{{LOCALE_CODE}}'}` to the `OPTIONS` array.

Ordering rule: English (`en`) stays at the top of the array. All other options are sorted alphabetically by `label` after English.

---

## Step 4 — Storybook preview

Edit `/Users/stevensacks/Development/gaia-react/gaia/.storybook/preview.ts`:

Inside `initialGlobals.locales`, add an entry for the new locale:

```
{{LOCALE_CODE}}: {left: '<flag emoji>', right: '{{LOCALE_CODE}}', title: '{{LANGUAGE_NAME_NATIVE}}'}
```

Pick the flag emoji from this lookup table:

| Locale code | Flag emoji |
| ----------- | ---------- |
| `ar`        | 🇸🇦         |
| `de`        | 🇩🇪         |
| `es`        | 🇪🇸         |
| `fa`        | 🇮🇷         |
| `fr`        | 🇫🇷         |
| `he`        | 🇮🇱         |
| `hi`        | 🇮🇳         |
| `it`        | 🇮🇹         |
| `ja`        | 🇯🇵         |
| `ko`        | 🇰🇷         |
| `nl`        | 🇳🇱         |
| `pl`        | 🇵🇱         |
| `pt`        | 🇧🇷         |
| `ru`        | 🇷🇺         |
| `sv`        | 🇸🇪         |
| `tr`        | 🇹🇷         |
| `uk`        | 🇺🇦         |
| `ur`        | 🇵🇰         |
| `zh`        | 🇨🇳         |

If `{{LOCALE_CODE}}` is not in the table above, use the locale code in brackets as the left value, e.g. `[{{LOCALE_CODE}}]`.

---

## Step 5 — RTL handling (only if `{{IS_RTL}}` is `true`)

**Only execute this step when `{{IS_RTL}}` is `true`.**

Verify that `/Users/stevensacks/Development/gaia-react/gaia/app/root.tsx` already uses `i18n.dir(i18n.language)` for the `dir` attribute on the HTML element. The seeded template sets this up — i18next handles RTL natively for locales in its known-RTL list.

No additional work is needed for the four standard ISO 639-1 RTL codes that i18next recognizes natively: `ar`, `he`, `fa`, `ur`.

For RTL locales **outside** that standard four (e.g. a custom or less common code), edit `/Users/stevensacks/Development/gaia-react/gaia/app/i18n.ts` to add the locale to the `i18n.services.languageUtils.formatLanguageCode` override list so that i18next returns `'rtl'` for `i18n.dir()` calls with that code.

**If `{{IS_RTL}}` is `false`, skip this step entirely.**

---

## Step 6 — Playwright spec

Check whether `/Users/stevensacks/Development/gaia-react/gaia/.playwright/e2e/language-switch.spec.ts` exists.

**If the file does not exist**, create it as a new spec. The spec must:

- Import from `@playwright/test`.
- Use a `test.describe` block named `'language switch — EN ↔ {{LOCALE_CODE}}'`.
- Test the following flow:
  1. Navigate to `/`.
  2. Assert that the page title (from `app/languages/en/pages/_index.ts` → `meta.title`) is visible in English.
  3. Find the language select and switch to `{{LOCALE_CODE}}`.
  4. Assert that the page title changes to the `{{LANGUAGE_NAME_EN}}` translation (from `app/languages/{{LOCALE_CODE}}/pages/_index.ts` → `meta.title`).
  5. Switch back to English and assert the English title is restored.

**If the file already exists**, append a new `test.describe` block for the new locale following the same shape as the existing blocks. Do not modify existing blocks.

---

## Step 7 — Manifest

Edit `/Users/stevensacks/Development/gaia-react/gaia/.gaia/manifest.json`:

Add the following six entries into the `"files"` object in alphabetical order (mirroring how the `en/` entries are listed):

```json
"app/languages/{{LOCALE_CODE}}/common.ts": "owned",
"app/languages/{{LOCALE_CODE}}/errors.ts": "owned",
"app/languages/{{LOCALE_CODE}}/index.ts": "owned",
"app/languages/{{LOCALE_CODE}}/pages/_index.ts": "owned",
"app/languages/{{LOCALE_CODE}}/pages/index.ts": "owned",
"app/languages/{{LOCALE_CODE}}/pages/legal.ts": "owned",
```

Insert these entries so the overall `"files"` object remains sorted alphabetically by key.

---

## Step 8 — Verify

Run the following from the project root:

```
pnpm typecheck && pnpm lint
```

If either `pnpm typecheck` or `pnpm lint` fails:

- **STOP immediately.**
- Report the exact error output.
- **Do not proceed to Step 9 (self-delete).**

Only proceed to Step 9 if both commands exit with code 0.

---

## Step 9 — Self-delete

On success (both `pnpm typecheck` and `pnpm lint` pass):

```
rm /Users/stevensacks/Development/gaia-react/gaia/.claude/instructions/add-locale.md
```

Print a one-line summary:

```
add-locale {{LOCALE_CODE}} ({{LANGUAGE_NAME_EN}}) — done
```
