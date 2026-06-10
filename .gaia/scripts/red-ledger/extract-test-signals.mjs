#!/usr/bin/env node
// Extract per-test (fullName, content signal) pairs from a vitest/jest test
// file, for the RED-observation ledger.
//
// A RED observation binds to a test by (file, fullName, signal). The signal
// lets the commit gate invalidate a RED once the test body changes: a fresh
// failing run must then be observed. vitest's --reporter=json emits
// location: null for every assertion, so the signal cannot come from the
// reporter. It is derived here, from the test file source.
//
// Invocation:
//   node .gaia/scripts/red-ledger/extract-test-signals.mjs <repo-relative-test-path>
//   ... --stdin   (read source bytes from stdin instead of disk)
//
// Output (stdout): one JSON object per discovered test(...)/it(...) call,
// newline-delimited:
//   {"fullName":"...","signal":"sha256:...","kind":"runtime"|"type-only"}
// Exit 0 on success (even when zero tests are found; emits nothing).
// Exit non-zero with a one-line stderr message on a parse failure.
//
// fullName: the titles of all enclosing describe(...) blocks (outermost
// first) plus the test's own title, single-space-joined. Matches vitest's
// fullName: top-level test('foo') -> "foo"; describe('a', describe('b',
// test('c'))) -> "a b c".
//
// signal: "sha256:" + lowercase-hex sha256 of the NORMALIZED source text of
// the whole test call expression (from the test/it identifier through the
// matching close paren). Normalization: trim leading/trailing whitespace,
// then collapse every internal run of whitespace to a single space. Stable
// under pure reformatting; changes when the title, assertion, or body
// changes.
//
// kind: "type-only" when the test's assertions are all type-level (an
// expectTypeOf(...)/assertType(...) call, or a `@ts-expect-error` proof
// directive) AND it carries no runtime assertion (expect(...)/assert(...));
// "runtime" otherwise. A type-only test has no runtime failure mode, so the
// RED-verification commit gate has no runtime red-green to demand from it and
// exempts it, delegating type correctness to the `tsc` Quality Gate step. The
// predicate requires a positive type-level signal and defaults to "runtime"
// (enforce) when unsure, so a no-assertion test is never silently exempted.

import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';

const require = createRequire(import.meta.url);

const args = process.argv.slice(2);
const useStdin = args.includes('--stdin');
const filePath = args.find((a) => !a.startsWith('--'));

if (!filePath) {
  process.stderr.write(
    'extract-test-signals: missing <repo-relative-test-path> argument\n',
  );
  process.exit(2);
}

let ts;
try {
  ts = require('typescript');
} catch {
  process.stderr.write(
    'extract-test-signals: cannot resolve "typescript" from node_modules\n',
  );
  process.exit(3);
}

let source;
try {
  if (useStdin) {
    source = readFileSync(0, 'utf8');
  } else {
    source = readFileSync(filePath, 'utf8');
  }
} catch (err) {
  process.stderr.write(
    `extract-test-signals: cannot read ${filePath}: ${err.message}\n`,
  );
  process.exit(4);
}

const scriptKind = /\.tsx$/i.test(filePath)
  ? ts.ScriptKind.TSX
  : ts.ScriptKind.TS;

let sourceFile;
try {
  sourceFile = ts.createSourceFile(
    filePath,
    source,
    ts.ScriptTarget.Latest,
    /* setParentNodes */ true,
    scriptKind,
  );
} catch (err) {
  process.stderr.write(
    `extract-test-signals: parse failed for ${filePath}: ${err.message}\n`,
  );
  process.exit(5);
}

// createSourceFile is lenient and records syntactic diagnostics rather than
// throwing. A genuinely broken file must fail the helper so the caller can
// fall back to fail-open (capture) / fail-closed-but-named (check).
const diagnostics = sourceFile.parseDiagnostics ?? [];
if (diagnostics.length > 0) {
  const first = diagnostics[0];
  const message = ts.flattenDiagnosticMessageText(first.messageText, '\n');
  process.stderr.write(
    `extract-test-signals: syntax error in ${filePath}: ${message}\n`,
  );
  process.exit(6);
}

// Resolve a call-expression callee to its bare identifier name, ignoring
// chained modifiers (test.each(...)(...), it.concurrent(...), describe.skip).
// Returns the base name: 'test', 'it', 'describe', or null.
function baseCalleeName(node) {
  let expr = node.expression;
  // Unwrap a call-of-a-call (test.each(table)('name', fn)).
  while (ts.isCallExpression(expr)) {
    expr = expr.expression;
  }
  // Walk down a property-access chain to its leftmost identifier.
  while (ts.isPropertyAccessExpression(expr)) {
    expr = expr.expression;
  }
  if (ts.isIdentifier(expr)) {
    return expr.text;
  }
  return null;
}

// The first string-literal/template title argument of a test/describe call.
// Returns the literal text, or null when the title is dynamic (template with
// substitutions, an identifier, etc.); a dynamic title cannot be matched to
// a recorded fullName, so we skip it.
function titleOf(node) {
  const arg = node.arguments[0];
  if (!arg) {
    return null;
  }
  if (ts.isStringLiteral(arg) || ts.isNoSubstitutionTemplateLiteral(arg)) {
    return arg.text;
  }
  return null;
}

const TEST_NAMES = new Set(['test', 'it']);
const DESCRIBE_NAMES = new Set(['describe', 'suite']);

// Runtime assertions give a test a runtime failure mode (a RED). Type-level
// proofs do not: they are evaluated by tsc, never by the test runner.
const RUNTIME_ASSERTION_NAMES = new Set(['expect', 'assert']);
const TYPE_ASSERTION_NAMES = new Set(['expectTypeOf', 'assertType']);

// A `@ts-expect-error` directive is itself a type-level proof: the build fails
// if the next line does NOT error. Matched only when anchored to a comment
// opener on the same line, so a string literal that merely contains the token
// is not a false signal. `@ts-ignore` is blanket suppression, not a proof, so
// it is deliberately NOT treated as a type-only signal.
const TS_EXPECT_ERROR_DIRECTIVE = /(?:\/\/|\/\*)[^\n]*@ts-expect-error\b/;

function normalize(text) {
  return text.trim().replace(/\s+/g, ' ');
}

function signalFor(node) {
  const text = node.getText(sourceFile);
  const normalized = normalize(text);
  const hex = createHash('sha256').update(normalized, 'utf8').digest('hex');
  return `sha256:${hex}`;
}

// Resolve the root identifier of a (possibly chained) call expression's
// callee: expect(x).toBe(y) -> "expect"; expectTypeOf<T>().toEqualTypeOf<U>()
// -> "expectTypeOf"; assert.equal(...) -> "assert". Unwraps call, property-
// access, element-access, non-null, and parenthesized layers. Returns null
// when the callee root is not a bare identifier.
function rootCallName(callNode) {
  let expr = callNode.expression;
  for (;;) {
    if (ts.isCallExpression(expr)) {
      expr = expr.expression;
    } else if (ts.isPropertyAccessExpression(expr)) {
      expr = expr.expression;
    } else if (ts.isElementAccessExpression(expr)) {
      expr = expr.expression;
    } else if (ts.isNonNullExpression(expr)) {
      expr = expr.expression;
    } else if (ts.isParenthesizedExpression(expr)) {
      expr = expr.expression;
    } else {
      break;
    }
  }
  return ts.isIdentifier(expr) ? expr.text : null;
}

// Classify a test as "type-only" or "runtime" by inspecting its argument
// subtrees (title + callback body). Type-only = at least one type-level proof
// and zero runtime assertions. Defaults to "runtime" (enforce) when unsure, so
// a test with no assertions at all is never silently exempted from the gate.
function classifyKind(testNode) {
  let runtime = 0;
  let typeLevel = 0;

  const scan = (node) => {
    if (ts.isCallExpression(node)) {
      const name = rootCallName(node);
      if (name && RUNTIME_ASSERTION_NAMES.has(name)) {
        runtime += 1;
      } else if (name && TYPE_ASSERTION_NAMES.has(name)) {
        typeLevel += 1;
      }
    }
    ts.forEachChild(node, scan);
  };

  for (const arg of testNode.arguments) {
    scan(arg);
  }

  if (
    typeLevel === 0 &&
    TS_EXPECT_ERROR_DIRECTIVE.test(testNode.getText(sourceFile))
  ) {
    typeLevel += 1;
  }

  return runtime === 0 && typeLevel > 0 ? 'type-only' : 'runtime';
}

const lines = [];

function visit(node, ancestors) {
  if (ts.isCallExpression(node)) {
    const name = baseCalleeName(node);
    if (name && TEST_NAMES.has(name)) {
      const title = titleOf(node);
      if (title !== null) {
        const fullName = [...ancestors, title].join(' ');
        lines.push(
          JSON.stringify({
            fullName,
            signal: signalFor(node),
            kind: classifyKind(node),
          }),
        );
      }
      // A test call never nests further test/describe blocks worth tracking;
      // still descend in case of unusual nesting, but without pushing a title.
      ts.forEachChild(node, (child) => visit(child, ancestors));
      return;
    }
    if (name && DESCRIBE_NAMES.has(name)) {
      const title = titleOf(node);
      const nextAncestors =
        title !== null ? [...ancestors, title] : ancestors;
      ts.forEachChild(node, (child) => visit(child, nextAncestors));
      return;
    }
  }
  ts.forEachChild(node, (child) => visit(child, ancestors));
}

visit(sourceFile, []);

if (lines.length > 0) {
  process.stdout.write(lines.join('\n') + '\n');
}
process.exit(0);
