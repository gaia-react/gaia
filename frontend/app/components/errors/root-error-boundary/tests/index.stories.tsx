import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import RootErrorBoundary from '..';

const meta: Meta = {
  component: RootErrorBoundary,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
    toaster: false,
  },
  title: 'Components/Errors/RootErrorBoundary',
};

export default meta;

type BoundaryProps = Parameters<typeof RootErrorBoundary>[0];

const createBoundaryProps = (error: unknown) =>
  ({error, params: {}}) as unknown as BoundaryProps;

export const NotFound: StoryFn = () => (
  <RootErrorBoundary
    {...createBoundaryProps({
      data: '',
      internal: true,
      status: 404,
      statusText: 'Not Found',
    })}
  />
);

export const ServerError: StoryFn = () => (
  <RootErrorBoundary
    {...createBoundaryProps(new Error('Something broke while rendering'))}
  />
);

export const Unexpected: StoryFn = () => (
  <RootErrorBoundary {...createBoundaryProps('boom')} />
);
