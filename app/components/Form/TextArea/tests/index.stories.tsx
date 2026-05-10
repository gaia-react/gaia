import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import TextArea from '..';

const meta: Meta = {
  component: TextArea,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4 max-w-sm space-y-4',
  },
  title: 'Form/TextArea',
};

export default meta;

export const Default: StoryFn = () => (
  <>
    <TextArea label="Autosize" name="auto" />
    <TextArea
      label="Max Length Manual Resize"
      maxLength={50}
      name="manual"
      resize="y"
      rows={3}
    />
  </>
);
