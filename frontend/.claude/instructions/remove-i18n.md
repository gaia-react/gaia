---
name: remove-i18n
description: Deterministic runbook that strips the entire i18next stack from a GAIA-derived project, packages, source wiring, audit checks, hooks, manifest entries, and wiki pages.
---

# Remove i18n

All paths in this file are repo-relative. The executing agent runs from the project root.

Execute every section in order, top to bottom. No skipping, no reordering. After Section I passes, Section J self-deletes this file.

This runbook takes no variables, i18n removal is identical for every project.

If any verification command in Section I fails, **stop** and report the failure verbatim. Do **not** self-delete.

---

## Section A, Unwrap `useTranslation` / `t()` calls in source

Discover every call site:

```bash
grep -rln "useTranslation\|i18next" frontend/app frontend/test
```

For every match in `frontend/app/` (excluding `frontend/app/i18n.ts`, `frontend/app/middleware/i18next.ts`, `frontend/app/languages/`, `frontend/app/sessions.server/language.ts`, `frontend/app/routes/actions.set-language.ts`, `frontend/app/components/language-select/`, those are deleted in Section C):

1. Open the file.
2. Delete the import line: `import {useTranslation} from 'react-i18next';`
3. Delete the destructure: `const {t} = useTranslation();` (or `useTranslation('namespace')`).
4. Replace every `t('key')` and `t('key', {…})` call with the literal English string from `frontend/app/languages/en/`.
5. If the file used `<Trans>` from `react-i18next`, replace the JSX with the literal English markup.

The seeded list of files known to use `t()` (verify against the grep output, add any newcomers, drop any that have already been unwrapped):

- `frontend/app/routes/_legal.terms.tsx`
- `frontend/app/routes/_legal.privacy.tsx`
- `frontend/app/routes/_public._index.tsx`
- `frontend/app/pages/index/page.tsx`
- `frontend/app/routes/resources.theme-switch.tsx`
- `frontend/app/components/errors/error-stack/index.tsx`
- `frontend/app/components/form/form-error/index.tsx`
- `frontend/app/components/theme-switch/index.tsx`
- All `tests/index.stories.tsx` files alongside the above components (`tests/page.stories.tsx` for the index page); stories are the component tests, so no `.test.tsx` sits beside them

Resolve translation keys via the `frontend/app/languages/en/` files. Example: `t('meta.siteName')` → look up `meta.siteName` in `frontend/app/languages/en/common.ts` and inline the resolved string.

`useTranslation`/`t()` is not the only i18n coupling on the index page: `frontend/app/pages/index/page.tsx` also imports and renders `LanguageSelect`, which Section C deletes. In every file that references it, remove the `import LanguageSelect from '~/components/language-select';` line and the `<LanguageSelect />` element. Discover all such files:

```bash
grep -rln "components/language-select" app
```

After unwrapping all source files, re-run the grep. If any matches remain in `frontend/app/` or `frontend/test/` outside the deletion targets above, unwrap those too. Repeat until grep returns no frontend/app/test matches.

---

## Section B, Root + entry files

These three files have structural i18n wiring that the regex-style unwrap in Section A does not cover. Apply the diffs below verbatim.

### B1. `frontend/app/root.tsx`

Remove these imports:

```ts
import {useTranslation} from 'react-i18next';
import {getLanguage, i18nextMiddleware} from '~/middleware/i18next';
import {languageCookie} from '~/sessions.server/language';
```

Delete the middleware export:

```ts
export const middleware = [i18nextMiddleware];
```

Inside the loader, delete:

```ts
const language = getLanguage(context);
```

```ts
headers.append('Set-Cookie', await languageCookie.serialize(language));

headers.set('Vary', 'Cookie');
```

Drop `language` from the loader's returned data object.

In the `App` component, delete:

```ts
const {i18n} = useTranslation();
```

```ts
useEffect(() => {
  void i18n.changeLanguage(language);
}, [i18n, language]);
```

Replace `language` in the destructure with the remaining loader fields (drop `language`).

Replace the `<Document>` props:

```tsx
dir={i18n.dir(i18n.language)}
lang={i18n.language}
```

with:

```tsx
dir = 'ltr';
lang = 'en';
```

### B2. `frontend/app/entry.client.tsx`

Replace the entire file body with:

```tsx
import {startTransition, StrictMode} from 'react';
import {hydrateRoot} from 'react-dom/client';
import {HydratedRouter} from 'react-router/dom';

const prepareApp = async () => {
  if (import.meta.env.DEV && window.process.env.MSW_ENABLED === true) {
    const [{network}, {default: handlers}] = await Promise.all([
      import('virtual:msw'),
      import('../test/mocks'),
    ]);

    network.configure({
      handlers,
      onUnhandledFrame: 'bypass',
    });
    await network.enable();
  }
};

const hydrate = async () => {
  await prepareApp().then(() => {
    // The react-perf capture harness sets this global (via addInitScript, before
    // hydration) to opt out of StrictMode for honest, non-doubled render
    // timings; everything else keeps StrictMode on.
    // eslint-disable-next-line no-underscore-dangle -- global injected by the react-perf capture harness
    const isStrictModeDisabled = window.__PERF_NO_STRICT;
    startTransition(() => {
      hydrateRoot(
        document,
        isStrictModeDisabled ?
          <HydratedRouter />
        : <StrictMode>
            <HydratedRouter />
          </StrictMode>
      );
    });
  });
};

await hydrate();
```

### B3. `frontend/app/entry.server.tsx`

Remove these imports:

```ts
import {I18nextProvider} from 'react-i18next';
import {createInstance} from 'i18next';
import i18nConfig from '~/i18n';
import {getInstance} from '~/middleware/i18next';
```

Delete the `i18n` IIFE:

```ts
const i18n = (() => {
  try {
    return getInstance(routerContext);
  } catch {
    // Middleware didn't run (e.g. unmatched routes like Chrome DevTools probes)
    const fallback = createInstance();

    void fallback.init({...i18nConfig, lng: i18nConfig.fallbackLng});

    return fallback;
  }
})();
```

Replace the JSX:

```tsx
<I18nextProvider i18n={i18n}>
  <ServerRouter context={entryContext} url={request.url} />
</I18nextProvider>
```

with:

```tsx
<ServerRouter context={entryContext} url={request.url} />
```

The `routerContext` parameter is now unused, drop it from the `handleRequest` signature.

---

## Section C, Delete files

```bash
rm -rf \
  frontend/app/i18n.ts \
  frontend/app/middleware/i18next.ts \
  frontend/app/types/i18n \
  frontend/app/languages \
  frontend/app/sessions.server/language.ts \
  frontend/app/routes/actions.set-language.ts \
  frontend/app/components/language-select \
  frontend/.storybook/i18next.ts \
  frontend/.playwright/e2e/language-switch-a11y.spec.ts \
  frontend/.claude/rules/i18n.md \
  frontend/.claude/agents/code-audit-frontend/react-i18next.md \
  frontend/.claude/skills/react-code/references/translation-patterns.md \
  wiki/modules/i18n.md \
  "wiki/flows/Language Flow.md" \
  wiki/dependencies/i18next.md \
  wiki/dependencies/remix-i18next.md
```

---

## Section D, Storybook preview, test infra

### D1. `frontend/.storybook/preview.ts`

Remove:

```ts
import i18n from './i18next';
```

Remove the `initialGlobals` block:

```ts
initialGlobals: {
  locale: 'en',
  locales: {
    en: {left: '🇺🇸', right: 'en', title: 'English'},
  },
},
```

Remove the `i18n` key from `parameters`:

```ts
i18n,
```

### D2. `frontend/test/utils.ts`

Remove:

```ts
import {pick} from 'accept-language-parser';
import type {Language} from '~/languages';
import {LANGUAGES} from '~/languages';
```

Remove the `getLanguage` export:

```ts
export const getLanguage = (request: Request) =>
  (pick(LANGUAGES, request.headers.get('Accept-Language') ?? 'en') ??
    'en') as Language;
```

The remaining file should export only `DELAY` and `date`.

After this edit, grep for `getLanguage` across the repo and unwrap any callers (typically loaders/actions in `frontend/app/routes/`):

```bash
grep -rln "getLanguage" frontend/app frontend/test
```

For each caller, drop the import and replace any usage with the literal `'en'`.

### D3. `frontend/.playwright/e2e/route-status.spec.ts` and `frontend/app/action-paths.ts`

Delete the `'set-language action redirects and sets the language cookie'` test (the one that POSTs to `ACTION_PATHS.setLanguage`) from `frontend/.playwright/e2e/route-status.spec.ts`, leaving the page-status and theme-toggle tests.

Remove the `setLanguage` key from `ACTION_PATHS` in `frontend/app/action-paths.ts`:

```ts
setLanguage: '/actions/set-language',
```

`frontend/test/action-paths.test.ts` iterates `Object.entries(ACTION_PATHS)`, so it needs no edit.

### D4. `frontend/playwright.config.ts`

Remove the import of the deleted `languages` module:

```ts
import {LANGUAGES} from './app/languages';
```

Remove the `testIgnore` property with its comment:

```ts
// The language switcher renders only with two or more languages, so its spec
// is excluded until a second language is added to LANGUAGES.
testIgnore:
  LANGUAGES.length < 2 ? ['**/language-switch-a11y.spec.ts'] : undefined,
```

The spec the property gated is deleted in Section C.

---

## Section E, package.json

Open `frontend/package.json` and:

Remove these keys from `dependencies`:

- `i18next`
- `react-i18next`
- `remix-i18next`
- `i18next-browser-languagedetector`

Remove these keys from `devDependencies`:

- `storybook-react-i18next`
- `accept-language-parser`
- `@types/accept-language-parser`

Remove any keys from the `overrides:` map in `pnpm-workspace.yaml` whose name starts with `remix-i18next>` (none may exist if the map is empty, leave it that way).

Then run:

```bash
pnpm install
```

---

## Section F, `.claude/` skills, rules, hooks, agents

### F1. `.claude/agents/code-audit-frontend.md` and `frontend/.claude/agents/code-audit-frontend/react-buckets.md`

In `.claude/agents/code-audit-frontend.md`, delete the entire `### Subagent 3: Translation Audit` section (and its body up to the next `###` or `##` heading).

In the same file's Extension Loading section (the step that parses each file's `subagents:` frontmatter field), drop `translation` from the list of legal values.

In `frontend/.claude/agents/code-audit-frontend/react-buckets.md`, delete the `## Translation (translation)` section and drop `translation` from the `subagents:` frontmatter list.

### F2. `frontend/.claude/agents/code-audit-frontend/README.md`

Search for any `subagents:` lists and drop `translation` from them.

### F3. `frontend/.claude/skills/react-code/SKILL.md`

Delete the `### Gate 3: Translation Check` section in its entirety.

In the References list, delete the line referencing `references/translation-patterns.md`.

If there is an "Adding New Keys" section that references `frontend/app/languages/`, delete that section.

### F4. `frontend/.claude/skills/new-route/SKILL.md`

Delete the `## Step 6: Create i18n keys (if requested)` section.

In the page-component template, delete:

```tsx
import {useTranslation} from 'react-i18next';
```

```tsx
const {t} = useTranslation('namespace');
```

In the loader template, delete:

```ts
import {getInstance} from '~/middleware/i18next';
```

Replace any `i18next.t('…')` calls in the loader template with literal placeholder strings.

### F5. `frontend/.claude/rules/routes.md`

In the conventions parenthetical, drop `i18n keys, ` (or `, i18n keys` depending on its position).

### F6. `frontend/.claude/rules/storybook.md`

Delete the `## i18n in stories` section.

---

## Section G, `.gaia/manifest.json`

Remove every key whose path matches any of:

- `frontend/app/languages/*` (every entry under `frontend/app/languages/`)
- `frontend/app/i18n.ts`
- `frontend/app/middleware/i18next.ts`
- `frontend/app/types/i18n/*`
- `frontend/app/sessions.server/language.ts`
- `frontend/app/routes/actions.set-language.ts`
- `frontend/app/components/language-select/*`
- `frontend/.claude/rules/i18n.md`
- `frontend/.claude/agents/code-audit-frontend/react-i18next.md`
- `frontend/.claude/skills/react-code/references/translation-patterns.md`
- `frontend/.storybook/i18next.ts`
- `frontend/.playwright/e2e/language-switch-a11y.spec.ts`
- `wiki/modules/i18n.md`
- `wiki/flows/Language Flow.md`
- `wiki/dependencies/i18next.md`
- `wiki/dependencies/remix-i18next.md`

A bare edit is blocked by `.claude/hooks/block-manifest-write.sh`, so the removal runs as a marker-carrying Bash write, a `jq` filter dropping the matched keys, written to a temp file and moved into place:

```bash
GAIA_MANIFEST_WRITE=remove-i18n jq '
  .files |= with_entries(
    select(.key
      | test("^frontend/app/languages/|^frontend/app/i18n\\.ts$|^frontend/app/middleware/i18next\\.ts$|^frontend/app/types/i18n/|^frontend/app/sessions\\.server/language\\.ts$|^frontend/app/routes/actions\\.set-language\\.ts$|^frontend/app/components/language-select/|^frontend/\\.claude/rules/i18n\\.md$|^frontend/\\.claude/agents/code-audit-frontend/react-i18next\\.md$|^frontend/\\.claude/skills/react-code/references/translation-patterns\\.md$|^frontend/\\.storybook/i18next\\.ts$|^frontend/\\.playwright/e2e/language-switch-a11y\\.spec\\.ts$|^wiki/modules/i18n\\.md$|^wiki/flows/Language Flow\\.md$|^wiki/dependencies/i18next\\.md$|^wiki/dependencies/remix-i18next\\.md$")
      | not))
' .gaia/manifest.json > .gaia/manifest.json.tmp \
  && GAIA_MANIFEST_WRITE=remove-i18n mv .gaia/manifest.json.tmp .gaia/manifest.json
```

Discovery sweep, confirm no leftover entries:

```bash
grep -nE "i18n|languages/|LanguageSelect|set-language|language-switch-a11y|check-i18n|react-i18next|translation-patterns|Language Flow" .gaia/manifest.json
```

The only expected match is this runbook's own entry, `frontend/.claude/instructions/remove-i18n.md`, it matches the sweep's broad `i18n` substring but is not an i18n content file and is not pruned here (the runbook self-deletes at the end of this process). Every i18n content key from the pattern list above is gone; that entry alone surviving is a pass.

---

## Section H, wiki

Edit each (skip any file that does not exist in this project):

- `wiki/index.md`, drop the lines `[[i18n]]`, `[[remix-i18next]]`, `[[i18next]]`.
- `wiki/overview.md`, drop the i18n bullet from "What's in the box". Drop `languages/` and `middleware/i18next.ts` mentions from the folder map. Drop any "i18n examples" row from feature tables.
- `wiki/modules/Folder Structure.md`, drop `languages/` and `middleware/i18next.ts` mentions.
- `wiki/modules/Middleware.md`, drop the `i18nextMiddleware` entry/section.
- `wiki/decisions/Quality Gate.md`, replace any "missing i18n keys" example with a generic "missing strings".
- `wiki/concepts/Component Testing.md`, drop "Render with i18n provider configured" if present.
- `wiki/dependencies/Storybook.md`, drop `storybook-react-i18next` from the addons list.
- `wiki/dependencies/React Router.md`, drop `[[remix-i18next]]` from related-deps lists.

Discovery sweep:

```bash
grep -rln "i18n\|useTranslation\|languages/\|i18next" wiki .claude
```

Review every match. Edit or delete each, the only acceptable surviving matches are inside this very file (`remove-i18n.md`) and inside the `add-locale.md` template. Both will be self-deleted after they run.

---

## Section I, Verify

```bash
pnpm typecheck && pnpm lint && pnpm test --run && pnpm build
```

If any step fails, **stop** and report the failing command + output verbatim. Do **not** proceed to Section J.

---

## Section J, Self-delete

On full verification success:

```bash
rm frontend/.claude/instructions/remove-i18n.md
```

Print: `remove-i18n, done`.
