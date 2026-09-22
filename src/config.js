'use strict';

const path = require('path');

function env(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v === '') {
    if (fallback === undefined) {
      throw new Error(`Missing required env var: ${name}`);
    }
    return fallback;
  }
  return v;
}

function int(name, fallback) {
  const n = parseInt(env(name, String(fallback)), 10);
  if (Number.isNaN(n)) throw new Error(`Env var ${name} must be an integer`);
  return n;
}

const root = path.join(__dirname, '..');

const device = env('WHISPER_DEVICE', 'auto').toLowerCase();
if (!['auto', 'cpu', 'gpu'].includes(device)) {
  throw new Error('WHISPER_DEVICE must be one of: auto, cpu, gpu');
}

const token = env('ENGINE_TOKEN');
if (token.length < 16) {
  throw new Error('ENGINE_TOKEN must be at least 16 characters (use: openssl rand -hex 32)');
}

const modelsDir = env('MODELS_DIR', path.join(root, 'models'));

module.exports = {
  host: env('HOST', '0.0.0.0'),
  port: int('PORT', 8080),
  token,
  whisperBin: env('WHISPER_BIN', '/opt/whisper.cpp/build/bin/whisper-cli'),
  modelsDir,
  vadModel: env('VAD_MODEL', path.join(modelsDir, 'ggml-silero-v5.1.2.bin')),
  jobsDir: env('JOBS_DIR', path.join(root, 'jobs')),
  defaultLanguage: env('WHISPER_LANGUAGE', 'es'),
  defaultModel: env('WHISPER_DEFAULT_MODEL', 'small'),
  device,
  // /dev/dri render node the OpenVINO GPU plugin will use; only checked in "auto" mode.
  renderNode: env('RENDER_NODE', '/dev/dri/renderD128'),
  threads: int('WHISPER_THREADS', 0), // 0 = whisper.cpp default
  extraArgs: env('WHISPER_EXTRA_ARGS', '-vmsd 20 -mc 0').split(/\s+/).filter(Boolean),
  maxUploadMb: int('MAX_UPLOAD_MB', 2048),
  maxJobMinutes: int('MAX_JOB_MINUTES', 90),
  jobTtlHours: int('JOB_TTL_HOURS', 24),
};
