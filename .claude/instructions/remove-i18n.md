---
name: remove-i18n
description: Deterministic runbook that strips the entire i18next stack from a GAIA-derived project — packages, source wiring, audit checks, hooks, manifest entries, and wiki pages.
---

# Remove i18n

Execute every section in order, top to bottom. No skipping, no reordering. After Section I passes, Section J self-deletes this file.

This runbook takes no variables — i18n removal is identical for every project.

If any verification command in Section I fails, **stop** and report the failure verbatim. Do **not** self-delete.

---

## Section A — Unwrap `useTranslation` / `t()` calls in source

Discover every call site:

```bash
grep -rln "useTranslation\|i18next" /Users/stevensacks/Development/gaia-react/gaia/app /Users/stevensacks/Development/gaia-react/gaia/test
```

For every match in `app/` (excluding `app/i18n.ts`, `app/middleware/i18next.ts`, `app/languages/`, `app/sessions.server/language.ts`, `app/routes/actions+/set-language.ts`, `app/components/LanguageSelect/` — those are deleted in Section C):

1. Open the file.
2. Delete the import line: `import {useTranslation} from 'react-i18next';`
3. Delete the destructure: `const {t} = useTranslation();` (or `useTranslation('namespace')`).
4. Replace every `t('key')` and `t('key', {…})` call with the literal English string from `/Users/stevensacks/Development/gaia-react/gaia/app/languages/en/`.
5. If the file used `<Trans>` from `react-i18next`, replace the JSX with the literal English markup.

The seeded list of files known to use `t()` (verify against the grep output — add any newcomers, drop any that have already been unwrapped):

- `/Users/stevensacks/Development/gaia-react/gaia/app/components/Header/index.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/components/Footer/index.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/routes/_legal+/terms.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/routes/_legal+/privacy.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/routes/_public+/_index.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/pages/Public/IndexPage/index.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/routes/resources+/theme-switch.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/components/Form/InputEmail/index.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/components/Form/InputPassword/index.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/components/Form/YearMonthDay/index.tsx`
- `/Users/stevensacks/Development/gaia-react/gaia/app/components/Form/Field/FieldLabel/FieldRequiredText/index.tsx`
- All `tests/index.stories.tsx` and `tests/index.test.tsx` files alongside the above components

Resolve translation keys via the `app/languages/en/` files. Example: `t('meta.siteName')` → look up `meta.siteName` in `app/languages/en/common.ts` and inline the resolved string.

After unwrapping all source files, re-run the grep. If any matches remain in `app/` or `test/` outside the deletion targets above, unwrap those too. Repeat until grep returns no app/test matches.

---

## Section B — Root + entry files

These three files have structural i18n wiring that the regex-style unwrap in Section A does not cover. Apply the diffs below verbatim.

### B1. `/Users/stevensacks/Development/gaia-react/gaia/app/root.tsx`

Remove these imports:

```ts
import {useTranslation} from 'react-i18next';
import {getLanguage, i18nextMiddleware} from '~/middleware/i18next';
import {setApiLanguage} from '~/services/api';
import {languageCookie} from '~/sessions.server/language';
```

(`setApiLanguage` is only kept if it's still used elsewhere — grep before deciding. The other three are deleted unconditionally.)

Delete the middleware export:

```ts
export const middleware = [i18nextMiddleware];
```

Inside the loader, delete:

```ts
const language = getLanguage(context);

setApiLanguage(language);
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
dir="ltr"
lang="en"
```

### B2. `/Users/stevensacks/Development/gaia-react/gaia/app/entry.client.tsx`

Replace the entire file body with:

```tsx
/**
 * By default, Remix will handle hydrating your app on the client for you.
 * You are free to delete this file if you'd like to, but if you ever want it revealed again, you can run `npx remix reveal` ✨
 * For more information, see https://remix.run/file-conventions/entry.client
 */

import {startTransition, StrictMode} from 'react';
import {hydrateRoot} from 'react-dom/client';
import {HydratedRouter} from 'react-router/dom';

const prepareApp = async () => {
  if (
    window.process.env.NODE_ENV === 'development' &&
    window.process.env.MSW_ENABLED === true
  ) {
    const {worker} = await import('../test/worker');

    return worker.start({onUnhandledRequest: 'bypass'});
  }
};

const hydrate = async () => {
  await prepareApp().then(() => {
    startTransition(() => {
      hydrateRoot(
        document,
        <StrictMode>
          <HydratedRouter />
        </StrictMode>
      );
    });
  });
};

await hydrate();
```

### B3. `/Users/stevensacks/Development/gaia-react/gaia/app/entry.server.tsx`

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

The `routerContext` parameter is now unused — drop it from the `handleRequest` signature.

---

## Section C — Delete files

```bash
rm -rf \
  /Users/stevensacks/Development/gaia-react/gaia/app/i18n.ts \
  /Users/stevensacks/Development/gaia-react/gaia/app/middleware/i18next.ts \
  /Users/stevensacks/Development/gaia-react/gaia/app/types/i18n \
  /Users/stevensacks/Development/gaia-react/gaia/app/languages \
  /Users/stevensacks/Development/gaia-react/gaia/app/sessions.server/language.ts \
  /Users/stevensacks/Development/gaia-react/gaia/app/routes/actions+/set-language.ts \
  /Users/stevensacks/Development/gaia-react/gaia/app/components/LanguageSelect \
  /Users/stevensacks/Development/gaia-react/gaia/.storybook/i18next.ts \
  /Users/stevensacks/Development/gaia-react/gaia/.playwright/e2e/language-switch.spec.ts \
  /Users/stevensacks/Development/gaia-react/gaia/.claude/rules/i18n.md \
  /Users/stevensacks/Development/gaia-react/gaia/.claude/agents/code-review-audit/react-i18next.md \
  /Users/stevensacks/Development/gaia-react/gaia/.claude/skills/react-code/references/translation-patterns.md \
  /Users/stevensacks/Development/gaia-react/gaia/.claude/hooks/check-i18n-strings.sh \
  /Users/stevensacks/Development/gaia-react/gaia/wiki/modules/i18n.md \
  /Users/stevensacks/Development/gaia-react/gaia/wiki/flows/Language\ Flow.md \
  /Users/stevensacks/Development/gaia-react/gaia/wiki/dependencies/i18next.md \
  /Users/stevensacks/Development/gaia-react/gaia/wiki/dependencies/remix-i18next.md
```

---

## Section D — Storybook preview, test infra

### D1. `/Users/stevensacks/Development/gaia-react/gaia/.storybook/preview.ts`

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

### D2. `/Users/stevensacks/Development/gaia-react/gaia/test/rtl.tsx`

Remove:

```ts
import '../.storybook/i18next';
```

### D3. `/Users/stevensacks/Development/gaia-react/gaia/test/utils.ts`

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

After this edit, grep for `getLanguage` across the repo and unwrap any callers (typically loaders/actions in `app/routes/`):

```bash
grep -rln "getLanguage" /Users/stevensacks/Development/gaia-react/gaia/app /Users/stevensacks/Development/gaia-react/gaia/test
```

For each caller, drop the import and replace any usage with the literal `'en'`.

---

## Section E — package.json

Open `/Users/stevensacks/Development/gaia-react/gaia/package.json` and:

Remove these keys from `dependencies`:

- `i18next`
- `react-i18next`
- `remix-i18next`
- `i18next-browser-languagedetector`

Remove these keys from `devDependencies`:

- `storybook-react-i18next`
- `accept-language-parser`
- `@types/accept-language-parser`

Remove any keys from `pnpm.overrides` whose name starts with `remix-i18next>` (none may exist if overrides is empty `{}` — leave it that way).

Then run:

```bash
pnpm install
```

---

## Section F — `.claude/` skills, rules, hooks, agents

### F1. `/Users/stevensacks/Development/gaia-react/gaia/.claude/agents/code-review-audit.md`

Delete the entire `### Subagent 3: Translation Audit` section (and its body up to the next `###` or `##` heading).

In the routing block (Step 3 / "Parse each file's `subagents:` frontmatter field"), drop `translation` from the list of legal values.

### F2. `/Users/stevensacks/Development/gaia-react/gaia/.claude/agents/code-review-audit/README.md`

Delete the row in the extension table that mentions `react-i18next.md` and `translation`.

Search for any `subagents:` lists and drop `translation` from them.

### F3. `/Users/stevensacks/Development/gaia-react/gaia/.claude/skills/react-code/SKILL.md`

Delete the `### Gate 3: Translation Check` section in its entirety.

In the References list, delete the line referencing `references/translation-patterns.md`.

If there is an "Adding New Keys" section that references `app/languages/`, delete that section.

### F4. `/Users/stevensacks/Development/gaia-react/gaia/.claude/skills/new-route/SKILL.md`

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

### F5. `/Users/stevensacks/Development/gaia-react/gaia/.claude/rules/routes.md`

In the conventions parenthetical, drop `i18n keys, ` (or `, i18n keys` depending on its position).

### F6. `/Users/stevensacks/Development/gaia-react/gaia/.claude/rules/storybook.md`

Delete the `## i18n in stories` section.

### F7. `/Users/stevensacks/Development/gaia-react/gaia/.claude/settings.json`

In `hooks.PreToolUse`, find the entry whose `matcher` is `Edit|Write|MultiEdit`. Inside its `hooks` array, remove the entry whose `command` is `.claude/hooks/check-i18n-strings.sh`. Preserve every other hook in the array.

---

## Section G — `.gaia/manifest.json`

Open `/Users/stevensacks/Development/gaia-react/gaia/.gaia/manifest.json` and remove every key whose path matches any of:

- `app/languages/*` (every entry under `app/languages/`)
- `app/i18n.ts`
- `app/middleware/i18next.ts`
- `app/types/i18n/*`
- `app/sessions.server/language.ts`
- `app/routes/actions+/set-language.ts`
- `app/components/LanguageSelect/*`
- `.claude/rules/i18n.md`
- `.claude/agents/code-review-audit/react-i18next.md`
- `.claude/skills/react-code/references/translation-patterns.md`
- `.claude/hooks/check-i18n-strings.sh`
- `.storybook/i18next.ts`
- `.playwright/e2e/language-switch.spec.ts`
- `wiki/modules/i18n.md`
- `wiki/flows/Language Flow.md`
- `wiki/dependencies/i18next.md`
- `wiki/dependencies/remix-i18next.md`

Discovery sweep — confirm no leftover entries:

```bash
grep -nE "i18n|languages/|LanguageSelect|set-language|check-i18n|react-i18next|translation-patterns|Language Flow" /Users/stevensacks/Development/gaia-react/gaia/.gaia/manifest.json
```

Should print nothing.

---

## Section H — wiki

Edit each:

- `/Users/stevensacks/Development/gaia-react/gaia/wiki/index.md` — drop the lines `[[i18n]]`, `[[remix-i18next]]`, `[[i18next]]`.
- `/Users/stevensacks/Development/gaia-react/gaia/wiki/overview.md` — drop the i18n bullet from "What's in the box". Drop `languages/` and `middleware/i18next.ts` mentions from the folder map. Drop any "i18n examples" row from feature tables.
- `/Users/stevensacks/Development/gaia-react/gaia/wiki/modules/Folder Structure.md` (if it exists) — drop `languages/` and `middleware/i18next.ts` mentions.
- `/Users/stevensacks/Development/gaia-react/gaia/wiki/modules/Middleware.md` (if it exists) — drop the `i18nextMiddleware` entry/section.
- `/Users/stevensacks/Development/gaia-react/gaia/wiki/decisions/Quality Gate.md` — replace any "missing i18n keys" example with a generic "missing strings".
- `/Users/stevensacks/Development/gaia-react/gaia/wiki/concepts/Component Testing.md` — drop "Render with i18n provider configured" if present.
- `/Users/stevensacks/Development/gaia-react/gaia/wiki/dependencies/Storybook.md` (if it exists) — drop `storybook-react-i18next` from the addons list.
- `/Users/stevensacks/Development/gaia-react/gaia/wiki/dependencies/React Router 7.md` (if it exists) — drop `[[remix-i18next]]` from related-deps lists.

Discovery sweep:

```bash
grep -rln "i18n\|useTranslation\|languages/\|i18next" /Users/stevensacks/Development/gaia-react/gaia/wiki /Users/stevensacks/Development/gaia-react/gaia/.claude
```

Review every match. Edit or delete each — the only acceptable surviving matches are inside this very file (`remove-i18n.md`) and inside the `add-locale.md` template. Both will be self-deleted after they run.

---

## Section I — Verify

```bash
pnpm -C /Users/stevensacks/Development/gaia-react/gaia typecheck && \
  pnpm -C /Users/stevensacks/Development/gaia-react/gaia lint && \
  pnpm -C /Users/stevensacks/Development/gaia-react/gaia test --run && \
  pnpm -C /Users/stevensacks/Development/gaia-react/gaia build
```

If any step fails, **stop** and report the failing command + output verbatim. Do **not** proceed to Section J.

---

## Section J — Self-delete

On full verification success:

```bash
rm /Users/stevensacks/Development/gaia-react/gaia/.claude/instructions/remove-i18n.md
```

Print: `remove-i18n — done`.
