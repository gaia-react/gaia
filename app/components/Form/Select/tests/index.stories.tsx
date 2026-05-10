import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import Select from '..';

const meta: Meta = {
  component: Select,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/Select',
};

export default meta;

const cuisines = [
  {label: 'Burgers', value: 'burgers'},
  {label: 'Pizza', value: 'pizza'},
  {label: 'Hot Dogs', value: 'hotdogs'},
];

const partial = [
  {label: 'Burgers', value: 'burgers'},
  {disabled: true, label: 'Pizza', value: 'pizza'},
  {label: 'Hot Dogs', value: 'hotdogs'},
];

const grouped = [
  {label: 'American', options: partial},
  {
    label: 'Japanese',
    options: [
      {label: 'Sushi', value: 'sushi'},
      {label: 'Ramen', value: 'ramen'},
      {label: 'Yakitori', value: 'yakitori'},
    ],
  },
];

export const Default: StoryFn = () => (
  <form className="max-w-sm space-y-4 p-4">
    <Select
      label="Enabled"
      name="cuisines"
      options={cuisines}
      unselected="Select a cuisine"
    />
    <Select
      label="Partially Disabled"
      name="partial"
      options={partial}
      unselected="Some are disabled"
    />
    <Select
      description="This is an example of some really long help text that can be used to provide additional context to the user."
      label="Grouped"
      name="grouped"
      options={grouped}
      unselected="Select a cuisine"
    />
    <Select
      disabled={true}
      label="Disabled"
      name="disabled"
      options={cuisines}
      unselected="Cannot select"
    />
  </form>
);
