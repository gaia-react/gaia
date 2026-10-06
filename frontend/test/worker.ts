import {setupWorker} from 'msw/browser';
import handlers from './mocks';

export const worker = setupWorker(...handlers);
