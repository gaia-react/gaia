import {http, HttpResponse} from 'msw';
import {afterEach, describe, expect, expectTypeOf, test} from 'vitest';
import {z} from 'zod';
import {create} from '..';
// eslint-disable-next-line no-restricted-imports -- the service layer's request tests register per-test MSW handlers on the suite's node server
import {server} from '../../../../test/test.server';
import {attempt} from '../helpers';

const ORIGIN_A = 'https://api-a.test';
const ORIGIN_B = 'https://api-b.test';

const itemSchema = z.object({displayName: z.string()});
const envelopeSchema = z.object({data: itemSchema});

const originalApiUrl = process.env.API_URL;

afterEach(() => {
  process.env.API_URL = originalApiUrl;
});

describe('create', () => {
  test('resolves the schema output for a valid envelope', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.get(`${ORIGIN_A}/items`, () =>
        HttpResponse.json({data: {displayName: 'x'}})
      )
    );

    const request = create();
    const parsedEnvelope = await request('items', {schema: envelopeSchema});

    expect(parsedEnvelope).toEqual({data: {displayName: 'x'}});
    expectTypeOf(parsedEnvelope).toEqualTypeOf<{data: {displayName: string}}>();
  });

  test('a 200 body that violates the schema resolves through attempt as a 500', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.get(`${ORIGIN_A}/items`, () => HttpResponse.json({data: {nope: 1}}))
    );

    const request = create();
    const attemptOutcome = await attempt(async () =>
      request('items', {schema: envelopeSchema})
    );

    expect(attemptOutcome).toEqual([
      {status: 500, statusText: 'Response failed schema validation'},
      undefined,
    ]);
  });

  test('a plain Error thrown by the request function rejects through attempt', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(http.get(`${ORIGIN_A}/items`, () => HttpResponse.error()));

    const request = create();

    await expect(
      attempt(async () => request('items', {schema: envelopeSchema}))
    ).rejects.toThrow('Request failed due to a network error');
  });

  test('a 204 without a schema resolves undefined', async () => {
    process.env.API_URL = ORIGIN_A;
    server.use(
      http.delete(
        `${ORIGIN_A}/items/1`,
        () => new HttpResponse(null, {status: 204})
      )
    );

    const request = create();

    await expect(
      request('items/1', {method: 'delete'})
    ).resolves.toBeUndefined();
  });

  test('isSnakeCaseEnabled converts a JSON body to snake_case and the response to camelCase', async () => {
    process.env.API_URL = ORIGIN_A;
    let received: unknown;
    server.use(
      http.post(`${ORIGIN_A}/items`, async ({request}) => {
        received = await request.json();

        return HttpResponse.json({data: {display_name: 'x'}});
      })
    );

    const request = create({isSnakeCaseEnabled: true});
    const parsedEnvelope = await request('items', {
      json: {displayName: 'x'},
      method: 'post',
      schema: envelopeSchema,
    });

    expect(received).toEqual({display_name: 'x'});
    expect(parsedEnvelope.data.displayName).toBe('x');
  });

  test('leaves the body and response keys unchanged by default', async () => {
    process.env.API_URL = ORIGIN_A;
    let received: unknown;
    server.use(
      http.post(`${ORIGIN_A}/items`, async ({request}) => {
        received = await request.json();

        return HttpResponse.json({data: {displayName: 'x'}});
      })
    );

    const request = create();
    const parsedEnvelope = await request('items', {
      json: {displayName: 'x'},
      method: 'post',
      schema: envelopeSchema,
    });

    expect(received).toEqual({displayName: 'x'});
    expect(parsedEnvelope.data.displayName).toBe('x');
  });

  test('resolves the base URL on every request', async () => {
    const observed: string[] = [];
    server.use(
      http.get(`${ORIGIN_A}/items`, ({request}) => {
        observed.push(request.url);

        return HttpResponse.json({data: {displayName: 'a'}});
      }),
      http.get(`${ORIGIN_B}/items`, ({request}) => {
        observed.push(request.url);

        return HttpResponse.json({data: {displayName: 'b'}});
      })
    );

    const request = create();

    process.env.API_URL = ORIGIN_A;
    await request('items', {schema: envelopeSchema});
    process.env.API_URL = ORIGIN_B;
    await request('items', {schema: envelopeSchema});

    expect(observed).toHaveLength(2);
    expect(observed[0]).toMatch(new RegExp(`^${ORIGIN_A}`));
    expect(observed[1]).toMatch(new RegExp(`^${ORIGIN_B}`));
  });

  test('a per-request prefix overrides the default origin', async () => {
    const observed: string[] = [];
    server.use(
      http.get(`${ORIGIN_A}/items`, ({request}) => {
        observed.push(request.url);

        return HttpResponse.json({data: {displayName: 'a'}});
      }),
      http.get(`${ORIGIN_B}/items`, ({request}) => {
        observed.push(request.url);

        return HttpResponse.json({data: {displayName: 'b'}});
      })
    );
    process.env.API_URL = ORIGIN_A;

    const request = create();
    await request('items', {prefix: ORIGIN_B, schema: envelopeSchema});

    expect(observed).toHaveLength(1);
    expect(observed[0]).toMatch(new RegExp(`^${ORIGIN_B}`));
  });
});
