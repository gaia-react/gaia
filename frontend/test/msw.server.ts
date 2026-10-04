/* eslint-disable @typescript-eslint/naming-convention,no-underscore-dangle,vars-on-top,no-console */
// noinspection ES6ConvertVarToLetConst

import type {SetupServer} from 'msw/node';
import {setupServer} from 'msw/node';
import {EventEmitter} from 'node:events';
import handlers from './mocks';

// Increase the default max listeners to avoid warnings
EventEmitter.defaultMaxListeners = 15;

declare global {
  var __MSW_SERVER: SetupServer | undefined;
}

const setup = () => {
  const server = setupServer(...handlers);

  globalThis.__MSW_SERVER = server;

  return server;
};

const start = (server: SetupServer) => {
  server.listen({onUnhandledRequest: 'bypass'});

  process.once('SIGTERM', () => {
    server.close();
  });
  process.once('SIGINT', () => {
    server.close();
  });

  console.info('\u001B[31m', '\n[MSW] Mocking enabled\n', '\u001B[0m');
};

const restart = (server: SetupServer) => {
  server.close();
  start(setup());
};

export const startApiMocks = () => {
  const persistedServer = globalThis.__MSW_SERVER;

  if (persistedServer === undefined) {
    start(setup());
  } else {
    restart(persistedServer);
  }
};
