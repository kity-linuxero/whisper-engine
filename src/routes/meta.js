'use strict';

const express = require('express');
const config = require('../config');
const queue = require('../engine/queue');
const { listModels, gpuAvailable } = require('../engine/models');
const { version } = require('../../package.json');

/** Public: no token needed, safe to use as a container/load-balancer healthcheck. */
const health = express.Router();
health.get('/health', (req, res) => {
  res.json({
    ok: true,
    version,
    busy: queue.isBusy(),
    queue_length: queue.queueLength(),
    device: config.device,
    gpu_available: config.device !== 'cpu' && gpuAvailable(),
    models: listModels().length,
  });
});

/** Authenticated. Shape loosely follows OpenAI's GET /v1/models. */
const models = express.Router();
models.get('/models', (req, res) => {
  res.json({
    object: 'list',
    default: config.defaultModel,
    language: config.defaultLanguage,
    data: listModels().map((m) => ({ id: m.id, object: 'model', openvino: m.openvino })),
  });
});

module.exports = { health, models };
