import type {
  ActionFunction,
  ActionFunctionArgs,
  LoaderFunctionArgs,
} from 'react-router';
import {createRoutesStub} from 'react-router';
import type {ReactRenderer} from '@storybook/react-vite';
import type {
  DecoratorFunction,
  PartialStoryFn,
  StoryContext,
} from 'storybook/internal/types';
import {addons} from 'storybook/preview-api';
import {ACTION_PATHS} from '~/action-paths';

const methods = ['DELETE', 'GET', 'PATCH', 'POST', 'PUT'] as const;
type Action = ActionFunction | SimpleAction | string;
type Method = (typeof methods)[number];

type ReactRouterDecoratorOptions = {
  action?: Action;
  /** Per-path action. Overrides the no-op ACTION_PATHS entry for the same path; adds a route for a path not in ACTION_PATHS. */
  actions?: Record<string, ActionFunction>;
  /** Each path renders `Navigated to {path}` inside a main landmark, so a play can assert arrival by visible text. */
  destinations?: string[];
  loader?: (args: LoaderFunctionArgs) => Promise<unknown>;
  path?: string;
  routes?: Routes;
};

type Routes = {path: string; storyId: string}[];

type SimpleAction = Partial<Record<Method, string>>;

const channel = addons.getChannel();

const isMethod = (key: string): key is Method =>
  (methods as readonly string[]).includes(key);

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
    Object.keys(action).some((key) => isMethod(key))
  ) {
    return ({request}: ActionFunctionArgs) => {
      const {method} = request;

      if (isMethod(method) && action[method]) {
        channel.emit('selectStory', {storyId: action[method]});
      }

      return null;
    };
  }

  return undefined;
};

const decorator =
  (
    options?:
      | ((context: StoryContext) => ReactRouterDecoratorOptions)
      | ReactRouterDecoratorOptions
  ): DecoratorFunction<ReactRenderer> =>
  (Story: PartialStoryFn, context: StoryContext) => {
    const resolvedOptions =
      typeof options === 'function' ? options(context) : options;
    const {
      action,
      actions = {},
      destinations = [],
      path = '/',
      routes = [],
      ...rest
    } = resolvedOptions ?? {};

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
      ...Object.values(ACTION_PATHS)
        .filter((actionPath) => !(actionPath in actions))
        .map((actionPath) => ({
          action: () => {},
          path: actionPath,
        })),
      ...Object.entries(actions).map(([actionPath, pathAction]) => ({
        action: pathAction,
        path: actionPath,
      })),
      ...destinations.map((destination) => ({
        Component: () => (
          <main>
            <p>Navigated to {destination}</p>
          </main>
        ),
        path: destination,
      })),
    ]);

    return reactRouterStub({initialEntries: [path]});
  };

export default decorator;
