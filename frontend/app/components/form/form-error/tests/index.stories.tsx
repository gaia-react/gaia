import {Form} from 'react-router';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {userEvent, within} from 'storybook/test';
import stubs from 'test/stubs';
import {Button} from '~/components/ui/button';
import FormError from '..';

const meta: Meta = {
  component: FormError,
  decorators: [
    stubs.reactRouter({
      action: () => ({error: 'Something went wrong. Please try again.'}),
    }),
  ],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-md p-4',
  },
  title: 'Components/Form/FormError',
};

export default meta;

const showError = async ({canvasElement}: {canvasElement: HTMLElement}) => {
  await userEvent.click(
    await within(canvasElement).findByRole('button', {name: 'Submit'})
  );
};

export const Default: StoryFn = () => (
  <Form className="space-y-4" method="post">
    <FormError />
    <Button type="submit">Submit</Button>
  </Form>
);

Default.play = showError;

export const Hidden: StoryFn = () => (
  <Form className="space-y-4" method="post">
    <FormError isHidden={true} />
    <Button type="submit">Submit</Button>
  </Form>
);

Hidden.play = showError;
