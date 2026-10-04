import {createRoutesStub} from 'react-router';
import type {ReactRenderer} from '@storybook/react-vite';
import type {DecoratorFunction} from 'storybook/internal/types';
import {Toaster} from '~/components/ui/sonner';
import {toasterProps} from '~/utils/notify';

// The vendored Toaster reads the theme through React Router hooks, so it needs
// a data router. This decorator sits outside each story's own router stub, so
// it renders the Toaster inside a router of its own. The stub is built once at
// module level so the Toaster does not remount on every story render.
const ToasterRouter = createRoutesStub([
  {Component: () => <Toaster {...toasterProps} />, path: '/'},
]);

const ToastDecorator: DecoratorFunction<ReactRenderer> = (storyFn) => (
  <>
    {storyFn()}
    <ToasterRouter initialEntries={['/']} />
  </>
);

export default ToastDecorator;
