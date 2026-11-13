import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { ApiError, validateInput } from './nemotron.mjs';

const MAX_BODY = 1100 * 1024;

function authorized(header, token) {
  const received = Buffer.from(header ?? '');
  const expected = Buffer.from(`Bearer ${token}`);
  return received.length === expected.length && timingSafeEqual(received, expected);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_BODY) {
        req.pause();
        reject(new ApiError(413, 'body_too_large', 'The submitted context is too large.'));
      } else chunks.push(chunk);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(new ApiError(400, 'invalid_json', 'Invalid JSON request.')); }
    });
    req.on('error', () => reject(new ApiError(400, 'invalid_request', 'The request could not be read.')));
  });
}

export function createApp({ analyze, speak, clientToken, configured = true, speechConfigured = Boolean(speak), now = Date.now }) {
  if (!clientToken || clientToken.length < 32) throw new Error('Set RAY_GUARDIAN_CLIENT_TOKEN to at least 32 characters.');
  let inFlight = 0;
  let windowStart = now();
  let requestsInWindow = 0;
  const server = createServer(async (req, res) => {
    const reply = (status, data) => {
      if (res.destroyed) return;
      res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff', 'Connection': 'close',
      });
      res.end(JSON.stringify(data));
    };
    if (req.url === '/health' && req.method === 'GET') return reply(200, { status: 'ok', aiConfigured: configured, speechConfigured });
    const speech = /^\/v1\/speech\/([a-z_]{1,40})$/.exec(req.url ?? '');
    if (speech && req.method === 'GET') {
      if (!authorized(req.headers.authorization, clientToken)) return reply(401, { error: 'unauthorized' });
      if (req.headers.origin) return reply(403, { error: 'browser_origin_not_allowed' });
      try {
        if (!speak) throw new ApiError(503, 'speech_not_configured', 'Speech is not configured.');
        const audio = await speak(speech[1]);
        if (res.destroyed) return;
        res.writeHead(200, {
          'Content-Type': 'audio/mpeg', 'Content-Length': audio.length, 'Cache-Control': 'no-store',
          'X-Content-Type-Options': 'nosniff', 'Connection': 'close',
        });
        return res.end(audio);
      } catch (error) {
        if (error instanceof ApiError) return reply(error.status, { error: error.code, message: error.message });
        return reply(500, { error: 'internal_error', message: 'Speech could not be generated.' });
      }
    }
    if (req.url !== '/v1/analyze' || req.method !== 'POST') return reply(404, { error: 'not_found' });
    if (!authorized(req.headers.authorization, clientToken)) return reply(401, { error: 'unauthorized' });
    if (req.headers.origin) return reply(403, { error: 'browser_origin_not_allowed' });
    if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] ?? '')) return reply(415, { error: 'json_required' });
    const abort = new AbortController();
    res.on('close', () => { if (!res.writableFinished) abort.abort(); });
    let counted = false;
    try {
      if (Number(req.headers['content-length']) > MAX_BODY) throw new ApiError(413, 'body_too_large', 'The submitted context is too large.');
      const input = validateInput(await readJson(req));
      if (abort.signal.aborted) return;
      if (now() - windowStart >= 60_000) { windowStart = now(); requestsInWindow = 0; }
      if (requestsInWindow >= 10) throw new ApiError(429, 'rate_limited', 'Limit reached. Wait a minute before retrying.');
      if (inFlight >= 2) throw new ApiError(503, 'busy', 'The AI server is busy. Try again shortly.');
      requestsInWindow++;
      inFlight++;
      counted = true;
      const analysis = await analyze(input, abort.signal);
      reply(200, { ...analysis, advisoryOnly: true });
    } catch (error) {
      if (error instanceof ApiError) reply(error.status, { error: error.code, message: error.message });
      else reply(500, { error: 'internal_error', message: 'The analysis could not be completed.' });
    } finally {
      if (counted) inFlight--;
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.timeout = 55_000;
  return server;
}
