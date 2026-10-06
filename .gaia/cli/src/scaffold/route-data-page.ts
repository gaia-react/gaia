/**
 * Template variables for a data route's page: the data read, the list or the
 * detail markup, and, with an action, the Conform form with one input per
 * service field.
 */
import type {DataRouteContext} from './route-data.js';
import {
  block,
  fieldLabel,
  fitOnLine,
  indent,
  isList,
  linkLabelField,
  metaElement,
  serviceImportPath,
  sortNames,
} from './route-data.js';
import type {ServiceField} from './route-service.js';
import type {TemplateVars} from './template.js';

const closingTag = (open: string): string =>
  `</${/^<([\w.]+)/u.exec(open)?.[1] ?? ''}>`;

/** An element on one line when it fits, else its child on a line of its own. */
const element = (depth: number, open: string, child: string): string => {
  const pad = indent(depth);
  const close = closingTag(open);

  return fitOnLine(`${pad}${open}${child}${close}`, [
    `${pad}${open}`,
    `${pad}  ${child}`,
    `${pad}${close}`,
  ]);
};

type TextHelpers = {
  /** A JSX attribute value: `{t('key')}` or `"literal"`. */
  attribute: (key: string, literal: string) => string;
  /** A JSX child: `{t('key')}` or the literal text. */
  child: (key: string, literal: string) => string;
};

const textHelpers = (i18n: boolean): TextHelpers => ({
  attribute: (key, literal) => (i18n ? `{t('${key}')}` : `"${literal}"`),
  child: (key, literal) => (i18n ? `{t('${key}')}` : literal),
});

const formFieldMarkup = (field: ServiceField, text: TextHelpers): string => {
  const meta = `fields.${field.name}`;
  const label = element(
    12,
    `<FieldLabel htmlFor={${meta}.id}>`,
    text.child(meta, fieldLabel(field))
  );
  const errors = block(
    '            <FieldError',
    `              errors={${meta}.errors?.map((message) => ({message}))}`,
    `              id={${meta}.errorId}`,
    '            />'
  );
  const close = block('          </Field>');

  if (field.kind === 'boolean') {
    const checkbox = block(
      '          <Field',
      `            data-invalid={${meta}.errors ? true : undefined}`,
      '            orientation="horizontal"',
      '          >',
      '            <Checkbox',
      `              {...omitType(getInputProps(${meta}, {type: 'checkbox'}))}`,
      '            />'
    );

    return `${checkbox}${label}${errors}${close}`;
  }

  const inputType = field.kind === 'number' ? 'number' : 'text';
  const open = block(
    `          <Field data-invalid={${meta}.errors ? true : undefined}>`
  );
  const input = block(
    `            <Input {...getInputProps(${meta}, {type: '${inputType}'})} />`
  );

  return `${open}${label}${input}${errors}${close}`;
};

const formMarkup = (context: DataRouteContext, text: TextHelpers): string => {
  if (!context.flags.action) return '';

  const open = block(
    '        <Form',
    '          className="flex max-w-md flex-col gap-4"',
    '          method="post"',
    '          {...getFormProps(form)}',
    '        >'
  );
  const fields = context.binding.inputFields
    .map((field) => formFieldMarkup(field, text))
    .join('');
  const close = block(
    `          <Button type="submit">${text.child('save', 'Save')}</Button>`,
    '        </Form>'
  );

  return `${open}${fields}${close}`;
};

/** The loop variable for list items; the singular unless it collides with the plural. */
const itemVariable = (context: DataRouteContext): string => {
  const {plural, singular} = context.binding.derived;

  return singular === plural ? 'entry' : singular;
};

const listMarkup = (context: DataRouteContext): string => {
  const item = itemVariable(context);
  const {plural} = context.binding.derived;
  const label = linkLabelField(context).name;
  const href = `{\`/${context.slug}/\${${item}.id}\`}`;

  return block(
    '        <ul className="flex flex-col gap-2">',
    `          {${plural}.map((${item}) => (`,
    `            <li key={${item}.id}>`,
    `              <Link className="underline" to=${href}>`,
    `                {${item}.${label}}`,
    '              </Link>',
    '            </li>',
    '          ))}',
    '        </ul>'
  );
};

const detailValue = (item: string, field: ServiceField): string => {
  const value = `${item}.${field.name}`;

  if (field.kind !== 'boolean') return `{${value}}`;

  return field.nullish ? `{String(${value} ?? false)}` : `{String(${value})}`;
};

const detailMarkup = (context: DataRouteContext, text: TextHelpers): string => {
  const item = context.binding.derived.singular;
  const rows = context.binding.inputFields.map(
    (field) =>
      element(
        10,
        '<dt className="font-semibold">',
        text.child(`fields.${field.name}`, fieldLabel(field))
      ) + element(10, '<dd>', detailValue(item, field))
  );

  return `${block('        <dl className="flex flex-col gap-1">')}${rows.join('')}${block('        </dl>')}`;
};

const formImportLines = (
  context: DataRouteContext,
  hasBoolean: boolean
): string[] => {
  const {derived, inputFields} = context.binding;
  const hasInput = inputFields.some((field) => field.kind !== 'boolean');

  return [
    "import {Button} from '~/components/ui/button';",
    ...(hasBoolean ?
      ["import {Checkbox} from '~/components/ui/checkbox';"]
    : []),
    "import {Field, FieldError, FieldLabel} from '~/components/ui/field';",
    ...(hasInput ? ["import {Input} from '~/components/ui/input';"] : []),
    `import {${derived.singular}InputSchema} from '${serviceImportPath(context)}';`,
  ];
};

const pageImportLines = (
  context: DataRouteContext,
  hasBoolean: boolean
): string => {
  const {action, data, i18n} = context.flags;
  const list = isList(context);
  const isQuery = data === 'query';
  const routerNames = [
    ...(list ? ['Link'] : []),
    ...(isQuery ? [] : ['useLoaderData']),
    ...(isQuery && !list ? ['useParams'] : []),
    ...(action ? ['Form', 'useActionData'] : []),
  ];

  return [
    ...(i18n ? ["import {useTranslation} from 'react-i18next';"] : []),
    `import {${sortNames(routerNames).join(', ')}} from 'react-router';`,
    ...(action ?
      [
        "import type {SubmissionResult} from '@conform-to/react';",
        "import {getFormProps, getInputProps, useForm} from '@conform-to/react';",
        "import {parseWithZod} from '@conform-to/zod/v4';",
      ]
    : []),
    ...(isQuery ?
      ["import {useSuspenseQuery} from '@tanstack/react-query';"]
    : []),
    ...(action ? formImportLines(context, hasBoolean) : []),
    isQuery ?
      `import {${context.calls.query}} from '${serviceImportPath(context)}/queries';`
    : "import type {LoaderData} from './types';",
  ].join('\n');
};

const dataReadLines = (context: DataRouteContext): string => {
  const {plural, singular} = context.binding.derived;

  if (context.flags.data !== 'query') {
    return block(
      `  const {${context.calls.dataKey}} = useLoaderData<LoaderData>();`
    );
  }

  if (isList(context)) {
    return block(
      `  const {data: ${plural}} = useSuspenseQuery(${plural}Query());`
    );
  }

  return block(
    "  const {id = ''} = useParams();",
    `  const {data: ${singular}} = useSuspenseQuery(${singular}Query(id));`
  );
};

const formHookLines = (context: DataRouteContext): string => {
  if (!context.flags.action) return '';

  const {singular} = context.binding.derived;

  return block(
    '  const lastResult = useActionData<SubmissionResult>();',
    '  const [form, fields] = useForm({',
    ...(isList(context) ? [] : [`    defaultValue: ${singular},`]),
    '    lastResult,',
    '    onValidate: ({formData}) =>',
    `      parseWithZod(formData, {schema: ${singular}InputSchema}),`,
    "    shouldValidate: 'onBlur',",
    '  });'
  );
};

const CHECKBOX_HELPER = block(
  "// Conform's `type` is an input attribute the Base UI checkbox root does not take.",
  'const omitType = <Props extends {type?: unknown}>({',
  '  type: _type,',
  '  ...props',
  '}: Props) => props;',
  ''
);

/** Variables for `page.data.tsx.tmpl`. */
export const buildDataPageVars = (context: DataRouteContext): TemplateVars => {
  const {action, i18n} = context.flags;
  const text = textHelpers(i18n);
  const i18nLine =
    i18n ?
      block(
        `  const {t} = useTranslation('pages', {keyPrefix: '${context.names.i18nKey}'});`
      )
    : '';
  const hasBoolean = context.binding.inputFields.some(
    (field) => field.kind === 'boolean'
  );

  return {
    checkboxHelper: action && hasBoolean ? CHECKBOX_HELPER : '',
    dataMarkup:
      isList(context) ? listMarkup(context) : detailMarkup(context, text),
    formMarkup: formMarkup(context, text),
    hookLines: `${i18nLine}${dataReadLines(context)}${formHookLines(context)}`,
    importLines: pageImportLines(context, hasBoolean),
    metaLine: metaElement(
      6,
      text.attribute('meta.description', context.names.description)
    ),
    pageName: context.names.pageName,
    titleText: text.child('title', context.names.title),
  };
};
