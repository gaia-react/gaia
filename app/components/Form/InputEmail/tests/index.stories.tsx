import {useTranslation} from 'react-i18next';
import {getFormProps, getInputProps, useForm} from '@conform-to/react';
import {parseWithZod} from '@conform-to/zod/v4';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {z} from 'zod';
import stubs from 'test/stubs';
import Button from '~/components/Button';
import FormActions from '~/components/Form/FormActions';
import InputEmail from '..';

const meta: Meta = {
  component: InputEmail,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/Input/Email',
};

export default meta;

const schema = z.object({email: z.email()});

export const Default: StoryFn = () => {
  const {t} = useTranslation('errors');

  const [form, fields] = useForm({
    defaultValue: {email: ''},
    onValidate: ({formData}) => parseWithZod(formData, {schema}),
  });

  return (
    <form className="max-w-md space-y-4 p-4" {...getFormProps(form)}>
      <InputEmail
        error={fields.email.errors?.length ? t('invalidEmail') : undefined}
        {...getInputProps(fields.email, {type: 'email'})}
      />
      <FormActions>
        <Button type="submit">{t('form.submit', {ns: 'common'})}</Button>
      </FormActions>
    </form>
  );
};
