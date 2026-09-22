'use strict';

const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');
const config = require('../config');

// Jobs live only in memory, plus one directory per job under JOBS_DIR. The
// engine is deliberately stateless across restarts: clients (e.g. whisper-idep)
// keep their own history and treat a 404 on a known id as "engine restarted".
const jobs = new Map();
const events = new EventEmitter();
events.setMaxListeners(0);

const TERMINAL = new Set(['done', 'failed', 'cancelled']);

function jobDir(id) {
  return path.join(config.jobsDir, id);
}

function create({ id, model, language, inputPath, originalName }) {
  const job = {
    id,
    status: 'queued',
    progress: 0,
    model,
    language,
    device: null,
    error: null,
    original_name: originalName || null,
    audio_duration: null,
    created_at: new Date().toISOString(),
    started_at: null,
    finished_at: null,
    // internal
    inputPath,
    dir: jobDir(id),
  };
  jobs.set(id, job);
  return job;
}

function get(id) {
  return jobs.get(id) || null;
}

function all() {
  return [...jobs.values()];
}

function update(id, fields) {
  const job = jobs.get(id);
  if (!job) return null;
  Object.assign(job, fields);
  if (TERMINAL.has(job.status) && !job.finished_at) {
    job.finished_at = new Date().toISOString();
  }
  if (TERMINAL.has(job.status)) events.emit('settled', job);
  return job;
}

/** Forget the job and delete its files. */
async function remove(id) {
  jobs.delete(id);
  await fs.promises.rm(jobDir(id), { recursive: true, force: true });
}

/** Public JSON shape — hides internal paths. */
function view(job, extra = {}) {
  const { inputPath, dir, cancelRequested, deleteRequested, killFn, ...pub } = job;
  return { ...pub, ...extra };
}

/** Resolves once the job reaches a terminal state. */
function waitSettled(id) {
  const job = jobs.get(id);
  if (!job) return Promise.reject(new Error('job not found'));
  if (TERMINAL.has(job.status)) return Promise.resolve(job);
  return new Promise((resolve) => {
    const onSettled = (j) => {
      if (j.id !== id) return;
      events.off('settled', onSettled);
      resolve(j);
    };
    events.on('settled', onSettled);
  });
}

/** Delete finished jobs older than JOB_TTL_HOURS, in case the client never called DELETE. */
async function sweep(now = Date.now()) {
  const cutoff = now - config.jobTtlHours * 3600_000;
  const expired = all().filter(
    (j) => TERMINAL.has(j.status) && j.finished_at && Date.parse(j.finished_at) < cutoff
  );
  for (const j of expired) await remove(j.id);
  return expired.length;
}

/** On startup, any job directory on disk is an orphan from a previous run. */
async function purgeOrphans() {
  await fs.promises.mkdir(config.jobsDir, { recursive: true });
  const entries = await fs.promises.readdir(config.jobsDir);
  for (const e of entries) {
    if (!jobs.has(e)) await fs.promises.rm(path.join(config.jobsDir, e), { recursive: true, force: true });
  }
  return entries.length;
}

module.exports = {
  TERMINAL, jobDir, create, get, all, update, remove, view, waitSettled, sweep, purgeOrphans,
};
