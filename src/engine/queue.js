'use strict';

// Deliberately trivial single-worker FIFO: one engine = one whisper-cli at a
// time. Running two in parallel on the same CPU/iGPU only makes both slower.
const queue = [];
let busy = false;
let processFn = null;

function setProcessor(fn) {
  processFn = fn;
}

function enqueue(job) {
  queue.push(job);
  drain();
}

/** Remove a not-yet-started job from the wait list. Returns true if it was found. */
function cancelQueued(id) {
  const idx = queue.findIndex((j) => j.id === id);
  if (idx === -1) return false;
  queue.splice(idx, 1);
  return true;
}

function queueLength() {
  return queue.length;
}

function isBusy() {
  return busy;
}

/** 1-based position in the wait list, or 0 if not waiting. */
function position(id) {
  return queue.findIndex((j) => j.id === id) + 1;
}

async function drain() {
  if (busy || queue.length === 0) return;
  busy = true;
  const job = queue.shift();
  try {
    await processFn(job);
  } catch (err) {
    // processFn handles its own errors; this only keeps the queue from wedging.
    console.error('[queue] unhandled error processing job', job.id, err);
  } finally {
    busy = false;
    drain();
  }
}

module.exports = { setProcessor, enqueue, cancelQueued, queueLength, isBusy, position };
