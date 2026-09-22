'use strict';

const { spawn } = require('child_process');
const config = require('../config');

// whisper-cli -pp prints "whisper_print_progress_callback: progress = NN%" to stderr.
const PROGRESS_RE = /progress\s*=\s*(\d+)%/;
// whisper.cpp's own log lines for OpenVINO encoder init (also on stderr).
const OPENVINO_OK_RE = /OpenVINO model loaded/;
const OPENVINO_FAIL_RE = /failed to init OpenVINO encoder/;

function buildArgs({ modelPath, language, wavPath, outPrefix, gpu }) {
  const args = [
    '-m', modelPath,
    '-l', language,
    '-f', wavPath,
    '-of', outPrefix,
    '-otxt', '-oj', '-osrt', '-ovtt',
    '-pp',
  ];
  if (config.vadModel) args.push('--vad', '--vad-model', config.vadModel);
  if (config.threads > 0) args.push('-t', String(config.threads));
  if (gpu) args.push('-oved', 'GPU');
  args.push(...config.extraArgs);
  return args;
}

/**
 * Run whisper-cli, streaming progress off stderr. Resolves with the compute
 * device that actually ran the encoder: 'GPU' if OpenVINO loaded, otherwise
 * 'CPU' (either GPU wasn't requested or OpenVINO init failed and whisper.cpp
 * silently fell back — the case that bit us when the cache dir wasn't writable).
 */
function runWhisper(opts, onProgress, { onSpawn } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(config.whisperBin, buildArgs(opts));
    if (onSpawn) onSpawn(child);
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      reject(new Error(`job timed out after ${config.maxJobMinutes} min`));
    }, config.maxJobMinutes * 60_000);

    // whisper-cli also prints the whole transcript to stdout. If nothing reads it,
    // 'close' (which waits for every stdio stream) never fires and we hang forever.
    child.stdout.resume();

    let buf = '';
    let stderrTail = '';
    let device = 'CPU';
    child.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      stderrTail = (stderrTail + text).slice(-4000);
      buf += text;
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        const m = line.match(PROGRESS_RE);
        if (m) onProgress(Math.min(100, parseInt(m[1], 10)));
        if (OPENVINO_OK_RE.test(line)) device = 'GPU';
        else if (OPENVINO_FAIL_RE.test(line)) {
          device = 'CPU';
          console.warn('[runner] OpenVINO init failed, whisper.cpp fell back to CPU:', line.trim());
        }
      }
    });
    child.on('error', (err) => { clearTimeout(timer); reject(err); });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      if (code === 0) resolve(device);
      else reject(new Error(`whisper-cli exited ${code ?? signal}: ${stderrTail.trim().slice(-500)}`));
    });
  });
}

module.exports = { runWhisper, buildArgs };
