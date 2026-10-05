import type {Meta, StoryObj} from '@storybook/react-vite';
import {notify} from '~/utils/notify';
import {expectToast} from './expect-toast';
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

export const ErrorToast: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.error({
      description: 'The server could not save your changes.',
      message: 'Something went wrong',
    });

    await expectToast(canvasElement, 'Something went wrong');
  },
};

export const Info: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.info({
      description: 'A new version of the app is available.',
      message: 'Update available',
    });

    await expectToast(canvasElement, 'Update available');
  },
};

export const Success: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.success({
      description: 'Your changes have been saved.',
      message: 'Saved',
    });

    await expectToast(canvasElement, 'Saved');
  },
};

export const Warning: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.warning('Your session expires in five minutes');

    await expectToast(canvasElement, 'Your session expires in five minutes');
  },
};

export const WithStack: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    notify.error({
      message: JSON.stringify({
        description: 'The stack trace is logged to the console in development',
        message: 'Error with stack trace',
        stack,
      }),
    });

    await expectToast(canvasElement, 'Error with stack trace');
  },
};
