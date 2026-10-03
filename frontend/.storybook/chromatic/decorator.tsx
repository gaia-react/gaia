import type {ReactRenderer} from '@storybook/react-vite';
import type {DecoratorFunction} from 'storybook/internal/types';

const ChromaticDecorator: DecoratorFunction<ReactRenderer> = (
  storyFn,
  {parameters}
) => {
  // sessionStorage carries over between snapshots so in order to
  // have consistent story snapshots, is necessary to clear the sessionStorage
  // before each snapshot is taken
  sessionStorage.clear();

  return (
    <>
      <div
        className="relative bg-white text-gray-900"
        style={{
          minHeight: parameters.chromatic?.excludeDark ? '100vh' : '50vh',
        }}
      >
        {storyFn()}
      </div>
      {!parameters.chromatic?.excludeDark && (
        <div
          className="dark relative bg-gray-900 text-white"
          style={{minHeight: '50vh'}}
        >
          {storyFn()}
        </div>
      )}
    </>
  );
};

export default ChromaticDecorator;
