'use strict';

const { spawn } = require('child_process');

function collect(child) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d.toString(); });
    child.stderr.on('data', (d) => { stderr += d.toString(); });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

/** First audio stream's format, plus the container duration in seconds. */
async function probe(filePath) {
  const child = spawn('ffprobe', [
    '-v', 'error',
    '-select_streams', 'a:0',
    '-show_entries', 'stream=codec_name,sample_rate,channels:format=format_name,duration',
    '-of', 'json',
    filePath,
  ]);
  const { code, stdout, stderr } = await collect(child);
  if (code !== 0) throw new Error(`ffprobe failed (${code}): ${stderr.trim().slice(-300)}`);
  const info = JSON.parse(stdout);
  const stream = (info.streams || [])[0];
  if (!stream) throw new Error('el archivo no tiene pista de audio');
  return {
    codec: stream.codec_name,
    sampleRate: parseInt(stream.sample_rate, 10),
    channels: stream.channels,
    container: info.format && info.format.format_name,
    duration: parseFloat(info.format && info.format.duration) || null,
  };
}

/** whisper.cpp reads 16 kHz mono 16-bit PCM WAV directly; anything else needs ffmpeg. */
function isWhisperReady(p) {
  return p.container === 'wav' && p.codec === 'pcm_s16le' && p.sampleRate === 16000 && p.channels === 1;
}

function toWav(inputPath, outputPath, onSpawn) {
  const child = spawn('ffmpeg', [
    '-y', '-nostdin',
    '-i', inputPath,
    '-vn',
    '-ar', '16000',
    '-ac', '1',
    '-c:a', 'pcm_s16le',
    outputPath,
  ]);
  if (onSpawn) onSpawn(child);
  return collect(child).then(({ code, stderr }) => {
    if (code !== 0) throw new Error(`ffmpeg conversion failed (${code}): ${stderr.trim().slice(-500)}`);
  });
}

module.exports = { probe, isWhisperReady, toWav };
