import {http, passthrough} from 'msw';

// Used for Remix development with MSW
const REMIX_DEV_PING = new URL(
  process.env.REMIX_DEV_ORIGIN ?? 'http://localhost:3001'
);
REMIX_DEV_PING.pathname = '/ping';

const ping = http.post(REMIX_DEV_PING.href, () => passthrough());

export default ping;
