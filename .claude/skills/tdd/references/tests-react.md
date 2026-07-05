# React Testing Reference (Vitest + RTL + MSW + Storybook)

## Testing Layers

Four layers share one mocking foundation (`msw` + `@msw/data`). Write tests at the **lowest layer that can verify the behavior**, a button's disabled state is a component test, not E2E; a route's redirect is E2E, a loader's parsing is a service test.

| Layer       | Tool                           | Runner     | File location                  | What to assert                                      |
| ----------- | ------------------------------ | ---------- | ------------------------------ | --------------------------------------------------- |
| Unit / hook | RTL `renderHook`               | Vitest     | `app/hooks/<name>/tests/`      | hook return values, state transitions, callbacks    |
| Component   | RTL + Storybook `composeStory` | Vitest     | `app/components/<Name>/tests/` | rendered DOM, user interactions, props behavior     |
| Service     | MSW handlers + Zod             | Vitest     | `app/services/<name>/tests/`   | parsed response shape, request payload, error cases |
| E2E         | Playwright + MSW browser       | Playwright | `.playwright/e2e/*.spec.ts`    | full user flow across routes                        |

## Component Tests via `composeStory`

The story is the test's source of truth. Use `composeStory`, never render a fresh `<Component prop={...} />` directly in tests, because stories already set up decorators (i18n, router, state) via `test/stubs`. Rendering fresh bypasses those stubs and produces flaky or incomplete tests.

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

The tracer bullet for any component: `composeStory(Default, Meta)` renders without throwing. Use ARIA roles and accessible names as selectors, `getByRole('button', {name: 'Save'})`, `getByText('$49.99')`, not class selectors or test ids.

### Overriding a prop (callback spies)

When a test overrides a prop on a composed story, especially a callback it spies on, the story must accept `(args)` and spread `{...args}` **last**, after any hardcoded default, so the override wins. Storybook's own guidance says the render function "spreads `args` onto the component" (https://storybook.js.org/docs/writing-stories), and `composeStory` says render-time props "override the values passed in the story's args" (https://storybook.js.org/docs/api/portable-stories/portable-stories-vitest#composestory). `args` only reaches the real component through that spread, so a story that hardcodes the callback, or spreads `{...args}` before it, silently drops the override.

Storybook's own examples spread every prop from `args`, so there's nothing to order against. This repo's stories hardcode structural/demo props inline (labels, names, options) and spread `{...args}` only for the controllable knobs, see `app/components/Form/RadioButtons/tests/index.stories.tsx`, so ordering is load-bearing: `{...args}` must come after the hardcoded props for an override to win.

```tsx
// app/components/Toggle/tests/index.stories.tsx
// GOOD - accepts args and spreads {...args} LAST, so a test can override onChange
const Template: StoryFn = (args) => (
  <Toggle label="Notifications" onChange={() => {}} {...args} />
);

export const Default = Template.bind({});
Default.args = {checked: false};
```

```tsx
// app/components/Toggle/tests/index.test.tsx
// GOOD - the override reaches the real component, so the spy assertion is real
test('emits onChange when toggled', async () => {
  const onChange = vi.fn();
  render(<Toggle onChange={onChange} />);
  await userEvent.click(screen.getByRole('switch', {name: 'Notifications'}));
  expect(onChange).toHaveBeenCalledWith(true);
});
```

(`Toggle` here is `composeStory(Default, Meta)` in the test, mirroring the `const DefaultTag = composeStory(Default, Meta)` idiom above.)

```tsx
// BAD: hardcodes onChange (or never accepts args), so a render-time override is dropped
const Template: StoryFn = (args) => (
  <Toggle label="Notifications" {...args} onChange={() => {}} />
);
// equally broken: a story that never accepts (args):
// export const Default: StoryFn = () => <Toggle label="Notifications" onChange={() => {}} />;
```

```tsx
// BAD: the spy is never wired, so this assertion passes vacuously
test('does not emit onChange while disabled', async () => {
  const onChange = vi.fn();
  render(<Toggle disabled onChange={onChange} />); // override silently dropped
  await userEvent.click(screen.getByRole('switch', {name: 'Notifications'}));
  expect(onChange).not.toHaveBeenCalled(); // green even if the disabled guard is broken
});
```

Why bad: the story hardcodes `onChange`, so the composed story ignores the render-time override and hands the component its own `() => {}`. The spy is never wired, so `not.toHaveBeenCalled()` passes no matter what the component does; it would stay green even if the disabled guard were removed. (A positive `toHaveBeenCalledWith` on the same broken story fails loudly instead, which tempts a raw-render "fix" that bypasses the story's stubs; the real fix is to make the story spread `{...args}` last.)

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

Assert on `result.current`, the observable hook surface. Don't reach into closures or internal state.

## Service Tests via MSW

MSW handlers run inside Vitest, you're exercising the real `api()` wrapper, real Zod parsing, and real URL resolution. No `vi.mock('fetch')`.

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

MSW handlers run in Vitest, Storybook, AND Playwright, one mock layer, three testing scopes.

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

Why bad: handler existence proves nothing. Assert on the effect, database state after the call, or the returned value.

## Worth Keeping: the Discriminator, Composition, and Platform Rules

A test that passes can still be worthless. The honesty rules ("Bad Tests" above) ask whether a test _can_ fail for a real reason; these rules ask whether the test is worth having at all. Tests that re-prove a dependency, re-prove a child component, or pin the byte output of a platform formatter add maintenance cost and break on unrelated upgrades while catching none of your bugs.

### The discriminator

Before keeping any test, ask:

> If this test failed, would the bug be in MY code or in the dependency? If the dependency, delete the test.

`date-fns`, `Intl`, Zod, `react-router`, `react-i18next` all have their own suites. A test whose only failure mode is "the library changed" tests the library, not you.

### The composition rule

A test for component `C` asserts the **emergent behavior of its children together**: the seam where data and events flow through `C`. It never re-proves what the children's own suites already cover.

```tsx
// app/components/Checkout/tests/index.test.tsx
// GOOD - the seam: PriceTag + QuantityStepper feeding the running total in Checkout
test('total updates when quantity changes', async () => {
  render(<DefaultCheckout />);
  await userEvent.click(screen.getByRole('button', {name: 'Increase quantity'}));
  expect(screen.getByRole('status', {name: 'Order total'})).toHaveTextContent('$99.98');
});

// BAD - re-proves PriceTag's own suite; nothing here is about Checkout
test('price renders with two decimals', () => {
  render(<DefaultCheckout />);
  expect(screen.getByText('$49.99')).toBeInTheDocument(); // PriceTag's job, tested in PriceTag's suite
});
```

This is a judgment call, not a lint rule: applied bluntly it strips real integration regressions. An agent applies it **PROPOSE-only and NEVER auto-deletes a child-redundant test.** Any proposed delete must cite both the specific redundant sibling assertion AND the seam assertion that subsumes it, and the cited sibling assertion is machine-verified to contain a matching assertion before the proposal reaches a human. Security, escaping, and data-integrity seam tests (for example a Toast XSS-escaping test) carry a never-delete-without-a-verified-sibling carve-out: they stay even when a sibling looks redundant.

### The platform rule

When a helper delegates to a platform formatter (`Intl`, `date-fns`), test the logic you own, not the formatter's output bytes.

```tsx
// WORTHLESS - tests Intl, not you
// formatPrice = (n) => new Intl.NumberFormat('en-US',
//   {style: 'currency', currency: 'USD'}).format(n);
test('formats as USD', () => expect(formatPrice(49.99)).toBe('$49.99'));

// WORTHY - tests YOUR logic; Intl is just the boundary it delegates to
// formatPrice = (cents, currency) => {
//   if (cents == null) return '';
//   return new Intl.NumberFormat(LOCALE_BY_CURRENCY[currency],
//     {style: 'currency', currency}).format(cents / 100);
// };
test('renders nothing for a null amount', () =>
  expect(formatPrice(null, 'USD')).toBe(''));
test('converts cents to major units', () =>
  expect(formatPrice(4999, 'USD')).toBe('$49.99'));
test('picks the locale for the currency', () => {
  // Assert the locale SELECTION you own with a TOLERANT matcher, never byte-exact
  // glyphs. Intl uses a narrow no-break space that varies by ICU version, so
  // toBe('49,99 €') is itself the platform-coupled anti-pattern this rule warns
  // against - it breaks on a Node/ICU upgrade with no bug in your code.
  const out = formatPrice(4999, 'EUR');
  expect(out).toMatch(/49,99/);
  expect(out).toContain('€');
});
```

The null-amount guard and the cents-to-major conversion and the currency-to-locale selection are yours. The decimal separator, currency glyph, and spacing belong to `Intl`. Assert the first set; tolerate the second.

### Thin wrappers over a platform formatter

A helper that only selects a locale or format and delegates to `Intl` or `date-fns` is the platform rule's most common shape. `formatMY` in `app/utils/date.ts` delegates straight to `date-fns`'s `format` with a fixed `MM/yy` pattern:

```ts
export const formatMY = (date = new Date()): string => format(date, 'MM/yy');
```

```ts
// WORTHLESS - re-proves date-fns formats MM/yy; the bug would be in date-fns
test('formats MM/yy', () =>
  expect(formatMY(new Date('2026-01-15'))).toBe('01/26'));
```

`formatMY` owns no branching logic to test, so it has nothing worth a unit test of its own; it is exercised through the components that render a card expiry. A sibling like `formatFullYear`, which DOES branch on language (`'en'` versus the `年` suffix), is worth testing on the branch you own, not on the year digits `date-fns` produces.

## Tracer Bullets and a11y

The tracer bullet for any component, `composeStory(Default, Meta)` renders without throwing, and the structural a11y check, `expectNoA11yViolations` on that render, are both **starting points, approved as a complete test ONLY for components with no interactive behavior** (a Spinner, a static badge). For a behavior-rich component, a tracer-bullet-only test is the start of a test, not the whole of it: the interactions, state transitions, and error paths still need assertions.

The same caveat extends to accessibility: `expectNoA11yViolations` on a render-only container is a starting point for interactive components, not a complete a11y test. A render-only axe pass says nothing about focus order, keyboard operation, or the accessible state of controls a user actually drives.

## Red Flags

- `vi.fn()` spy on a function the component uses internally
- `toHaveBeenCalled` as the only assertion (you're testing call-through, not behavior)
- Importing from `../internals` or `.server.ts` files the public consumer wouldn't touch
- Test names like "`useX` returns an object with `a`, `b`, `c`", that's testing shape, not behavior
- Asserting on i18n keys, raw class lists, or DOM structure instead of accessible roles and text
- `vi.mock('~/services/...')`, you've mocked something MSW already handles
- `vi.mock('~/hooks/...')` or `vi.mock('~/components/...')`, internal collaborator mocking
- Test setup that reimplements application logic to seed data (write to `database` instead)
- A fixture file larger than the code it tests
