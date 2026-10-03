import {useTranslation} from 'react-i18next';
import {Form} from 'react-router';
import {getFormProps, getInputProps, useForm} from '@conform-to/react';
import {parseWithZod} from '@conform-to/zod/v4';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {z} from 'zod';
import stubs from 'test/stubs';
import Button from '~/components/Button';
import FormActions from '~/components/Form/FormActions';
import InputPassword from '..';

const meta: Meta = {
  component: InputPassword,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/Input/Password',
};

export default meta;

const schema = z.object({password: z.string().min(6)});

export const Default: StoryFn = () => {
  const {t} = useTranslation('errors');

  const [form, fields] = useForm({
    defaultValue: {password: ''},
    onValidate: ({formData}) => parseWithZod(formData, {schema}),
  });

  return (
    <Form className="max-w-md space-y-4 p-4" {...getFormProps(form)}>
      <InputPassword
        error={
          fields.password.errors?.length ? t('invalidPassword') : undefined
        }
        {...getInputProps(fields.password, {type: 'password'})}
      />
      <FormActions>
        <Button type="submit">{t('form.submit', {ns: 'common'})}</Button>
      </FormActions>
    </Form>
  );
};
