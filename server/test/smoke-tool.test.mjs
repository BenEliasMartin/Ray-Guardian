import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Test the live CLI's success/failure reporting, not media decoding or provider accuracy.
// The production media/provider contracts are exercised separately in guardian.test.mjs.
async function runSmoke({ source = 'nemotron', transcription = 'elevenlabs_scribe', callState } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'guardian-smoke-contract-'));
  const routes = [];
  const server = createServer(async (request, response) => {
    for await (const _ of request) { /* Drain the request body. */ }
    const route = request.url;
    routes.push(route);
    let body = {};
    if (route === '/health') body = { ready: true };
    else if (route === '/v1/sessions') body = { id: 'session' };
    else if (route.endsWith('/triggers')) body = { window: { id: 'window' } };
    else if (route.endsWith('/observations')) body = {
      detection: { source, label: 'ordinary_activity' }, framesAnalyzed: 1,
      audioTranscriptionSource: transcription, incident: callState ? { id: 'incident' } : null,
    };
    else if (route === '/v1/voice/prompts') {
      response.writeHead(200, { 'Content-Type': 'audio/mpeg' }); response.end('fixture-audio'); return;
    } else if (route === '/v1/incidents/incident') body = { state: callState };
    response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(body));
  });
  try {
    // Stand in for ffmpeg's image pipe. This test deliberately does not claim decoded video.
    const ffmpeg = join(directory, 'frame-pipe');
    await writeFile(ffmpeg, '#!/usr/bin/env node\nprocess.stdout.write(Buffer.from([255,216,255,217]));\n', { mode: 0o700 });
    await writeFile(join(directory, 'audio.wav'), Buffer.alloc(3244));
    const manifest = join(directory, 'manifest.json');
    await writeFile(manifest, JSON.stringify({ clips: [{ video: 'unused.mp4', audio: 'audio.wav' }] }));
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    const args = [fileURLToPath(new URL('../../scripts/smoke_guardian.mjs', import.meta.url)),
      '--manifest', manifest, '--ffmpeg', ffmpeg, '--output', join(directory, 'results'),
      '--url', `http://127.0.0.1:${server.address().port}`];
    if (callState) args.push('--demo-call');
    const child = spawn(process.execPath, args, {
      env: { ...process.env, RAY_GUARDIAN_CLIENT_TOKEN: 'smoke-cli-contract-only' },
      timeout: 15000,
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    const [code] = await once(child, 'close');
    return { code, stdout, stderr, routes };
  } finally {
    await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  }
}

test('live smoke accepts an ordinary real-provider result without manufacturing an incident', async () => {
  const result = await runSmoke();
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /no positive detection was fabricated/);
  assert.ok(result.routes.includes('/v1/sessions/session/disarm'));
  assert.ok(!result.routes.includes('/v1/voice/prompts'));
});

test('live smoke fails on unavailable Nemotron instead of claiming success', async () => {
  const result = await runSmoke({ source: 'nemotron_unavailable' });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /real Nemotron response/);
  assert.ok(result.routes.includes('/v1/sessions/session/disarm'));
});

test('live smoke fails when audio transcription used a fixture', async () => {
  const result = await runSmoke({ transcription: 'test_fixture_stt' });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /real ElevenLabs Scribe/);
});

test('live smoke fails on a failed demo call and disarms its session', async () => {
  const result = await runSmoke({ callState: 'call_failed' });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /Demo transport was not verified: call_failed/);
  assert.ok(result.routes.includes('/v1/sessions/session/disarm'));
});
