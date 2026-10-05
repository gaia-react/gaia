import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn, StoryObj} from '@storybook/react-vite';
import {expect, userEvent, within} from 'storybook/test';
import {Checkbox} from '~/components/ui/checkbox';
import {Field, FieldLabel} from '~/components/ui/field';
import {Label} from '~/components/ui/label';

const meta: Meta = {
  component: Checkbox,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/Checkbox',
};

export default meta;

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex gap-4">
      <Checkbox aria-label={t('form.ok')} />
      <Checkbox aria-label={t('form.ok')} defaultChecked={true} />
    </div>
  );
};

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex gap-4">
      <Checkbox aria-invalid={true} aria-label={t('form.ok')} />
      <Checkbox
        aria-invalid={true}
        aria-label={t('form.ok')}
        defaultChecked={true}
      />
    </div>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex gap-4">
      <Checkbox aria-label={t('form.ok')} disabled={true} />
      <Checkbox
        aria-label={t('form.ok')}
        defaultChecked={true}
        disabled={true}
      />
    </div>
  );
};

export const KeyboardToggle: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    const checkbox = within(canvasElement).getByRole('checkbox', {
      name: 'Accept',
    });

    await userEvent.tab();
    await expect(checkbox).toHaveFocus();
    await expect(checkbox).not.toBeChecked();

    await userEvent.keyboard(' ');

    await expect(checkbox).toBeChecked();
    await expect(checkbox).toHaveFocus();
  },
  render: () => (
    <div className="flex gap-2">
      <Checkbox id="acceptKeyboard" />
      <Label htmlFor="acceptKeyboard">Accept</Label>
    </div>
  ),
};

export const WithLabel: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    await expect(
      within(canvasElement).getByRole('checkbox', {name: 'Accept'})
    ).toHaveAccessibleName('Accept');
  },
  render: () => (
    <div className="flex gap-2">
      <Checkbox id="acceptPlain" />
      <Label htmlFor="acceptPlain">Accept</Label>
    </div>
  ),
};

export const WithFieldLabel: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    await expect(
      within(canvasElement).getByRole('checkbox', {name: 'Accept'})
    ).toHaveAccessibleName('Accept');
  },
  render: () => (
    <Field orientation="horizontal">
      <Checkbox id="accept" />
      <FieldLabel htmlFor="accept">Accept</FieldLabel>
    </Field>
  ),
};

export const WithClassName: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    await expect(
      within(canvasElement).getByRole('checkbox', {name: 'Accept'})
    ).toHaveClass('mt-2');
  },
  render: () => <Checkbox aria-label="Accept" className="mt-2" />,
};
