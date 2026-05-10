import type {Meta, StoryFn} from '@storybook/react-vite';
import Checkboxes from '..';

const meta: Meta = {
  component: Checkboxes,
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/Checkboxes',
};

export default meta;

const toppings = [
  {
    label: (
      <span>
        Cheese{' '}
        <span className="text-secondary rounded-sm px-2 py-0.5 text-sm">
          Included
        </span>
      </span>
    ),
    name: 'cheese',
  },
  {
    label: (
      <span>
        Ham{' '}
        <span className="text-sm text-gray-400 dark:text-gray-600">
          {' '}
          (¥200)
        </span>
      </span>
    ),
    name: 'ham',
  },
];

const sizes = [
  {
    label: 'Medium',
    name: 'md',
  },
  {
    label: 'Large',
    name: 'lg',
  },
];

export const Default: StoryFn = () => (
  <div className="max-w-sm space-y-4 p-4">
    <Checkboxes
      options={[
        {label: 'No group label', name: 'w1'},
        {label: 'Another choice', name: 'w2'},
      ]}
    />
    <hr />
    <Checkboxes
      description="This is a description"
      isHorizontal={true}
      label="Horizontal Checkboxes"
      options={toppings}
    />
    <hr />
    <Checkboxes
      description="This is a description"
      label="Vertical Checkboxes"
      options={sizes}
    />
    <hr />
    <Checkboxes
      error="You must check it"
      isHorizontal={true}
      label="Required group"
      options={[
        {
          error: true,
          label: 'Option 1',
          name: 'w3',
          required: true,
        },
        {
          error: false,
          label: 'Option 2',
          name: 'w6',
          required: true,
        },
      ]}
    />
  </div>
);
