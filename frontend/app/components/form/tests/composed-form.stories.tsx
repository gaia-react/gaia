import type {ComponentProps} from 'react';
import {parseWithZod} from '@conform-to/zod/v4';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {expect, fn, userEvent, waitFor, within} from 'storybook/test';
import stubs from 'test/stubs';
import {ComposedForm, composedFormSchema} from './composed-form';

type PostedEntries = [string, string][];

type StoryArgs = ComponentProps<typeof ComposedForm> & {
  holdAction?: () => Promise<void>;
  isActionHeld?: boolean;
  onSubmit: (entries: PostedEntries) => void;
};

// The form posts to its own route, so the story observes the submission through
// the route's own action rather than a separate path.
const meta: Meta<StoryArgs> = {
  args: {onSubmit: fn()},
  component: ComposedForm,
  decorators: [
    stubs.reactRouter(({args}) => {
      const {holdAction, isActionHeld, onSubmit} = args as StoryArgs;

      return {
        action: async ({request}) => {
          const formData = await request.formData();

          onSubmit(
            [...formData.entries()].map(([key, value]) => [key, String(value)])
          );

          // A held action never settles, so the pending state stays put for
          // the accessibility scan instead of racing the re-enable transition.
          if (isActionHeld) {
            await new Promise(() => {});
          }

          // A releasable hold keeps the pending state observable until the
          // play lets the action settle.
          await holdAction?.();

          return {
            result: parseWithZod(formData, {
              schema: composedFormSchema,
            }).reply(),
          };
        },
      };
    }),
  ],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Components/Form/ComposedForm',
};

export default meta;

export const Default: StoryFn<StoryArgs> = () => <ComposedForm />;

export const Invalid: StoryFn<StoryArgs> = () => <ComposedForm />;

Invalid.play = async ({canvasElement}) => {
  const canvas = within(canvasElement);

  await userEvent.click(await canvas.findByRole('button', {name: 'Submit'}));

  await expect(await canvas.findByLabelText('Name')).toHaveAttribute(
    'aria-invalid',
    'true'
  );
};

export const Disabled: StoryFn<StoryArgs> = () => (
  <ComposedForm disabled={true} />
);

const submitEmptyForm = async (canvasElement: HTMLElement) => {
  const canvas = within(canvasElement);

  await userEvent.click(canvas.getByRole('button', {name: 'Submit'}));

  return canvas;
};

const getColorCheckboxes = (canvasElement: HTMLElement): HTMLElement[] =>
  within(canvasElement).getAllByRole('checkbox', {name: /Blue|Green|Red/});

export const EmptySubmitInvalidControls: StoryFn<StoryArgs> = () => (
  <ComposedForm />
);

EmptySubmitInvalidControls.play = async ({canvasElement}) => {
  const canvas = await submitEmptyForm(canvasElement);
  const invalidControls = [
    canvas.getByRole('textbox', {name: 'Name'}),
    ...getColorCheckboxes(canvasElement),
    canvas.getByRole('radiogroup', {name: 'Size'}),
  ];

  for (const control of invalidControls) {
    await waitFor(async () => {
      await expect(control).toHaveAttribute('aria-invalid', 'true');
    });

    const describedBy = (control.getAttribute('aria-describedby') ?? '').split(
      ' '
    );
    const alertIds = canvas.getAllByRole('alert').map((alert) => alert.id);

    await expect(describedBy.some((id) => alertIds.includes(id))).toBe(true);

    const fieldGroups = canvas
      .getAllByRole('group')
      .filter(
        (group) => group.dataset.slot === 'field' && group.contains(control)
      );

    await expect(fieldGroups).not.toHaveLength(0);

    for (const group of fieldGroups) {
      await expect(group).toHaveAttribute('data-invalid', 'true');
    }
  }
};

export const EmptySubmitRequiredFlags: StoryFn<StoryArgs> = () => (
  <ComposedForm />
);

EmptySubmitRequiredFlags.play = async ({canvasElement}) => {
  const canvas = await submitEmptyForm(canvasElement);

  await expect(canvas.getByRole('textbox', {name: 'Name'})).toBeRequired();
  await expect(canvas.getByRole('radiogroup', {name: 'Size'})).toBeRequired();

  for (const checkbox of getColorCheckboxes(canvasElement)) {
    await expect(checkbox).not.toBeRequired();
  }
};

export const EmptySubmitGroupNames: StoryFn<StoryArgs> = () => <ComposedForm />;

EmptySubmitGroupNames.play = async ({canvasElement}) => {
  const canvas = await submitEmptyForm(canvasElement);

  await expect(
    canvas.getByRole('group', {name: 'Favorite colors'})
  ).toBeVisible();
  await expect(canvas.getByRole('radiogroup', {name: 'Size'})).toBeVisible();
};

export const EmptySubmitFocus: StoryFn<StoryArgs> = () => <ComposedForm />;

EmptySubmitFocus.play = async ({canvasElement}) => {
  const canvas = await submitEmptyForm(canvasElement);

  await waitFor(async () => {
    await expect(canvas.getByRole('textbox', {name: 'Name'})).toHaveFocus();
  });
};

export const LabelToggles: StoryFn<StoryArgs> = () => <ComposedForm />;

LabelToggles.play = async ({canvasElement}) => {
  const canvas = within(canvasElement);

  for (const name of ['Blue', 'Green', 'Red']) {
    const checkbox = canvas.getByRole('checkbox', {name});

    await expect(checkbox).not.toBeChecked();
    await userEvent.click(canvas.getByText(name));
    await expect(checkbox).toBeChecked();
  }

  for (const name of ['Large', 'Medium', 'Small']) {
    await userEvent.click(canvas.getByText(name));
    await expect(canvas.getByRole('radio', {name})).toBeChecked();
  }
};

export const SpaceTogglesCheckbox: StoryFn<StoryArgs> = () => <ComposedForm />;

SpaceTogglesCheckbox.play = async ({canvasElement}) => {
  const canvas = within(canvasElement);
  const red = canvas.getByRole('checkbox', {name: 'Red'});
  const green = canvas.getByRole('checkbox', {name: 'Green'});

  red.focus();
  await userEvent.keyboard(' ');
  await expect(red).toBeChecked();

  await userEvent.tab();
  await expect(green).toHaveFocus();
  await userEvent.keyboard(' ');
  await expect(green).toBeChecked();
};

export const ArrowKeysMoveRadioGroup: StoryFn<StoryArgs> = () => (
  <ComposedForm />
);

ArrowKeysMoveRadioGroup.play = async ({canvasElement}) => {
  const canvas = within(canvasElement);

  await userEvent.click(canvas.getByRole('radio', {name: 'Small'}));
  await expect(canvas.getByRole('radio', {name: 'Small'})).toHaveFocus();

  await userEvent.keyboard('{ArrowDown}');
  await expect(canvas.getByRole('radio', {name: 'Medium'})).toBeChecked();
  await expect(canvas.getByRole('radio', {name: 'Medium'})).toHaveFocus();

  await userEvent.tab();
  await expect(canvas.getByRole('radio', {name: 'Medium'})).not.toHaveFocus();
  await expect(canvas.getByRole('button', {name: 'Submit'})).toHaveFocus();
};

// The submit button animates its opacity when its disabled state flips, and a
// scan taken mid-animation reads blended colors, so the play waits for the
// settled value.
const waitForSettledOpacity = async (button: HTMLElement, opacity: string) => {
  await waitFor(async () => {
    await expect(getComputedStyle(button).opacity).toBe(opacity);
  });
};

let releaseAction: (() => void) | undefined;

export const FilledSubmit: StoryFn<StoryArgs> = () => <ComposedForm />;

FilledSubmit.args = {
  holdAction: async () =>
    new Promise<void>((resolve) => {
      releaseAction = resolve;
    }),
};

FilledSubmit.play = async ({args, canvasElement}) => {
  const canvas = within(canvasElement);

  await userEvent.type(canvas.getByRole('textbox', {name: 'Name'}), 'Ada');
  await userEvent.type(
    canvas.getByRole('textbox', {name: 'Email'}),
    'ada@example.com'
  );
  await userEvent.type(canvas.getByLabelText('Password'), 'Secret123!');
  await userEvent.type(canvas.getByRole('textbox', {name: 'Bio'}), 'Hello');
  await userEvent.selectOptions(
    canvas.getByRole('combobox', {name: 'Country'}),
    'jp'
  );
  await userEvent.click(canvas.getByText('I accept the terms'));
  await userEvent.click(canvas.getByText('Blue'));
  await userEvent.click(canvas.getByText('Red'));
  await userEvent.click(canvas.getByText('Medium'));
  await userEvent.click(canvas.getByRole('button', {name: 'Submit'}));

  await waitFor(async () => {
    await expect(args.onSubmit).toHaveBeenCalledWith([
      ['name', 'Ada'],
      ['email', 'ada@example.com'],
      ['password', 'Secret123!'],
      ['bio', 'Hello'],
      ['country', 'jp'],
      ['terms', 'on'],
      ['colors', 'red'],
      ['colors', 'blue'],
      ['size', 'md'],
    ]);
  });

  // The action is held, so the pending render is observable before the action
  // settles; release it only after that render committed, then wait for the
  // button to settle back to Submit.
  await canvas.findByRole('button', {name: /Please wait/});
  releaseAction?.();
  await waitForSettledOpacity(
    await canvas.findByRole('button', {name: 'Submit'}),
    '1'
  );
};

export const SubmittingState: StoryFn<StoryArgs> = () => <ComposedForm />;

SubmittingState.args = {isActionHeld: true};

SubmittingState.play = async ({canvasElement}) => {
  const canvas = within(canvasElement);

  await userEvent.type(canvas.getByRole('textbox', {name: 'Name'}), 'Ada');
  await userEvent.click(canvas.getByText('Blue'));
  await userEvent.click(canvas.getByText('Medium'));
  await userEvent.click(canvas.getByRole('button', {name: 'Submit'}));

  const button = await canvas.findByRole('button', {name: /Please wait/});

  await expect(button).toBeDisabled();
  await waitForSettledOpacity(button, '0.5');
  await expect(canvas.getByRole('status', {hidden: true})).toHaveAttribute(
    'aria-hidden',
    'true'
  );
};
