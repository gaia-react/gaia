---
subagents: [translation]
library: react-i18next
---

# react-i18next Audit Rules

- Single `useTranslation()` call per component, flag multiple `useTranslation` calls in the same component
- Namespace override via `{ns: 'other'}` as the second arg to `t()`, not separate `useTranslation` calls
- Most-used namespace should be the one declared in `useTranslation()`. If more `t()` calls override than use the declared namespace, flag it.
- Use `keyPrefix` for nested keys to avoid repetition: `{keyPrefix: 'index'}` + `t('title')` instead of `t('index.title')`. Remove `keyPrefix` when namespace overrides are needed in the same component, `keyPrefix` is applied before the namespace switch, producing wrong keys.
- Namespace convention: `'common'` for shared UI strings, `'pages'` for page-specific content, `'errors'` for error messages
- String deduplication: check `app/languages/en/common.ts` first, shared keys (Save, Cancel, Delete, Close, email, password) belong in the `common` namespace. Flag new keys that duplicate existing strings.
- New keys must be added to ALL language files under `app/languages/` (English plus every locale directory present)
- Dynamic keys: interpolated values must be literal union types, not `string`. Flag `as` casts on template literals passed to `t()`
