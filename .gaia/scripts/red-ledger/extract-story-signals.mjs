// Story mode for extract-test-signals.mjs: per-story (fullName, signal) pairs
// from a CSF `*.stories.tsx` / `*.stories.ts` file, whose play functions run
// as Vitest tests through @storybook/addon-vitest.
//
// One entry per story export that has an EFFECTIVE play function and whose
// tags keep it a test. Nothing for a render-only story, a story whose
// combined tags drop `test` (Storybook's combineTags over "test", "dev", the
// meta `tags`, then the story's own static `tags`, so a story-level `test`
// re-adds what a meta-level `!test` removed), the default export, or a
// type-only export.
//
// fullName: what addon-vitest names the test, read from Storybook 10.6.1's
// CsfFile parse: storyNameFromExport(exportName), overridden by a string-
// literal `name` property on the story object, then by a top-level
// `Export.storyName = '<literal>'` assignment. A top-level test, with no meta
// title prefix and no describe ancestry.
//
// signal: "sha256:" + hex sha256 of these regions, each normalized and
// comment-free exactly as a test signal is, joined by "\n":
//   1. the story's own declaration statement, plus every top-level
//      `Export.<anything> = …` statement targeting it, in source order;
//   2. the resolved play: the function node, the same-file declaration an
//      identifier resolves to, the whole factory declaration for a factory-
//      built story, or the spread source's / meta's resolved play;
//   3. the default-export meta object literal.
// Editing a shared play rotates every story using it; editing the meta
// rotates every story in the file.
//
// Effective-play resolution follows module evaluation order:
//
//   shape              | example                                  | play source
//   object property    | {play: async () => {…}}                  | the property initializer (or method)
//   assignment         | Invalid.play = async () => {…}           | the assignment's right side
//   shared identifier  | Default.play = showError                 | showError's top-level declaration
//   factory            | export const Info = createTypeStory('i') | the returned object's play; signal
//                      |                                          | carries the whole factory declaration
//   meta-level play    | const meta = {play: …}                   | the meta's play, when the story has none
//   spread             | export const B = {...A, args: {…}}       | A's play at B's declaration (recursive)
//   story reference    | {play: A.play}                           | A's own play at that point
//   name override      | {name: 'Custom', play: …}                | as object property; fullName Custom
//
// Object members apply in source order, so a later member wins, and a
// top-level `Export.play =` assignment wins over the object it follows. A play
// that is literally `undefined` counts as no own play and falls through to the
// meta's play, as Storybook's `storyAnnotations.play ?? meta.play` does.
//
// Refusal: any shape where presence or source of the effective play cannot be
// decided throws StoryShapeRefusal for the first offending export in source
// order (the meta reports as `default`). Refused shapes include a play bound
// to an import or a mutable binding, a story built by an imported function or
// a CSF4 `meta.story(...)` factory, a `.test(...)` call on a story, meta
// `includeStories` / `excludeStories`, an `export {…}` clause or a destructured
// export, a spread or identifier cycle, a factory with no single top-level
// `return {…}`, and non-literal `tags`. A play body calling imported helpers
// is normal and never refused.

import {createHash} from 'node:crypto';

export class StoryShapeRefusal extends Error {
  constructor(exportName, reason) {
    super(reason);
    this.exportName = exportName;
    this.reason = reason;
  }
}

// Mirrors storybook 10.6.1 `toStartCaseStr` (src/csf/toStartCaseStr.ts), which
// its `storyNameFromExport` (src/csf/export-story.ts) returns unchanged. Copied
// rather than imported: this script resolves only `typescript` from the repo
// root and must not depend on frontend's node_modules.
export function storyNameFromExport(key) {
  return key
    .replace(/_/g, ' ')
    .replace(/-/g, ' ')
    .replace(/\./g, ' ')
    .replace(/([^\n])([A-Z])([a-z])/g, (_match, a, b, c) => `${a} ${b}${c}`)
    .replace(/([a-z])([A-Z])/g, (_match, a, b) => `${a} ${b}`)
    .replace(/([a-z])([0-9])/gi, (_match, a, b) => `${a} ${b}`)
    .replace(/([0-9])([a-z])/gi, (_match, a, b) => `${a} ${b}`)
    .replace(/(\s|^)(\w)/g, (_match, a, b) => `${a}${b.toUpperCase()}`)
    .replace(/ +/g, ' ')
    .trim();
}

// Mirrors storybook 10.6.1 `combineTags` (src/csf/csf-utils.ts): later tags
// win, and a `!tag` deletes an earlier `tag`.
function combineTags(...tags) {
  const result = new Set();
  for (const tag of tags) {
    if (tag.startsWith('!')) {
      result.delete(tag.slice(1));
    } else {
      result.add(tag);
    }
  }
  return result;
}

// A play that is present but literally `undefined`.
const UNDEFINED_PLAY = Object.freeze({undefinedPlay: true});

export function extractStorySignals({ts, sourceFile, textWithoutComments, normalize}) {
  const hasModifier = (node, kind) =>
    (ts.canHaveModifiers?.(node) ? ts.getModifiers(node) : node.modifiers)?.some(
      (modifier) => modifier.kind === kind,
    ) ?? false;

  const unwrap = (expression) => {
    let current = expression;
    while (
      current &&
      (ts.isParenthesizedExpression(current) ||
        ts.isAsExpression(current) ||
        ts.isSatisfiesExpression(current) ||
        ts.isNonNullExpression(current) ||
        ts.isTypeAssertionExpression(current))
    ) {
      current = current.expression;
    }
    return current;
  };

  // Top-level bindings: name -> {kind, statement, node, init}.
  const bindings = new Map();
  // Story exports and export clauses, in source order.
  const exportEntries = [];
  // Top-level `Name.prop = value` statements: name -> [{statement, property, value}].
  const assignments = new Map();
  // Top-level `Name.test(...)` calls: name -> statement.
  const testCalls = new Map();
  let defaultExport = null;

  const addAssignment = (name, record) => {
    if (!assignments.has(name)) {
      assignments.set(name, []);
    }
    assignments.get(name).push(record);
  };

  const collectBindingNames = (nameNode, out) => {
    if (ts.isIdentifier(nameNode)) {
      out.push(nameNode.text);
      return;
    }
    for (const element of nameNode.elements) {
      if (!ts.isOmittedExpression(element)) {
        collectBindingNames(element.name, out);
      }
    }
  };

  for (const statement of sourceFile.statements) {
    if (ts.isImportDeclaration(statement)) {
      const clause = statement.importClause;
      if (clause?.name) {
        bindings.set(clause.name.text, {kind: 'import', statement});
      }
      const named = clause?.namedBindings;
      if (named && ts.isNamespaceImport(named)) {
        bindings.set(named.name.text, {kind: 'import', statement});
      } else if (named) {
        for (const element of named.elements) {
          bindings.set(element.name.text, {kind: 'import', statement});
        }
      }
    } else if (ts.isImportEqualsDeclaration(statement)) {
      bindings.set(statement.name.text, {kind: 'import', statement});
    } else if (ts.isVariableStatement(statement)) {
      if (hasModifier(statement, ts.SyntaxKind.DeclareKeyword)) {
        continue;
      }
      const flags = statement.declarationList.flags;
      const kind =
        flags & ts.NodeFlags.Const ? 'const' : flags & ts.NodeFlags.Let ? 'let' : 'var';
      const exported = hasModifier(statement, ts.SyntaxKind.ExportKeyword);
      for (const declaration of statement.declarationList.declarations) {
        if (ts.isIdentifier(declaration.name)) {
          const name = declaration.name.text;
          bindings.set(name, {kind, statement, node: declaration, init: declaration.initializer});
          if (exported && name !== '__namedExportsOrder') {
            exportEntries.push({name, statement});
          }
        } else {
          const names = [];
          collectBindingNames(declaration.name, names);
          for (const name of names) {
            bindings.set(name, {kind: 'destructured', statement});
          }
          if (exported) {
            exportEntries.push({
              name: names[0] ?? '<destructured>',
              statement,
              refusal: 'a destructured export has no story name the extractor can read',
            });
          }
        }
      }
    } else if (ts.isFunctionDeclaration(statement)) {
      if (statement.name) {
        bindings.set(statement.name.text, {kind: 'function', statement, node: statement});
      }
      if (hasModifier(statement, ts.SyntaxKind.ExportKeyword)) {
        if (hasModifier(statement, ts.SyntaxKind.DefaultKeyword)) {
          defaultExport = {statement, expression: null};
        } else if (statement.name && statement.body) {
          exportEntries.push({name: statement.name.text, statement});
        }
      }
    } else if (ts.isClassDeclaration(statement)) {
      if (statement.name) {
        bindings.set(statement.name.text, {kind: 'class', statement});
      }
      if (
        hasModifier(statement, ts.SyntaxKind.ExportKeyword) &&
        hasModifier(statement, ts.SyntaxKind.DefaultKeyword)
      ) {
        defaultExport = {statement, expression: null};
      }
    } else if (ts.isExportDeclaration(statement)) {
      if (statement.isTypeOnly) {
        continue;
      }
      const clause = statement.exportClause;
      if (!clause) {
        exportEntries.push({
          name: '*',
          statement,
          refusal: 'an `export * from` re-export hides which stories the file exports',
        });
      } else if (ts.isNamespaceExport(clause)) {
        exportEntries.push({
          name: clause.name.text,
          statement,
          refusal: 'a namespace re-export is not a story the extractor can read',
        });
      } else {
        for (const element of clause.elements) {
          if (!element.isTypeOnly) {
            exportEntries.push({
              name: element.name.text,
              statement,
              refusal: 'an `export {…}` clause is not a story declaration the extractor can read',
            });
          }
        }
      }
    } else if (ts.isExportAssignment(statement)) {
      defaultExport = statement.isExportEquals
        ? {statement, expression: null}
        : {statement, expression: statement.expression};
    } else if (ts.isExpressionStatement(statement)) {
      const expression = statement.expression;
      if (
        ts.isBinaryExpression(expression) &&
        expression.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
        ts.isPropertyAccessExpression(expression.left) &&
        ts.isIdentifier(expression.left.expression)
      ) {
        addAssignment(expression.left.expression.text, {
          statement,
          property: expression.left.name.text,
          value: expression.right,
        });
      } else if (
        ts.isCallExpression(expression) &&
        ts.isPropertyAccessExpression(expression.expression) &&
        ts.isIdentifier(expression.expression.expression) &&
        expression.expression.name.text === 'test'
      ) {
        const name = expression.expression.expression.text;
        if (!testCalls.has(name)) {
          testCalls.set(name, statement);
        }
      }
    }
  }

  const propertyName = (member, refuse) => {
    const name = member.name;
    if (!name) {
      return null;
    }
    if (ts.isIdentifier(name) || ts.isPrivateIdentifier(name)) {
      return name.text;
    }
    if (ts.isStringLiteral(name) || ts.isNoSubstitutionTemplateLiteral(name) || ts.isNumericLiteral(name)) {
      return name.text;
    }
    refuse('an object member has a computed key the extractor cannot read');
    return null;
  };

  const regionText = (node) => normalize(textWithoutComments(node.getStart(sourceFile), node.getEnd()));

  // ---- meta -------------------------------------------------------------

  const refuseMeta = (reason) => {
    throw new StoryShapeRefusal('default', reason);
  };

  if (!defaultExport) {
    refuseMeta('the file has no default-export meta object');
  }
  let metaObject = null;
  let metaBindingName = null;
  {
    const expression = defaultExport.expression ? unwrap(defaultExport.expression) : null;
    if (expression && ts.isObjectLiteralExpression(expression)) {
      metaObject = expression;
    } else if (expression && ts.isIdentifier(expression)) {
      const binding = bindings.get(expression.text);
      const init = binding?.kind === 'const' ? unwrap(binding.init) : null;
      if (init && ts.isObjectLiteralExpression(init)) {
        metaObject = init;
        metaBindingName = expression.text;
      }
    }
  }
  if (!metaObject) {
    refuseMeta('the default export is not a same-file object literal meta (a CSF4 meta factory is unsupported)');
  }

  let metaTagsNode = null;
  let metaPlayMember = null;
  for (const member of metaObject.properties) {
    if (ts.isSpreadAssignment(member)) {
      refuseMeta('the meta spreads another object, which can carry play or tags');
    }
    const name = propertyName(member, refuseMeta);
    if (name === 'includeStories' || name === 'excludeStories') {
      refuseMeta(`the meta sets ${name}, which decides story exports at runtime`);
    }
    if (name === 'play' || name === 'tags') {
      if (ts.isGetAccessorDeclaration(member) || ts.isSetAccessorDeclaration(member)) {
        refuseMeta(`the meta defines ${name} through an accessor`);
      }
      if (name === 'play') {
        metaPlayMember = member;
      } else {
        metaTagsNode = memberValue(member);
      }
    }
  }
  if (metaBindingName) {
    for (const record of assignments.get(metaBindingName) ?? []) {
      if (['play', 'tags', 'includeStories', 'excludeStories'].includes(record.property)) {
        refuseMeta(`the meta's ${record.property} is reassigned after its declaration`);
      }
    }
  }

  function memberValue(member) {
    if (ts.isPropertyAssignment(member)) {
      return member.initializer;
    }
    if (ts.isShorthandPropertyAssignment(member)) {
      return member.name;
    }
    return member;
  }

  const parseTags = (node, refuse) => {
    let value = unwrap(node);
    if (value && ts.isIdentifier(value)) {
      const binding = bindings.get(value.text);
      value = binding?.kind === 'const' ? unwrap(binding.init) : null;
    }
    if (!value || !ts.isArrayLiteralExpression(value)) {
      refuse('tags is not an array of string literals');
    }
    return value.elements.map((element) => {
      if (!ts.isStringLiteral(element)) {
        refuse('tags is not an array of string literals');
      }
      return element.text;
    });
  };

  const metaTags = metaTagsNode ? parseTags(metaTagsNode, refuseMeta) : [];

  // ---- play resolution ---------------------------------------------------

  // A resolved play is null (absent), UNDEFINED_PLAY, or {nodes: [...]}, the
  // nodes being the play's region-2 text.

  const statementPosition = (statement) => statement.getStart(sourceFile);

  function resolvePlayValue(expression, context) {
    const value = unwrap(expression);
    if (ts.isArrowFunction(value) || ts.isFunctionExpression(value) || ts.isMethodDeclaration(value)) {
      return {nodes: [value]};
    }
    if (ts.isIdentifier(value)) {
      return resolvePlayIdentifier(value.text, context);
    }
    if (
      ts.isPropertyAccessExpression(value) &&
      ts.isIdentifier(value.expression) &&
      value.name.text === 'play'
    ) {
      if (context.parameters.has(value.expression.text)) {
        context.refuse('play is read from a factory parameter');
      }
      const owner = value.expression.text;
      if (owner === metaBindingName) {
        return metaPlay(context);
      }
      const state = ownPlayAt(owner, context.position, context);
      return state ?? UNDEFINED_PLAY;
    }
    context.refuse('play is not a function, a same-file identifier, or a story play reference the extractor can read');
    return null;
  }

  function resolvePlayIdentifier(name, context) {
    if (context.parameters.has(name)) {
      context.refuse(`play is bound to the factory parameter ${name}`);
    }
    const binding = bindings.get(name);
    if (!binding) {
      if (name === 'undefined') {
        return UNDEFINED_PLAY;
      }
      context.refuse(`play is bound to ${name}, which has no same-file top-level declaration`);
    }
    if (binding.kind === 'import') {
      context.refuse(`play is bound to the imported identifier ${name}`);
    }
    if (binding.kind === 'function') {
      return {nodes: [binding.node]};
    }
    if (binding.kind !== 'const' || !binding.init) {
      context.refuse(`play is bound to ${name}, which is not a const or function declaration`);
    }
    return withVisit(`identifier ${name}`, context, () => resolvePlayValue(binding.init, context));
  }

  function withVisit(key, context, run) {
    if (context.visiting.has(key)) {
      context.refuse(`a spread or identifier cycle runs through ${key.replace(/^\w+ /, '')}`);
    }
    context.visiting.add(key);
    try {
      return run();
    } finally {
      context.visiting.delete(key);
    }
  }

  // The play an object literal carries once its members have applied.
  function objectPlay(objectNode, context) {
    let state = null;
    for (const member of objectNode.properties) {
      if (ts.isSpreadAssignment(member)) {
        const spread = unwrap(member.expression);
        let spreadState;
        if (ts.isObjectLiteralExpression(spread)) {
          spreadState = objectPlay(spread, context);
        } else if (ts.isIdentifier(spread)) {
          if (context.parameters.has(spread.text)) {
            context.refuse(`the story spreads the factory parameter ${spread.text}`);
          }
          spreadState =
            spread.text === metaBindingName ? metaPlay(context) : ownPlayAt(spread.text, context.position, context);
        } else {
          context.refuse('the story spreads an expression the extractor cannot read');
        }
        if (spreadState) {
          state = spreadState;
        }
        continue;
      }
      const name = propertyName(member, context.refuse);
      if (name !== 'play') {
        continue;
      }
      if (ts.isGetAccessorDeclaration(member) || ts.isSetAccessorDeclaration(member)) {
        context.refuse('play is defined through an accessor');
      }
      state = resolvePlayValue(memberValue(member), context);
    }
    return state;
  }

  // The play a top-level binding's object carries at `position` in module
  // evaluation: its initializer, then each `name.play =` statement before it.
  function ownPlayAt(name, position, context) {
    return withVisit(`story ${name}`, context, () => {
      const binding = bindings.get(name);
      if (!binding) {
        context.refuse(`the story reads ${name}, which has no same-file top-level declaration`);
      }
      if (binding.kind === 'import') {
        context.refuse(`the story reads the imported value ${name}`);
      }
      let state = null;
      if (binding.kind === 'const' || binding.kind === 'let' || binding.kind === 'var') {
        if (binding.init) {
          state = initializerPlay(binding.init, binding.statement, {
            ...context,
            parameters: new Set(),
            position: statementPosition(binding.statement),
          });
        }
      } else if (binding.kind !== 'function') {
        context.refuse(`the story reads ${name}, which is not a variable or function declaration`);
      }
      for (const record of assignments.get(name) ?? []) {
        if (record.property === 'play' && statementPosition(record.statement) < position) {
          state = resolvePlayValue(record.value, {
            ...context,
            parameters: new Set(),
            position: statementPosition(record.statement),
          });
        }
      }
      return state;
    });
  }

  function initializerPlay(initializer, statement, context) {
    const value = unwrap(initializer);
    if (ts.isObjectLiteralExpression(value)) {
      return objectPlay(value, context);
    }
    if (ts.isArrowFunction(value) || ts.isFunctionExpression(value) || ts.isClassExpression(value)) {
      return null;
    }
    if (ts.isIdentifier(value)) {
      if (value.text === metaBindingName) {
        return metaPlay(context);
      }
      return ownPlayAt(value.text, context.position, context);
    }
    if (ts.isCallExpression(value)) {
      return callPlay(value, context);
    }
    context.refuse('the story initializer is not an object, function, or same-file factory call the extractor can read');
    return null;
  }

  function callPlay(call, context) {
    const callee = unwrap(call.expression);
    if (ts.isPropertyAccessExpression(callee)) {
      const method = callee.name.text;
      if (method === 'story' || method === 'extend') {
        context.refuse(`a CSF4 factory story (.${method}(…)) is unsupported`);
      }
      const target = unwrap(callee.expression);
      if (method === 'bind' && ts.isIdentifier(target)) {
        const binding = bindings.get(target.text);
        const init = binding?.kind === 'const' ? unwrap(binding.init) : null;
        if (
          binding?.kind === 'function' ||
          (init && (ts.isArrowFunction(init) || ts.isFunctionExpression(init)))
        ) {
          // A bound function carries none of its target's properties.
          return null;
        }
      }
      context.refuse('the story initializer is a method call the extractor cannot read');
    }
    if (!ts.isIdentifier(callee)) {
      context.refuse('the story initializer is a call the extractor cannot read');
    }
    const binding = bindings.get(callee.text);
    if (!binding) {
      context.refuse(`the story is built by ${callee.text}, which has no same-file top-level declaration`);
    }
    if (binding.kind === 'import') {
      context.refuse(`the story is built by the imported function ${callee.text}`);
    }
    let factory = null;
    if (binding.kind === 'function') {
      factory = binding.node;
    } else if (binding.kind === 'const') {
      const init = unwrap(binding.init);
      if (init && (ts.isArrowFunction(init) || ts.isFunctionExpression(init))) {
        factory = init;
      }
    }
    if (!factory?.body) {
      context.refuse(`the story is built by ${callee.text}, which is not a same-file function`);
    }
    return withVisit(`factory ${callee.text}`, context, () => {
      const returned = factoryReturn(factory, callee.text, context);
      const parameters = [];
      for (const parameter of factory.parameters) {
        collectBindingNames(parameter.name, parameters);
      }
      const state = objectPlay(returned, {...context, parameters: new Set(parameters)});
      if (state && state !== UNDEFINED_PLAY) {
        return {nodes: [binding.statement]};
      }
      return state;
    });
  }

  function factoryReturn(factory, name, context) {
    let returned = null;
    if (ts.isBlock(factory.body)) {
      const returns = [];
      const collect = (node) => {
        if (ts.isFunctionLike(node) || ts.isClassLike(node)) {
          return;
        }
        if (ts.isReturnStatement(node)) {
          returns.push(node);
        }
        ts.forEachChild(node, collect);
      };
      ts.forEachChild(factory.body, collect);
      if (returns.length !== 1 || returns[0].parent !== factory.body || !returns[0].expression) {
        context.refuse(`the factory ${name} has no single top-level return the extractor can read`);
      }
      returned = unwrap(returns[0].expression);
    } else {
      returned = unwrap(factory.body);
    }
    if (!ts.isObjectLiteralExpression(returned)) {
      context.refuse(`the factory ${name} does not return an object literal`);
    }
    return returned;
  }

  function metaPlay(context) {
    if (!metaPlayMember) {
      return null;
    }
    return resolvePlayValue(memberValue(metaPlayMember), {
      ...context,
      parameters: new Set(),
      position: statementPosition(defaultExport.statement),
    });
  }

  // ---- stories -----------------------------------------------------------

  const metaRegion = regionText(metaObject);
  const lines = [];

  for (const entry of exportEntries) {
    const refuse = (reason) => {
      throw new StoryShapeRefusal(entry.name, reason);
    };
    if (entry.refusal) {
      refuse(entry.refusal);
    }
    const binding = bindings.get(entry.name);
    const storyAssignments = assignments.get(entry.name) ?? [];

    if (testCalls.has(entry.name)) {
      refuse('a `.test(…)` call on a story (a CSF4 test story) is unsupported');
    }
    for (const record of storyAssignments) {
      if (record.property === 'story') {
        refuse('a legacy `.story` annotation object is unsupported');
      }
    }

    const storyObject =
      binding.kind === 'function' || !binding.init ? null : unwrap(binding.init);
    const directObject = storyObject && ts.isObjectLiteralExpression(storyObject) ? storyObject : null;

    // Static name and tags, as Storybook's CsfFile reads them.
    let fullName = storyNameFromExport(entry.name);
    let storyTagsNode = null;
    for (const member of directObject?.properties ?? []) {
      if (ts.isSpreadAssignment(member)) {
        continue;
      }
      const name = propertyName(member, refuse);
      if (name === 'name' && ts.isPropertyAssignment(member) && ts.isStringLiteral(member.initializer)) {
        fullName = member.initializer.text;
      } else if (name === 'tags') {
        storyTagsNode = memberValue(member);
      }
    }
    const declaredAt = statementPosition(entry.statement);
    for (const record of storyAssignments) {
      if (statementPosition(record.statement) < declaredAt) {
        continue;
      }
      if (record.property === 'storyName' && ts.isStringLiteral(record.value)) {
        fullName = record.value.text;
      } else if (record.property === 'tags') {
        storyTagsNode = record.value;
      }
    }
    const storyTags = storyTagsNode ? parseTags(storyTagsNode, refuse) : [];
    if (!combineTags('test', 'dev', ...metaTags, ...storyTags).has('test')) {
      continue;
    }

    const context = {
      parameters: new Set(),
      position: Number.POSITIVE_INFINITY,
      refuse,
      visiting: new Set(),
    };
    let play = ownPlayAt(entry.name, Number.POSITIVE_INFINITY, context);
    if (!play || play === UNDEFINED_PLAY) {
      play = metaPlay(context);
    }
    if (!play || play === UNDEFINED_PLAY) {
      continue;
    }

    const regions = [
      [entry.statement, ...storyAssignments.map((record) => record.statement)]
        .map(regionText)
        .join('\n'),
      play.nodes.map(regionText).join('\n'),
      metaRegion,
    ];
    const hex = createHash('sha256').update(regions.join('\n'), 'utf8').digest('hex');
    lines.push(JSON.stringify({fullName, signal: `sha256:${hex}`, kind: 'runtime'}));
  }

  return lines;
}
