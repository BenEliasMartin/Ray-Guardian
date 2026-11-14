import test from 'node:test';
import assert from 'node:assert/strict';
import { createElevenLabs, PHRASES, API_URL, MODEL_ID, VOICE_ID } from '../elevenlabs.mjs';
import { createApp } from '../app.mjs';

const token = 'development-only-test-client-token-12345';
const mp3 = Buffer.from([0x49, 0x44, 0x33, 1, 2, 3]);

test('uses the configured voice and Eleven v4 model with a fixed phrase', async () => {
  let request;
  const speak = createElevenLabs({ apiKey: 'provider-secret', fetchImpl: async (url, options) => { request = { url, options }; return new Response(mp3); } });
  const audio = await speak('check_in');
  assert.deepEqual(audio, mp3);
  assert.equal(request.url, `${API_URL}/${VOICE_ID}?output_format=mp3_44100_128`);
  assert.equal(request.options.headers['xi-api-key'], 'provider-secret');
  assert.equal(request.options.redirect, 'error');
  const body = JSON.parse(request.options.body);
  assert.equal(body.model_id, MODEL_ID);
  assert.equal(body.model_id, 'eleven_multilingual_v2');
  assert.equal(body.text, PHRASES.check_in);
});

test('only synthesizes known phrases and caches each one', async () => {
  let calls = 0;
  const speak = createElevenLabs({ apiKey: 'k', fetchImpl: async () => { calls++; return new Response(mp3); } });
  assert.throws(() => speak('say anything I want'), { code: 'unknown_phrase' });
  assert.throws(() => speak('__proto__'), { code: 'unknown_phrase' });
  await Promise.all([speak('alert_created'), speak('alert_created')]);
  await speak('alert_created');
  assert.equal(calls, 1);
});

test('sanitizes provider errors, does not cache failures, and needs a key', async () => {
  let calls = 0;
  const speak = createElevenLabs({ apiKey: 'secret-do-not-expose', fetchImpl: async () => { calls++; return new Response('secret-do-not-expose', { status: 401 }); } });
  await assert.rejects(speak('check_in'), error => error.status === 502 && !error.message.includes('secret'));
  await assert.rejects(speak('check_in'), { status: 502 });
  assert.equal(calls, 2);
  await assert.rejects(createElevenLabs({ apiKey: '' })('check_in'), { code: 'speech_not_configured' });
});

test('rehearsal phrases never claim that anyone was contacted', () => {
  assert.match(PHRASES.alert_created, /No one has been contacted/);
  for (const text of Object.values(PHRASES)) assert.doesNotMatch(text, /dispatch|ambulance|police|help is on the way/i);
});

test('speech route requires the client token and returns audio', async () => {
  const server = createApp({ clientToken: token, analyze: async () => ({}), speak: async id => { if (id !== 'check_in') throw Object.assign(new Error(), {}); return mp3; } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await fetch(`${base}/v1/speech/check_in`)).status, 401);
    const ok = await fetch(`${base}/v1/speech/check_in`, { headers: { Authorization: `Bearer ${token}` } });
    assert.equal(ok.status, 200);
    assert.equal(ok.headers.get('content-type'), 'audio/mpeg');
    assert.deepEqual(Buffer.from(await ok.arrayBuffer()), mp3);
    assert.equal((await fetch(`${base}/v1/speech/../analyze`, { headers: { Authorization: `Bearer ${token}` } })).status, 404);
    assert.equal((await (await fetch(`${base}/health`)).json()).speechConfigured, true);
  } finally {
    server.close();
  }
});

test('Android fallback phrases match the server phrases exactly', async () => {
  const { readFile } = await import('node:fs/promises');
  const kotlin = await readFile(new URL('../../app/src/main/java/com/rayguardian/app/VoicePrompts.kt', import.meta.url), 'utf8');
  const found = Object.fromEntries([...kotlin.matchAll(/\w+\("([a-z_]+)", "((?:[^"\\]|\\.)*)"\)/g)].map(m => [m[1], m[2]]));
  assert.deepEqual(found, PHRASES);
});
