'use strict';

/**
 * Container HEALTHCHECK probe.
 *
 * Uses Node's built-in http module so the runtime image does not need curl
 * or wget. Exits 0 when GET /healthz returns HTTP 200, otherwise exits 1.
 */

const http = require('node:http');

const port = Number.parseInt(process.env.PORT, 10) || 3000;
const timeoutMs = 3000;

const req = http.get(
  { host: '127.0.0.1', port, path: '/healthz', timeout: timeoutMs },
  (res) => {
    res.resume(); // discard body
    process.exit(res.statusCode === 200 ? 0 : 1);
  },
);

req.on('timeout', () => {
  req.destroy(new Error('timeout'));
});

req.on('error', (err) => {
  console.error(`healthcheck failed: ${err.message}`);
  process.exit(1);
});
