import type {ActionFunctionArgs} from 'react-router';
import {parseWithZod} from '@conform-to/zod/v4';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {expect, userEvent, within} from 'storybook/test';
import stubs from 'test/stubs';
import {ComposedForm, composedFormSchema} from './composed-form';

const action = async ({request}: ActionFunctionArgs) => {
  const submission = parseWithZod(await request.formData(), {
    schema: composedFormSchema,
  });

  return {result: submission.reply()};
};

const meta: Meta = {
  component: ComposedForm,
  decorators: [stubs.reactRouter({action})],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Components/Form/ComposedForm',
};

export default meta;

export const Default: StoryFn = () => <ComposedForm />;

export const Invalid: StoryFn = () => <ComposedForm />;

Invalid.play = async ({canvasElement}) => {
  const canvas = within(canvasElement);

  // Chromatic renders the story in light and dark panes, so act on every copy.
  for (const submit of await canvas.findAllByRole('button', {name: 'Submit'})) {
    await userEvent.click(submit);
  }

  for (const nameField of await canvas.findAllByLabelText('Name')) {
    await expect(nameField).toHaveAttribute('aria-invalid', 'true');
  }
};

export const Disabled: StoryFn = () => <ComposedForm disabled={true} />;
