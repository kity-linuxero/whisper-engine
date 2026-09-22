'use strict';

const crypto = require('crypto');
const config = require('./config');

const expected = crypto.createHash('sha256').update(config.token).digest();

/** Bearer-token check. Both sides are hashed first so timingSafeEqual always
 * compares equal-length buffers, regardless of what the client sent. */
function requireToken(req, res, next) {
  const header = req.get('authorization') || '';
  const m = header.match(/^Bearer\s+(.+)$/i);
  const given = crypto.createHash('sha256').update(m ? m[1].trim() : '').digest();
  if (m && crypto.timingSafeEqual(given, expected)) return next();
  res.set('WWW-Authenticate', 'Bearer');
  return res.status(401).json({ error: 'unauthorized' });
}

module.exports = { requireToken };
