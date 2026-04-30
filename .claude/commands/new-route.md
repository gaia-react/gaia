---
name: new-route
description: Scaffold a new route with its page component, test, and optional i18n keys.
---

Scaffold a new route with its page component, test, and optional i18n keys.

## Step 1: Gather user input

Ask the user these questions using AskUserQuestion:

- Route name (e.g. `dashboard`, `settings`, `things.$id`) — used for the route filename
- Route group (options: `_public+`, `_session+`, or custom) — default `_public+`
- Does the route need a loader? (yes/no) — default yes
- Does the route need an action? (yes/no) — default no
- Does the route need i18n keys? (yes/no) — default yes

## Step 2: Derive names

From the route name, derive:

- **routeFile**: `app/routes/{group}/{routeName}.tsx` (e.g. `app/routes/_public+/dashboard.tsx`)
- **pageName**: PascalCase of the route name + `Page` (e.g. `DashboardPage`). For nested routes like `things.$id`, use the parent segment (e.g. `ThingDetailPage`).
- **pageDir**: For `_public+` group, use `app/pages/Public/{pageName}/`. For `_session+`, use `app/pages/Session/{pageName}/`.
- **i18nKey**: kebab-case or snake_case matching the route flat file name (e.g. `dashboard`)

## Step 3: Create route file

Create `app/routes/{group}/{routeName}.tsx` following the pattern from `app/routes/_public+/_index.tsx`:

```tsx
import type {RouterContextProvider} from 'react-router';
import {useLoaderData} from 'react-router';
import {getInstance} from '~/middleware/i18next';
import {PageName} from '~/pages/{Group}/{PageName}';
import type {Route} from './+types/{routeName}';

export const loader = async ({context}: Route.LoaderArgs) => {
  const i18next = getInstance(context as RouterContextProvider);
  const title = i18next.t('{i18nKey}.meta.title', {ns: 'pages'});
  const description = i18next.t('{i18nKey}.meta.description', {ns: 'pages'});

  return {description, title};
};

const {RouteName}Route = () => {
  const {description, title} = useLoaderData<typeof loader>();

  return (
    <>
      <title>{title}</title>
      <meta content={description} name="description" />
      <{PageName} />
    </>
  );
};

export default {RouteName}Route;
```

- If loader is not needed, remove the loader export, `useLoaderData`, meta tags, and just render `<PageName />`.
- If action is needed, add an action export with `Route.ActionArgs`.

## Step 4: Create page component

Create `app/pages/{Group}/{PageName}/index.tsx`:

```tsx
import type {FC} from 'react';
import {useTranslation} from 'react-i18next';

const {
  PageName,
}: FC = () => {
  const {t} = useTranslation('pages', {keyPrefix: '{i18nKey}'});

  return (
    <section className="flex h-full items-center justify-center p-4">
      <h1>{t('title')}</h1>
    </section>
  );
};

export default {PageName};
```

If i18n is not needed, remove the `useTranslation` import and hook call.

## Step 5: Create page test

Create `app/pages/{Group}/{PageName}/tests/index.test.tsx`:

```tsx
import {composeStory} from '@storybook/react-vite';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import Meta, {Default} from './index.stories';

const {PageName} = composeStory(Default, Meta);

describe('{PageName}', () => {
  test('renders', () => {
    render(<{PageName} />);
    expect(screen.getByRole('heading', {level: 1})).toBeInTheDocument();
  });
});
```

Create `app/pages/{Group}/{PageName}/tests/index.stories.tsx`:

```tsx
import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import {PageName} from '..';

const meta: Meta = {
  component: {PageName},
  decorators: [stubs.reactRouter()],
};

export default meta;

export const Default: StoryFn = () => <{PageName} />;
```

## Step 6: Create i18n keys (if requested)

Create `app/languages/en/pages/{i18nKey}.ts`:

```ts
export default {
  meta: {
    description: 'Description of the {routeName} page',
    title: '{PageName}',
  },
  title: '{PageName}',
};
```

Then update `app/languages/en/pages/index.ts` — add the import and export for the new i18n key, maintaining alphabetical order.

Also update any other language folders that exist under `app/languages/` (e.g. `ja/`) with the same structure.

## Step 7: Verify

Run these commands sequentially, stopping if any fails:

```bash
pnpm typecheck && pnpm lint && pnpm test --run
```

Fix any issues before reporting to the user.
