import { createServer } from 'node:http';
import { createReadStream, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const clip = process.env.SIMULATOR_VIDEO ?? path.join(root, '../captures/browser-pov.mp4');
const port = Number(process.env.SIMULATOR_PORT ?? 4173);
const aiPort = Number(process.env.PORT ?? 8787);
const receipts = new Map();
const testLocation = 'Helsinki demo point · 60.1699, 24.9384';
const files = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/style.css', ['style.css', 'text/css; charset=utf-8']],
]);

function reply(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(data));
}

const server = createServer(async (req, res) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  if (!['127.0.0.1', 'localhost'].some(host => req.headers.host === `${host}:${port}`)) {
    return reply(res, 403, { message: 'Local access only.' });
  }
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  if (['/api/analyze', '/api/dispatch'].includes(url.pathname) && req.method === 'POST') {
    const origin = req.headers.origin;
    if (![`http://127.0.0.1:${port}`, `http://localhost:${port}`].includes(origin)) return reply(res, 403, { message: 'Invalid origin.' });
    const isDispatch = url.pathname === '/api/dispatch';
    try {
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > (isDispatch ? 8192 : 1100 * 1024)) return reply(res, 413, { message: 'Request is too large.' });
        chunks.push(chunk);
      }
      const body = Buffer.concat(chunks);
      if (isDispatch) {
        let report;
        try { report = JSON.parse(body.toString('utf8')); }
        catch { return reply(res, 400, { message: 'Invalid incident report.' }); }
        if (typeof report?.id !== 'string' ||
            !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(report.id) ||
            !['staged-collapse', 'ai-check-in', 'manual-sos'].includes(report.trigger) ||
            (report.context != null && (typeof report.context !== 'string' || report.context.length > 1000))) {
          return reply(res, 400, { message: 'Invalid incident report.' });
        }
        let receipt = receipts.get(report.id);
        if (!receipt) {
          receipt = {
            callId: `SIM-${report.id.slice(0, 8).toUpperCase()}`,
            status: 'simulated-accepted',
            location: testLocation,
            trigger: report.trigger,
            receivedAt: new Date().toISOString(),
          };
          receipts.set(report.id, receipt);
          if (receipts.size > 200) receipts.delete(receipts.keys().next().value);
        }
        if (report.context) receipt.context = report.context;
        const { context, ...metadata } = receipt;
        return reply(res, 200, { ...metadata, contextIncluded: Boolean(context) });
      }
      const controller = new AbortController();
      res.on('close', () => { if (!res.writableFinished) controller.abort(); });
      const upstream = await fetch(`http://127.0.0.1:${aiPort}/v1/analyze`, {
        method: 'POST', signal: AbortSignal.any([controller.signal, AbortSignal.timeout(48_000)]),
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${process.env.RAY_GUARDIAN_CLIENT_TOKEN ?? ''}` },
        body,
      });
      const data = await upstream.json();
      if (!res.destroyed) reply(res, upstream.status, data);
    } catch {
      if (!res.destroyed) reply(res, 502, { message: isDispatch ? 'Test dispatch is unavailable.' : 'AI backend unavailable. Start npm --prefix server start.' });
    }
    return;
  }
  if (url.pathname === '/clip.mp4' && ['GET', 'HEAD'].includes(req.method)) {
    try {
      const { size } = statSync(clip);
      const match = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range ?? '');
      let start = 0, end = size - 1;
      if (match) {
        start = Number(match[1]); end = match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
        if (start > end || start >= size) { res.writeHead(416, { 'Content-Range': `bytes */${size}` }); return res.end(); }
      }
      res.writeHead(match ? 206 : 200, {
        'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1,
        'Cache-Control': 'no-store', ...(match ? { 'Content-Range': `bytes ${start}-${end}/${size}` } : {}),
      });
      if (req.method === 'HEAD') return res.end();
      createReadStream(clip, { start, end }).on('error', () => res.destroy()).pipe(res);
    } catch { reply(res, 404, { message: 'Add a clip with Choose video, or prepare captures/browser-pov.mp4.' }); }
    return;
  }
  const file = files.get(url.pathname);
  if (file && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': file[1], 'Cache-Control': 'no-store' });
    return createReadStream(path.join(root, file[0])).pipe(res);
  }
  reply(res, 404, { message: 'Not found.' });
});
server.listen(port, '127.0.0.1', () => console.log(`Ray Guardian browser feed: http://localhost:${port}`));
