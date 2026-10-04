---
name: a11y-fixes
description: Resolve axe-core accessibility violations reported by Vitest (test/a11y.ts), Playwright (.playwright/a11y.ts), or the code-audit-frontend agent's a11y bucket. Trigger on any axe rule id appearing in test output, not only the ones named here. Contains fix patterns for the most common violations (color-contrast, label, label-title-only, image-alt, button-name, link-name, region, landmark-one-main, heading-order, aria-allowed-attr, aria-required-attr, aria-required-children, aria-required-parent, aria-valid-attr-value, focus-trap, tabindex, html-has-lang, document-title, duplicate-id, listitem, definition-list); for any violation not listed, apply the general axe guidance and the same fix-then-verify loop.
model: haiku
---

# Accessibility Fix Patterns

How to resolve specific axe-core violations in this project.

Violations come from `test/a11y.ts` (Vitest), `.playwright/a11y.ts` (Playwright), or the `code-audit-frontend` agent's a11y bucket. General a11y guidance lives in `frontend/.claude/rules/accessibility.md`.

## Fix-then-verify loop

1. Fix one violation with the pattern below; for a rule id not listed here, use the violation's `help` and `failureSummary` from the axe output.
2. Re-run the reporter that flagged it: Vitest `pnpm test --run <test-file>`, Playwright `pnpm pw <spec-file>`.
3. Some rules never go green on their own. Under Vitest (jsdom) axe records `color-contrast`, `landmark-one-main` and `page-has-heading-one` as `incomplete`, not violations (see the comment in `test/a11y.ts`), so a Vitest run never checks them. Verify `color-contrast` with `pnpm pw`. The Playwright scan's WCAG tag filter does not run `landmark-one-main` either, so for that rule check the rendered page by hand (exactly one `<main>`) instead of counting a green run as proof.
4. Repeat until the reporter shows no violations.

## color-contrast

WCAG AA requires 4.5:1 for normal text, 3:1 for large text. Use the theme role tokens (see `frontend/.claude/rules/tailwind.md`) instead of raw palette colors: each token carries a light and a dark value that pass in both themes. Pair a surface token with its foreground (`bg-primary` with `text-primary-foreground`).

```tsx
// BAD, fails contrast in dark mode, raw colors
<p className="text-gray-400 bg-white">Status</p>

// GOOD, role tokens, contrast-safe in both themes
<p className="bg-background text-foreground">Status</p>
```

If a token itself fails (the placeholder values are a neutral default), fix the value in `app/styles/theme.css` and keep it an accessibility fix, per `frontend/.claude/rules/design-baseline.md`.

## label

Form inputs need an associated label. Compose the ui `Field` parts around the control rather than a bare `<label>`: `FieldLabel htmlFor` names it, and `FieldError` carries the error. See `frontend/.claude/skills/react-code/references/conform-forms.md` for the full wiring.

```tsx
// BAD, bare input with no label association
<input type="text" name="email" />

// GOOD, Field and FieldLabel wire the label to the ui control
<Field>
  <FieldLabel htmlFor="email">{t('email')}</FieldLabel>
  <Input id="email" name="email" />
</Field>
```

## label-title-only

`title` attributes are not labels, screen readers and mobile devices ignore them. Use `aria-label` or a real `<label>`.

```tsx
// BAD, title is not an accessible name
<input type="text" title="Search" />

// GOOD, aria-label provides the accessible name
<input type="text" aria-label={t('search')} />
```

## image-alt

Every `<img>` needs `alt`. Content images describe the image; decorative images use `alt=""`. See `frontend/.claude/rules/accessibility.md`.

```tsx
// BAD, no alt attribute
<img src="/logo.png" />

// GOOD, content image
<img src="/logo.png" alt={t('companyLogo')} />

// GOOD, decorative image, hidden from AT
<img src="/divider.svg" alt="" />
```

## button-name

Buttons need an accessible name. Visible text is fine; icon-only buttons need `aria-label`.

```tsx
// BAD, icon-only button with no name
<button onClick={onClose}>
  <CloseIcon />
</button>

// GOOD, aria-label supplies the name
<button aria-label={t('close')} onClick={onClose}>
  <CloseIcon />
</button>

// GOOD, visible text, no aria-label needed
<button onClick={onSave}>{t('save')}</button>
```

## link-name

Same pattern as `button-name`, anchors need an accessible name.

```tsx
// BAD, icon-only link
<Link to="/settings"><GearIcon /></Link>

// GOOD, aria-label on the link
<Link to="/settings" aria-label={t('settings')}>
  <GearIcon />
</Link>
```

## region / landmark-one-main

Page content must live inside a landmark, and there must be exactly one `<main>`. The Layout component owns the `<main>` landmark, page components render inside it and should not add their own.

```tsx
// BAD, page component wraps itself in <main>, duplicating Layout's
const Page = () => (
  <main>
    <h1>{t('title')}</h1>
  </main>
);

// GOOD, page renders into Layout's <main>
const Page = () => (
  <>
    <h1>{t('title')}</h1>
  </>
);
```

## heading-order

One `<h1>` per page. Levels do not skip, `h2 → h4` is a violation.

```tsx
// BAD, skips h3
<h2>{t('section')}</h2>
<h4>{t('subsection')}</h4>

// GOOD, sequential levels
<h2>{t('section')}</h2>
<h3>{t('subsection')}</h3>
```

## aria-allowed-attr

ARIA attributes are role-scoped. Look up the role; only attrs in its allowed list are valid. Common case: `aria-checked` only on `role="checkbox"`, `role="radio"`, `role="menuitemcheckbox"`, `role="menuitemradio"`, `role="switch"`, `role="treeitem"`.

```tsx
// BAD, aria-checked is not allowed on a button
<button aria-checked={selected}>{t('toggle')}</button>

// GOOD, aria-pressed for buttons, aria-checked for checkbox role
<button aria-pressed={selected}>{t('toggle')}</button>
```

## aria-required-attr

Some roles require companion attrs. Disclosure widgets (`aria-expanded`) need `aria-controls` pointing at the controlled element's id.

```tsx
// BAD, aria-expanded with no aria-controls
<button aria-expanded={open}>{t('menu')}</button>

// GOOD, aria-controls names the panel
<button aria-expanded={open} aria-controls="menu-panel">
  {t('menu')}
</button>
<div id="menu-panel" hidden={!open}>...</div>
```

## aria-required-children / aria-required-parent

Composite roles need their child roles, and child roles need the right parent. Prefer semantic HTML (`<ul><li>`, `<select><option>`) over recreating these structures with ARIA.

```tsx
// BAD, role="listbox" with no role="option" children
<div role="listbox">
  <div>{t('one')}</div>
  <div>{t('two')}</div>
</div>

// GOOD, semantic <select> with <option> children
<select aria-label={t('choose')}>
  <option value="1">{t('one')}</option>
  <option value="2">{t('two')}</option>
</select>
```

## aria-valid-attr-value

`aria-*` attrs that take id refs must point at existing ids; boolean attrs take `true`/`false`, not arbitrary strings.

```tsx
// BAD, aria-labelledby points at id that does not exist
<input aria-labelledby="missing-id" />

// GOOD, id exists in the DOM
<>
  <span id="email-label">{t('email')}</span>
  <input aria-labelledby="email-label" />
</>
```

## focus-trap (focus management)

Modals must trap focus while open and return focus to the trigger on close (see `frontend/.claude/rules/accessibility.md`). Use the native `<dialog>` opened with `showModal()`: the browser makes the rest of the page inert, closes it on Escape, and restores focus to the opener on close. Reach for a dialog library only if the project already has one installed.

```tsx
// BAD, open modal leaves focus on body, close drops focus
{
  open && (
    <div role="dialog">
      <button onClick={() => setOpen(false)}>{t('close')}</button>
    </div>
  );
}

// GOOD, native modal dialog handles inert background, Escape, and focus restore
const dialogRef = useRef<HTMLDialogElement>(null);
const handleClickOpen = () => dialogRef.current?.showModal();
const handleClickClose = () => dialogRef.current?.close();

<>
  <button onClick={handleClickOpen} type="button">
    {t('open')}
  </button>
  <dialog ref={dialogRef}>
    <button onClick={handleClickClose} type="button">
      {t('close')}
    </button>
  </dialog>
</>;
```

## tabindex

Positive `tabindex` (`tabindex={1}`, `tabindex={2}`, ...) reorders the tab sequence and is always a violation. Use `tabIndex={0}` to insert into natural order, `tabIndex={-1}` for programmatic-only focus.

```tsx
// BAD, positive tabindex skews tab order
<div tabIndex={1}>{t('first')}</div>
<div tabIndex={2}>{t('second')}</div>

// GOOD, natural DOM order, programmatic focus on the panel
<div tabIndex={0}>{t('first')}</div>
<div tabIndex={0}>{t('second')}</div>
<section tabIndex={-1} ref={panelRef}>...</section>
```

## html-has-lang

`<html>` must have a `lang` attribute. The React Router root sets it from the i18n locale; if a violation appears, the root loader is not threading locale through. Verify the root layout reads locale from the request context and renders `<html lang={locale}>`.

```tsx
// BAD, hardcoded or missing lang
<html>...</html>

// GOOD, locale from the loader / i18n
<html lang={locale}>...</html>
```

## document-title

Every page needs a `<title>`. Resolve the string in the route `loader` with `getInstance(context)` (see `frontend/.claude/rules/i18n.md`) and render `<title>` (and `<meta name="description">`) as JSX, either in the route component (as `app/routes/_public._index.tsx` does) or in the page it renders; React 19 hoists it into `<head>`. Do not add a route `meta` export: next to a JSX `<title>` it produces duplicate tags (react-code skill, Gate 4).

```tsx
// BAD, no <title> rendered
const DashboardRoute = () => <DashboardPage />;

// GOOD, i18n-resolved title in the loader, rendered as JSX
export const loader = async ({context}: Route.LoaderArgs) => {
  const i18next = getInstance(context);

  return {title: i18next.t('dashboard.meta.title', {ns: 'pages'})};
};

const DashboardRoute = () => {
  const {title} = useLoaderData<typeof loader>();

  return (
    <>
      <title>{title}</title>
      <DashboardPage />
    </>
  );
};
```

## duplicate-id

Every `id` in the rendered DOM must be unique. Common Conform pitfall: rendering the same field `name` twice in a fieldset produces duplicate ids. Pass an explicit unique `id`.

```tsx
// BAD, same field rendered twice, ids collide
<Input name="email" />
<Input name="email" />

// GOOD, unique ids
<Input id="email-primary" name="emailPrimary" />
<Input id="email-secondary" name="emailSecondary" />
```

## listitem

`<li>` must be a direct child of `<ul>` or `<ol>`. A standalone `<li>` is a violation.

```tsx
// BAD, <li> with no list parent
<div>
  <li>{t('one')}</li>
</div>

// GOOD, wrapped in <ul>
<ul>
  <li>{t('one')}</li>
</ul>
```

## definition-list

`<dt>` and `<dd>` must live inside `<dl>`. Group related term/description pairs in one `<dl>`.

```tsx
// BAD, dt/dd outside <dl>
<div>
  <dt>{t('term')}</dt>
  <dd>{t('definition')}</dd>
</div>

// GOOD, wrapped in <dl>
<dl>
  <dt>{t('term')}</dt>
  <dd>{t('definition')}</dd>
</dl>
```

## Upstream shadcn and Base UI findings

The vendored `components/ui/` files are byte-identical to `shadcn add` output, so a violation that comes from a vendored file is fixed by a local patch recorded in `wiki/decisions/shadcn Component Layer.md`, or by a scoped exclusion in the scan, never by editing the file silently. The a11y scan hits these cases:

| Rule and symptom | Source | Fix kind |
| --- | --- | --- |
| `label`: the Slider thumb `<input type="range">` ignores `aria-label` on the root | shadcn-ui/ui#10221 | Local patch forwarding the label to the thumb input |
| `button-name`: the Combobox trigger and icon buttons have no accessible name | shadcn-ui/ui#11589 | Local patch naming the icon buttons |
| `aria-hidden-focus` on Base UI overlay focus guards (`span[data-base-ui-focus-guard][aria-hidden="true"]`, seen on open dropdown menus) | No upstream issue found as of 2026-10-03 (measured against the shadcn Base UI overlay set). TODO: file one | Selector-scoped exclusion in the scan, with a canary check that fails if no guard matches the selector, so the exclusion cannot go stale |
| Radix Select `aria-hidden` sibling findings | shadcn-ui/ui#10074, shadcn-ui/ui#8707 | Informational: they describe the Radix Select, which does not apply because GAIA's `base-nova` style uses Base UI |

`shadcn add --overwrite` drops a local patch along with the rest of the file. After refreshing a patched ui file, re-apply its patch from the decision page's list and re-run the scan.
