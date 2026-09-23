'use strict';

const fs = require('fs');
const path = require('path');
const store = require('./store');
const queue = require('./queue');
const { probe, isWhisperReady, toWav } = require('./convert');
const { runWhisper } = require('./runner');
const { findModel, wantsGpu } = require('./models');

function removeAudio(job) {
  return Promise.all([job.inputPath, path.join(job.dir, 'input.wav')].map(
    (f) => fs.promises.rm(f, { force: true })
  ));
}

async function processJob({ id }) {
  const job = store.get(id);
  if (!job) return; // deleted while queued
  const register = (child) => {
    job.killFn = () => child.kill('SIGTERM');
    // A cancel may have landed between phases, before this child existed.
    if (job.cancelRequested) job.killFn();
  };

  try {
    store.update(id, { status: 'converting', progress: 0, started_at: new Date().toISOString() });
    const info = await probe(job.inputPath);
    store.update(id, { audio_duration: info.duration });

    let wavPath = job.inputPath;
    if (!isWhisperReady(info)) {
      wavPath = path.join(job.dir, 'input.wav');
      await toWav(job.inputPath, wavPath, register);
    }
    if (job.cancelRequested) throw new Error('cancelled');

    const model = findModel(job.model);
    if (!model) throw new Error(`model "${job.model}" is no longer available`);

    store.update(id, { status: 'transcribing', progress: 0 });
    const device = await runWhisper(
      {
        modelPath: model.path,
        language: job.language,
        wavPath,
        outPrefix: path.join(job.dir, 'output'),
        gpu: wantsGpu(model),
      },
      (pct) => { if (pct !== job.progress) store.update(id, { progress: pct }); },
      { onSpawn: register }
    );
    store.update(id, { status: 'done', progress: 100, device });
  } catch (err) {
    if (job.cancelRequested) {
      store.update(id, { status: 'cancelled', error: 'cancelled' });
    } else {
      console.error(`[job ${id}] failed:`, err.message);
      store.update(id, { status: 'failed', error: err.message });
    }
  } finally {
    job.killFn = null;
    // Privacy: audio never outlives its job. Whatever the outcome, both the
    // upload and the converted WAV are deleted; only the transcripts remain
    // (until the client DELETEs the job or JOB_TTL_HOURS expires).
    await removeAudio(job);
    if (job.deleteRequested) await store.remove(id);
  }
}

/**
 * Cancel a job and (optionally) delete it. Queued jobs are dropped immediately;
 * a running job gets SIGTERM and is cleaned up once its child actually exits.
 * Returns false if the job doesn't exist.
 */
async function cancel(id, { remove = true } = {}) {
  const job = store.get(id);
  if (!job) return false;
  if (store.TERMINAL.has(job.status)) {
    if (remove) await store.remove(id);
    return true;
  }
  if (queue.cancelQueued(id)) {
    store.update(id, { status: 'cancelled', error: 'cancelled' });
    if (remove) await store.remove(id);
    else await removeAudio(job);
    return true;
  }
  job.cancelRequested = true;
  job.deleteRequested = remove;
  if (job.killFn) job.killFn();
  return true;
}

queue.setProcessor(processJob);

module.exports = { cancel };
