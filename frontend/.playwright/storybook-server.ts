import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

// Serves the built Storybook (`pnpm build-storybook`) for the story a11y scan.
// A missing build still starts the server, so the other specs run; the story
// spec is the one that fails, naming the build command. `/__ready` answers 200
// regardless, so Playwright's readiness probe never depends on the build.

const MIME_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.ico': 'image/x-icon',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf',
  '.txt': 'text/plain; charset=utf-8',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
};

const root = path.resolve(
  fileURLToPath(new URL('..', import.meta.url)),
  'storybook-static'
);
const port = Number(process.argv[2]);

if (!Number.isInteger(port) || port < 1) {
  throw new Error('Usage: tsx storybook-server.ts <port>');
}

const server = http.createServer((request, response) => {
  const {pathname} = new URL(request.url ?? '/', 'http://localhost');

  if (pathname === '/__ready') {
    response.writeHead(200).end('ok');

    return;
  }

  const requested = path.resolve(
    root,
    `.${decodeURIComponent(pathname === '/' ? '/index.html' : pathname)}`
  );

  if (!requested.startsWith(`${root}${path.sep}`)) {
    response.writeHead(403).end('forbidden');

    return;
  }

  fs.readFile(requested, (error, body) => {
    if (error) {
      response.writeHead(404).end('not found');

      return;
    }
    response
      .writeHead(200, {
        'Content-Type':
          MIME_TYPES[path.extname(requested)] ?? 'application/octet-stream',
      })
      .end(body);
  });
});

server.listen(port, '127.0.0.1');
