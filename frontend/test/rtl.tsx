import {cleanup} from '@testing-library/react';
import {afterEach} from 'vitest';
import {resetTestData} from './mocks/database';
import '../.storybook/i18next';

afterEach(async () => {
  await resetTestData();
  cleanup();
});

// re-export testing library
export * from '@testing-library/react';
