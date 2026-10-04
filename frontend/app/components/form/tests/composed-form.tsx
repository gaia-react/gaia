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

// Sorted `as const` lists feed the schema; the display-order lists drive rendering.
const COLORS = ['blue', 'green', 'red'] as const;
const COUNTRIES = ['fr', 'jp', 'us'] as const;
const SIZES = ['lg', 'md', 'sm'] as const;

const COLORS_DISPLAY_ORDER: (typeof COLORS)[number][] = [
  'red',
  'green',
  'blue',
];
const SIZES_DISPLAY_ORDER: (typeof SIZES)[number][] = ['sm', 'md', 'lg'];

const REQUIRED_MESSAGE = 'required';

// Strings used only by this fixture, kept here so they do not ship in the
// adopter `common` namespace.
const FIXTURE_TEXT = {
  bio: 'Bio',
  colorOptions: {blue: 'Blue', green: 'Green', red: 'Red'},
  colors: 'Favorite colors',
  country: 'Country',
  countryOptions: {
    fr: 'France',
    jp: 'Japan',
    none: 'Select a country',
    us: 'United States',
  },
  passwordDescription: 'Use at least 8 characters',
  passwordError: 'Password must be at least 8 characters',
  size: 'Size',
  sizeOptions: {lg: 'Large', md: 'Medium', sm: 'Small'},
  terms: 'I accept the terms',
} as const;

export const composedFormSchema = z.object({
  bio: z.string().optional(),
  colors: z
    .array(z.literal(COLORS), {error: REQUIRED_MESSAGE})
    .min(1, REQUIRED_MESSAGE),
  country: z.literal(COUNTRIES).optional(),
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
  const {t} = useTranslation(['common', 'errors']);
  const actionData = useActionData<{result: SubmissionResult}>();
  const navigation = useNavigation();
  const isSubmitting = navigation.state === 'submitting';

  const [form, fields] = useForm({
    constraint: getZodConstraint(composedFormSchema),
    lastResult: actionData?.result,
    onValidate: ({formData}) =>
      parseWithZod(formData, {schema: composedFormSchema}),
    shouldRevalidate: 'onInput',
    shouldValidate: 'onBlur',
  });

  const errorMessages: Record<string, string> = {
    email: t('errors:invalidEmail'),
    password: FIXTURE_TEXT.passwordError,
    required: t('form.required'),
  };
  const colorLabels: Record<string, string> = FIXTURE_TEXT.colorOptions;
  const countryLabels: Record<string, string> = FIXTURE_TEXT.countryOptions;
  const sizeLabels: Record<string, string> = FIXTURE_TEXT.sizeOptions;

  const mapToFieldErrors = (messages?: string[]) =>
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
          errors={mapToFieldErrors(fields.name.errors)}
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
          errors={mapToFieldErrors(fields.email.errors)}
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
          {FIXTURE_TEXT.passwordDescription}
        </FieldDescription>
        <FieldError
          errors={mapToFieldErrors(fields.password.errors)}
          id={fields.password.errorId}
        />
      </Field>

      <Field data-invalid={fields.bio.errors ? true : undefined}>
        <FieldLabel htmlFor={fields.bio.id}>{FIXTURE_TEXT.bio}</FieldLabel>
        <Textarea {...getTextareaProps(fields.bio)} disabled={disabled} />
        <FieldError
          errors={mapToFieldErrors(fields.bio.errors)}
          id={fields.bio.errorId}
        />
      </Field>

      <Field data-invalid={fields.country.errors ? true : undefined}>
        <FieldLabel htmlFor={fields.country.id}>
          {FIXTURE_TEXT.country}
        </FieldLabel>
        <NativeSelect {...getSelectProps(fields.country)} disabled={disabled}>
          <NativeSelectOption value="">
            {FIXTURE_TEXT.countryOptions.none}
          </NativeSelectOption>
          {COUNTRIES.map((country) => (
            <NativeSelectOption key={country} value={country}>
              {countryLabels[country]}
            </NativeSelectOption>
          ))}
        </NativeSelect>
        <FieldError
          errors={mapToFieldErrors(fields.country.errors)}
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
        <FieldLabel htmlFor={fields.terms.id}>{FIXTURE_TEXT.terms}</FieldLabel>
        <FieldError
          errors={mapToFieldErrors(fields.terms.errors)}
          id={fields.terms.errorId}
        />
      </Field>

      <FieldSet disabled={disabled}>
        <FieldLegend variant="label">{FIXTURE_TEXT.colors}</FieldLegend>
        {getCollectionProps(fields.colors, {
          options: COLORS_DISPLAY_ORDER,
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
          errors={mapToFieldErrors(fields.colors.errors)}
          id={fields.colors.errorId}
        />
      </FieldSet>

      <Field data-invalid={fields.size.errors ? true : undefined}>
        <FieldSet disabled={disabled}>
          <FieldLegend id={`${fields.size.id}-legend`} variant="label">
            {FIXTURE_TEXT.size}
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
            {SIZES_DISPLAY_ORDER.map((size) => (
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
            errors={mapToFieldErrors(fields.size.errors)}
            id={fields.size.errorId}
          />
        </FieldSet>
      </Field>

      <Button disabled={disabled || isSubmitting} type="submit">
        {isSubmitting && <Spinner aria-hidden={true} />}
        {isSubmitting ? t('form.submitting') : t('form.submit')}
      </Button>
    </Form>
  );
};
