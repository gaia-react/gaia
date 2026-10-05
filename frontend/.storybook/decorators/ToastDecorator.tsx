import type {ReactRenderer} from '@storybook/react-vite';
import type {DecoratorFunction} from 'storybook/internal/types';
import {Toaster} from '~/components/ui/toast';

// A story that renders a whole Document sets `toaster: false`: its <html> and
// <body> take over the real document, and the Toaster portals into that body.
const ToastDecorator: DecoratorFunction<ReactRenderer> = (
  storyFn,
  {parameters}
) =>
  parameters.toaster === false ?
    storyFn()
  : <>
      {storyFn()}
      <Toaster />
    </>;

export default ToastDecorator;
