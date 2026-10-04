import {useTranslation} from 'react-i18next';
import {Form, useActionData, useNavigation} from 'react-router';
import type {SubmissionResult} from '@conform-to/react';
import {
  getCollectionProps,
  getFormProps,
  getInputProps,
  getSelectProps,
  getTextareaProps,
  useForm,
  useInputControl,
} from '@conform-to/react';
import {getZodConstraint, parseWithZod} from '@conform-to/zod/v4';
import {z} from 'zod';
import {Button} from '~/components/ui/button';
import {Checkbox} from '~/components/ui/checkbox';
import {
  Field,
  FieldDescription,
  FieldError,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from '~/components/ui/field';
import {Input} from '~/components/ui/input';
import {NativeSelect, NativeSelectOption} from '~/components/ui/native-select';
import {RadioGroup, RadioGroupItem} from '~/components/ui/radio-group';
import {Spinner} from '~/components/ui/spinner';
import {Textarea} from '~/components/ui/textarea';
import YearMonthDay from '../year-month-day';

const COLORS = ['red', 'green', 'blue'];
const COUNTRIES = ['fr', 'jp', 'us'];
const SIZES = ['sm', 'md', 'lg'];

const REQUIRED_MESSAGE = 'required';

export const composedFormSchema = z.object({
  bio: z.string().optional(),
  colors: z
    .array(z.literal(COLORS), {error: REQUIRED_MESSAGE})
    .min(1, REQUIRED_MESSAGE),
  country: z.literal(COUNTRIES).optional(),
  dob: z.iso.date(),
  email: z.email({error: 'email'}).optional(),
  name: z.string({error: REQUIRED_MESSAGE}).min(1, REQUIRED_MESSAGE),
  password: z.string().min(8, 'password').optional(),
  size: z.literal(SIZES, {error: REQUIRED_MESSAGE}),
  terms: z.boolean().optional(),
});

// Conform's `type` is an input attribute the Base UI checkbox root does not take.
const omitType = <Props extends {type?: unknown}>({
  type: _type,
  ...props
}: Props) => props;

type ComposedFormProps = {
  disabled?: boolean;
};

export const ComposedForm = ({disabled = false}: ComposedFormProps) => {
  const {t} = useTranslation('common');
  const actionData = useActionData<{result: SubmissionResult}>();
  const navigation = useNavigation();
  const isSubmitting = navigation.state === 'submitting';

  const [form, fields] = useForm({
    constraint: getZodConstraint(composedFormSchema),
    defaultValue: {dob: '2000-01-01'},
    lastResult: actionData?.result,
    onValidate: ({formData}) =>
      parseWithZod(formData, {schema: composedFormSchema}),
    shouldRevalidate: 'onInput',
    shouldValidate: 'onBlur',
  });

  const dobControl = useInputControl(fields.dob);

  const errorMessages: Record<string, string> = {
    email: t('composedForm.errors.email'),
    password: t('composedForm.errors.password'),
    required: t('composedForm.errors.required'),
  };
  const colorLabels: Record<string, string> = {
    blue: t('composedForm.colorOptions.blue'),
    green: t('composedForm.colorOptions.green'),
    red: t('composedForm.colorOptions.red'),
  };
  const countryLabels: Record<string, string> = {
    fr: t('composedForm.countryOptions.fr'),
    jp: t('composedForm.countryOptions.jp'),
    us: t('composedForm.countryOptions.us'),
  };
  const sizeLabels: Record<string, string> = {
    lg: t('composedForm.sizeOptions.lg'),
    md: t('composedForm.sizeOptions.md'),
    sm: t('composedForm.sizeOptions.sm'),
  };

  const toErrors = (messages?: string[]) =>
    messages?.map((message) => ({message: errorMessages[message]}));

  return (
    <Form
      className="flex max-w-md flex-col gap-6 p-4"
      method="post"
      {...getFormProps(form)}
    >
      <Field data-invalid={fields.name.errors ? true : undefined}>
        <FieldLabel htmlFor={fields.name.id}>{t('name')}</FieldLabel>
        <Input
          {...getInputProps(fields.name, {type: 'text'})}
          disabled={disabled}
        />
        <FieldError
          errors={toErrors(fields.name.errors)}
          id={fields.name.errorId}
        />
      </Field>

      <Field data-invalid={fields.email.errors ? true : undefined}>
        <FieldLabel htmlFor={fields.email.id}>{t('email')}</FieldLabel>
        <Input
          {...getInputProps(fields.email, {type: 'email'})}
          disabled={disabled}
          placeholder={t('emailPlaceholder')}
        />
        <FieldError
          errors={toErrors(fields.email.errors)}
          id={fields.email.errorId}
        />
      </Field>

      <Field data-invalid={fields.password.errors ? true : undefined}>
        <FieldLabel htmlFor={fields.password.id}>{t('password')}</FieldLabel>
        <Input
          {...getInputProps(fields.password, {
            ariaDescribedBy: fields.password.descriptionId,
            type: 'password',
          })}
          disabled={disabled}
        />
        <FieldDescription id={fields.password.descriptionId}>
          {t('composedForm.passwordDescription')}
        </FieldDescription>
        <FieldError
          errors={toErrors(fields.password.errors)}
          id={fields.password.errorId}
        />
      </Field>

      <Field data-invalid={fields.bio.errors ? true : undefined}>
        <FieldLabel htmlFor={fields.bio.id}>{t('composedForm.bio')}</FieldLabel>
        <Textarea {...getTextareaProps(fields.bio)} disabled={disabled} />
        <FieldError
          errors={toErrors(fields.bio.errors)}
          id={fields.bio.errorId}
        />
      </Field>

      <Field data-invalid={fields.country.errors ? true : undefined}>
        <FieldLabel htmlFor={fields.country.id}>
          {t('composedForm.country')}
        </FieldLabel>
        <NativeSelect {...getSelectProps(fields.country)} disabled={disabled}>
          <NativeSelectOption value="">
            {t('composedForm.countryOptions.none')}
          </NativeSelectOption>
          {COUNTRIES.map((country) => (
            <NativeSelectOption key={country} value={country}>
              {countryLabels[country]}
            </NativeSelectOption>
          ))}
        </NativeSelect>
        <FieldError
          errors={toErrors(fields.country.errors)}
          id={fields.country.errorId}
        />
      </Field>

      <Field
        data-invalid={fields.terms.errors ? true : undefined}
        orientation="horizontal"
      >
        <Checkbox
          {...omitType(getInputProps(fields.terms, {type: 'checkbox'}))}
          disabled={disabled}
        />
        <FieldLabel htmlFor={fields.terms.id}>
          {t('composedForm.terms')}
        </FieldLabel>
        <FieldError
          errors={toErrors(fields.terms.errors)}
          id={fields.terms.errorId}
        />
      </Field>

      <FieldSet disabled={disabled}>
        <FieldLegend variant="label">{t('composedForm.colors')}</FieldLegend>
        {getCollectionProps(fields.colors, {
          options: COLORS,
          type: 'checkbox',
        }).map(({key, type: collectionType, ...checkboxProps}) => (
          <Field
            key={key}
            data-invalid={fields.colors.errors ? true : undefined}
            orientation="horizontal"
          >
            <Checkbox {...checkboxProps} disabled={disabled} />
            <FieldLabel htmlFor={checkboxProps.id}>
              {colorLabels[checkboxProps.value]}
            </FieldLabel>
          </Field>
        ))}
        <FieldError
          errors={toErrors(fields.colors.errors)}
          id={fields.colors.errorId}
        />
      </FieldSet>

      <Field data-invalid={fields.size.errors ? true : undefined}>
        <FieldSet disabled={disabled}>
          <FieldLegend id={`${fields.size.id}-legend`} variant="label">
            {t('composedForm.size')}
          </FieldLegend>
          <RadioGroup
            aria-describedby={
              fields.size.errors ? fields.size.errorId : undefined
            }
            aria-invalid={fields.size.errors ? true : undefined}
            aria-labelledby={`${fields.size.id}-legend`}
            defaultValue={fields.size.initialValue}
            disabled={disabled}
            id={fields.size.id}
            name={fields.size.name}
            required={true}
          >
            {SIZES.map((size) => (
              <Field
                key={size}
                data-invalid={fields.size.errors ? true : undefined}
                orientation="horizontal"
              >
                <RadioGroupItem id={`${fields.size.id}-${size}`} value={size} />
                <FieldLabel htmlFor={`${fields.size.id}-${size}`}>
                  {sizeLabels[size]}
                </FieldLabel>
              </Field>
            ))}
          </RadioGroup>
          <FieldError
            errors={toErrors(fields.size.errors)}
            id={fields.size.errorId}
          />
        </FieldSet>
      </Field>

      <FieldSet disabled={disabled}>
        <FieldLegend variant="label">{t('form.dateOfBirth')}</FieldLegend>
        <YearMonthDay
          aria-describedby={fields.dob.errors ? fields.dob.errorId : undefined}
          aria-invalid={fields.dob.errors ? true : undefined}
          id={fields.dob.id}
          name={fields.dob.name}
          onBlur={dobControl.blur}
          onChange={dobControl.change}
          required={true}
          value={dobControl.value ?? ''}
        />
        <FieldError
          errors={toErrors(fields.dob.errors)}
          id={fields.dob.errorId}
        />
      </FieldSet>

      <Button disabled={disabled || isSubmitting} type="submit">
        {isSubmitting && <Spinner aria-label={t('form.submitting')} />}
        {t('form.submit')}
      </Button>
    </Form>
  );
};
