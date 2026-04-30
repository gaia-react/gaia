---
name: new-component
description: Scaffold a new React component with optional Storybook story and Vitest test files. Use this skill whenever the user asks to "create a component", "make a button", "scaffold a card", "add a new component", or asks for a new file under `app/components/` following the project's component pattern (PascalCase folder, index.tsx, tests/).
---

Scaffold a new React component with optional test and story files.

## Step 1: Gather user input

Ask the user these questions using AskUserQuestion:

- Component name (PascalCase, e.g. `Card`, `UserAvatar`)
- Parent directory (default: `app/components/`)
- Does it need a Storybook story? (yes/no) — default yes
- Describe the props (or "none")

## Step 2: Create component file

Create `{parentDir}/{ComponentName}/index.tsx` following the Button pattern:

```tsx
import type {FC} from 'react';

type {ComponentName}Props = {
  // props from user input
};

const {ComponentName}: FC<{ComponentName}Props> = ({...props}) => {
  return (
    <div>
      {/* component content */}
    </div>
  );
};

export default {ComponentName};
```

- If no props, use `const {ComponentName}: FC = () => { ... }` and omit the type.
- Use `twMerge`/`twJoin` from `tailwind-merge` if the component accepts a `className` prop.

## Step 3: Create test file

Create `{parentDir}/{ComponentName}/tests/index.test.tsx`:

```tsx
import {composeStory} from '@storybook/react-vite';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import Meta, {Default} from './index.stories';

const {ComponentName} = composeStory(Default, Meta);

describe('{ComponentName}', () => {
  test('renders', () => {
    render(<{ComponentName} />);
    // basic assertion
  });
});
```

If no story was requested, write the test without `composeStory`:

```tsx
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import {ComponentName} from '../index';

describe('{ComponentName}', () => {
  test('renders', () => {
    render(<{ComponentName} />);
    // basic assertion
  });
});
```

## Step 4: Create story file (if requested)

Create `{parentDir}/{ComponentName}/tests/index.stories.tsx`:

```tsx
import type {Meta, StoryFn} from '@storybook/react-vite';
import {ComponentName} from '..';

const meta: Meta = {
  component: {ComponentName},
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/{ComponentName}',
};

export default meta;

export const Default: StoryFn = () => <{ComponentName} />;
```

- If the component uses React Router features (Form, Link, useNavigation, etc.), add `decorators: [stubs.reactRouter()]` and import `stubs from 'test/stubs'`.
- If the component uses global state, add `stubs.state()` decorator.
- Adjust the story title path based on the parent directory (e.g. `Form/{ComponentName}` if under `app/components/Form/`).

## Step 5: Verify

Run these commands sequentially, stopping if any fails:

```bash
pnpm typecheck && pnpm lint && pnpm test --run
```

Fix any issues before reporting to the user.
