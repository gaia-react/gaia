import type {ReactRenderer} from '@storybook/react-vite';
import type {DecoratorFunction} from 'storybook/internal/types';
import Toast from '~/components/Toast';

const ToastDecorator: DecoratorFunction<ReactRenderer> = (storyFn) => (
  <>
    {storyFn()}
    <Toast />
  </>
);

export default ToastDecorator;
