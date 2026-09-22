'use strict';

const express = require('express');
const config = require('./config');
const store = require('./engine/store');
const { requireToken } = require('./auth');
const { listModels } = require('./engine/models');
const { health, models } = require('./routes/meta');
const jobsRouter = require('./routes/jobs');
const openaiRouter = require('./routes/openai');
const { version } = require('../package.json');

function createApp() {
  const app = express();
  app.disable('x-powered-by');
  app.use(health);
  app.use('/v1', requireToken, models, jobsRouter, openaiRouter);
  app.use((req, res) => res.status(404).json({ error: 'not found' }));
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    console.error('[http] unhandled error:', err);
    if (!res.headersSent) res.status(500).json({ error: 'internal error' });
  });
  return app;
}

async function start() {
  const purged = await store.purgeOrphans();
  if (purged) console.warn(`[startup] removed ${purged} orphaned job dir(s) from a previous run`);
  setInterval(() => {
    store.sweep().then((n) => { if (n) console.log(`[sweep] removed ${n} expired job(s)`); })
      .catch((err) => console.error('[sweep] failed:', err));
  }, 10 * 60_000).unref();

  const found = listModels();
  if (!found.length) console.warn(`[startup] no models found in ${config.modelsDir}`);
  else console.log(`[startup] models: ${found.map((m) => `${m.id}${m.openvino ? '(openvino)' : ''}`).join(', ')}`);

  const app = createApp();
  return new Promise((resolve) => {
    const server = app.listen(config.port, config.host, () => {
      console.log(`whisper-engine ${version} listening on ${config.host}:${config.port} (device=${config.device})`);
      resolve(server);
    });
    // Uploads of long recordings can take a while on slow links.
    server.requestTimeout = 0;
  });
}

if (require.main === module) {
  start().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { createApp, start };
