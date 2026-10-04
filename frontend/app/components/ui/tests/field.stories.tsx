import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {Checkbox} from '~/components/ui/checkbox';
import {
  Field,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from '~/components/ui/field';
import {Input} from '~/components/ui/input';

const meta: Meta = {
  component: Field,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-md p-4',
  },
  title: 'Components/Ui/Field',
};

export default meta;

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <FieldSet>
      <FieldLegend>{t('form.dateOfBirth')}</FieldLegend>
      <FieldGroup>
        <Field>
          <FieldLabel htmlFor="field-story-email">{t('email')}</FieldLabel>
          <Input id="field-story-email" placeholder={t('emailPlaceholder')} />
          <FieldDescription>{t('form.allFieldsAreRequired')}</FieldDescription>
        </Field>
      </FieldGroup>
    </FieldSet>
  );
};

export const Horizontal: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Field orientation="horizontal">
      <Checkbox id="field-story-horizontal" />
      <FieldLabel htmlFor="field-story-horizontal">{t('form.ok')}</FieldLabel>
    </Field>
  );
};

export const Responsive: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Field orientation="responsive">
      <FieldLabel htmlFor="field-story-responsive">{t('name')}</FieldLabel>
      <Input id="field-story-responsive" />
    </Field>
  );
};

export const WithError: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Field data-invalid={true}>
      <FieldLabel htmlFor="field-story-error">{t('email')}</FieldLabel>
      <Input
        aria-describedby="field-story-error-message"
        aria-invalid={true}
        id="field-story-error"
      />
      <FieldError id="field-story-error-message">
        {t('form.required')}
      </FieldError>
    </Field>
  );
};
