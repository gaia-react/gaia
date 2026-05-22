import type {Meta, StoryFn} from '@storybook/react-vite';
import ErrorStack from '..';

const meta: Meta = {
  component: ErrorStack,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Components/ErrorStack',
};

export default meta;

const stack = `Unable to do something
  SyntaxError: Unexpected token (17:33)
    at constructor (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:134713:15)
    at xv.raise (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:137030:54)
    at xv.unexpected (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:137047:18)
    at xv.parseParenAndDistinguishExpression (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:142326:125)
    at xv.parseExprAtom (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:142104:23)
    at xv.parseExprAtom (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:139480:45)
    at xv.parseExprSubscripts (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141962:78)
    at xv.parseUpdate (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141952:45)
    at xv.parseMaybeUnary (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141937:20)
    at xv.parseMaybeUnary (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141232:93)
    at xv.parseMaybeUnaryOrPrivate (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141845:63)
    at xv.parseExprOps (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141848:78)
    at xv.parseMaybeConditional (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141833:78)
    at xv.parseMaybeAssign (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141817:20)
    at xv.parseMaybeAssign (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141205:22)
    at /Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141799:41
    at xv.allowInAnd (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:142786:18)
    at xv.parseMaybeAssignAllowIn (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141799:19)
    at xv.parseVar (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:143361:105)
    at xv.parseVarStatement (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:143275:32)
    at xv.parseVarStatement (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141027:33)
    at xv.parseStatementContent (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:143074:23)
    at xv.parseStatementContent (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:141050:20)
    at xv.parseStatementLike (/Users/username/Development/gaia/framework/remix/node_modules/@storybook/core/dist/babel/index.cjs:143022:69)`;

export const Default: StoryFn = () => (
  <ErrorStack
    className="max-h-96 max-w-360 overflow-y-auto"
    stack={stack}
    status={500}
    statusText="Server error"
  />
);
