'use strict';

const fs = require('fs');
const path = require('path');
const config = require('../config');

// ggml-<name>.bin, excluding the VAD model and whisper.cpp's test fixtures.
const MODEL_RE = /^ggml-(.+)\.bin$/;
const EXCLUDE_RE = /silero|^for-tests|encoder-openvino/;

/** Models currently present in MODELS_DIR. Read on every call (it's a tiny
 * directory listing) so models downloaded while the engine runs show up
 * without a restart. */
function listModels() {
  let files;
  try {
    files = fs.readdirSync(config.modelsDir);
  } catch {
    return [];
  }
  const names = new Set(files);
  return files
    .map((f) => f.match(MODEL_RE))
    .filter((m) => m && !EXCLUDE_RE.test(m[1]))
    .map((m) => ({
      id: m[1],
      path: path.join(config.modelsDir, m[0]),
      openvino: names.has(`ggml-${m[1]}-encoder-openvino.xml`),
    }))
    .sort((a, b) => a.id.localeCompare(b.id));
}

function findModel(id) {
  return listModels().find((m) => m.id === id) || null;
}

function gpuAvailable() {
  try {
    fs.accessSync(config.renderNode, fs.constants.R_OK | fs.constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

/** Whether a job on this model should try the OpenVINO GPU encoder. whisper.cpp
 * falls back to CPU on its own if init fails; the runner reports which one won. */
function wantsGpu(model) {
  if (config.device === 'cpu' || !model.openvino) return false;
  if (config.device === 'gpu') return true;
  return gpuAvailable();
}

module.exports = { listModels, findModel, gpuAvailable, wantsGpu };
