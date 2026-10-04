import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import {Toaster} from '~/components/ui/sonner';

const meta: Meta = {
  component: Toaster,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Components/Ui/Sonner',
};

export default meta;

export const Default: StoryFn = () => <Toaster />;
