/* eslint-disable canonical/filename-match-exported -- ESLint rule modules are named by their kebab-case rule id */
const BANNED_METHODS = new Map([
  ['ensureInfiniteQueryData', 'infiniteQuery'],
  ['ensureQueryData', 'query'],
  ['fetchInfiniteQuery', 'infiniteQuery'],
  ['fetchQuery', 'query'],
  ['prefetchInfiniteQuery', 'infiniteQuery'],
  ['prefetchQuery', 'query'],
]);

const getPropertyName = (callee) => {
  const {computed, property} = callee;

  if (!computed && property.type === 'Identifier') {
    return property.name;
  }

  if (
    computed &&
    property.type === 'Literal' &&
    typeof property.value === 'string'
  ) {
    return property.value;
  }

  return undefined;
};

/** @type {import('eslint').Rule.RuleModule} */
const noImperativeQueryFetch = {
  create: (context) => ({
    CallExpression: (node) => {
      const {callee} = node;

      if (callee.type !== 'MemberExpression') {
        return;
      }

      const method = getPropertyName(callee);
      const replacement = method && BANNED_METHODS.get(method);

      if (replacement) {
        context.report({
          data: {method, replacement},
          messageId: 'banned',
          node,
        });
      }
    },
  }),
  meta: {
    messages: {
      banned:
        '`{{method}}` is banned. Await `queryClient.{{replacement}}(options)` in a clientLoader and read the data with `useSuspenseQuery(options)` in the component.',
    },
    schema: [],
    type: 'problem',
  },
};

export default noImperativeQueryFetch;
