'use strict';

const express = require('express');
const config = require('../config');
const store = require('../engine/store');
const { cancel } = require('../engine/processor');
const { findModel } = require('../engine/models');
const { uploadFile } = require('../engine/upload');
const { submit } = require('../engine/submit');
const { resultPath, readText, readVerbose } = require('../engine/formats');

const router = express.Router();

const RESPONSE_FORMATS = ['json', 'text', 'srt', 'vtt', 'verbose_json'];

/**
 * OpenAI-compatible, synchronous transcription (Buzz, openai SDKs, etc.).
 * Goes through the same FIFO queue as /v1/jobs and holds the connection open
 * until done — fine for short audio; for long meetings use /v1/jobs, since
 * proxies and client SDKs tend to time out long-held requests.
 */
router.post('/audio/transcriptions', uploadFile, async (req, res, next) => {
  try {
    const format = String(req.body.response_format || 'json');
    if (!RESPONSE_FORMATS.includes(format)) {
      return res.status(400).json({ error: { message: `response_format must be one of: ${RESPONSE_FORMATS.join(', ')}` } });
    }
    // OpenAI clients send model names like "whisper-1": anything we don't have
    // maps to the default model instead of failing.
    const requested = String(req.body.model || '').toLowerCase();
    const model = findModel(requested) ? requested : config.defaultModel;

    const job = await submit(req, res, { model });
    if (!job) return;

    // One cleanup path for every outcome: once the response is over (sent, or
    // the client gave up mid-wait) the job is cancelled if needed and deleted.
    res.on('close', () => { cancel(job.id, { remove: true }).catch(() => {}); });

    const done = await store.waitSettled(job.id);
    if (res.writableEnded || res.destroyed) return;
    if (done.status !== 'done') {
      return res.status(500).json({ error: { message: done.error || `job ${done.status}` } });
    }

    if (format === 'json') res.json({ text: await readText(done) });
    else if (format === 'verbose_json') res.json(await readVerbose(done));
    else if (format === 'text') res.type('text/plain').send(`${await readText(done)}\n`);
    else res.type(format === 'srt' ? 'application/x-subrip' : 'text/vtt').sendFile(resultPath(done, format));
  } catch (err) {
    next(err);
  }
});

module.exports = router;
