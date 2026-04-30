import {IoSearch} from 'react-icons/io5';
import type {Meta, StoryFn} from '@storybook/react-vite';
import Button from '~/components/Button';
import InputText from '~/components/Form/InputText';
import Select from '~/components/Form/Select';
import Chain from '../index';

const meta: Meta = {
  component: Chain,
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/Chain',
};

export default meta;

const options1 = [
  {label: 'Option 1', value: '1'},
  {label: 'Option 2', value: '2'},
];

export const Default: StoryFn = () => (
  <form className="space-y-8 p-4">
    <Chain>
      <InputText name="foo" placeholder="Input" />
      <Select name="bar" options={options1} unselected="Select" />
    </Chain>
    <Chain>
      <InputText name="foo1" placeholder="Input" />
      <Select name="bar1" options={options1} unselected="Select" />
      <Button variant="primary">Button</Button>
    </Chain>
    <Chain>
      <Button variant="primary">Button</Button>
      <InputText name="foo2" placeholder="Input" />
      <Select name="bar2" options={options1} unselected="Select" />
    </Chain>
    <Chain>
      <InputText
        label="Example Label"
        name="foo3"
        placeholder="Labeled Input"
      />
      <InputText name="bar3" placeholder="Input" />
      <Button icon={IoSearch} variant="primary" />
      <Select
        label="Choice"
        name="baz1"
        options={options1}
        unselected="Select"
      />
    </Chain>
  </form>
);

export const FullWidth: StoryFn = () => (
  <form className="max-w-2xl space-y-8 p-4">
    <Chain isFullWidth={true}>
      <InputText name="full-foo" placeholder="Input" />
      <Select name="full-bar" options={options1} unselected="Select" />
    </Chain>
    <Chain isFullWidth={true}>
      <InputText name="full-foo1" placeholder="Input" />
      <Select name="full-bar1" options={options1} unselected="Select" />
      <Button variant="primary">Button</Button>
    </Chain>
    <Chain isFullWidth={true}>
      <Button variant="primary">Button</Button>
      <InputText name="full-foo2" placeholder="Input" />
      <Select name="full-bar2" options={options1} unselected="Select" />
    </Chain>
    <Chain isFullWidth={true}>
      <InputText
        label="Example Label"
        name="full-foo3"
        placeholder="Labeled Input"
      />
      <InputText name="full-baz1" placeholder="Input" />
      <Button icon={IoSearch} variant="primary" />
      <Select
        label="Choice"
        name="full-bar3"
        options={options1}
        unselected="Select"
      />
    </Chain>
  </form>
);
