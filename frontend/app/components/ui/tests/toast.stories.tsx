import type {Meta, StoryObj} from '@storybook/react-vite';
import {expect, waitFor, within} from 'storybook/test';
import {toast, Toaster} from '~/components/ui/toast';

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

type Story = StoryObj<typeof meta>;

const expectToast = async (canvasElement: HTMLElement, text: string) => {
  await waitFor(async () => {
    await expect(
      within(canvasElement.ownerDocument.body).getByText(text)
    ).toBeVisible();
  });
};

export const Default: Story = {
  play: async ({canvasElement}) => {
    toast.add({
      description: 'Monday, January 3rd at 6:00pm',
      title: 'Event created',
    });

    await expectToast(canvasElement, 'Event created');
  },
};

export const WithAction: Story = {
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

export const Loading: Story = {
  parameters: {chromatic: {disableSnapshot: true}},
  play: async ({canvasElement}) => {
    toast.add({title: 'Uploading file', type: 'loading'});

    await expectToast(canvasElement, 'Uploading file');
  },
};

const createTypeStory = (
  type: 'error' | 'info' | 'success' | 'warning'
): Story => ({
  play: async ({canvasElement}) => {
    toast.add({title: `${type} toast`, type});

    await expectToast(canvasElement, `${type} toast`);
  },
});

export const ErrorType: Story = createTypeStory('error');

export const Info: Story = createTypeStory('info');

export const Success: Story = createTypeStory('success');

export const Warning: Story = createTypeStory('warning');
