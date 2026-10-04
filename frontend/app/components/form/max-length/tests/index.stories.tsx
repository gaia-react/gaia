import type {Meta, StoryFn} from '@storybook/react-vite';
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
