'use strict';

// Must be required before anything under src/, since config.js reads env at load time.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'whisper-engine-test-'));
const modelsDir = path.join(tmp, 'models');
fs.mkdirSync(modelsDir);
for (const f of ['ggml-small.bin', 'ggml-medium.bin', 'ggml-small-encoder-openvino.xml',
  'ggml-silero-v5.1.2.bin', 'for-tests-ggml-tiny.bin']) {
  fs.writeFileSync(path.join(modelsDir, f), '');
}

const TOKEN = 'test-token-0123456789abcdef';
Object.assign(process.env, {
  ENGINE_TOKEN: TOKEN,
  MODELS_DIR: modelsDir,
  JOBS_DIR: path.join(tmp, 'jobs'),
  WHISPER_BIN: path.join(__dirname, 'fake-whisper-cli.sh'),
  WHISPER_DEVICE: 'auto',
  RENDER_NODE: '/dev/null', // readable+writable, so "auto" sees a GPU
  JOB_TTL_HOURS: '1',
  HOST: '127.0.0.1',
  PORT: '0',
});

/** Short test clips generated with ffmpeg: a 16 kHz mono WAV (no conversion
 * needed) and an MP3 (forces the ffmpeg path). */
function makeAudio() {
  const wav = path.join(tmp, 'clip.wav');
  const mp3 = path.join(tmp, 'clip.mp3');
  const src = ['-f', 'lavfi', '-i', 'sine=frequency=440:duration=2'];
  execFileSync('ffmpeg', ['-y', '-v', 'error', ...src, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav]);
  execFileSync('ffmpeg', ['-y', '-v', 'error', ...src, mp3]);
  return { wav, mp3 };
}

async function startServer() {
  const { start } = require('../src/server');
  const server = await start();
  const base = `http://127.0.0.1:${server.address().port}`;
  return { server, base };
}

function auth(extra = {}) {
  return { Authorization: `Bearer ${TOKEN}`, ...extra };
}

async function upload(base, filePath, fields = {}, route = '/v1/jobs', headers = auth()) {
  const form = new FormData();
  form.append('file', await fs.openAsBlob(filePath), path.basename(filePath));
  for (const [k, v] of Object.entries(fields)) form.append(k, v);
  return fetch(base + route, { method: 'POST', body: form, headers });
}

async function waitFor(base, id, statuses = ['done', 'failed', 'cancelled'], timeoutMs = 10_000) {
  const t0 = Date.now();
  for (;;) {
    const r = await fetch(`${base}/v1/jobs/${id}`, { headers: auth() });
    const j = await r.json();
    if (statuses.includes(j.status)) return j;
    if (Date.now() - t0 > timeoutMs) throw new Error(`timeout waiting for ${statuses}: ${JSON.stringify(j)}`);
    await new Promise((r2) => setTimeout(r2, 25));
  }
}

module.exports = { tmp, TOKEN, makeAudio, startServer, auth, upload, waitFor };
