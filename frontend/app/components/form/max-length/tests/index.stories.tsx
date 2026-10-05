import type {Meta, StoryFn} from '@storybook/react-vite';
import {expect, within} from 'storybook/test';
import {
  InputGroup,
  InputGroupAddon,
  InputGroupInput,
} from '~/components/ui/input-group';
import MaxLength from '..';

const meta: Meta = {
  component: MaxLength,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Components/Form/MaxLength',
};

export default meta;

export const Default: StoryFn = () => <MaxLength length={12} maxLength={100} />;

Default.play = async ({canvasElement}) => {
  await expect(within(canvasElement).getByText('12 / 100')).toBeVisible();
};

export const AtLimit: StoryFn = () => (
  <MaxLength length={100} maxLength={100} />
);

export const InInputGroup: StoryFn = () => (
  <InputGroup className="max-w-sm">
    <InputGroupInput aria-label="Nickname" defaultValue="gaia" />
    <InputGroupAddon align="inline-end">
      <MaxLength length={4} maxLength={20} />
    </InputGroupAddon>
  </InputGroup>
);

export const WithClassName: StoryFn = () => (
  <MaxLength className="ml-2" length={1} maxLength={10} />
);

WithClassName.play = async ({canvasElement}) => {
  await expect(within(canvasElement).getByText('1 / 10')).toHaveClass('ml-2');
};
