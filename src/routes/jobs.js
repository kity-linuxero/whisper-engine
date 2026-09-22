'use strict';

const express = require('express');
const store = require('../engine/store');
const queue = require('../engine/queue');
const { cancel } = require('../engine/processor');
const { uploadFile } = require('../engine/upload');
const { submit } = require('../engine/submit');
const { FORMATS, resultPath } = require('../engine/formats');

const router = express.Router();

function withPosition(job) {
  return store.view(job, { queue_position: queue.position(job.id) });
}

router.post('/jobs', uploadFile, async (req, res, next) => {
  try {
    const job = await submit(req, res);
    if (!job) return;
    res.status(202).location(`/v1/jobs/${job.id}`).json(withPosition(job));
  } catch (err) {
    next(err);
  }
});

router.get('/jobs', (req, res) => {
  res.json({ data: store.all().map(withPosition) });
});

router.get('/jobs/:id', (req, res) => {
  const job = store.get(req.params.id);
  if (!job) return res.status(404).json({ error: 'job not found' });
  res.json(withPosition(job));
});

router.get('/jobs/:id/result', (req, res) => {
  const job = store.get(req.params.id);
  if (!job) return res.status(404).json({ error: 'job not found' });
  const format = String(req.query.format || 'txt');
  if (!FORMATS[format]) {
    return res.status(400).json({ error: `format must be one of: ${Object.keys(FORMATS).join(', ')}` });
  }
  if (job.status !== 'done') {
    return res.status(409).json({ error: `job is ${job.status}`, status: job.status });
  }
  res.type(FORMATS[format].type);
  res.sendFile(resultPath(job, format), (err) => {
    if (err && !res.headersSent) res.status(404).json({ error: 'result file missing' });
  });
});

router.delete('/jobs/:id', async (req, res, next) => {
  try {
    const found = await cancel(req.params.id, { remove: true });
    if (!found) return res.status(404).json({ error: 'job not found' });
    res.status(204).end();
  } catch (err) {
    next(err);
  }
});

module.exports = router;
