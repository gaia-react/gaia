import type {Meta, StoryFn} from '@storybook/react-vite';
import RadioButtons from '..';

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
  component: RadioButtons,
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/RadioButtons',
};

export default meta;

const hawaii = [
  {label: 'Fish Tacos', value: 'fishtacos'},
  {label: 'Loco Moco', value: 'locomoco'},
  {label: 'Poke', value: 'poke'},
];

const vegetables = [
  {label: 'Asparagus', value: 'asparagus'},
  {label: 'Broccoli', value: 'broccoli'},
  {label: 'Carrot', value: 'carrot'},
];

const ramen = [
  {error: true, label: 'Tonkotsu', value: 'tonkotsu'},
  {disabled: true, label: 'Shoyu', value: 'shouyu'},
  {label: 'Miso', value: 'miso'},
];

const doughnuts = [
  {label: 'Glazed', value: 'glazed'},
  {label: 'Chocolate', value: 'chocolate'},
  {label: 'Jelly', value: 'jelly'},
];

const pizza = [
  {
    label: (
      <span>
        Hawaiian
        <span className="ml-2 rounded-sm bg-purple-600 px-1.5 py-0.5 text-xs text-white">
          Special Offer $3.99
        </span>
      </span>
    ),
    value: 'hawaiian',
  },
  {
    disabled: true,
    label: (
      <span>
        Cheese <span className="text-xs text-gray-300">(Out of stock)</span>
      </span>
    ),
    value: 'cheese',
  },
  {label: 'Pepperoni', value: 'pepperoni'},
];

const Template: StoryFn = (args) => (
  <form className="grid max-w-4xl grid-cols-2 gap-8 p-4">
    <RadioButtons
      description="Aloha this is help text"
      isHorizontal={true}
      label="Horizontal Hawaiian"
      name="hawaii"
      options={hawaii}
      {...args}
    />
    <RadioButtons
      defaultValue="glazed"
      description="No doughnuts for you"
      disabled={true}
      isHorizontal={true}
      label="Disabled Doughnuts"
      name="doughnuts"
      options={doughnuts}
      {...args}
    />
    <RadioButtons
      label="Vertical Vegetables"
      name="vegetables"
      options={vegetables}
      {...args}
    />
    <RadioButtons
      label="Partial Pizza"
      name="pizza"
      options={pizza}
      {...args}
    />
    <RadioButtons
      description="Shoyu ramen is not available"
      error="You must choose one"
      label="Ramen Flavor"
      name="ramen"
      options={ramen}
      required={true}
      {...args}
    />
  </form>
);

export const Default = Template.bind({});
Default.args = {
  size: 'base',
};
