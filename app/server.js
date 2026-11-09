'use strict';

/**
 * ContainerOps Dashboard - Express server
 *
 * Exposes a small monitoring dashboard plus health, readiness and runtime
 * metadata endpoints. Designed to run as several identical replicas behind
 * an Nginx load balancer (see compose.yaml and nginx/nginx.conf).
 */

const os = require('node:os');
const path = require('node:path');
const express = require('express');

// ---------------------------------------------------------------------------
// Configuration (all values come from environment variables, never secrets)
// ---------------------------------------------------------------------------
function parsePort(value, fallback) {
  const port = Number.parseInt(value, 10);
  return Number.isInteger(port) && port > 0 && port < 65536 ? port : fallback;
}

function parsePositiveInt(value, fallback) {
  const n = Number.parseInt(value, 10);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

const config = Object.freeze({
  port: parsePort(process.env.PORT, 3000),
  host: process.env.HOST || '0.0.0.0',
  appName: process.env.APP_NAME || 'ContainerOps Dashboard',
  appEnv: process.env.APP_ENV || 'development',
  shutdownTimeoutMs: parsePositiveInt(process.env.SHUTDOWN_TIMEOUT_MS, 10000),
});

const HOSTNAME = os.hostname();
const STARTED_AT = new Date();

// Docker sets the container hostname to the first 12 hex characters of the
// container ID unless a custom hostname is configured.
const CONTAINER_ID = /^[0-9a-f]{12}$/.test(HOSTNAME) ? HOSTNAME : null;

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------
const state = {
  ready: false, // becomes true once the HTTP server is listening
  shuttingDown: false,
  requestCount: 0, // dashboard/API/static requests handled by THIS instance
  probeCount: 0, // /healthz and /readyz requests (kept separate on purpose)
};

const PROBE_PATHS = new Set(['/healthz', '/readyz']);

function status() {
  if (state.shuttingDown) return 'shutting-down';
  return state.ready ? 'healthy' : 'starting';
}

function runtimeInfo() {
  const mem = process.memoryUsage();
  return {
    hostname: HOSTNAME,
    containerId: CONTAINER_ID,
    pid: process.pid,
    uid: typeof process.getuid === 'function' ? process.getuid() : null,
    nodeVersion: process.version,
    platform: `${process.platform}/${process.arch}`,
    uptimeSeconds: Math.round(process.uptime()),
    startedAt: STARTED_AT.toISOString(),
    memoryRssMb: Math.round((mem.rss / 1024 / 1024) * 10) / 10,
  };
}

// ---------------------------------------------------------------------------
// Express application
// ---------------------------------------------------------------------------
const app = express();

app.disable('x-powered-by');
// Exactly one proxy hop (Nginx) sits in front of the app.
app.set('trust proxy', 1);

// Baseline security headers (kept dependency-free on purpose).
app.use((req, res, next) => {
  res.set({
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
    'Content-Security-Policy':
      "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " +
      "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
  });
  next();
});

// Request counter.
app.use((req, res, next) => {
  if (PROBE_PATHS.has(req.path)) {
    state.probeCount += 1;
  } else {
    state.requestCount += 1;
  }
  next();
});

// Only GET/HEAD are meaningful for this application.
app.use((req, res, next) => {
  if (req.method === 'GET' || req.method === 'HEAD') return next();
  res.set('Allow', 'GET, HEAD');
  return res.status(405).json({ error: 'Method Not Allowed' });
});

// API and probe responses must never be cached by browsers or proxies.
function noStore(req, res, next) {
  res.set('Cache-Control', 'no-store');
  next();
}

// Liveness: the process is running and the event loop is responsive.
app.get('/healthz', noStore, (req, res) => {
  res.status(200).json({
    status: 'healthy',
    hostname: HOSTNAME,
    timestamp: new Date().toISOString(),
  });
});

// Readiness: the instance is accepting traffic (false while starting/stopping).
app.get('/readyz', noStore, (req, res) => {
  const ready = state.ready && !state.shuttingDown;
  res.status(ready ? 200 : 503).json({
    status: ready ? 'ready' : 'not-ready',
    reason: ready ? undefined : status(),
    hostname: HOSTNAME,
    timestamp: new Date().toISOString(),
  });
});

app.get('/api/info', noStore, (req, res) => {
  const info = runtimeInfo();
  res.status(200).json({
    application: config.appName,
    environment: config.appEnv,
    status: status(),
    hostname: info.hostname,
    containerId: info.containerId,
    nodeVersion: info.nodeVersion,
    uptimeSeconds: info.uptimeSeconds,
    startedAt: info.startedAt,
    timestamp: new Date().toISOString(),
    requestCount: state.requestCount,
    probeCount: state.probeCount,
  });
});

app.get('/api/instances', noStore, (req, res) => {
  res.status(200).json({
    instance: {
      ...runtimeInfo(),
      status: status(),
      requestCount: state.requestCount,
    },
    request: {
      // Address of the immediate peer (the Nginx container) and the
      // original client as forwarded by Nginx.
      peerAddress: req.socket.remoteAddress,
      clientIp: req.ip,
      forwardedProto: req.get('x-forwarded-proto') || req.protocol,
      requestId: req.get('x-request-id') || null,
    },
    timestamp: new Date().toISOString(),
  });
});

// Static dashboard assets (index.html is served for "/").
app.use(
  express.static(path.join(__dirname, 'public'), {
    index: 'index.html',
    dotfiles: 'deny',
    etag: true,
    maxAge: '5m',
  }),
);

// 404 handler.
app.use((req, res) => {
  res.status(404).json({ error: 'Not Found', path: req.path });
});

// Error handler: never leak stack traces to clients.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error(`[${new Date().toISOString()}] ERROR ${req.method} ${req.path}: ${err.message}`);
  res.status(err.status || 500).json({ error: 'Internal Server Error' });
});

// ---------------------------------------------------------------------------
// Startup and graceful shutdown
// ---------------------------------------------------------------------------
const server = app.listen(config.port, config.host, () => {
  state.ready = true;
  console.log(
    `[${new Date().toISOString()}] ${config.appName} listening on ${config.host}:${config.port} ` +
      `(hostname=${HOSTNAME}, node=${process.version}, env=${config.appEnv}, uid=${runtimeInfo().uid})`,
  );
});

// Keep-alive must outlive Nginx's upstream keepalive_timeout to avoid races.
server.keepAliveTimeout = 65_000;
server.headersTimeout = 66_000;
server.requestTimeout = 30_000;

server.on('error', (err) => {
  console.error(`[${new Date().toISOString()}] Server error: ${err.message}`);
  process.exit(1);
});

function shutdown(signal) {
  if (state.shuttingDown) return;
  state.shuttingDown = true;
  state.ready = false;
  console.log(`[${new Date().toISOString()}] Received ${signal}; draining connections...`);

  // Stop accepting new connections, finish in-flight requests.
  server.close((err) => {
    if (err) {
      console.error(`[${new Date().toISOString()}] Error during shutdown: ${err.message}`);
      process.exit(1);
    }
    console.log(`[${new Date().toISOString()}] Shutdown complete.`);
    process.exit(0);
  });
  // Close idle keep-alive sockets immediately so close() can complete.
  server.closeIdleConnections();

  // Hard deadline in case connections refuse to drain.
  setTimeout(() => {
    console.error(`[${new Date().toISOString()}] Forced shutdown after ${config.shutdownTimeoutMs}ms.`);
    process.exit(1);
  }, config.shutdownTimeoutMs).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = { app, server };
