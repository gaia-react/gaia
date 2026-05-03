# Translation Patterns — Edge Cases

## Core Rule

One `useTranslation()` per component. Use `{ns: 'other'}` for cross-namespace access.

```tsx
// GOOD
const {t} = useTranslation('pages');
t('onboarding.step1.title'); // 'pages' namespace
t('previous', {ns: 'common'}); // override to 'common'

// BAD
const {t} = useTranslation('pages');
const {t: tc} = useTranslation('common');
```

Choose whichever namespace is used most frequently. If more calls override than use the declared namespace, switch it.

## keyPrefix

`keyPrefix` is useful when many keys share a deep prefix — it keeps `t()` calls short. But it conflicts with `{ns: '...'}` overrides (the prefix is applied before the namespace switch, producing wrong keys). If you need both, drop `keyPrefix` and prefix manually:

```tsx
// GOOD — keyPrefix alone, no namespace overrides needed
const {t} = useTranslation('pages', {keyPrefix: 'onboarding.step1'});
t('title'); // → pages:onboarding.step1.title
t('subtitle'); // → pages:onboarding.step1.subtitle

// BAD — keyPrefix + namespace override: prefix is misapplied
const {t} = useTranslation('pages', {keyPrefix: 'onboarding.step1'});
t('previous', {ns: 'common'}); // ❌ looks up common:onboarding.step1.previous

// GOOD — drop keyPrefix when namespace overrides needed
const {t} = useTranslation('pages');
t('onboarding.step1.title');
t('previous', {ns: 'common'}); // ✓
```

## Dynamic Translation Keys

i18next's typed `t()` only accepts statically-known keys. Template literals with `${string}` fail type-checking.

**Fix:** Ensure the interpolated value has a literal union type, not `string`.

```tsx
// BAD — value is string
const options = values.map((value) => ({
  label: t(`exercises.categoryValues.${value}`), // TS error
  value,
}));

// BAD — casting is a workaround
label: t(`exercises.categoryValues.${value}` as 'exercises.categoryValues.cardio'),

// GOOD — value is ExerciseCategory (literal union), typed at prop/LoaderData level
import type {ExerciseCategory} from '~/types/database';
// categoryOptions: ExerciseCategory[]  ← typed upstream, no cast needed
const options = categoryOptions.map((value) => ({
  label: t(`exercises.categoryValues.${value}`), // ✓ TypeScript happy
  value,
}));
```

**Where to define the union type:** add it to `app/types/database.ts` alongside other DB-derived types. Then use it in `LoaderData`, component props, and anywhere else the value flows — the template literal in `t()` will just work.

## Inline Styled Segments (Trans component)

When part of a translated string needs different styling, use `Trans` with XML tags — never split into separate keys:

```ts
// Translation string
previousWorkout: 'Previous <accent>Workout</accent>',
```

```tsx
// Component
import {Trans} from 'react-i18next';

// Pass ns as a separate prop — never embed it in i18nKey.
// i18nKey is namespace-relative: "dashboard.previousWorkout", not "pages:dashboard.previousWorkout"
<Trans
  components={{accent: <span className="text-orange-500" />}}
  i18nKey="dashboard.previousWorkout"
  ns="pages"
/>;
```

## String Deduplication

Before adding a new key:

1. Search `app/languages/en/common.ts` for generic labels
2. Search all `app/languages/en/` files for the exact string value
3. If found, reuse with namespace override: `t('key', {ns: 'namespace'})`
4. If not found, add to the most appropriate namespace

### Where shared labels belong

- **Enum display labels** → `common` namespace, snake_case keys matching DB values (enables ``t(`key.${dbValue}`, {ns: 'common'})``)
- **Generic UI actions** (Save, Cancel, Edit, etc.) → already in `common`
- **Page-specific content** → page's namespace

**Locale placeholders:** when adding a new locale folder, copy the English string verbatim — no empty strings, no TODO comments. Translation happens in a separate pass.

## Plurals

i18next uses `_one`/`_other` key suffixes for pluralization:

```ts
// Translation file (en)
exerciseCount_one: '{{count}} exercise',
exerciseCount_other: '{{count}} exercises',
```

```tsx
// Component — i18next selects the right suffix automatically
t('exerciseCount', {count: n});
```

Always define both `_one` and `_other`. For locales without grammatical plural (e.g. Japanese, Chinese), define only `_other`.
