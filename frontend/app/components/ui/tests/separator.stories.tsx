import type {Meta, StoryFn} from '@storybook/react-vite';
import {Separator} from '~/components/ui/separator';

const meta: Meta = {
  component: Separator,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Separator',
};

export default meta;

export const Default: StoryFn = () => (
  <div className="flex flex-col gap-4">
    <p className="text-sm">Above</p>
    <Separator />
    <div className="flex h-5 items-center gap-4 text-sm">
      <span>Left</span>
      <Separator orientation="vertical" />
      <span>Right</span>
    </div>
  </div>
);
