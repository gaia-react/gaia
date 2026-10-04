import {Form} from 'react-router';
import {getFormProps, useForm, useInputControl} from '@conform-to/react';
import {parseWithZod} from '@conform-to/zod/v4';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {z} from 'zod';
import stubs from 'test/stubs';
import YearMonthDay from '..';

const meta: Meta = {
  component: YearMonthDay,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/YearMonthDay',
};

export default meta;

const schema = z.object({dob: z.iso.date()});

export const Default: StoryFn = () => {
  const [form, fields] = useForm({
    defaultValue: {dob: '2000-01-01'},
    onValidate: ({formData}) => parseWithZod(formData, {schema}),
  });

  const dobControl = useInputControl(fields.dob);

  return (
    <Form className="max-w-md p-4" {...getFormProps(form)}>
      <YearMonthDay
        name={fields.dob.name}
        onBlur={dobControl.blur}
        onChange={dobControl.change}
        value={dobControl.value ?? ''}
      />
    </Form>
  );
};
