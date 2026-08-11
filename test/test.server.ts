import {setupServer} from 'msw/node';
import {afterAll, afterEach, beforeAll} from 'vitest';
import handlers from './mocks';

export const server = setupServer(...handlers);

beforeAll(() => {
  server.listen({onUnhandledRequest: 'bypass'});
});

afterEach(() => {
  server.resetHandlers();
});

afterAll(() => {
  server.close();
});
