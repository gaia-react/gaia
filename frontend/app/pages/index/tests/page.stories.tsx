import type {Meta, StoryFn} from '@storybook/react-vite';
import {expect, userEvent, within} from 'storybook/test';
import stubs from 'test/stubs';
import {LANGUAGES} from '~/languages';
import common from '~/languages/en/common';
import IndexPage from '../page';

const meta: Meta = {
  component: IndexPage,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Pages/Index',
};

export default meta;

export const Default: StoryFn = () => <IndexPage />;

Default.play = async ({canvasElement}) => {
  const canvas = within(canvasElement);

  const headings = await canvas.findAllByRole('heading', {level: 1});
  await expect(headings).toHaveLength(1);
  await expect(headings[0]).toHaveTextContent(common.meta.siteName);

  // Marketing chrome, branding, and layout landmarks stay absent.
  await expect(
    canvas.queryByRole('link', {name: /github/i})
  ).not.toBeInTheDocument();
  await expect(canvas.queryByRole('term')).not.toBeInTheDocument();
  await expect(
    canvas.queryByRole('img', {name: /gaia/i})
  ).not.toBeInTheDocument();
  await expect(canvas.queryByRole('banner')).not.toBeInTheDocument();
  await expect(canvas.queryByRole('contentinfo')).not.toBeInTheDocument();

  // The language select renders only once a second locale is configured, so
  // the expectation follows the configured language count.
  const languageSelect = canvas.queryByRole('combobox', {name: /language/i});

  if (LANGUAGES.length <= 1) {
    await expect(languageSelect).not.toBeInTheDocument();
  } else {
    await expect(languageSelect).toBeInTheDocument();
  }

  // ThemeSwitch's aria-label names the mode the button switches to. The router
  // stub registers no route the root loader data hangs off, so no stored
  // preference reaches the component and the mode is the "system" default.
  const button = canvas.getByRole('button', {
    name: common.theme.enableLightMode,
  });
  await expect(button).toBeInTheDocument();

  await userEvent.click(button);

  // `button` is the pre-click reference, so this reads as a tautology and is
  // not one: a fetcher path the stub does not register unmounts the story in
  // favor of the router's error boundary.
  await expect(button).toBeInTheDocument();
};

export const Mobile: StoryFn = () => <IndexPage />;
Mobile.parameters = {
  chromatic: {modes: {dark: {viewport: 375}, light: {viewport: 375}}},
};
