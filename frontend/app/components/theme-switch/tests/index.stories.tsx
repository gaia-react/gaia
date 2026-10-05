import type {Meta, StoryObj} from '@storybook/react-vite';
import {expect, fn, userEvent, waitFor, within} from 'storybook/test';
import stubs from 'test/stubs';
import {ACTION_PATHS} from '~/action-paths';
import ThemeSwitch from '..';
import type {ThemeSwitchProps} from '..';

type StoryArgs = ThemeSwitchProps & {
  onSubmit: (theme: FormDataEntryValue | null) => void;
};

const meta: Meta<StoryArgs> = {
  args: {onSubmit: fn()},
  component: ThemeSwitch,
  decorators: [
    stubs.reactRouter(({args}) => ({
      actions: {
        [ACTION_PATHS.themeSwitch]: async ({request}) => {
          const formData = await request.formData();

          args.onSubmit(formData.get('theme'));

          return null;
        },
      },
    })),
  ],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  render: ({userPreference}) => <ThemeSwitch userPreference={userPreference} />,
  title: 'Components/ThemeSwitch',
};

export default meta;

type Story = StoryObj<StoryArgs>;

const expectIconAndPost = async ({
  args,
  canvasElement,
  icon,
  name,
  next,
}: {
  args: StoryArgs;
  canvasElement: HTMLElement;
  icon: string;
  name: string;
  next: string;
}) => {
  const button = await within(canvasElement).findByRole('button', {name});

  // Icons are aria-hidden, so the lucide class is the only handle on them.
  await expect(button.querySelector(`svg.lucide-${icon}`)).toBeInTheDocument();

  await userEvent.click(button);

  await waitFor(async () => {
    await expect(args.onSubmit).toHaveBeenCalledTimes(1);
  });
  await expect(args.onSubmit).toHaveBeenCalledWith(next);
};

export const Default: Story = {
  play: async ({args, canvasElement}) =>
    expectIconAndPost({
      args,
      canvasElement,
      icon: 'monitor',
      name: 'Enable light mode',
      next: 'light',
    }),
};

export const Light: Story = {
  args: {userPreference: 'light'},
  play: async ({args, canvasElement}) =>
    expectIconAndPost({
      args,
      canvasElement,
      icon: 'sun',
      name: 'Enable dark mode',
      next: 'dark',
    }),
};

export const Dark: Story = {
  args: {userPreference: 'dark'},
  play: async ({args, canvasElement}) =>
    expectIconAndPost({
      args,
      canvasElement,
      icon: 'moon',
      name: 'Use system theme',
      next: 'system',
    }),
};
