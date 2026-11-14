import { createServer } from 'node:http';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { ApiError } from '../server/nemotron.mjs';
import { createDispatchStore, DEFAULT_TEST_LOCATION, validateBriefingRequest } from '../server/dispatch.mjs';
import { createSimulatedDispatch } from '../server/simulated-dispatch.mjs';
import { PHRASES, validatePhrase } from '../server/elevenlabs.mjs';

const root = path.dirname(fileURLToPath(import.meta.url));
const localClip = path.join(root, '../captures/browser-pov.mp4');
const defaultClip = process.env.SIMULATOR_VIDEO ?? (existsSync(localClip) ? localClip : path.join(root, 'demo-pov.mp4'));
const defaultPort = Number(process.env.SIMULATOR_PORT ?? 4173);
const defaultAiPort = Number(process.env.PORT ?? 8787);

const files = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/style.css', ['style.css', 'text/css; charset=utf-8']],
]);

function reply(res, status, data) {
  if (res.destroyed) return;
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(data));
}

async function readBody(req, maxBytes) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) throw new ApiError(413, 'body_too_large', 'Request is too large.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export function createSimulatorServer({
  port = defaultPort,
  aiPort = defaultAiPort,
  clip = defaultClip,
  clientToken = () => process.env.RAY_GUARDIAN_CLIENT_TOKEN ?? '',
} = {}) {
  const localDispatch = createDispatchStore({ defaultLocation: DEFAULT_TEST_LOCATION });
  const localSimulatedDispatch = createSimulatedDispatch();

  const server = createServer(async (req, res) => {
    const boundPort = server.address()?.port ?? port;
    res.setHeader('X-Content-Type-Options', 'nosniff');
    if (!['127.0.0.1', 'localhost'].some(host => req.headers.host === `${host}:${boundPort}`)) {
      return reply(res, 403, { message: 'Local access only.' });
    }
    const validOrigin = [`http://127.0.0.1:${boundPort}`, `http://localhost:${boundPort}`].includes(req.headers.origin);
    const url = new URL(req.url, `http://127.0.0.1:${boundPort}`);
    const token = typeof clientToken === 'function' ? clientToken() : (clientToken ?? '');

    if (url.pathname === '/api/health' && req.method === 'GET') {
      try {
        const upstream = await fetch(`http://127.0.0.1:${aiPort}/health`, { signal: AbortSignal.timeout(2_500) });
        if (upstream.ok) {
          const data = await upstream.json();
          return reply(res, 200, { backendOnline: true, ...data });
        }
      } catch {
        // Backend offline; simulator still runs standalone with local dispatch and browser TTS fallback.
      }
      return reply(res, 200, { backendOnline: false, aiConfigured: false, speechConfigured: false, dispatchConfigured: true });
    }

    const speechMatch = /^\/api\/speech\/([a-z_]{1,40})$/.exec(url.pathname);
    if (speechMatch && req.method === 'GET') {
      const phraseId = speechMatch[1];
      try {
        validatePhrase(phraseId);
      } catch {
        return reply(res, 404, { message: 'Unknown speech phrase.' });
      }
      try {
        const upstream = await fetch(`http://127.0.0.1:${aiPort}/v1/speech/${phraseId}`, {
          signal: AbortSignal.timeout(15_000),
          headers: { Authorization: `Bearer ${token}` },
        });
        if (upstream.ok && (upstream.headers.get('content-type') ?? '').startsWith('audio/mpeg')) {
          const audio = Buffer.from(await upstream.arrayBuffer());
          if (!res.destroyed) {
            res.writeHead(200, {
              'Content-Type': 'audio/mpeg',
              'Content-Length': audio.length,
              'Cache-Control': 'no-store',
            });
            res.end(audio);
          }
          return;
        }
      } catch {
        // Fall through to 503 with fallback text for browser speechSynthesis.
      }
      return reply(res, 503, { message: 'ElevenLabs backend unavailable; using local voice fallback.', fallbackText: PHRASES[phraseId] });
    }

    if (['/api/analyze', '/api/dispatch', '/api/simulated-dispatch', '/api/speech/briefing'].includes(url.pathname) && req.method === 'POST') {
      if (!validOrigin) return reply(res, 403, { message: 'Invalid origin.' });
      const controller = new AbortController();
      res.on('close', () => { if (!res.writableFinished) controller.abort(); });

      try {
        const maxBytes = url.pathname === '/api/analyze' ? 1100 * 1024 : 16 * 1024;
        const body = await readBody(req, maxBytes);

        if (url.pathname === '/api/simulated-dispatch') {
          let parsed;
          try { parsed = JSON.parse(body.toString('utf8')); }
          catch { return reply(res, 400, { message: 'Invalid incident report.' }); }
          try {
            return reply(res, 200, localSimulatedDispatch(parsed));
          } catch (error) {
            if (error instanceof ApiError) return reply(res, error.status, { error: error.code, message: error.message });
            return reply(res, 400, { message: 'Invalid incident report.' });
          }
        }

        if (url.pathname === '/api/dispatch') {
          let parsed;
          try { parsed = JSON.parse(body.toString('utf8')); }
          catch { return reply(res, 400, { message: 'Invalid incident report.' }); }
          let localReceipt;
          try {
            localReceipt = localDispatch.record(parsed);
          } catch (error) {
            if (error instanceof ApiError) return reply(res, error.status, { error: error.code, message: error.message });
            return reply(res, 400, { message: 'Invalid incident report.' });
          }
          try {
            const upstream = await fetch(`http://127.0.0.1:${aiPort}/v1/dispatch`, {
              method: 'POST',
              signal: AbortSignal.any([controller.signal, AbortSignal.timeout(4_000)]),
              headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
              body,
            });
            if (upstream.ok) return reply(res, 200, await upstream.json());
          } catch {
            // Standalone simulator dispatch succeeds even when AI server is stopped.
          }
          return reply(res, 200, localReceipt);
        }

        if (url.pathname === '/api/speech/briefing') {
          let parsed;
          try { parsed = JSON.parse(body.toString('utf8')); }
          catch { return reply(res, 400, { message: 'Invalid briefing request.' }); }
          let script;
          try {
            script = validateBriefingRequest(parsed, localDispatch.get);
          } catch (error) {
            if (error instanceof ApiError) return reply(res, error.status, { error: error.code, message: error.message });
            return reply(res, 400, { message: 'Invalid briefing request.' });
          }
          const stored = parsed.incidentId ? localDispatch.get(parsed.incidentId) : null;
          const upstreamPayload = stored
            ? {
                service: stored.service,
                hazardType: stored.hazardType,
                trigger: stored.trigger,
                location: stored.location,
                context: stored.context ?? undefined,
                heartRateBpm: stored.heartRateBpm ?? undefined,
              }
            : parsed;
          try {
            const upstream = await fetch(`http://127.0.0.1:${aiPort}/v1/speech/briefing`, {
              method: 'POST',
              signal: AbortSignal.any([controller.signal, AbortSignal.timeout(22_000)]),
              headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
              body: JSON.stringify(upstreamPayload),
            });
            if (upstream.ok && (upstream.headers.get('content-type') ?? '').startsWith('audio/mpeg')) {
              const audio = Buffer.from(await upstream.arrayBuffer());
              if (!res.destroyed) {
                res.writeHead(200, {
                  'Content-Type': 'audio/mpeg',
                  'Content-Length': audio.length,
                  'Cache-Control': 'no-store',
                });
                res.end(audio);
              }
              return;
            }
          } catch {
            // Fall through to 503 with script text so browser TTS speaks it immediately.
          }
          return reply(res, 503, { message: 'ElevenLabs briefing unavailable; using local voice.', fallbackText: script });
        }

        const upstream = await fetch(`http://127.0.0.1:${aiPort}/v1/analyze`, {
          method: 'POST',
          signal: AbortSignal.any([controller.signal, AbortSignal.timeout(48_000)]),
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
          body,
        });
        const data = await upstream.json();
        if (!res.destroyed) reply(res, upstream.status, data);
      } catch (error) {
        if (error instanceof ApiError) return reply(res, error.status, { message: error.message });
        if (!res.destroyed) reply(res, 502, { message: 'AI backend unavailable. Start npm --prefix server start.' });
      }
      return;
    }

    if (url.pathname === '/clip.mp4' && ['GET', 'HEAD'].includes(req.method)) {
      try {
        const { size } = statSync(clip);
        const match = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range ?? '');
        let start = 0;
        let end = size - 1;
        if (match) {
          start = Number(match[1]);
          end = match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
          if (start > end || start >= size) {
            res.writeHead(416, { 'Content-Range': `bytes */${size}` });
            return res.end();
          }
        }
        res.writeHead(match ? 206 : 200, {
          'Content-Type': 'video/mp4',
          'Accept-Ranges': 'bytes',
          'Content-Length': end - start + 1,
          'Cache-Control': 'no-store',
          ...(match ? { 'Content-Range': `bytes ${start}-${end}/${size}` } : {}),
        });
        if (req.method === 'HEAD') return res.end();
        createReadStream(clip, { start, end }).on('error', () => res.destroy()).pipe(res);
      } catch {
        reply(res, 404, { message: 'Add a clip with Choose video, or prepare captures/browser-pov.mp4.' });
      }
      return;
    }

    const file = files.get(url.pathname);
    if (file && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': file[1], 'Cache-Control': 'no-store' });
      return createReadStream(path.join(root, file[0])).pipe(res);
    }
    reply(res, 404, { message: 'Not found.' });
  });

  return server;
}

if (path.resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  const server = createSimulatorServer();
  server.listen(defaultPort, '127.0.0.1', () => {
    console.log(`Ray Guardian browser simulator: http://localhost:${defaultPort}`);
  });
}
