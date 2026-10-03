import {setupWorker} from 'msw/browser';
import handlers from './mocks';
import ping from './mocks/ping';

export const worker = setupWorker(ping, ...handlers);
