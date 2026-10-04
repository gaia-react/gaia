import type {ReactRenderer} from '@storybook/react-vite';
import type {DecoratorFunction} from 'storybook/internal/types';
import {Toaster} from '~/components/ui/toast';

const ToastDecorator: DecoratorFunction<ReactRenderer> = (storyFn) => (
  <>
    {storyFn()}
    <Toaster />
  </>
);

export default ToastDecorator;
