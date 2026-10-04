import type {ComponentProps} from 'react';
import {Form} from 'react-router';
import {getFormProps, useForm, useInputControl} from '@conform-to/react';
import {parseWithZod} from '@conform-to/zod/v4';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {z} from 'zod';
import stubs from 'test/stubs';
import {FieldError} from '~/components/ui/field';
import YearMonthDay from '..';

const meta: Meta = {
  component: YearMonthDay,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Components/Form/YearMonthDay',
};

export default meta;

const schema = z.object({dob: z.iso.date()});

type ExampleProps = Partial<ComponentProps<typeof YearMonthDay>> & {
  errorText?: string;
};

const Example = ({errorText, ...props}: ExampleProps) => {
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
        {...props}
      />
      {errorText && <FieldError id="dob-error">{errorText}</FieldError>}
    </Form>
  );
};

export const Default: StoryFn = () => <Example />;

export const WithLabel: StoryFn = () => <Example label="Date of birth" />;

export const Required: StoryFn = () => (
  <Example label="Date of birth" required={true} />
);

export const Invalid: StoryFn = () => (
  <Example
    aria-describedby="dob-error"
    aria-invalid={true}
    errorText="Enter a valid date of birth"
    label="Date of birth"
    required={true}
  />
);
