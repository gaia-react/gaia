#!/usr/bin/env node
// Determinism classifier: label one touched source file STRICT (deterministic;
// goes under the RED gate) or EMERGENT (clock-/entropy-/I-O-bound or
// tree-dependent; advisory audit only, no RED proof required).
//
// Path scopes the candidate set; content decides. A file classifies STRICT only
// when ALL of conditions 1-4 hold. Failing any of 2-4 -> EMERGENT regardless of
// path. The bias is deliberate: err EMERGENT. A missed RED is caught late by the
// advisory audit; forcing RED onto non-deterministic code produces theater that
// corrupts the ledger. Over-strict is the worse failure.
//
// The rule, the versioned DOM-API allowlist, and the file-granularity limitation
// are documented in `wiki/decisions/Determinism Classifier.md`.
//
// Invocation:
//   node .gaia/scripts/classifier/classify-determinism.mjs <repo-relative-source-path>
//   ... --stdin   (read source bytes from stdin; the path arg still names the
//                  file identity for path scoping and .ts-vs-.tsx script kind)
//
// Output (stdout): one JSON object,
//   {"file":"...","classification":"strict"|"emergent","reasons":[...]}
// Exit 0 on success. Exit non-zero with a one-line stderr message on a missing
// argument, a missing `typescript`, an unreadable file, or a parse failure, so
// the bash callers can apply their own fail-open policy.

import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';

const require = createRequire(import.meta.url);

const args = process.argv.slice(2);
const useStdin = args.includes('--stdin');
const filePath = args.find((a) => !a.startsWith('--'));

if (!filePath) {
  process.stderr.write(
    'classify-determinism: missing <repo-relative-source-path> argument\n',
  );
  process.exit(2);
}

let ts;
try {
  ts = require('typescript');
} catch {
  process.stderr.write(
    'classify-determinism: cannot resolve "typescript" from node_modules\n',
  );
  process.exit(3);
}

let source;
try {
  source = useStdin ? readFileSync(0, 'utf8') : readFileSync(filePath, 'utf8');
} catch (err) {
  process.stderr.write(
    `classify-determinism: cannot read ${filePath}: ${err.message}\n`,
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
    `classify-determinism: parse failed for ${filePath}: ${err.message}\n`,
  );
  process.exit(5);
}

// createSourceFile is lenient and records syntactic diagnostics rather than
// throwing. A genuinely broken file must fail the helper so the caller can fall
// back to its own fail-open policy.
const diagnostics = sourceFile.parseDiagnostics ?? [];
if (diagnostics.length > 0) {
  const first = diagnostics[0];
  const message = ts.flattenDiagnosticMessageText(first.messageText, '\n');
  process.stderr.write(
    `classify-determinism: syntax error in ${filePath}: ${message}\n`,
  );
  process.exit(6);
}

// --- Versioned DOM-API allowlist (condition 3) --------------------------------
//
// The strict/emergent split for DOM APIs is an enumerable allowlist, not an
// inferable property. matchMedia and timers (deterministic behind fake timers)
// are STRICT; layout / observer / router-runtime APIs are EMERGENT. An unknown
// DOM API classifies EMERGENT until the allowlist is updated. The version marker
// bumps whenever an entry is added or moved between buckets, so a consumer can
// pin against a known allowlist.
const DOM_ALLOWLIST_VERSION = 1;

// Member-call names (obj.foo()) and bare global identifiers treated as
// deterministic when called from a hook. matchMedia is the canonical discrete
// DOM API; timer scheduling is deterministic under fake timers.
const DOM_STRICT_NAMES = new Set([
  'matchMedia',
  'setTimeout',
  'clearTimeout',
  'setInterval',
  'clearInterval',
]);

// DOM APIs known to depend on layout or live observation; always EMERGENT.
const DOM_LAYOUT_NAMES = new Set([
  'getBoundingClientRect',
  'getClientRects',
  'ResizeObserver',
  'IntersectionObserver',
  'MutationObserver',
]);

// react-router runtime hooks; reading them makes a hook depend on the router
// tree, so the hook is EMERGENT.
const ROUTER_RUNTIME_HOOKS = new Set([
  'useFetcher',
  'useFetchers',
  'useRouteLoaderData',
  'useLoaderData',
  'useActionData',
  'useNavigate',
  'useNavigation',
  'useLocation',
  'useParams',
  'useSearchParams',
  'useMatches',
  'useSubmit',
  'useRevalidator',
]);

// a11y helper call names. A static-markup a11y check is environment- and
// render-dependent, so these names are members of the emergent-signal set
// regardless of whether the file renders a component.
const A11Y_HELPER_NAMES = new Set(['expectNoA11yViolations', 'runAxe']);

const reasons = [];

const addReason = (reason) => {
  if (!reasons.includes(reason)) {
    reasons.push(reason);
  }
};

// --- Condition 1: path scoping + hook/non-hook discriminator ------------------

const inCandidatePath = () => {
  if (/^app\/utils\//.test(filePath)) return true;
  if (/^app\/services\//.test(filePath)) return true;
  if (/^app\/hooks\//.test(filePath)) return true;
  // A `.ts` (NOT `.tsx`) under app/components/**.
  if (/^app\/components\//.test(filePath) && !/\.tsx$/i.test(filePath)) {
    return true;
  }
  return false;
};

// A file is a hook when it exports a `use*` symbol. Detected from the source
// AST: an exported declaration (function / variable / class) whose name starts
// with `use` followed by an uppercase letter, or a `use*` name in an export
// clause / default export.
const isUseName = (name) => /^use[A-Z0-9]/.test(name);

const exportsHook = () => {
  let found = false;

  const hasExportModifier = (node) =>
    (ts.getCombinedModifierFlags?.(node) ?? 0) & ts.ModifierFlags.Export ||
    (node.modifiers ?? []).some((m) => m.kind === ts.SyntaxKind.ExportKeyword);

  const visit = (node) => {
    if (found) return;

    if (ts.isFunctionDeclaration(node) && node.name && hasExportModifier(node)) {
      if (isUseName(node.name.text)) found = true;
    } else if (ts.isClassDeclaration(node) && node.name && hasExportModifier(node)) {
      if (isUseName(node.name.text)) found = true;
    } else if (ts.isVariableStatement(node) && hasExportModifier(node)) {
      for (const decl of node.declarationList.declarations) {
        if (ts.isIdentifier(decl.name) && isUseName(decl.name.text)) {
          found = true;
        }
      }
    } else if (ts.isExportDeclaration(node) && node.exportClause) {
      if (ts.isNamedExports(node.exportClause)) {
        for (const el of node.exportClause.elements) {
          if (isUseName(el.name.text)) found = true;
        }
      }
    }

    if (!found) ts.forEachChild(node, visit);
  };

  visit(sourceFile);
  return found;
};

// --- Shared AST helpers -------------------------------------------------------

// The leftmost identifier of a property-access chain: a.b.c -> "a".
const rootIdentifierName = (expr) => {
  let cur = expr;
  while (ts.isPropertyAccessExpression(cur) || ts.isElementAccessExpression(cur)) {
    cur = cur.expression;
  }
  return ts.isIdentifier(cur) ? cur.text : null;
};

// The trailing member name of a property-access chain: a.b.c -> "c".
const memberName = (expr) =>
  ts.isPropertyAccessExpression(expr) ? expr.name.text : null;

// --- Condition 2: module-reachable non-determinism ----------------------------
//
// Reachable sites are NOT limited to the module top level. They include
// module-top-level statements, default-parameter initializers, and class-field
// initializers, each evaluated per call/instantiation when no argument is
// supplied, so each is as clock-/entropy-dependent as a top-level statement.
// The whole file is scanned for the non-determinism sources; a hit anywhere
// fails condition 2.

const checkNonDeterminism = () => {
  let failed = false;

  const flag = (reason) => {
    failed = true;
    addReason(reason);
  };

  const visit = (node) => {
    // `new Date()` with no argument is clock-dependent. `new Date(x)` is not.
    if (
      ts.isNewExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === 'Date' &&
      (node.arguments === undefined || node.arguments.length === 0)
    ) {
      flag('module-reachable new Date() (clock-dependent)');
    }

    if (ts.isCallExpression(node)) {
      const member = memberName(node.expression);
      const root = ts.isPropertyAccessExpression(node.expression)
        ? rootIdentifierName(node.expression)
        : null;

      // Date.now()
      if (root === 'Date' && member === 'now') {
        flag('module-reachable Date.now() (clock-dependent)');
      }
      // Math.random()
      if (root === 'Math' && member === 'random') {
        flag('module-reachable Math.random() (entropy-dependent)');
      }
    }

    // Any reference to the `crypto` global (crypto.randomUUID, crypto.subtle, ...).
    if (
      ts.isPropertyAccessExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === 'crypto'
    ) {
      flag('module-reachable crypto usage (entropy-dependent)');
    }

    // Top-level await: an AwaitExpression whose nearest function/method ancestor
    // does not exist (i.e. it sits at module scope or a module-scope initializer).
    if (ts.isAwaitExpression(node) && !insideFunction(node)) {
      flag('top-level await (I/O-bound at module load)');
    }

    ts.forEachChild(node, visit);
  };

  visit(sourceFile);
  return !failed;
};

// True when `node` has a function-like ancestor (arrow, function, method,
// constructor, accessor). A default-parameter or class-field initializer is NOT
// inside a function body, so its non-determinism is correctly module-reachable.
const insideFunction = (node) => {
  let cur = node.parent;
  while (cur) {
    if (
      ts.isFunctionDeclaration(cur) ||
      ts.isFunctionExpression(cur) ||
      ts.isArrowFunction(cur) ||
      ts.isMethodDeclaration(cur) ||
      ts.isConstructorDeclaration(cur) ||
      ts.isGetAccessorDeclaration(cur) ||
      ts.isSetAccessorDeclaration(cur)
    ) {
      // A default-parameter initializer is a child of a Parameter that is a
      // child of the function; the await would sit in the function's body, not
      // its signature, so being inside the function counts as a real body await.
      return true;
    }
    cur = cur.parent;
  }
  return false;
};

// --- Condition 3: hook call-surface rule (use* files only) --------------------

const checkHookSurface = () => {
  let emergent = false;

  const flag = (reason) => {
    emergent = true;
    addReason(reason);
  };

  const visit = (node) => {
    if (ts.isCallExpression(node)) {
      // Bare identifier call: useNavigate(), matchMedia(), runAxe().
      if (ts.isIdentifier(node.expression)) {
        const name = node.expression.text;
        if (ROUTER_RUNTIME_HOOKS.has(name)) {
          flag(`hook reads react-router runtime hook ${name}()`);
        } else if (A11Y_HELPER_NAMES.has(name)) {
          flag(`a11y helper ${name}() is an emergent signal`);
        } else if (DOM_LAYOUT_NAMES.has(name)) {
          flag(`hook constructs DOM-layout/observer API ${name}`);
        }
      }

      // Member call: el.getBoundingClientRect(), navigator.getBattery(),
      // globalThis.matchMedia().
      const member = memberName(node.expression);
      if (member) {
        if (DOM_LAYOUT_NAMES.has(member)) {
          flag(`hook calls DOM-layout API ${member}()`);
        } else if (isDomApiCandidate(node.expression) && !isDomStrict(member)) {
          flag(
            `hook calls DOM API ${member}() not in DOM allowlist v${DOM_ALLOWLIST_VERSION} -> unknown DOM API`,
          );
        }
      }
    }

    // `new ResizeObserver(...)` etc.
    if (
      ts.isNewExpression(node) &&
      ts.isIdentifier(node.expression) &&
      DOM_LAYOUT_NAMES.has(node.expression.text)
    ) {
      flag(`hook constructs DOM observer ${node.expression.text}`);
    }

    ts.forEachChild(node, visit);
  };

  visit(sourceFile);
  return !emergent;
};

// A member call is a DOM-API candidate when its receiver root is a recognized
// DOM/browser host: a `navigator`/`document`/`window`/`globalThis` global, or a
// value typed as an Element/HTMLElement. Without type info we treat the known
// host globals plus parameter names that read as elements; for anything we
// cannot resolve we only flag NAMED layout APIs (handled above) and otherwise
// stay silent, so a domain method call (e.g. `result.map`) is not mistaken for
// a DOM API.
const DOM_HOST_GLOBALS = new Set([
  'navigator',
  'document',
  'window',
  'globalThis',
  'screen',
]);

const isDomApiCandidate = (propAccess) => {
  if (!ts.isPropertyAccessExpression(propAccess)) return false;
  const root = rootIdentifierName(propAccess);
  return root !== null && DOM_HOST_GLOBALS.has(root);
};

const isDomStrict = (name) => DOM_STRICT_NAMES.has(name);

// --- Condition 4: no public async I/O export ----------------------------------
//
// A public (exported) async function/arrow whose body reaches a real I/O
// primitive: fetch, a Ky client call, or setTimeout-used-as-sleep (a setTimeout
// scheduled inside a returned/awaited Promise to model elapsed time). The
// setTimeout reconciling principle: STRICT when timing is the unit under test
// and fake timers make it deterministic; EMERGENT when it models real elapsed
// I/O, which a public async sleep export does.

const checkAsyncIoExport = () => {
  let emergent = false;

  const flag = (reason) => {
    emergent = true;
    addReason(reason);
  };

  const hasExportModifier = (node) =>
    (node.modifiers ?? []).some((m) => m.kind === ts.SyntaxKind.ExportKeyword);

  // Walk an exported async function-like body for I/O primitives.
  const bodyReachesIo = (fnNode) => {
    let io = false;
    const scan = (n) => {
      if (ts.isCallExpression(n)) {
        const callee = n.expression;
        if (ts.isIdentifier(callee)) {
          if (callee.text === 'fetch') io = 'fetch';
          if (callee.text === 'setTimeout') io = 'setTimeout-as-sleep';
        }
        const root = ts.isPropertyAccessExpression(callee)
          ? rootIdentifierName(callee)
          : null;
        // Ky client: ky.get(...), ky(...), api.post(...) where root is a ky-like
        // identifier. We recognize the literal `ky` import name.
        if (root === 'ky') io = 'ky';
        if (ts.isIdentifier(callee) && callee.text === 'ky') io = 'ky';
      }
      ts.forEachChild(n, scan);
    };
    if (fnNode.body) scan(fnNode.body);
    return io;
  };

  const isAsyncFn = (node) =>
    (node.modifiers ?? []).some((m) => m.kind === ts.SyntaxKind.AsyncKeyword);

  const visit = (node) => {
    if (
      ts.isFunctionDeclaration(node) &&
      isAsyncFn(node) &&
      hasExportModifier(node)
    ) {
      const io = bodyReachesIo(node);
      if (io) flag(`public async export wraps real I/O (${io})`);
    }

    // export const f = async (...) => {...}
    if (
      ts.isVariableStatement(node) &&
      node.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword)
    ) {
      for (const decl of node.declarationList.declarations) {
        const init = decl.initializer;
        if (
          init &&
          (ts.isArrowFunction(init) || ts.isFunctionExpression(init)) &&
          isAsyncFn(init)
        ) {
          const io = bodyReachesIo(init);
          if (io) flag(`public async export wraps real I/O (${io})`);
        }
      }
    }

    ts.forEachChild(node, visit);
  };

  visit(sourceFile);
  return !emergent;
};

// a11y helpers anywhere in a non-hook file are an emergent signal too: a
// static-markup a11y test under app/components/**/*.ts must not leak strict.
const checkA11ySignal = () => {
  let emergent = false;
  const visit = (node) => {
    if (
      ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      A11Y_HELPER_NAMES.has(node.expression.text)
    ) {
      emergent = true;
      addReason(`a11y helper ${node.expression.text}() is an emergent signal`);
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return !emergent;
};

// --- Classify -----------------------------------------------------------------

const emit = (classification) => {
  process.stdout.write(
    JSON.stringify({file: filePath, classification, reasons}) + '\n',
  );
  process.exit(0);
};

if (!inCandidatePath()) {
  addReason(
    'path not in app/utils, app/services, app/hooks, or a .ts under app/components',
  );
  emit('emergent');
}

const hook = exportsHook();

// Condition 2 applies to every candidate file (hooks included: a hook with a
// module-level new Date() is still clock-dependent).
const cond2 = checkNonDeterminism();

if (hook) {
  // HOOK path: condition 3 (whole-hook). Conditions 2 and the a11y signal still
  // apply; conditions 4 (public async I/O export) is folded into the hook
  // surface judgement (a hook is not an I/O service export).
  const cond3 = checkHookSurface();
  const a11yOk = checkA11ySignal();
  if (cond2 && cond3 && a11yOk) {
    emit('strict');
  }
  emit('emergent');
}

// NON-HOOK path: conditions 2 and 4, plus the a11y signal. Condition 3 is
// skipped for non-hook files.
const cond4 = checkAsyncIoExport();
const a11yOk = checkA11ySignal();

if (cond2 && cond4 && a11yOk) {
  emit('strict');
}
emit('emergent');
