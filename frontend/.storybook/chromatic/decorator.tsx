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

  // The wrapper fills the viewport; with the dark pane present the two panes
  // split it evenly, otherwise the light pane takes all of it.
  return (
    <div className="flex min-h-screen flex-col">
      <div className="bg-background text-foreground relative flex-1">
        {storyFn()}
      </div>
      {!parameters.chromatic?.excludeDark && (
        <div className="dark bg-background text-foreground relative flex-1">
          {storyFn()}
        </div>
      )}
    </div>
  );
};

export default ChromaticDecorator;
