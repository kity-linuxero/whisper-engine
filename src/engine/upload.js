'use strict';

const fs = require('fs');
const path = require('path');
const multer = require('multer');
const { nanoid } = require('nanoid');
const config = require('../config');
const store = require('./store');

/**
 * multer middleware for a single "file" field. The job id is minted before the
 * upload streams in, so the file lands directly in its final job directory.
 */
const upload = multer({
  storage: multer.diskStorage({
    destination(req, file, cb) {
      req.jobId = req.jobId || nanoid(12);
      const dir = store.jobDir(req.jobId);
      fs.mkdir(dir, { recursive: true }, (err) => cb(err, dir));
    },
    filename(req, file, cb) {
      const ext = path.extname(file.originalname || '').toLowerCase().replace(/[^.a-z0-9]/g, '').slice(0, 10);
      cb(null, `upload${ext}`);
    },
  }),
  limits: { fileSize: config.maxUploadMb * 1024 * 1024, files: 1 },
}).single('file');

/** Wraps multer so its errors come back as JSON with a sensible status. */
function uploadFile(req, res, next) {
  upload(req, res, (err) => {
    if (!err) return next();
    if (req.jobId) fs.promises.rm(store.jobDir(req.jobId), { recursive: true, force: true }).catch(() => {});
    if (err.code === 'LIMIT_FILE_SIZE') {
      return res.status(413).json({ error: `file exceeds MAX_UPLOAD_MB (${config.maxUploadMb} MB)` });
    }
    return res.status(400).json({ error: err.message });
  });
}

/** Discard an accepted upload when the request turns out to be invalid. */
function discard(req) {
  if (req.jobId) return fs.promises.rm(store.jobDir(req.jobId), { recursive: true, force: true });
  return Promise.resolve();
}

module.exports = { uploadFile, discard };
