import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import RootErrorBoundary from '..';

const meta: Meta = {
  component: RootErrorBoundary,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Components/Errors/RootErrorBoundary',
};

export default meta;

type BoundaryProps = Parameters<typeof RootErrorBoundary>[0];

const boundaryProps = (error: unknown) =>
  ({error, params: {}}) as unknown as BoundaryProps;

export const NotFound: StoryFn = () => (
  <RootErrorBoundary
    {...boundaryProps({
      data: '',
      internal: true,
      status: 404,
      statusText: 'Not Found',
    })}
  />
);

export const ServerError: StoryFn = () => (
  <RootErrorBoundary
    {...boundaryProps(new Error('Something broke while rendering'))}
  />
);

export const Unexpected: StoryFn = () => (
  <RootErrorBoundary {...boundaryProps('boom')} />
);
