import type {ReactRenderer} from '@storybook/react-vite';
import type {DecoratorFunction} from 'storybook/internal/types';

const WrapDecorator: DecoratorFunction<ReactRenderer> = (
  storyFn,
  {parameters}
) =>
  parameters.wrap ?
    <div className={parameters.wrap as string}>{storyFn()}</div>
  : storyFn();

export default WrapDecorator;
