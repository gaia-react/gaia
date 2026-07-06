---
name: add-locale
description: Add a single locale to the GAIA i18n setup. Parameterized, substitute LOCALE_CODE / LANGUAGE_NAME_EN / LANGUAGE_NAME_NATIVE / IS_RTL before executing.
---

# add-locale instruction

All paths in this file are repo-relative. The executing agent runs from the project root.

## Variable substitution

Before executing any step, verify all four variables below have been replaced with real values. If any variable is still in `{{...}}` form, **refuse to proceed** and report which variables are unsubstituted.

| Variable                   | Expected form                                    |
| -------------------------- | ------------------------------------------------ |
| `{{LOCALE_CODE}}`          | ISO 639-1 lowercase, e.g. `pl`, `es`, `ja`, `ar` |
| `{{LANGUAGE_NAME_EN}}`     | English display name, e.g. `Polish`              |
| `{{LANGUAGE_NAME_NATIVE}}` | Native display name, e.g. `Polski`, `العربية`    |
| `{{IS_RTL}}`               | `true` or `false`                                |

---

## Step 1, Mirror the English language tree

For each file under `app/languages/en/`, create the same path under `app/languages/{{LOCALE_CODE}}/` with the same TypeScript module shape (same keys, same exports).

Files to create (mirroring the `en/` tree):

- `app/languages/{{LOCALE_CODE}}/common.ts`
- `app/languages/{{LOCALE_CODE}}/errors.ts`
- `app/languages/{{LOCALE_CODE}}/index.ts`
- `app/languages/{{LOCALE_CODE}}/pages/_index.ts`
- `app/languages/{{LOCALE_CODE}}/pages/index.ts`
- `app/languages/{{LOCALE_CODE}}/pages/legal.ts`

Translation rules:

- Translate all user-visible string values from English to `{{LANGUAGE_NAME_EN}}`.
- If a confident translation cannot be produced for a key (proper noun, brand name, code identifier embedded in a string, placeholder like `{{count}}` or `{{name}}`), copy the English value verbatim, an English placeholder is better than a wrong translation.
- Keep all TypeScript structure, export shapes, key names, and template literals (`{{count}}`, `{{name}}`, `{{status}}`) identical to the `en/` source. Only string values change.

---

## Step 2, Register the locale

Edit `app/languages/index.ts`:

1. Add `import {{LOCALE_CODE}} from './{{LOCALE_CODE}}';` in alphabetical order among existing locale imports.
2. Append `'{{LOCALE_CODE}}'` to the `LANGUAGES` array, keeping the array alphabetically sorted.
3. Append `| '{{LOCALE_CODE}}'` to the `Language` union type, keeping the union alphabetically sorted.
4. Add `{{LOCALE_CODE}}` to the default export object in alphabetical order among existing keys.

---

## Step 3, LanguageSelect

Edit `app/components/LanguageSelect/index.tsx`:

Add `{{LOCALE_CODE}}: '{{LANGUAGE_NAME_NATIVE}}'` to the `LANGUAGE_LABELS` record (keep `en: 'English'` first). Do **not** edit `OPTIONS`, it is derived automatically by mapping over the `LANGUAGES` array (registered in Step 2) and falls back to the bare locale code when a label is missing. Adding the `LANGUAGE_LABELS` entry is what gives the new option its native display name.

The dropdown's option order follows the `LANGUAGES` array order from Step 2, so there is no manual sorting to do here.

---

## Step 4, Storybook preview

Edit `.storybook/preview.ts`:

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

## Step 5, RTL handling (only if `{{IS_RTL}}` is `true`)

**Only execute this step when `{{IS_RTL}}` is `true`.**

Verify that `app/root.tsx` already uses `i18n.dir(i18n.language)` for the `dir` attribute on the HTML element. The seeded template sets this up, i18next handles RTL natively for locales in its known-RTL list.

No additional work is needed for the four standard ISO 639-1 RTL codes that i18next recognizes natively: `ar`, `he`, `fa`, `ur`.

For RTL locales **outside** that standard four (e.g. a custom or less common code), edit `app/i18n.ts` to add the locale to the `i18n.services.languageUtils.formatLanguageCode` override list so that i18next returns `'rtl'` for `i18n.dir()` calls with that code.

**If `{{IS_RTL}}` is `false`, skip this step entirely.**

---

## Step 6, Playwright spec

Check whether `.playwright/e2e/language-switch-a11y.spec.ts` exists.

**Pick a verification key that genuinely differs between English and `{{LOCALE_CODE}}`.** Do **not** assert against `meta.title`, top-level `title`, or `heroTitle`: `gaia init rename` rewrites all three to the project title, and the Step 1 translation rule copies a brand / proper-noun value verbatim, so they are identical in every locale and a switch assertion against them never changes. Use the seed's `cta` key instead (English `'View on GitHub'`), a normal UI string the index page renders as a visible link. Read the English value from `app/languages/en/pages/_index.ts` and the translated value from `app/languages/{{LOCALE_CODE}}/pages/_index.ts`. Before writing the assertion, confirm the two values actually differ; if `cta` is missing or was copied verbatim for this locale, pick any other body string whose English and `{{LOCALE_CODE}}` values differ.

**If the file does not exist**, create it as a new spec. The spec must:

- Import from `@playwright/test`.
- Use a `test.describe` block named `'language switch, EN ↔ {{LOCALE_CODE}}'`.
- Test the following flow:
  1. Navigate to `/`.
  2. Assert the English `cta` text (e.g. `'View on GitHub'`) is visible.
  3. Find the language select and switch to `{{LOCALE_CODE}}`.
  4. Assert the `cta` text changes to the `{{LOCALE_CODE}}` translation from `app/languages/{{LOCALE_CODE}}/pages/_index.ts`.
  5. Switch back to English and assert the English `cta` text is restored.

**If the file already exists**, append a new `test.describe` block for the new locale following the same shape as the existing blocks. Do not modify existing blocks.

---

## Step 7, Manifest (no change needed)

`.gaia/manifest.json` is release-generated and lists only files GAIA ships. New-locale files are adopter-owned, so **do not add them to the manifest**, a path absent from the manifest is adopter-owned and invisible to `/update-gaia`. No manifest edit is needed here. See `.claude/rules/gaia-folder.md`.

---

## Step 8, Verify

Run from the project root:

```
pnpm typecheck && pnpm lint
```

If either command fails:

- **STOP immediately.**
- Report the exact error output.
- **Do not proceed to Step 9 (self-delete).**

Only proceed to Step 9 if both commands exit with code 0.

---

## Step 9, Self-delete

On success (both `pnpm typecheck` and `pnpm lint` pass):

```
rm .claude/instructions/add-locale.md
```

Print a one-line summary:

```
add-locale {{LOCALE_CODE}} ({{LANGUAGE_NAME_EN}}), done
```
