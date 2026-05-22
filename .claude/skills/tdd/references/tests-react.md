# React Testing Reference (Vitest + RTL + MSW + Storybook)

## Testing Layers

Four layers share one mocking foundation (`msw` + `@msw/data`). Write tests at the **lowest layer that can verify the behavior** — a button's disabled state is a component test, not E2E; a route's redirect is E2E, a loader's parsing is a service test.

| Layer       | Tool                           | Runner     | File location                  | What to assert                                      |
| ----------- | ------------------------------ | ---------- | ------------------------------ | --------------------------------------------------- |
| Unit / hook | RTL `renderHook`               | Vitest     | `app/hooks/<name>/tests/`      | hook return values, state transitions, callbacks    |
| Component   | RTL + Storybook `composeStory` | Vitest     | `app/components/<Name>/tests/` | rendered DOM, user interactions, props behavior     |
| Service     | MSW handlers + Zod             | Vitest     | `app/services/<name>/tests/`   | parsed response shape, request payload, error cases |
| E2E         | Playwright + MSW browser       | Playwright | `.playwright/e2e/*.spec.ts`    | full user flow across routes                        |

## Component Tests via `composeStory`

The story is the test's source of truth. Use `composeStory` — never render a fresh `<Component prop={...} />` directly in tests, because stories already set up decorators (i18n, router, state) via `test/stubs`. Rendering fresh bypasses those stubs and produces flaky or incomplete tests.

```tsx
// app/components/PriceTag/tests/index.stories.tsx
import type {Meta, StoryFn} from '@storybook/react-vite';
import PriceTag from '..';

const meta: Meta = {component: PriceTag};
export default meta;

export const Default: StoryFn = () => <PriceTag amount={4999} currency="USD" />;
export const Discounted: StoryFn = () => (
  <PriceTag amount={4999} currency="USD" discountPercent={20} />
);
```

```tsx
// app/components/PriceTag/tests/index.test.tsx
import {composeStory} from '@storybook/react-vite';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import Meta, {Default, Discounted} from './index.stories';

const DefaultTag = composeStory(Default, Meta);
const DiscountedTag = composeStory(Discounted, Meta);

describe('PriceTag', () => {
  test('renders formatted price', () => {
    render(<DefaultTag />);
    expect(screen.getByText('$49.99')).toBeInTheDocument();
  });

  test('shows strike-through original when discounted', () => {
    render(<DiscountedTag />);
    expect(screen.getByText('$39.99')).toBeInTheDocument();
    expect(screen.getByText('$49.99')).toHaveClass('line-through');
  });
});
```

The tracer bullet for any component: `composeStory(Default, Meta)` renders without throwing. Use ARIA roles and accessible names as selectors — `getByRole('button', {name: 'Save'})`, `getByText('$49.99')` — not class selectors or test ids.

## Hook Tests via `renderHook`

```tsx
// app/hooks/useToggle/tests/index.test.ts
import {act, renderHook} from 'test/rtl';
import {describe, expect, test} from 'vitest';
import useToggle from '..';

describe('useToggle', () => {
  test('starts with initial value', () => {
    const {result} = renderHook(() => useToggle(true));
    expect(result.current[0]).toBe(true);
  });
  test('toggles value', () => {
    const {result} = renderHook(() => useToggle(false));
    act(() => result.current[1]());
    expect(result.current[0]).toBe(true);
  });
});
```

Assert on `result.current` — the observable hook surface. Don't reach into closures or internal state.

## Service Tests via MSW

MSW handlers run inside Vitest — you're exercising the real `api()` wrapper, real Zod parsing, and real URL resolution. No `vi.mock('fetch')`.

```tsx
// app/services/gaia/things/tests/requests.test.ts
import {afterEach, describe, expect, test} from 'vitest';
import database, {resetTestData} from 'test/mocks/database';
import {getThings} from '../requests.server';

describe('getThings', () => {
  afterEach(() => resetTestData());

  test('returns Zod-parsed Things collection', async () => {
    const things = await getThings();
    expect(things).toHaveLength(3);
    expect(things[0]).toMatchObject({
      id: expect.any(String),
      name: expect.any(String),
    });
  });

  test('throws on malformed response', async () => {
    await database.things.create({id: 'x', name: null as unknown as string});
    await expect(getThings()).rejects.toThrow();
  });
});
```

The tracer bullet for services: the happy-path request returns a Zod-parsed result.

## When to Mock

Mock at **system boundaries** only:

| Boundary                | Mock via                               | Example                                       |
| ----------------------- | -------------------------------------- | --------------------------------------------- |
| HTTP / external APIs    | MSW handlers in `test/mocks/`          | REST calls made by `app/services/`            |
| Database read/write     | `@msw/data` collections via `database` | `await database.things.create(...)` in a test |
| Time                    | `vi.useFakeTimers()`                   | Debounced handlers, TTL expiry                |
| Randomness              | `vi.spyOn` at boundary                 | IDs, crypto                                   |
| Navigation (unit scope) | `stubs.reactRouter({routes})`          | Buttons that push to `/done`                  |

**Never mock:**

- Your own services, hooks, components, or utilities. If a component uses `useThings()`, test it against the real hook reading from real MSW. Mocking `useThings` means you're testing a fiction.
- `react-router` or `react-i18next`. Use `stubs.reactRouter()` / `stubs.state()` from `test/stubs`. Global i18n is wired in `test/setup.ts`.
- Zod schemas. If a service fails to parse, that's a real bug the test should surface.

**Mutating data in a test**: write to `database` directly; reset in `afterEach` via `resetTestData()` from `test/mocks/database`. The read-then-verify shape tests the interface end-to-end and survives schema renames as long as the public service contract holds.

MSW handlers run in Vitest, Storybook, AND Playwright — one mock layer, three testing scopes.

## Testing Forms with Conform

For components using `@conform-to/react`, create a story that wraps the component with `useForm`:

```tsx
export const Default: StoryFn = () => {
  const [form, fields] = useForm({
    onValidate: ({formData}) => parseWithZod(formData, {schema}),
  });

  return (
    <Form {...getFormProps(form)}>
      <MyFormComponent fields={fields} />
    </Form>
  );
};
```

### Custom form components: use `useInputControl`

When using custom form components (like `YearMonthDay`, `TimePicker`, etc.) that manage their own internal state, you **must** use `useInputControl` to properly integrate them with Conform's validation state:

```tsx
// BAD - Local state conflicts with Conform's validation
const [value, setValue] = useState(savedData?.field ?? DEFAULT);
const handleChangeValue = useCallback((newValue) => {
  setValue(newValue);
}, []);

<CustomComponent onChange={handleChangeValue} value={value} />;

// GOOD - useInputControl keeps component synced with Conform
const fieldControl = useInputControl(fields.fieldName);

<CustomComponent
  onBlur={fieldControl.blur}
  onChange={fieldControl.change}
  value={fieldControl.value ?? DEFAULT}
/>;
```

**Why this matters**: When validation fails, Conform takes control of the field value. If you use local `useState`, the component becomes disconnected from Conform's state and stops responding to changes after validation errors occur.

See `app/components/Form/YearMonthDay/tests/` for a complete example of this pattern in action.

## Bad Tests

```tsx
// BAD: asserts on translation internals, not user output
test('greets the user', () => {
  const tSpy = vi.fn();
  vi.mock('react-i18next', () => ({useTranslation: () => ({t: tSpy})}));
  render(<Greeting name="Ada" />);
  expect(tSpy).toHaveBeenCalledWith('greeting.hello', {name: 'Ada'});
});
```

Why bad: renaming the key (`greeting.hello` → `pages.home.greeting`) breaks the test even though the user still sees "Hello, Ada".

```tsx
// BAD: mocks react-router, tests the mock
vi.mock('react-router', () => ({useNavigate: () => mockNavigate}));
test('submit navigates to /done', async () => {
  render(<CheckoutButton />);
  await userEvent.click(screen.getByRole('button'));
  expect(mockNavigate).toHaveBeenCalledWith('/done');
});
```

Why bad: tests the mock, not the component. Use `stubs.reactRouter({routes: [{path: '/done', storyId: '...'}]})` and assert on the resulting page.

```tsx
// BAD: reads MSW internals
test('saveThing called POST', async () => {
  const handler = server
    .listHandlers()
    .find((h) => h.info.path.endsWith('/things'));
  expect(handler).toBeDefined();
});
```

Why bad: handler existence proves nothing. Assert on the effect — database state after the call, or the returned value.

## Red Flags

- `vi.fn()` spy on a function the component uses internally
- `toHaveBeenCalled` as the only assertion (you're testing call-through, not behavior)
- Importing from `../internals` or `.server.ts` files the public consumer wouldn't touch
- Test names like "`useX` returns an object with `a`, `b`, `c`" — that's testing shape, not behavior
- Asserting on i18n keys, raw class lists, or DOM structure instead of accessible roles and text
- `vi.mock('~/services/...')` — you've mocked something MSW already handles
- `vi.mock('~/hooks/...')` or `vi.mock('~/components/...')` — internal collaborator mocking
- Test setup that reimplements application logic to seed data (write to `database` instead)
- A fixture file larger than the code it tests
