// exchange-gateway - a deliberately transparent service.
// Its whole job is to show you WHERE its configuration came from, WHAT it has
// remembered, and WHO answered you - so that ConfigMaps, volumes and autoscaling
// stop being abstract.
const express = require('express');
const fs = require('fs');
const path = require('path');
const os = require('os');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;
const POD = process.env.POD_NAME || os.hostname();
const NODE = process.env.NODE_NAME || 'no cluster - just Docker';
const VERSION = process.env.APP_VERSION || 'v1';

// --- config directories, both overridable so the app runs anywhere ---
const CONFIG_DIR = process.env.CONFIG_DIR || '/etc/gateway';
const SECRET_DIR = process.env.SECRET_DIR || '/etc/gateway-secrets';
const DATA_DIR   = process.env.DATA_DIR   || '/data';

// THE KEY TRICK for Act 1:
// TICK_SIZE is read from the environment ONCE, here, at process start.
// It can never change again for the life of this pod.
const TICK_SIZE_FROM_ENV = process.env.TICK_SIZE || '(not set)';

// ...whereas this reads the SAME key from a mounted file on EVERY request.
// Edit the ConfigMap and watch only one of them move.
function tickSizeFromFile() {
  return readFileSafe(path.join(CONFIG_DIR, 'TICK_SIZE')) || '(no file mounted)';
}

function readFileSafe(p) {
  try { return fs.readFileSync(p, 'utf8').trim(); } catch { return null; }
}

function instruments() {
  const raw = readFileSafe(path.join(CONFIG_DIR, 'instruments.csv'));
  if (!raw) return [];
  return raw.split('\n').filter(Boolean).map(line => {
    const [symbol, tick] = line.split(',');
    return { symbol, tick };
  });
}

// Secrets are shown as present-or-absent and masked - never printed in full.
function secretStatus() {
  const key = readFileSafe(path.join(SECRET_DIR, 'API_KEY')) || process.env.API_KEY;
  if (!key) return { present: false, masked: null, source: null };
  return {
    present: true,
    masked: key.slice(0, 3) + '*'.repeat(Math.max(0, key.length - 6)) + key.slice(-3),
    source: readFileSafe(path.join(SECRET_DIR, 'API_KEY')) ? 'mounted file' : 'environment variable'
  };
}

// --- persisted state, for Act 2 -------------------------------------------
const ORDERS_FILE = path.join(DATA_DIR, 'orders.json');
function loadOrders() {
  try { return JSON.parse(fs.readFileSync(ORDERS_FILE, 'utf8')).count || 0; }
  catch { return 0; }
}
function saveOrders(count) {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(ORDERS_FILE, JSON.stringify({ count }));
    return true;
  } catch { return false; }
}
let orderCount = loadOrders();
const storageWritable = saveOrders(orderCount);

// --- identity, so replicas are told apart at a glance ----------------------
const COLOURS = ['#f43f5e', '#f59e0b', '#22c55e', '#3b82f6', '#a855f7', '#ec4899', '#14b8a6', '#fb923c'];
const EMOJI = ['\u{1F98A}', '\u{1F419}', '\u{1F989}', '\u{1F433}', '\u{1F984}', '\u{1F41D}', '\u{1F99C}', '\u{1F422}'];
const fp = [...POD].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) % COLOURS.length;

let healthy = true;
const startedAt = Date.now();
const ballast = [];          // memory deliberately held, for Act 3

app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/state', (req, res) => {
  res.json({
    pod: POD, node: NODE, version: VERSION,
    colour: COLOURS[fp], emoji: EMOJI[fp],
    uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
    config: {
      tickSizeFromEnv: TICK_SIZE_FROM_ENV,     // frozen at boot
      tickSizeFromFile: tickSizeFromFile(),    // re-read every request
      maxOrderSize: process.env.MAX_ORDER_SIZE || '(not set)',
      instruments: instruments()
    },
    secret: secretStatus(),
    state: { orders: orderCount, dataDir: DATA_DIR, writable: storageWritable },
    memoryHeldMb: Math.round(ballast.length * 8),
    healthy
  });
});

// Act 2: record an order, persisted to disk.
app.post('/api/order', (req, res) => {
  orderCount += 1;
  const ok = saveOrders(orderCount);
  res.json({ pod: POD, orders: orderCount, persisted: ok });
});

// Act 3: burn CPU so the HorizontalPodAutoscaler has something to react to.
app.get('/api/burn', (req, res) => {
  const ms = Math.min(parseInt(req.query.ms, 10) || 200, 2000);
  const until = Date.now() + ms;
  let n = 0;
  while (Date.now() < until) { n += Math.sqrt(n + 1); }   // deliberately wasteful
  res.json({ pod: POD, burnedMs: ms });
});

// Act 3: hold memory, to walk into an OOMKill on purpose.
app.get('/api/alloc', (req, res) => {
  const mb = Math.min(parseInt(req.query.mb, 10) || 8, 512);
  for (let i = 0; i < mb / 8; i++) ballast.push(Buffer.alloc(8 * 1024 * 1024, 1));
  res.json({ pod: POD, heldMb: Math.round(ballast.length * 8) });
});
app.get('/api/release', (req, res) => { ballast.length = 0; res.json({ pod: POD, heldMb: 0 }); });

app.get('/healthz', (req, res) => res.status(healthy ? 200 : 500).send(healthy ? 'ok' : 'unhealthy'));
app.get('/readyz', (req, res) => res.status(healthy ? 200 : 503).send(healthy ? 'ready' : 'not ready'));
app.post('/api/break', (req, res) => { healthy = false; res.json({ pod: POD, healthy }); });

const server = app.listen(PORT, () => {
  console.log(`exchange-gateway ${VERSION} listening on ${PORT} as ${POD}`);
  console.log(`  config dir ${CONFIG_DIR} | secret dir ${SECRET_DIR} | data dir ${DATA_DIR}`);
});

// PID 1 inside a container ignores SIGTERM unless we handle it ourselves.
function shutdown(sig) {
  console.log(`[${POD}] ${sig} - closing down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
