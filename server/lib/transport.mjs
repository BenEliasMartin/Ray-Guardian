import { ApiError } from '../nemotron.mjs';

export async function boundedBytes(response, limit) {
  const reader = response.body?.getReader();
  if (!reader) throw new ApiError(502, 'empty_provider_response', 'The provider returned no data.');
  let size = 0;
  const chunks = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) throw new ApiError(502, 'provider_response_too_large', 'The provider response exceeded the limit.');
      chunks.push(value);
    }
    return Buffer.concat(chunks);
  } catch (error) { await reader.cancel().catch(() => {}); throw error; }
}

export function httpsEndpoint(base, path) {
  const url = new URL(base);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new Error('Provider base URLs must be HTTPS without credentials, queries or fragments.');
  return url.href.replace(/\/$/, '') + path;
}

export async function providerRequest(fetchImpl, url, options, { signal, timeoutMs = 40_000, limit = 256 * 1024 } = {}) {
  try {
    const response = await fetchImpl(url, {
      ...options, redirect: 'error',
      signal: AbortSignal.any([AbortSignal.timeout(timeoutMs), ...(signal ? [signal] : [])]),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new ApiError(502, 'provider_unavailable', 'The configured provider could not complete the request.');
    }
    return { bytes: await boundedBytes(response, limit), contentType: response.headers.get('content-type') ?? '' };
  } catch (error) {
    if (signal?.aborted) throw new ApiError(499, 'request_cancelled', 'The request was cancelled.');
    if (error instanceof ApiError) throw error;
    if (['TimeoutError', 'AbortError'].includes(error.name)) throw new ApiError(504, 'provider_timeout', 'The provider took too long.');
    throw new ApiError(502, 'provider_unavailable', 'The configured provider could not complete the request.');
  }
}

export async function readBody(req, limit = 2 * 1024 * 1024) {
  const chunks = [];
  let size = 0;
  if (Number(req.headers['content-length']) > limit) throw new ApiError(413, 'body_too_large', 'Request is too large.');
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new ApiError(413, 'body_too_large', 'Request is too large.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export async function readJSON(req) {
  if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] ?? '')) throw new ApiError(415, 'json_required', 'Send application/json.');
  try { const value=JSON.parse((await readBody(req)).toString('utf8')); if(!value||typeof value!=='object'||Array.isArray(value))throw new ApiError(400,'invalid_json','Send a JSON object.'); return value; }
  catch (error) { if (error instanceof ApiError) throw error; throw new ApiError(400, 'invalid_json', 'Invalid JSON.'); }
}

export function sendJSON(res, status, body) {
  if (res.destroyed || res.writableEnded) return;
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(JSON.stringify(body));
}
