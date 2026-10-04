import type {Meta, StoryFn} from '@storybook/react-vite';
import {InfoIcon} from 'lucide-react';
import {Alert, AlertDescription, AlertTitle} from '~/components/ui/alert';

const meta: Meta = {
  component: Alert,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-md p-4',
  },
  title: 'Components/Ui/Alert',
};

export default meta;

export const Default: StoryFn = () => (
  <Alert>
    <InfoIcon />
    <AlertTitle>Heads up</AlertTitle>
    <AlertDescription>You can add components to your app.</AlertDescription>
  </Alert>
);

export const Destructive: StoryFn = () => (
  <Alert variant="destructive">
    <InfoIcon />
    <AlertTitle>Something went wrong</AlertTitle>
    <AlertDescription>Your session has expired.</AlertDescription>
  </Alert>
);
