import type {Meta, StoryFn} from '@storybook/react-vite';
import Spinner from '..';

const meta: Meta = {
  argTypes: {
    size: {
      control: {
        type: 'select',
      },
      name: 'Size',
      options: ['xs', 'sm', 'base', 'lg', 'xl'],
    },
  },
  component: Spinner,
  parameters: {
    chromatic: {disableSnapshot: true},
    wrap: 'p-4',
  },
  title: 'Components/Loaders/Spinner',
};

export default meta;

const Template: StoryFn = (args) => <Spinner {...args} />;

export const Default = Template.bind({});
Default.args = {
  size: 'base',
};
