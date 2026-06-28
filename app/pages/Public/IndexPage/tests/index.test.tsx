import {composeStory} from '@storybook/react-vite';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import common from '~/languages/en/common';
import Meta, {Default} from './index.stories';

// composeStory applies the story's decorators (stubs.reactRouter()) so that
// router hooks (useFetcher, useLocation) work without a real server.
const IndexPageStory = composeStory(Default, Meta);

describe('IndexPage', () => {
  // ------------------------------------------------------------------
  // Present: required content
  // ------------------------------------------------------------------

  test('renders exactly one <h1> with the configured site name', () => {
    render(<IndexPageStory />);
    const headings = screen.getAllByRole('heading', {level: 1});
    expect(headings).toHaveLength(1);
    expect(headings[0]).toHaveTextContent(common.meta.siteName);
  });

  test('renders a labeled theme-switch button', () => {
    render(<IndexPageStory />);
    // ThemeSwitch aria-label cycles through theme keys; default mode is
    // "system" so the button reads t('theme.enableLightMode') = "Enable light mode".
    // Match any of the three possible labels.
    expect(
      screen.getByRole('button', {name: /light mode|dark mode|system theme/i})
    ).toBeInTheDocument();
  });

  test('renders a labeled language-select combobox', () => {
    render(<IndexPageStory />);
    // LanguageSelect renders a <select aria-label={t('language')}> = "Language"
    expect(
      screen.getByRole('combobox', {name: /language/i})
    ).toBeInTheDocument();
  });

  // ------------------------------------------------------------------
  // Absent: removed brand surface (C5)
  // ------------------------------------------------------------------

  test('has no GitHub CTA link', () => {
    render(<IndexPageStory />);
    expect(
      screen.queryByRole('link', {name: /github/i})
    ).not.toBeInTheDocument();
  });

  test('has no feature definition-list term', () => {
    render(<IndexPageStory />);
    expect(screen.queryByRole('term')).not.toBeInTheDocument();
  });

  test('has no GaiaLogo image', () => {
    render(<IndexPageStory />);
    // GaiaLogo was deleted; no img referencing gaia branding should exist
    expect(screen.queryByRole('img', {name: /gaia/i})).not.toBeInTheDocument();
  });

  test('has no banner landmark (Header removed)', () => {
    render(<IndexPageStory />);
    expect(screen.queryByRole('banner')).not.toBeInTheDocument();
  });

  test('has no contentinfo landmark (Footer removed)', () => {
    render(<IndexPageStory />);
    expect(screen.queryByRole('contentinfo')).not.toBeInTheDocument();
  });
});
