import type {Meta, StoryFn} from '@storybook/react-vite';
import {Input} from '~/components/ui/input';
import {Label} from '~/components/ui/label';

const meta: Meta = {
  component: Label,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Label',
};

export default meta;

export const Default: StoryFn = () => (
  <div className="flex flex-col gap-2">
    <Label htmlFor="label-story-input">Email</Label>
    <Input id="label-story-input" type="email" />
  </div>
);
