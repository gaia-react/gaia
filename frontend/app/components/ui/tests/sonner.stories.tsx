import type {Meta, StoryObj} from '@storybook/react-vite';
import {toast} from 'sonner';
import {expect, waitFor, within} from 'storybook/test';
import {Toaster} from '~/components/ui/sonner';

// The global ToastDecorator already renders the Toaster, so each story fires a
// toast through sonner rather than mounting a second, empty Toaster. The
// per-type toasts the app sends live in the Utils/Notify stories; these cover
// the sonner calls notify does not wrap.
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
    await expect(within(canvasElement).getByText(text)).toBeVisible();
  });
};

export const Default: Story = {
  play: async ({canvasElement}) => {
    toast('Event created', {description: 'Monday, January 3rd at 6:00pm'});

    await expectToast(canvasElement, 'Event created');
  },
};

export const WithAction: Story = {
  play: async ({canvasElement}) => {
    toast('Message archived', {
      action: {label: 'Undo', onClick: () => undefined},
    });

    await expectToast(canvasElement, 'Message archived');
  },
};

export const Loading: Story = {
  parameters: {chromatic: {disableSnapshot: true}},
  play: async ({canvasElement}) => {
    toast.loading('Uploading file');

    await expectToast(canvasElement, 'Uploading file');
  },
};
