#!/usr/bin/env node
// Structural a11y-triviality floor: a judge-INDEPENDENT static-AST check that
// flags a vacuous a11y test as an advisory non-triviality fix. It reads no LLM
// judgement and rests on no can-it-fail axis (an a11y render reads GREEN
// identically whether the test is honest or vacuous); the structural shape is
// the mechanical pass condition, and a worthiness evaluator's agreement is
// corroborating evidence only.
//
// It inspects a11y test files: those calling the emergent-signal a11y helpers
// `expectNoA11yViolations` / `runAxe`. Those call names are members of the
// determinism classifier's emergent set, so an a11y test never leaks to the
// deterministic RED surface; this helper is the complement that grades the same
// test's worthiness.
//
// An a11y test is flagged TRIVIAL when EITHER condition holds:
//   A. its `render(...)` passes no props (only defaults): a degenerate
//      instance that axe passes vacuously against; OR
//   B. its rendered markup carries no interactive or landmark host node WHILE
//      the component's stories declare interactive variants: a render-only axe
//      pass that says nothing about the focus order, keyboard operation, or
//      accessible state of the controls a user drives.
//
// The floor is ADVISORY. It surfaces a `fix`; it is never a hard block. A
// render-only axe pass stays a complete a11y test for a component with no
// interactive behavior (a Spinner, a static badge); the floor only flags it when
// the shape (no props) or the stories (declared interactive variants) say the
// component has behavior the test leaves unexercised.
//
// Invocation:
//   node .gaia/scripts/a11y-structural/check-a11y-triviality.mjs <repo-relative-test-path>
//   ... --stdin            (read test bytes from stdin; the path arg still names
//                           the file identity for .ts-vs-.tsx script kind)
//   ... --stories <path>   (read the component's stories from this path)
//
// When --stories is not given, the sibling `index.stories.tsx` in the test's
// folder is read from disk when present; absent it, condition B simply cannot
// fire and only condition A applies.
//
// Output (stdout): one JSON object,
//   {"file":"...","verdict":"trivial"|"non-trivial"|"not-a11y","findings":[{fullName,reason}]}
// `not-a11y`: the file calls no a11y helper. `non-trivial`: a11y tests exist and
// none are flagged. `trivial`: at least one a11y test is flagged (findings list
// the test fullNames and the structural reason).
// Exit 0 on success. Exit non-zero with a one-line stderr message on a missing
// argument, a missing `typescript`, an unreadable file, or a parse failure, so
// the callers can apply their own fail-open policy.

import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);

const args = process.argv.slice(2);
const useStdin = args.includes('--stdin');
const storiesFlagIndex = args.indexOf('--stories');
const storiesArg =
  storiesFlagIndex >= 0 ? args[storiesFlagIndex + 1] : undefined;
// The first non-flag arg that is not the value consumed by `--stories`.
const filePath = args.find(
  (a, i) =>
    !a.startsWith('--') && (storiesFlagIndex < 0 || i !== storiesFlagIndex + 1),
);

if (!filePath) {
  process.stderr.write(
    'check-a11y-triviality: missing <repo-relative-test-path> argument\n',
  );
  process.exit(2);
}

let ts;
try {
  ts = require('typescript');
} catch {
  process.stderr.write(
    'check-a11y-triviality: cannot resolve "typescript" from node_modules\n',
  );
  process.exit(3);
}

let testSource;
try {
  testSource = useStdin ? readFileSync(0, 'utf8') : readFileSync(filePath, 'utf8');
} catch (err) {
  process.stderr.write(
    `check-a11y-triviality: cannot read ${filePath}: ${err.message}\n`,
  );
  process.exit(4);
}

// Resolve the stories source: an explicit --stories path, else the sibling
// index.stories.tsx in the test's folder (skipped under --stdin, where there is
// no on-disk sibling to resolve against). A missing stories file is not an
// error; condition B simply cannot fire without it.
let storiesSource;
let storiesPath = storiesArg;
if (!storiesPath && !useStdin) {
  storiesPath = path.join(path.dirname(filePath), 'index.stories.tsx');
}
if (storiesPath) {
  try {
    storiesSource = readFileSync(storiesPath, 'utf8');
  } catch {
    storiesSource = undefined;
  }
}

const scriptKind = /\.tsx$/i.test(filePath)
  ? ts.ScriptKind.TSX
  : ts.ScriptKind.TS;

const parse = (source, identity, kind) => {
  let sourceFile;
  try {
    sourceFile = ts.createSourceFile(
      identity,
      source,
      ts.ScriptTarget.Latest,
      /* setParentNodes */ true,
      kind,
    );
  } catch (err) {
    process.stderr.write(
      `check-a11y-triviality: parse failed for ${identity}: ${err.message}\n`,
    );
    process.exit(5);
  }
  // createSourceFile is lenient and records syntactic diagnostics rather than
  // throwing. A genuinely broken file must fail the helper so the caller can
  // fall back to its own fail-open policy.
  const diagnostics = sourceFile.parseDiagnostics ?? [];
  if (diagnostics.length > 0) {
    const first = diagnostics[0];
    const message = ts.flattenDiagnosticMessageText(first.messageText, '\n');
    process.stderr.write(
      `check-a11y-triviality: syntax error in ${identity}: ${message}\n`,
    );
    process.exit(6);
  }
  return sourceFile;
};

const testFile = parse(testSource, filePath, scriptKind);
const storiesFile =
  storiesSource !== undefined
    ? parse(storiesSource, 'stories.tsx', ts.ScriptKind.TSX)
    : null;

const A11Y_HELPER_NAMES = new Set(['expectNoA11yViolations', 'runAxe']);
const TEST_NAMES = new Set(['test', 'it']);
const DESCRIBE_NAMES = new Set(['describe', 'suite']);

// Lowercase host elements that carry interactive or landmark semantics. Their
// presence in a render's markup means the test exercises real a11y surface, so
// condition B does not fire.
const INTERACTIVE_HOST_TAGS = new Set([
  'a',
  'button',
  'input',
  'select',
  'textarea',
  'details',
  'summary',
  'dialog',
  'audio',
  'video',
]);
const LANDMARK_HOST_TAGS = new Set([
  'nav',
  'main',
  'header',
  'footer',
  'aside',
  'section',
  'form',
  'search',
]);

// JSX prop names that mark a story (or a render) as wiring up interactive
// behavior. A story that passes any of these declares an interactive variant.
const INTERACTIVE_PROP_RE = /^(on[A-Z]|disabled$|checked$|selected$|readOnly$)/;

// --- shared AST helpers -------------------------------------------------------

// The bare identifier name of a (possibly chained) call's callee:
// expect(x).toBe(y) -> "expect"; describe.skip(...) -> "describe".
const baseCalleeName = (node) => {
  let expr = node.expression;
  while (ts.isCallExpression(expr)) expr = expr.expression;
  while (ts.isPropertyAccessExpression(expr)) expr = expr.expression;
  return ts.isIdentifier(expr) ? expr.text : null;
};

// The first string-literal title of a test/describe call, or null when dynamic.
const titleOf = (node) => {
  const arg = node.arguments[0];
  if (!arg) return null;
  if (ts.isStringLiteral(arg) || ts.isNoSubstitutionTemplateLiteral(arg)) {
    return arg.text;
  }
  return null;
};

// The tag name of a JSX opening element: <Foo> -> "Foo", <button> -> "button".
const tagNameOf = (opening) => {
  const tag = opening.tagName;
  if (ts.isIdentifier(tag)) return tag.text;
  // Namespaced / dotted tags (Foo.Bar): take the trailing member.
  if (ts.isPropertyAccessExpression(tag)) return tag.name.text;
  return null;
};

// The JSX attributes (props) of an opening element, excluding spread.
const namedAttrs = (opening) =>
  (opening.attributes?.properties ?? []).filter((p) =>
    ts.isJsxAttribute(p),
  );

// True when an opening element carries a spread prop ({...props}); a spread is
// an unknown prop set, so we cannot call the element propless.
const hasSpread = (opening) =>
  (opening.attributes?.properties ?? []).some((p) =>
    ts.isJsxSpreadAttribute(p),
  );

// --- collect a11y tests in the test file --------------------------------------

// Does a subtree call an a11y helper (expectNoA11yViolations / runAxe)?
const callsA11yHelper = (node) => {
  let found = false;
  const visit = (n) => {
    if (found) return;
    if (
      ts.isCallExpression(n) &&
      ts.isIdentifier(n.expression) &&
      A11Y_HELPER_NAMES.has(n.expression.text)
    ) {
      found = true;
      return;
    }
    ts.forEachChild(n, visit);
  };
  visit(node);
  return found;
};

// The root JSX element(s) passed to each `render(...)` call inside a subtree.
// `render(<Foo .../>)` -> the <Foo> opening element. Returns one entry per
// render call (a11y tests usually have exactly one).
const renderedElements = (node) => {
  const elements = [];
  const visit = (n) => {
    if (
      ts.isCallExpression(n) &&
      ts.isIdentifier(n.expression) &&
      n.expression.text === 'render'
    ) {
      const arg = n.arguments[0];
      const opening = rootJsxOpening(arg);
      if (opening) elements.push({opening, arg});
    }
    ts.forEachChild(n, visit);
  };
  visit(node);
  return elements;
};

// Resolve a render argument to its root JSX opening element, unwrapping a
// parenthesized expression and a JSX fragment's single element child.
const rootJsxOpening = (arg) => {
  let node = arg;
  while (node && ts.isParenthesizedExpression(node)) node = node.expression;
  if (!node) return null;
  if (ts.isJsxElement(node)) return node.openingElement;
  if (ts.isJsxSelfClosingElement(node)) return node;
  if (ts.isJsxFragment(node)) {
    for (const child of node.children) {
      if (ts.isJsxElement(child)) return child.openingElement;
      if (ts.isJsxSelfClosingElement(child)) return child;
    }
  }
  return null;
};

// Does a render argument's JSX subtree contain any interactive or landmark host
// node? Walks every JSX opening/self-closing element under the argument.
const hasInteractiveOrLandmarkMarkup = (arg) => {
  let found = false;
  const visit = (n) => {
    if (found) return;
    if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
      const tag = tagNameOf(n);
      if (
        tag &&
        (INTERACTIVE_HOST_TAGS.has(tag) || LANDMARK_HOST_TAGS.has(tag))
      ) {
        found = true;
        return;
      }
      // An interactive prop on any element (host or component) also counts: a
      // rendered <Foo onClick={...}/> drives interactive surface.
      for (const attr of namedAttrs(n)) {
        const name = attr.name.getText(testFile);
        if (INTERACTIVE_PROP_RE.test(name)) {
          found = true;
          return;
        }
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(arg);
  return found;
};

// --- stories: do they declare an interactive variant? -------------------------

// A stories file declares an interactive variant when ANY exported story renders
// markup with an interactive prop or an interactive/landmark host node. As a
// secondary signal, more than one non-default exported StoryFn means the
// component has variants worth exercising beyond a single render.
const storiesDeclareInteractiveVariant = () => {
  if (!storiesFile) return false;

  let interactive = false;
  let exportedStoryCount = 0;

  const visitJsxForInteractive = (n) => {
    if (interactive) return;
    if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
      const tag = tagNameOf(n);
      if (
        tag &&
        (INTERACTIVE_HOST_TAGS.has(tag) || LANDMARK_HOST_TAGS.has(tag))
      ) {
        interactive = true;
        return;
      }
      for (const attr of namedAttrs(n)) {
        const name = attr.name.getText(storiesFile);
        if (INTERACTIVE_PROP_RE.test(name)) {
          interactive = true;
          return;
        }
      }
    }
    ts.forEachChild(n, visitJsxForInteractive);
  };

  const visit = (node) => {
    // export const Foo = ... (a named story export)
    if (
      ts.isVariableStatement(node) &&
      node.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword)
    ) {
      for (const decl of node.declarationList.declarations) {
        if (ts.isIdentifier(decl.name) && decl.name.text !== 'default') {
          exportedStoryCount += 1;
        }
        if (decl.initializer) visitJsxForInteractive(decl.initializer);
      }
    }
    ts.forEachChild(node, visit);
  };

  visit(storiesFile);

  return interactive || exportedStoryCount > 1;
};

// --- classify each a11y test --------------------------------------------------

const findings = [];
let sawA11yTest = false;

const judgeA11yTest = (testNode, fullName) => {
  sawA11yTest = true;

  const renders = renderedElements(testNode);
  if (renders.length === 0) {
    // An a11y assertion with no render in the test body is not a vacuous-render
    // shape this floor recognizes; leave it for the runtime worthiness audit.
    return;
  }

  // Condition A: a render whose root component element carries no props (only
  // defaults) is a degenerate instance.
  const propless = renders.some(
    ({opening}) =>
      !hasSpread(opening) &&
      namedAttrs(opening).length === 0 &&
      // host-element-only renders (a literal <button/>) are not the degenerate
      // shape; condition A targets a propless render of the component itself.
      /^[A-Z]/.test(tagNameOf(opening) ?? ''),
  );
  if (propless) {
    findings.push({
      fullName,
      reason:
        'a11y render passes no props (only defaults); axe passes vacuously against a degenerate instance',
    });
    return;
  }

  // Condition B: no interactive/landmark markup in the render WHILE the stories
  // declare interactive variants.
  const anyInteractiveMarkup = renders.some(({arg}) =>
    hasInteractiveOrLandmarkMarkup(arg),
  );
  if (!anyInteractiveMarkup && storiesDeclareInteractiveVariant()) {
    findings.push({
      fullName,
      reason:
        'a11y render has no interactive or landmark node while the stories declare interactive variants; the render-only axe pass leaves the interactive surface unexercised',
    });
  }
};

const visit = (node, ancestors) => {
  if (ts.isCallExpression(node)) {
    const name = baseCalleeName(node);
    if (name && TEST_NAMES.has(name)) {
      const title = titleOf(node);
      if (title !== null && callsA11yHelper(node)) {
        const fullName = [...ancestors, title].join(' ');
        judgeA11yTest(node, fullName);
      }
      return;
    }
    if (name && DESCRIBE_NAMES.has(name)) {
      const title = titleOf(node);
      const next = title !== null ? [...ancestors, title] : ancestors;
      ts.forEachChild(node, (child) => visit(child, next));
      return;
    }
  }
  ts.forEachChild(node, (child) => visit(child, ancestors));
};

visit(testFile, []);

const verdict = !sawA11yTest
  ? 'not-a11y'
  : findings.length > 0
    ? 'trivial'
    : 'non-trivial';

process.stdout.write(JSON.stringify({file: filePath, verdict, findings}) + '\n');
process.exit(0);
