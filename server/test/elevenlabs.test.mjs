import test from 'node:test';
import assert from 'node:assert/strict';
import { createElevenLabs, PHRASES, API_URL, MODEL_ID, VOICE_ID, validateBriefingText } from '../elevenlabs.mjs';
import { createApp } from '../app.mjs';

const token = 'development-only-test-client-token-12345';
const mp3 = Buffer.from([0x49, 0x44, 0x33, 1, 2, 3]);
const incidentId = '123e4567-e89b-42d3-a456-426614174000';

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
  assert.equal(body.model_id, 'eleven_v4');
  assert.equal(body.text, PHRASES.check_in);
});

test('only synthesizes known fixed phrases and caches each one', async () => {
  let calls = 0;
  const speak = createElevenLabs({ apiKey: 'k', fetchImpl: async () => { calls++; return new Response(mp3); } });
  assert.throws(() => speak('say anything I want'), { code: 'unknown_phrase' });
  assert.throws(() => speak('__proto__'), { code: 'unknown_phrase' });
  await Promise.all([speak('alert_created'), speak('alert_created')]);
  await speak('alert_created');
  assert.equal(calls, 1);
});

test('synthesizes and caches dynamic emergency briefings by text hash', async () => {
  let calls = 0;
  let lastBody = null;
  const speak = createElevenLabs({
    apiKey: 'k',
    fetchImpl: async (_, options) => {
      calls++;
      lastBody = JSON.parse(options.body);
      return new Response(mp3);
    },
  });
  const script = 'Automated Ray Guardian emergency call for Fire and Rescue Services. Hazard detected: large open fire.';
  const [first, second] = await Promise.all([speak.briefing(script), speak.briefing(script)]);
  assert.deepEqual(first, mp3);
  assert.deepEqual(second, mp3);
  assert.equal(calls, 1);
  assert.equal(lastBody.model_id, 'eleven_v4');
  assert.equal(lastBody.text, script);
  assert.throws(() => validateBriefingText(''), { code: 'invalid_briefing_text' });
  assert.throws(() => validateBriefingText('x'.repeat(651)), { code: 'invalid_briefing_text' });
});

test('sanitizes provider errors, does not cache failures, and needs a key', async () => {
  let calls = 0;
  const speak = createElevenLabs({ apiKey: 'secret-do-not-expose', fetchImpl: async () => { calls++; return new Response('secret-do-not-expose', { status: 401 }); } });
  await assert.rejects(speak('check_in'), error => error.status === 502 && !error.message.includes('secret'));
  await assert.rejects(speak('check_in'), { status: 502 });
  assert.equal(calls, 2);
  await assert.rejects(createElevenLabs({ apiKey: '' })('check_in'), { code: 'speech_not_configured' });
  await assert.rejects(createElevenLabs({ apiKey: '' }).briefing('Test briefing'), { code: 'speech_not_configured' });
});

test('rehearsal phrase stays honest and hazard phrases match their services', () => {
  assert.equal(Object.keys(PHRASES).length, 13);
  assert.match(PHRASES.alert_created, /demo emergency alert/);
  assert.match(PHRASES.hazard_medical, /Ambulance Services/);
  assert.match(PHRASES.hazard_trembling, /Ambulance Services/);
  assert.match(PHRASES.hazard_crash, /Ambulance Services/);
  assert.match(PHRASES.hazard_fire, /Fire Department/);
  assert.match(PHRASES.hazard_police, /Police Services/);
  assert.match(PHRASES.calling_ambulance, /Ambulance Services/);
  assert.match(PHRASES.calling_fire_department, /Fire Department/);
  assert.match(PHRASES.calling_police, /Police Services/);
});

test('speech routes require the client token and serve both fixed phrases and structured briefings', async () => {
  let synthesizedScript = '';
  const speak = async id => {
    if (!Object.hasOwn(PHRASES, id)) throw Object.assign(new Error(), {});
    return mp3;
  };
  speak.briefing = async script => {
    synthesizedScript = script;
    return mp3;
  };
  const server = createApp({ clientToken: token, analyze: async () => ({}), speak });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await fetch(`${base}/v1/speech/check_in`)).status, 401);
    const ok = await fetch(`${base}/v1/speech/hazard_fire`, { headers: { Authorization: `Bearer ${token}` } });
    assert.equal(ok.status, 200);
    assert.equal(ok.headers.get('content-type'), 'audio/mpeg');
    assert.deepEqual(Buffer.from(await ok.arrayBuffer()), mp3);

    const dispatchRes = await fetch(`${base}/v1/dispatch`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        id: incidentId,
        trigger: 'fire-hazard',
        hazardType: 'fire',
        location: 'Helsinki Lab · 60.1699, 24.9384',
        context: 'Large open fire visible on floor ahead.',
      }),
    });
    assert.equal(dispatchRes.status, 200);
    const receipt = await dispatchRes.json();
    assert.equal(receipt.service, 'fire_department');

    const briefingRes = await fetch(`${base}/v1/speech/briefing`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ incidentId }),
    });
    assert.equal(briefingRes.status, 200);
    assert.equal(briefingRes.headers.get('content-type'), 'audio/mpeg');
    assert.deepEqual(Buffer.from(await briefingRes.arrayBuffer()), mp3);
    assert.match(synthesizedScript, /Fire and Rescue Services/);
    assert.match(synthesizedScript, /Large open fire visible/);

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
