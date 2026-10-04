import type {Meta, StoryObj} from '@storybook/react-vite';
import {expect, waitFor, within} from 'storybook/test';
import {notify} from '~/utils/notify';
import stack from './stack';

const meta: Meta = {
  component: () => <div />,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Utils/Notify',
};

export default meta;

type Story = StoryObj<typeof meta>;

// Each story fires its toast and waits until it is on screen, so an
// accessibility scan sees a rendered toast instead of an empty Toaster.
const expectToast = async (canvasElement: HTMLElement, text: string) => {
  await waitFor(async () => {
    await expect(within(canvasElement).getByText(text)).toBeVisible();
  });
};

export const ErrorToast: Story = {
  play: async ({canvasElement}) => {
    notify.error({
      description: 'The server could not save your changes.',
      message: 'Something went wrong',
    });

    await expectToast(canvasElement, 'Something went wrong');
  },
};

export const Info: Story = {
  play: async ({canvasElement}) => {
    notify.info({
      description: 'A new version of the app is available.',
      message: 'Update available',
    });

    await expectToast(canvasElement, 'Update available');
  },
};

export const Success: Story = {
  play: async ({canvasElement}) => {
    notify.success({
      description: 'Your changes have been saved.',
      message: 'Saved',
    });

    await expectToast(canvasElement, 'Saved');
  },
};

export const Warning: Story = {
  play: async ({canvasElement}) => {
    notify.warning('Your session expires in five minutes');

    await expectToast(canvasElement, 'Your session expires in five minutes');
  },
};

export const WithStack: Story = {
  play: async ({canvasElement}) => {
    notify.error({
      message: JSON.stringify({
        description: 'Expand to view the stack trace',
        message: 'Error with stack trace',
        stack,
      }),
    });

    await expectToast(canvasElement, 'Error with stack trace');
  },
};
