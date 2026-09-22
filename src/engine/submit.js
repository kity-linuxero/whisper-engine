'use strict';

const config = require('../config');
const store = require('./store');
const queue = require('./queue');
const { findModel } = require('./models');
const { discard } = require('./upload');

const LANG_RE = /^(auto|[a-z]{2,3})$/;

/**
 * Validate an uploaded request and enqueue it. Shared by /v1/jobs and the
 * OpenAI-compatible endpoint. On validation errors it answers the request
 * itself and returns null.
 */
async function submit(req, res, { model: requestedModel } = {}) {
  if (!req.file) {
    res.status(400).json({ error: 'missing multipart field "file"' });
    return null;
  }
  const modelId = String(requestedModel || req.body.model || config.defaultModel).toLowerCase();
  if (!findModel(modelId)) {
    await discard(req);
    res.status(400).json({ error: `unknown model "${modelId}" (see GET /v1/models)` });
    return null;
  }
  const language = String(req.body.language || config.defaultLanguage).toLowerCase();
  if (!LANG_RE.test(language)) {
    await discard(req);
    res.status(400).json({ error: 'language must be an ISO-639-1 code (e.g. "es") or "auto"' });
    return null;
  }

  const job = store.create({
    id: req.jobId,
    model: modelId,
    language,
    inputPath: req.file.path,
    originalName: req.file.originalname,
  });
  queue.enqueue({ id: job.id });
  return job;
}

module.exports = { submit };
