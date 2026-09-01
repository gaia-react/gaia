import {composeStory} from '@storybook/react-vite';
import userEvent from '@testing-library/user-event';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import {LANGUAGES} from '~/languages';
import common from '~/languages/en/common';
import Meta, {Default} from './index.stories';

// composeStory applies the story's decorators (stubs.reactRouter()) so that
// router hooks (useFetcher, useLocation) work without a real server.
const IndexPageStory = composeStory(Default, Meta);

describe('IndexPage', () => {
  // Present: required content

  test('renders exactly one <h1> with the configured site name', () => {
    render(<IndexPageStory />);
    const headings = screen.getAllByRole('heading', {level: 1});
    expect(headings).toHaveLength(1);
    expect(headings[0]).toHaveTextContent(common.meta.siteName);
  });

  test('renders a labeled theme-switch button', () => {
    render(<IndexPageStory />);
    // ThemeSwitch's aria-label names the mode the button switches to. The router
    // stub registers no route the root loader data hangs off, so no stored
    // preference reaches the component and the mode is the "system" default.
    expect(
      screen.getByRole('button', {name: common.theme.enableLightMode})
    ).toBeInTheDocument();
  });

  test('submits the theme switch without a router error', async () => {
    const {click} = userEvent.setup();
    render(<IndexPageStory />);
    const button = screen.getByRole('button', {
      name: common.theme.enableLightMode,
    });
    await click(button);
    // `button` is the pre-click reference, so this reads as a tautology and is
    // not one: a fetcher path the stub does not register unmounts the story in
    // favor of the router's error boundary.
    expect(button).toBeInTheDocument();
  });

  // Conditional: language select tracks LANGUAGES (LanguageSelect guard)

  // LanguageSelect renders nothing with a single configured language and the
  // <select> only once a second locale is added (add-locale grows LANGUAGES).
  // Branch at declaration so the suite stays green in both modes without a
  // conditional expect.
  test.runIf(LANGUAGES.length <= 1)(
    'renders no language select for a single configured language',
    () => {
      render(<IndexPageStory />);
      expect(
        screen.queryByRole('combobox', {name: /language/i})
      ).not.toBeInTheDocument();
    }
  );

  test.runIf(LANGUAGES.length > 1)(
    'renders a language select when multiple languages are configured',
    () => {
      render(<IndexPageStory />);
      expect(
        screen.getByRole('combobox', {name: /language/i})
      ).toBeInTheDocument();
    }
  );

  // Absent: marketing chrome, branding, and layout landmarks

  test.each([
    ['has no GitHub CTA link', 'link', {name: /github/i}],
    ['has no feature definition-list term', 'term', undefined],
    ['has no gaia-branded image', 'img', {name: /gaia/i}],
    ['has no banner landmark', 'banner', undefined],
    ['has no contentinfo landmark', 'contentinfo', undefined],
  ] as const)('%s', (_label, role, options) => {
    render(<IndexPageStory />);
    expect(screen.queryByRole(role, options)).not.toBeInTheDocument();
  });
});
