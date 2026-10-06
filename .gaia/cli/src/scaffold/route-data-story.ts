/**
 * Template variables for a data route's page story: the record the MSW
 * handlers serve, the values the play submits, and the body it expects the
 * mutation handler to receive on the wire.
 */
import type {DataRouteContext} from './route-data.js';
import {
  block,
  dataExportNames,
  destructure,
  fieldLabel,
  fitOnLine,
  humanize,
  isList,
  linkLabelField,
  objectLiteralLines,
  serviceImportPath,
  sortNames,
  toLiteral,
} from './route-data.js';
import type {FieldKind, ServiceField} from './route-service.js';
import {camelToSnake} from './service.js';
import type {TemplateVars} from './template.js';

type Sample = {
  /** The value as a TypeScript literal in the story source. */
  literal: string;
  /** The value as the page renders it and the play types it. */
  text: string;
};

const textSample = (text: string): Sample => ({literal: toLiteral(text), text});

const plainSample = (value: boolean | number): Sample => ({
  literal: String(value),
  text: String(value),
});

// The record the handlers serve and the values the play submits differ for
// every field, so the play can tell a value it typed from one it was served. A
// boolean is served false so that checking its box submits true.
const SAMPLE_BUILDERS: Record<
  FieldKind,
  (field: ServiceField, isRecord: boolean) => Sample
> = {
  boolean: (_field, isRecord) => plainSample(!isRecord),
  datetime: (_field, isRecord) =>
    textSample(isRecord ? '2026-01-01T00:00:00Z' : '2026-02-01T00:00:00Z'),
  enum: (field, isRecord) =>
    textSample(
      (isRecord ? field.enumValues.at(0) : field.enumValues.at(-1)) ?? ''
    ),
  number: (_field, isRecord) => plainSample(isRecord ? 42 : 7),
  string: (field, isRecord) =>
    textSample(`${humanize(field.name)} ${isRecord ? 1 : 2}`),
};

const sample = (field: ServiceField, phase: 'record' | 'submitted'): Sample =>
  SAMPLE_BUILDERS[field.kind](field, phase === 'record');

const idSample = (field: ServiceField): Sample =>
  field.kind === 'number' ? plainSample(1) : textSample('1');

const wireKey = (context: DataRouteContext, field: ServiceField): string =>
  context.binding.snakeCaseWire ? camelToSnake(field.name) : field.name;

const routeExportNames = (context: DataRouteContext): string[] => {
  const {action, data} = context.flags;
  const {action: actionName, loader: loaderName} = dataExportNames(data);

  return sortNames([
    loaderName,
    ...(data === 'server' ? [] : ['HydrateFallback']),
    ...(action ? [actionName] : []),
  ]);
};

const recordLines = (context: DataRouteContext): string => {
  const {idField, inputFields} = context.binding;

  return objectLiteralLines(
    [
      [wireKey(context, idField), idSample(idField).literal],
      ...inputFields.map(
        (field) =>
          [wireKey(context, field), sample(field, 'record').literal] as const
      ),
    ],
    2
  );
};

const handlerLines = (context: DataRouteContext): string => {
  const {derived} = context.binding;
  const list = isList(context);
  const urls = `${derived.NAME_UPPER}_URLS`;
  const target =
    list ?
      `url(${urls}.${derived.plural})`
    : `url(${urls}.${derived.plural}Id)`;
  const getter = block(
    `        http.get(${target}, () =>`,
    `          HttpResponse.json({data: ${list ? '[RECORD]' : 'RECORD'}})`,
    '        ),'
  );

  if (!context.flags.action) return getter;

  const mutation = block(
    `        http.${list ? 'post' : 'put'}(${target}, async ({request}) => {`,
    '          submittedBody = await request.json();',
    '',
    '          return HttpResponse.json({data: RECORD});',
    '        }),'
  );

  return `${getter}${mutation}`;
};

const renderAssertion = (context: DataRouteContext): string => {
  const {idField, inputFields} = context.binding;

  if (isList(context)) {
    const labelField = linkLabelField(context);
    const label =
      labelField === idField ? idSample(idField) : sample(labelField, 'record');

    return block(
      '  await expect(',
      `    await canvas.findByRole('link', {name: ${toLiteral(label.text)}})`,
      `  ).toHaveAttribute('href', '/${context.slug}/${idSample(idField).text}');`
    );
  }

  const [first] = inputFields;
  const shown = first === undefined ? '' : sample(first, 'record').text;

  return fitOnLine(
    `  await expect(await canvas.findByText(${toLiteral(shown)})).toBeInTheDocument();`,
    [
      '  await expect(',
      `    await canvas.findByText(${toLiteral(shown)})`,
      '  ).toBeInTheDocument();',
    ]
  );
};

const fillStep = (field: ServiceField): string => {
  const label = toLiteral(fieldLabel(field));

  if (field.kind === 'boolean') {
    return block(
      `  await userEvent.click(canvas.getByRole('checkbox', {name: ${label}}));`
    );
  }

  const input = `canvas.getByLabelText(${label})`;
  const value = toLiteral(sample(field, 'submitted').text);
  const typeLine = `  await userEvent.type(${input}, ${value});`;
  const clearLine = `  await userEvent.clear(${input});`;

  return `${block(clearLine)}${fitOnLine(typeLine, [
    '  await userEvent.type(',
    `    ${input},`,
    `    ${value}`,
    '  );',
  ])}`;
};

const expectedBody = (context: DataRouteContext): string => {
  const entries = objectLiteralLines(
    context.binding.inputFields.map(
      (field) =>
        [wireKey(context, field), sample(field, 'submitted').literal] as const
    ),
    4
  );

  return `{\n${entries}  }`;
};

const storyImportLines = (context: DataRouteContext): string => {
  const {derived} = context.binding;
  const testNames =
    context.flags.action ?
      ['expect', 'userEvent', 'within']
    : ['expect', 'within'];

  return [
    "import type {Meta, StoryFn} from '@storybook/react-vite';",
    "import {http, HttpResponse} from 'msw';",
    `import {${testNames.join(', ')}} from 'storybook/test';`,
    "import {url} from 'test/mocks/url';",
    "import stubs from 'test/stubs';",
    "import Layout from '~/components/layout';",
    destructure(
      'import ',
      routeExportNames(context),
      ` from '~/routes/${context.names.routeFile}';`
    ),
    `import {${derived.NAME_UPPER}_URLS} from '${serviceImportPath(context)}';`,
    `import ${context.names.pageName} from '../page';`,
  ].join('\n');
};

/** Variables for `page.data.stories.tsx.tmpl`. */
export const buildDataStoryVars = (context: DataRouteContext): TemplateVars => {
  const list = isList(context);
  const {derived, idField, inputFields} = context.binding;

  return {
    expectedBody: expectedBody(context),
    fillSteps: inputFields.map((field) => fillStep(field)).join(''),
    handlerLines: handlerLines(context),
    hasAction: context.flags.action,
    importLines: storyImportLines(context),
    initialEntry: list ? '' : `/${context.slug}/${idSample(idField).text}`,
    isDetail: !list,
    isList: list,
    pageName: context.names.pageName,
    recordLines: recordLines(context),
    renderAssertion: renderAssertion(context),
    routeExports: routeExportNames(context).join(', '),
    routeSlug: context.slug,
    saveLabel: 'Save',
    storyPath: list ? '/' : `/${context.slug}/:id`,
    storyTitle: context.names.storyTitle,
    submitStoryName: `${list ? 'Creates' : 'Updates'}${derived.Singular}`,
  };
};
