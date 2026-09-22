'use strict';

const fs = require('fs');
const path = require('path');

// Files written by whisper-cli -otxt -oj -osrt -ovtt with -of <dir>/output.
const FORMATS = {
  txt: { file: 'output.txt', type: 'text/plain; charset=utf-8' },
  json: { file: 'output.json', type: 'application/json; charset=utf-8' },
  srt: { file: 'output.srt', type: 'application/x-subrip; charset=utf-8' },
  vtt: { file: 'output.vtt', type: 'text/vtt; charset=utf-8' },
};

function resultPath(job, format) {
  return path.join(job.dir, FORMATS[format].file);
}

async function readText(job) {
  const raw = await fs.promises.readFile(resultPath(job, 'txt'), 'utf8');
  // whisper-cli writes one segment per line; OpenAI's "text" is a single string.
  return raw.split('\n').map((l) => l.trim()).filter(Boolean).join(' ');
}

/** OpenAI-style verbose_json, built from whisper.cpp's own -oj output. */
async function readVerbose(job) {
  const raw = JSON.parse(await fs.promises.readFile(resultPath(job, 'json'), 'utf8'));
  const segments = (raw.transcription || []).map((s, i) => ({
    id: i,
    start: s.offsets.from / 1000,
    end: s.offsets.to / 1000,
    text: s.text.trim(),
  }));
  return {
    task: 'transcribe',
    language: (raw.result && raw.result.language) || job.language,
    duration: job.audio_duration,
    text: segments.map((s) => s.text).join(' '),
    segments,
  };
}

module.exports = { FORMATS, resultPath, readText, readVerbose };
