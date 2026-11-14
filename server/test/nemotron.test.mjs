import test from 'node:test';
import assert from 'node:assert/strict';
import { createNemotron, validateInput, parseAnalysis, BASE_URL, MODEL } from '../nemotron.mjs';
import { createApp } from '../app.mjs';

const analysis = { summary: 'A reported stumble.', observations: ['The description says the person stood up.'], uncertainties: ['No direct observation is available.'] };
const token = 'development-only-test-client-token-12345';
const input = { consent: true, description: 'Synthetic example: a person stumbles and stands up.' };
const png = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1i8AAAAASUVORK5CYII=';
const completion = (overrides = {}) => new Response(JSON.stringify({ choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(analysis), reasoning_content: 'private reasoning' }, ...overrides }] }));

test('requires explicit consent and rejects remote or oversized context', () => {
  assert.throws(() => validateInput({ description: 'hello' }), { code: 'consent_required' });
  assert.throws(() => validateInput({ ...input, description: 'x'.repeat(4001) }), { code: 'invalid_description' });
  assert.throws(() => validateInput({ ...input, imageDataUrl: 'https://example.com/photo.jpg' }), { code: 'invalid_image' });
  assert.throws(() => validateInput({ ...input, imageDataUrl: 'data:image/jpeg;base64,YWJj' }), { code: 'invalid_image' });
  assert.equal(validateInput({ ...input, imageDataUrl: png }).imageDataUrl, png);
});

test('uses the supplied Nemotron endpoint, model and final-content-only contract', async () => {
  let request;
  const analyze = createNemotron({ apiKey: 'provider-test-secret', fetchImpl: async (url, options) => { request = { url, options }; return completion(); } });
  const result = await analyze(validateInput(input));
  assert.equal(request.url, `${BASE_URL}/chat/completions`);
  assert.equal(request.options.headers.Authorization, 'Bearer provider-test-secret');
  assert.equal(request.options.redirect, 'error');
  const body = JSON.parse(request.options.body);
  assert.equal(body.model, MODEL);
  assert.equal(body.max_tokens, 1024);
  assert.equal(body.chat_template_kwargs.enable_thinking, false);
  assert.equal(body.tools, undefined);
  assert.equal(result.summary, analysis.summary);
  assert.equal(result.reasoning_content, undefined);
  assert.equal(result.imageIncluded, false);
});

test('sends only validated inline image content for vision', async () => {
  const analyze = createNemotron({ apiKey: 'test', fetchImpl: async (_, options) => {
    const parts = JSON.parse(options.body).messages[1].content;
    assert.equal(parts[1].image_url.url, png);
    return completion();
  } });
  assert.equal((await analyze(validateInput({ ...input, imageDataUrl: png }))).imageIncluded, true);
});

test('replay assessment uses ordered frames and requires a boolean before it can trigger a check-in', async () => {
  assert.throws(() => validateInput({ ...input, assessCollapse: true, imageDataUrls: [png] }), { code: 'invalid_image' });
  const frames = [png, 'data:image/jpeg;base64,/9j/'];
  const replay = validateInput({ ...input, assessCollapse: true, imageDataUrls: frames });
  const analyze = createNemotron({ apiKey: 'test', fetchImpl: async (_, options) => {
    const messages = JSON.parse(options.body).messages;
    assert.match(messages[0].content, /checkInRecommended/);
    assert.deepEqual(messages[1].content.slice(1).map(part => part.image_url.url), frames);
    return completion({ message: { content: JSON.stringify({ ...analysis, checkInRecommended: false }) } });
  } });
  assert.equal((await analyze(replay)).checkInRecommended, false);
  assert.throws(() => parseAnalysis(JSON.stringify({ ...analysis, checkInRecommended: 'true' }), true),
    { code: 'invalid_model_output' });
  assert.equal(parseAnalysis(JSON.stringify({ ...analysis, checkInRecommended: true })).checkInRecommended, undefined);
});

test('multi-hazard assessment detects medical falls and open fires and routes to the right service', async () => {
  const fireInput = validateInput({ ...input, assessHazards: true, imageDataUrl: png });
  assert.equal(fireInput.assessHazards, true);
  assert.equal(fireInput.imageDataUrls.length, 1);

  const analyzeFire = createNemotron({
    apiKey: 'test',
    fetchImpl: async (_, options) => {
      const messages = JSON.parse(options.body).messages;
      assert.match(messages[0].content, /fire_department/);
      return completion({
        message: {
          content: JSON.stringify({
            summary: 'Large open fire visible ahead in the hallway.',
            observations: ['Bright orange uncontrolled flames on the floor.', 'Dense dark smoke rising.'],
            uncertainties: ['Exact heat and spread speed cannot be measured from one frame.'],
            hazardDetected: true,
            hazardType: 'fire',
            severity: 'critical',
            recommendedService: 'police', // server normalizes deterministically to fire_department
            urgentImmediate: true,
          }),
        },
      });
    },
  });
  const fireResult = await analyzeFire(fireInput);
  assert.equal(fireResult.hazardDetected, true);
  assert.equal(fireResult.hazardType, 'fire');
  assert.equal(fireResult.severity, 'critical');
  assert.equal(fireResult.recommendedService, 'fire_department');
  assert.equal(fireResult.urgentImmediate, true);
  assert.equal(fireResult.checkInRecommended, true);

  const fallParsed = parseAnalysis(JSON.stringify({
    ...analysis,
    hazardDetected: true,
    hazardType: 'medical',
    severity: 'critical',
    recommendedService: 'ambulance',
    urgentImmediate: true,
  }), { assessHazards: true });
  assert.equal(fallParsed.recommendedService, 'ambulance');
  assert.equal(fallParsed.hazardType, 'medical');

  const clearParsed = parseAnalysis(JSON.stringify({
    ...analysis,
    hazardDetected: false,
    hazardType: 'none',
    severity: 'none',
    recommendedService: 'none',
    urgentImmediate: false,
  }), { assessHazards: true });
  assert.equal(clearParsed.hazardDetected, false);
  assert.equal(clearParsed.recommendedService, 'none');
  assert.equal(clearParsed.checkInRecommended, false);
});

test('rejects truncated responses, tool calls, and malformed model JSON', async () => {
  for (const response of [
    { finish_reason: 'length' },
    { message: { content: JSON.stringify(analysis), tool_calls: [{ function: { name: 'send_alert' } }] } },
    { message: { content: 'not JSON', reasoning_content: JSON.stringify(analysis) } },
  ]) {
    const analyze = createNemotron({ apiKey: 'test', fetchImpl: async () => completion(response) });
    await assert.rejects(analyze(validateInput(input)), { status: 502 });
  }
  assert.deepEqual(parseAnalysis(JSON.stringify({ ...analysis, dispatch: true })), analysis);
});

test('sanitizes provider errors without retrying or leaking the credential', async () => {
  let count = 0;
  const analyze = createNemotron({ apiKey: 'secret-do-not-expose', fetchImpl: async () => { count++; return new Response('secret-do-not-expose', { status: 401 }); } });
  await assert.rejects(analyze(validateInput(input)), error => error.code === 'provider_unavailable' && !error.message.includes('secret-do-not-expose'));
  assert.equal(count, 1);
});

test('times out and honors client cancellation', async () => {
  const fetchImpl = (_, { signal }) => new Promise((_, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });
  // Keep a referenced timer alive: AbortSignal.timeout itself is unreferenced in Node.
  const keepAlive = setTimeout(() => {}, 1000);
  try {
    const analyze = createNemotron({ apiKey: 'test', timeoutMs: 15, fetchImpl });
    await assert.rejects(analyze(validateInput(input)), { status: 504 });
    const controller = new AbortController();
    const pending = createNemotron({ apiKey: 'test', fetchImpl })(validateInput(input), controller.signal);
    controller.abort();
    await assert.rejects(pending, { code: 'request_cancelled' });
  } finally { clearTimeout(keepAlive); }
});

async function serve(t, options = {}) {
  const server = createApp({ clientToken: token, analyze: async () => analysis, ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}`;
  return (body = input, headers = {}) => fetch(`${url}/v1/analyze`, {
    method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body),
  });
}

test('HTTP API checks auth and consent before invoking Nemotron', async t => {
  let calls = 0;
  const request = await serve(t, { analyze: async () => { calls++; return analysis; } });
  assert.equal((await request(input, { Authorization: 'Bearer wrong' })).status, 401);
  assert.equal((await request({ description: 'missing consent' })).status, 400);
  assert.equal((await request(input, { Origin: 'https://untrusted.example' })).status, 403);
  assert.equal(calls, 0);
  const response = await request();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal((await response.json()).advisoryOnly, true);
  assert.equal(calls, 1);
});

test('HTTP API enforces a bounded request rate', async t => {
  const request = await serve(t);
  for (let n = 0; n < 10; n++) assert.equal((await request()).status, 200);
  assert.equal((await request()).status, 429);
});

test('HTTP API rejects more than two simultaneous inference calls', async t => {
  const releases = [];
  const request = await serve(t, { analyze: () => new Promise(resolve => releases.push(() => resolve(analysis))) });
  const first = request();
  const second = request();
  while (releases.length < 2) await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal((await request()).status, 503);
  releases.forEach(resolve => resolve());
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
});

test('HTTP client disconnect aborts the upstream inference', async t => {
  let started;
  let stopped;
  const start = new Promise(resolve => { started = resolve; });
  const stop = new Promise(resolve => { stopped = resolve; });
  const server = createApp({ clientToken: token, analyze: async (_, signal) => {
    started();
    await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }));
    stopped();
    throw new Error('cancelled');
  } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const controller = new AbortController();
  const pending = fetch(`http://127.0.0.1:${server.address().port}/v1/analyze`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(input), signal: controller.signal,
  }).catch(() => {});
  await start;
  controller.abort();
  await Promise.race([stop, new Promise((_, reject) => {
    const timer = setTimeout(() => reject(new Error('Upstream did not abort')), 1000);
    stop.then(() => clearTimeout(timer));
  })]);
  await pending;
});
