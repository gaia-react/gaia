import type {ReactNode} from 'react';
import {Form} from 'react-router';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {expect, fireEvent, userEvent, within} from 'storybook/test';
import stubs from 'test/stubs';
import {Button} from '~/components/ui/button';
import {Input} from '~/components/ui/input';
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

const submitAndFindAlert = async (
  canvasElement: HTMLElement
): Promise<HTMLElement> => {
  const canvas = within(canvasElement);

  await userEvent.click(canvas.getByRole('button', {name: 'Submit'}));

  return canvas.findByRole('alert');
};

export const Default: StoryFn = () => (
  <Form className="space-y-4" method="post">
    <FormError />
    <Button type="submit">Submit</Button>
  </Form>
);

Default.play = async ({canvasElement}) => {
  await expect(await submitAndFindAlert(canvasElement)).toHaveTextContent(
    'Something went wrong. Please try again.'
  );
};

export const Hidden: StoryFn = () => (
  <Form className="space-y-4" method="post">
    <FormError isHidden={true} />
    <Button type="submit">Submit</Button>
  </Form>
);

type PlayContext = {canvasElement: HTMLElement};

const actionErrorMessage = 'Something went wrong. Please try again.';

type ErrorFormProps = {children?: ReactNode};

const ErrorForm = ({children}: ErrorFormProps) => (
  <Form className="space-y-4" method="post">
    <FormError />
    {children}
    <Button type="submit">Submit</Button>
  </Form>
);

const focusDismissButton = (canvasElement: HTMLElement): HTMLElement => {
  const dismissButton = within(canvasElement).getByRole('button', {
    name: 'Dismiss',
  });

  dismissButton.focus();

  return dismissButton;
};

const FieldForm = () => (
  <ErrorForm>
    <Input aria-label="Email" name="email" type="email" />
  </ErrorForm>
);

export const KeyboardDismissal: StoryFn = () => <FieldForm />;

KeyboardDismissal.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await submitAndFindAlert(canvasElement);
  focusDismissButton(canvasElement);
  await userEvent.keyboard('{Enter}');

  await expect(canvas.queryByRole('alert')).not.toBeInTheDocument();
  await expect(canvas.getByRole('textbox', {name: 'Email'})).toHaveFocus();

  await userEvent.tab();
  await expect(canvas.getByRole('button', {name: 'Submit'})).toHaveFocus();
};

export const TouchDismissal: StoryFn = () => <FieldForm />;

TouchDismissal.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await submitAndFindAlert(canvasElement);
  await fireEvent(
    canvas.getByRole('button', {name: 'Dismiss'}),
    new PointerEvent('click', {
      bubbles: true,
      cancelable: true,
      pointerType: 'touch',
    })
  );

  await expect(canvas.queryByRole('alert')).not.toBeInTheDocument();
  await expect(canvas.getByRole('textbox', {name: 'Email'})).not.toHaveFocus();
};

export const PenDismissal: StoryFn = () => <FieldForm />;

PenDismissal.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await submitAndFindAlert(canvasElement);
  await fireEvent(
    canvas.getByRole('button', {name: 'Dismiss'}),
    new PointerEvent('click', {
      bubbles: true,
      cancelable: true,
      pointerType: 'pen',
    })
  );

  await expect(canvas.queryByRole('alert')).not.toBeInTheDocument();
  await expect(canvas.getByRole('textbox', {name: 'Email'})).not.toHaveFocus();
};

export const ClickWithClickCountDismissal: StoryFn = () => <FieldForm />;

ClickWithClickCountDismissal.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await submitAndFindAlert(canvasElement);
  await fireEvent(
    canvas.getByRole('button', {name: 'Dismiss'}),
    new MouseEvent('click', {bubbles: true, cancelable: true, detail: 1})
  );

  await expect(canvas.queryByRole('alert')).not.toBeInTheDocument();
  await expect(canvas.getByRole('textbox', {name: 'Email'})).not.toHaveFocus();
};

export const ClickWithoutClickCountDismissal: StoryFn = () => <FieldForm />;

ClickWithoutClickCountDismissal.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await submitAndFindAlert(canvasElement);
  await fireEvent(
    focusDismissButton(canvasElement),
    new MouseEvent('click', {bubbles: true, cancelable: true, detail: 0})
  );

  await expect(canvas.queryByRole('alert')).not.toBeInTheDocument();
  await expect(canvas.getByRole('textbox', {name: 'Email'})).toHaveFocus();
};

export const UnfocusableFirstField: StoryFn = () => (
  <ErrorForm>
    <Input aria-label="Hidden" hidden={true} name="hidden" type="text" />
    <Input aria-label="Email" name="email" type="email" />
  </ErrorForm>
);

UnfocusableFirstField.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await submitAndFindAlert(canvasElement);
  focusDismissButton(canvasElement);
  await userEvent.keyboard('{Enter}');

  await expect(canvas.queryByRole('alert')).not.toBeInTheDocument();
  await expect(canvas.getByRole('textbox', {name: 'Email'})).toHaveFocus();
};

export const SubmitOnlyForm: StoryFn = () => <ErrorForm />;

SubmitOnlyForm.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await submitAndFindAlert(canvasElement);
  focusDismissButton(canvasElement);
  await userEvent.keyboard('{Enter}');

  await expect(canvas.queryByRole('alert')).not.toBeInTheDocument();
  await expect(canvas.getByRole('button', {name: 'Submit'})).toHaveFocus();
};

export const ReshowsIdenticalError: StoryFn = () => <ErrorForm />;

ReshowsIdenticalError.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await expect(await submitAndFindAlert(canvasElement)).toHaveTextContent(
    actionErrorMessage
  );

  await userEvent.click(canvas.getByRole('button', {name: 'Dismiss'}));
  await expect(canvas.queryByRole('alert')).not.toBeInTheDocument();

  await expect(await submitAndFindAlert(canvasElement)).toHaveTextContent(
    actionErrorMessage
  );
};

export const HiddenBesideVisible: StoryFn = () => (
  <ErrorForm>
    <FormError isHidden={true} />
  </ErrorForm>
);

HiddenBesideVisible.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);

  await submitAndFindAlert(canvasElement);

  await expect(canvas.getAllByRole('alert')).toHaveLength(1);
};

export const AlertStructure: StoryFn = () => <ErrorForm />;

AlertStructure.play = async ({canvasElement}: PlayContext) => {
  const canvas = within(canvasElement);
  const alert = await submitAndFindAlert(canvasElement);

  await expect(canvas.getAllByRole('alert')).toHaveLength(1);
  await expect(canvas.getByRole('button', {name: 'Dismiss'})).toBeVisible();
  // Icons are aria-hidden, so the lucide class is the only handle on them.
  await expect(alert.querySelector('svg.lucide')).toBeInTheDocument();
};
