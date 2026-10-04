import type {Meta, StoryFn} from '@storybook/react-vite';
import {Button} from '~/components/ui/button';
import {
  ButtonGroup,
  ButtonGroupSeparator,
  ButtonGroupText,
} from '~/components/ui/button-group';

const meta: Meta = {
  component: ButtonGroup,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/ButtonGroup',
};

export default meta;

export const Default: StoryFn = () => (
  <ButtonGroup>
    <Button variant="outline">One</Button>
    <Button variant="outline">Two</Button>
    <ButtonGroupSeparator />
    <ButtonGroupText>Three</ButtonGroupText>
  </ButtonGroup>
);

export const Vertical: StoryFn = () => (
  <ButtonGroup orientation="vertical">
    <Button variant="outline">One</Button>
    <Button variant="outline">Two</Button>
    <Button variant="outline">Three</Button>
  </ButtonGroup>
);
