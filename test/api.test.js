'use strict';

const h = require('./helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

let server;
let base;
let audio;

before(async () => {
  audio = h.makeAudio();
  ({ server, base } = await h.startServer());
});

after(() => {
  server.close();
  fs.rmSync(h.tmp, { recursive: true, force: true });
});

test('health is public and reports the engine state', async () => {
  const r = await fetch(`${base}/health`);
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.ok, true);
  assert.equal(j.version, require('../package.json').version);
  assert.equal(j.models, 2);
});

test('every /v1 route requires the bearer token', async () => {
  for (const headers of [{}, { Authorization: 'Bearer wrong' }, { Authorization: h.TOKEN }]) {
    const r = await fetch(`${base}/v1/models`, { headers });
    assert.equal(r.status, 401);
  }
  const r = await h.upload(base, audio.wav, {}, '/v1/jobs', {});
  assert.equal(r.status, 401);
});

test('models lists only real models, flagging OpenVINO IR', async () => {
  const j = await (await fetch(`${base}/v1/models`, { headers: h.auth() })).json();
  assert.deepEqual(j.data.map((m) => [m.id, m.openvino]), [['medium', false], ['small', true]]);
  assert.equal(j.default, 'small');
  assert.equal(j.language, 'es');
});

test('job lifecycle: upload wav, progress, done, results in every format, delete', async () => {
  const r = await h.upload(base, audio.wav, { model: 'small' });
  assert.equal(r.status, 202);
  const { id, status } = await r.json();
  // The queue picks the job up synchronously when idle, so it may already be converting.
  assert.ok(['queued', 'converting'].includes(status), status);

  const job = await h.waitFor(base, id);
  assert.equal(job.status, 'done');
  assert.equal(job.progress, 100);
  assert.equal(job.device, 'GPU'); // small has an OpenVINO IR and RENDER_NODE is accessible
  assert.equal(job.language, 'es');
  assert.ok(Math.abs(job.audio_duration - 2) < 0.1);
  assert.equal(job.inputPath, undefined, 'internal fields must not leak');

  const args = fs.readFileSync(path.join(h.tmp, 'jobs', id, 'output.args'), 'utf8');
  assert.match(args, /-vmsd 20 -mc 0/);
  assert.match(args, /--vad-model/);

  const txt = await fetch(`${base}/v1/jobs/${id}/result?format=txt`, { headers: h.auth() });
  assert.equal(txt.status, 200);
  assert.match(await txt.text(), /Hola mundo/);
  for (const format of ['json', 'srt', 'vtt']) {
    const res = await fetch(`${base}/v1/jobs/${id}/result?format=${format}`, { headers: h.auth() });
    assert.equal(res.status, 200, format);
  }
  const bad = await fetch(`${base}/v1/jobs/${id}/result?format=docx`, { headers: h.auth() });
  assert.equal(bad.status, 400);

  const del = await fetch(`${base}/v1/jobs/${id}`, { method: 'DELETE', headers: h.auth() });
  assert.equal(del.status, 204);
  assert.equal((await fetch(`${base}/v1/jobs/${id}`, { headers: h.auth() })).status, 404);
  assert.equal(fs.existsSync(path.join(h.tmp, 'jobs', id)), false);
});

test('non-WAV input is converted with ffmpeg; model without IR runs on CPU', async () => {
  const r = await h.upload(base, audio.mp3, { model: 'medium', language: 'auto' });
  const { id } = await r.json();
  const job = await h.waitFor(base, id);
  assert.equal(job.status, 'done');
  assert.equal(job.device, 'CPU');
  assert.ok(fs.existsSync(path.join(h.tmp, 'jobs', id, 'input.wav')));
  assert.equal(fs.existsSync(path.join(h.tmp, 'jobs', id, 'upload.mp3')), false, 'upload removed after conversion');
  await fetch(`${base}/v1/jobs/${id}`, { method: 'DELETE', headers: h.auth() });
});

test('validation: unknown model, bad language, missing file', async () => {
  let r = await h.upload(base, audio.wav, { model: 'large-v9' });
  assert.equal(r.status, 400);
  r = await h.upload(base, audio.wav, { language: 'español' });
  assert.equal(r.status, 400);
  r = await fetch(`${base}/v1/jobs`, { method: 'POST', headers: h.auth(), body: new FormData() });
  assert.equal(r.status, 400);
  // Rejected uploads leave nothing behind.
  assert.deepEqual(fs.readdirSync(path.join(h.tmp, 'jobs')), []);
});

test('result before done is 409', async () => {
  process.env.FAKE_STEP_DELAY = '0.3';
  try {
    const { id } = await (await h.upload(base, audio.wav)).json();
    const r = await fetch(`${base}/v1/jobs/${id}/result`, { headers: h.auth() });
    assert.equal(r.status, 409);
    await fetch(`${base}/v1/jobs/${id}`, { method: 'DELETE', headers: h.auth() });
  } finally {
    delete process.env.FAKE_STEP_DELAY;
  }
});

test('FIFO: one job at a time; deleting a running job kills it and the next one starts', async () => {
  process.env.FAKE_STEP_DELAY = '0.4';
  try {
    const a = await (await h.upload(base, audio.wav)).json();
    const b = await (await h.upload(base, audio.wav)).json();
    const c = await (await h.upload(base, audio.wav)).json();

    await h.waitFor(base, a.id, ['transcribing']);
    const bNow = await (await fetch(`${base}/v1/jobs/${b.id}`, { headers: h.auth() })).json();
    assert.equal(bNow.status, 'queued');
    assert.equal(bNow.queue_position, 1);

    // Delete a queued job: gone immediately.
    assert.equal((await fetch(`${base}/v1/jobs/${c.id}`, { method: 'DELETE', headers: h.auth() })).status, 204);
    assert.equal((await fetch(`${base}/v1/jobs/${c.id}`, { headers: h.auth() })).status, 404);

    // Delete the running job: killed, then b takes over.
    assert.equal((await fetch(`${base}/v1/jobs/${a.id}`, { method: 'DELETE', headers: h.auth() })).status, 204);
    await h.waitFor(base, b.id, ['transcribing']);
    assert.equal((await fetch(`${base}/v1/jobs/${a.id}`, { headers: h.auth() })).status, 404);
    assert.equal(fs.existsSync(path.join(h.tmp, 'jobs', a.id)), false);
    await fetch(`${base}/v1/jobs/${b.id}`, { method: 'DELETE', headers: h.auth() });
    await new Promise((r) => setTimeout(r, 200));
  } finally {
    delete process.env.FAKE_STEP_DELAY;
  }
});

test('whisper-cli failure marks the job failed with its stderr', async () => {
  process.env.FAKE_FAIL = '1';
  try {
    const { id } = await (await h.upload(base, audio.wav)).json();
    const job = await h.waitFor(base, id);
    assert.equal(job.status, 'failed');
    assert.match(job.error, /exited 3.*boom/s);
    await fetch(`${base}/v1/jobs/${id}`, { method: 'DELETE', headers: h.auth() });
  } finally {
    delete process.env.FAKE_FAIL;
  }
});

test('OpenAI-compatible endpoint: json, verbose_json, text, srt; unknown model maps to default', async () => {
  const route = '/v1/audio/transcriptions';
  let r = await h.upload(base, audio.wav, { model: 'whisper-1' }, route);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { text: 'Hola mundo. Segunda linea.' });

  r = await h.upload(base, audio.wav, { response_format: 'verbose_json' }, route);
  const v = await r.json();
  assert.equal(v.language, 'es');
  assert.equal(v.segments.length, 2);
  assert.equal(v.segments[1].end, 3.5);

  r = await h.upload(base, audio.wav, { response_format: 'text' }, route);
  assert.equal(await r.text(), 'Hola mundo. Segunda linea.\n');

  r = await h.upload(base, audio.wav, { response_format: 'srt' }, route);
  assert.match(await r.text(), /00:00:00,000 --> 00:00:02,000/);

  r = await h.upload(base, audio.wav, { response_format: 'docx' }, route);
  assert.equal(r.status, 400);

  // Sync jobs clean up after themselves once the response is sent.
  await new Promise((res) => setTimeout(res, 100));
  const list = await (await fetch(`${base}/v1/jobs`, { headers: h.auth() })).json();
  assert.deepEqual(list.data, []);
});

test('TTL sweep removes old finished jobs only', async () => {
  const store = require('../src/engine/store');
  const { id } = await (await h.upload(base, audio.wav)).json();
  await h.waitFor(base, id);
  assert.equal(await store.sweep(Date.now()), 0);
  assert.equal(await store.sweep(Date.now() + 2 * 3600_000), 1);
  assert.equal((await fetch(`${base}/v1/jobs/${id}`, { headers: h.auth() })).status, 404);
});
