import type {
  ActionFunction,
  ActionFunctionArgs,
  LoaderFunctionArgs,
} from 'react-router';
import {createRoutesStub} from 'react-router';
import type {PartialStoryFn} from 'storybook/internal/types';
import {addons} from 'storybook/preview-api';
import {ACTION_PATHS} from '~/action-paths';

const methods = ['DELETE', 'GET', 'PATCH', 'POST', 'PUT'];
type Action = ActionFunction | SimpleAction | string;
type Method = (typeof methods)[number];

type ReactRouterDecoratorOptions = {
  action?: Action;
  loader?: (args: LoaderFunctionArgs) => Promise<unknown>;
  path?: string;
  routes?: Routes;
};

type Routes = {path: string; storyId: string}[];

type SimpleAction = Partial<Record<Method, string>>;

const channel = addons.getChannel();

const getAction = (action?: Action) => {
  if (!action) {
    return undefined;
  }

  // Simple - Any call to the action will select the story
  if (typeof action === 'string') {
    return () => {
      channel.emit('selectStory', {storyId: action});

      return null;
    };
  }

  // Advanced - Call a ReactRouter ActionFunction, and if it returns {storyId} select the story
  if (typeof action === 'function') {
    return async (args: ActionFunctionArgs) => {
      const result = await action(args);

      if (
        typeof result === 'object' &&
        result !== null &&
        'storyId' in result &&
        typeof result.storyId === 'string' &&
        result.storyId.length > 0
      ) {
        channel.emit('selectStory', {storyId: result.storyId});

        return null;
      }

      return result;
    };
  }

  // Intermediate - Assign different storyIds to different methods
  if (
    typeof action === 'object' &&
    Object.keys(action).some((key) => methods.includes(key))
  ) {
    return ({request}: ActionFunctionArgs) => {
      if (action[request.method]) {
        channel.emit('selectStory', {storyId: action[request.method]});
      }

      return null;
    };
  }

  return undefined;
};

const decorator =
  (options?: ReactRouterDecoratorOptions) => (Story: PartialStoryFn) => {
    const {action, path = '/', routes = [], ...rest} = options ?? {};

    const reactRouterStub = createRoutesStub([
      {
        action: getAction(action),
        Component: () => <Story />,
        ...rest,
        path,
      },
      // loading different routes will select different stories
      ...routes.map((route) => ({
        Component: () => <Story />,
        ...rest,
        loader: () => {
          channel.emit('selectStory', {storyId: route.storyId});

          return null;
        },
        path: route.path,
      })),
      // Every path the app submits a fetcher to. One the router cannot match
      // answers 404 and replaces the story with its error boundary, so a story
      // rendering that control fails in a way that looks unrelated to it.
      // Reading the app's own declarations is the one app dependency this file
      // takes, and it is deliberate: leaving each story to pass its own path is
      // what let this set fall behind the routes the app actually serves.
      // Dropping that module breaks every story using this decorator at import,
      // which is the loud direction to fail in next to an entry that silently
      // stops matching.
      ...Object.values(ACTION_PATHS).map((actionPath) => ({
        action: () => {},
        path: actionPath,
      })),
    ]);

    return reactRouterStub({initialEntries: [path]});
  };

export default decorator;
