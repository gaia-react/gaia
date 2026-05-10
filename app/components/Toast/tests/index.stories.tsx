import type {Meta, StoryFn} from '@storybook/react-vite';
import Button from '~/components/Button';
import {notify} from '..';
import stack from './stack';

const meta: Meta = {
  component: () => <div />,
  parameters: {
    controls: {hideNoControlsWarning: true},
    toast: true,
    wrap: 'p-4',
  },
  title: 'Components/Toast',
};

export default meta;

const handleClick = (type: string) => {
  if (type === 'error') {
    notify.error({
      message: JSON.stringify({
        description: 'Expand to view the stack trace',
        message: 'Error with stack trace',
        stack,
      }),
    });
  } else if (type === 'success') {
    notify.success({
      description:
        'HTML in message and description are supported.<br/><br/>When the description is long it will wrap and display as multiline so you can see how it looks when the description is very long.<br/><br/><em>This toast</em> displays for <strong>10 seconds</strong>.',
      duration: 10_000, // custom duration overrides default
      message:
        'This is a long success message that shows how wrapping to multiple lines will display when triggered.',
    });
  } else if (type === 'warning') {
    notify.warning('Basic toast can be passed a string message');
  } else if (type === 'info') {
    notify.info({
      description:
        'This is a what a very long message without a title looks like.Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.',
    });
  }
};

export const Default: StoryFn = () => (
  <div
    style={{
      display: 'flex',
      flexDirection: 'column',
      gap: '1rem',
      width: 'fit-content',
    }}
  >
    <Button
      onClick={() => {
        handleClick('error');
      }}
      size="sm"
      variant="tertiary"
    >
      Error
    </Button>
    <Button
      onClick={() => {
        handleClick('success');
      }}
      size="sm"
      variant="tertiary"
    >
      Success
    </Button>
    <Button
      onClick={() => {
        handleClick('warning');
      }}
      size="sm"
      variant="tertiary"
    >
      Warning
    </Button>
    <Button
      onClick={() => {
        handleClick('info');
      }}
      size="sm"
      variant="tertiary"
    >
      Info
    </Button>
  </div>
);
