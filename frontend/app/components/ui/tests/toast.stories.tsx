import type {Meta, StoryObj} from '@storybook/react-vite';
import {expect, within} from 'storybook/test';
import {toast, Toaster} from '~/components/ui/toast';
import {expectToast} from '~/utils/tests/expect-toast';

// The global ToastDecorator already renders the Toaster, so each story fires a
// toast through the ui toast manager rather than mounting a second, empty
// Toaster. The per-type toasts the app sends live in the Utils/Notify stories;
// these cover the manager calls notify does not wrap.
const meta: Meta = {
  component: Toaster,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  render: () => <div />,
  title: 'Components/Ui/Toast',
};

export default meta;

export const Default: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    toast.add({
      description: 'Monday, January 3rd at 6:00pm',
      title: 'Event created',
    });

    await expectToast(canvasElement, 'Event created');
  },
};

export const WithAction: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    toast.add({
      actionProps: {children: 'Undo', onClick: () => undefined},
      title: 'Message archived',
    });

    await expectToast(canvasElement, 'Message archived');
    await expect(
      within(canvasElement.ownerDocument.body).getByRole('button', {
        name: 'Undo',
      })
    ).toBeVisible();
  },
};

export const Loading: StoryObj<typeof meta> = {
  parameters: {chromatic: {disableSnapshot: true}},
  play: async ({canvasElement}) => {
    toast.add({title: 'Uploading file', type: 'loading'});

    await expectToast(canvasElement, 'Uploading file');
  },
};

const createTypeStory = (
  type: 'error' | 'info' | 'success' | 'warning'
): StoryObj<typeof meta> => ({
  play: async ({canvasElement}) => {
    toast.add({title: `${type} toast`, type});

    await expectToast(canvasElement, `${type} toast`);
  },
});

export const ErrorType: StoryObj<typeof meta> = createTypeStory('error');

export const Info: StoryObj<typeof meta> = createTypeStory('info');

export const Success: StoryObj<typeof meta> = createTypeStory('success');

export const Warning: StoryObj<typeof meta> = createTypeStory('warning');
