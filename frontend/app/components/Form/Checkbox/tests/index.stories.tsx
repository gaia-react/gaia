import type {Meta, StoryFn} from '@storybook/react-vite';
import Checkbox from '..';

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
  component: Checkbox,
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/Checkbox',
};

export default meta;

const Template: StoryFn = (args) => (
  <div className="max-w-sm space-y-4 p-4">
    <div>
      <Checkbox defaultChecked={true} name="noLabel" {...args} />
    </div>
    <hr />
    <div>
      <Checkbox label="Choice" name="normal" {...args} />
    </div>
    <hr />
    <div>
      <Checkbox
        label={
          <span>
            This has a{' '}
            <a href="https://www.google.com" rel="noreferrer" target="_blank">
              link
            </a>{' '}
            in it
          </span>
        }
        name="withLink"
        {...args}
      />
    </div>
    <hr />
    <div>
      <Checkbox
        description="This has a description"
        label="Choice"
        name="description"
        {...args}
      />
    </div>
    <hr />
    <div>
      <Checkbox
        error="Required"
        label="Required Invalidated"
        name="required"
        required={true}
        {...args}
      />
    </div>
    <hr />
    <div>
      <Checkbox disabled={true} label="Disabled" name="disabled" {...args} />
    </div>
    <hr />
    <div>
      <Checkbox
        defaultChecked={true}
        disabled={true}
        label="Disabled Checked"
        name="disabledChecked"
        {...args}
      />
    </div>
  </div>
);

export const Default = Template.bind({});
Default.args = {
  size: 'base',
};
