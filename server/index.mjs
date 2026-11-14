import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createGuardianHTTP } from './http.mjs';
import { createNemotron } from './nemotron.mjs';
import { createDetector } from './detection.mjs';
import { createVoiceProvider, createElevenLabs } from './elevenlabs.mjs';
import { createDemoCalls } from './demo-calls.mjs';
import { createDispatchStore } from './dispatch.mjs';
import { EncryptedStore } from './store.mjs';
import { GuardianService } from './guardian.mjs';
import { loadReplays } from './replays.mjs';

const env = process.env;
const host = env.HOST || '127.0.0.1';
const port = Number(env.PORT ?? 8787);
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid PORT.');

const directory = fileURLToPath(new URL('.', import.meta.url));
const rawEncryptionKey = env.DATA_ENCRYPTION_KEY?.trim() || '';
const useEphemeralDevStore = !rawEncryptionKey && env.NODE_ENV !== 'production';
if (useEphemeralDevStore) {
  console.warn('DATA_ENCRYPTION_KEY not set; using ephemeral in-memory EncryptedStore for development.');
}
const store = new EncryptedStore({
  path: useEphemeralDevStore ? ':memory:' : (env.DATA_PATH || resolve(directory, 'data/guardian.sqlite')),
  key: useEphemeralDevStore ? randomBytes(32).toString('hex') : rawEncryptionKey,
});

const provider = {
  apiKey: env.VERDA_INFERENCE_KEY || undefined,
  baseURL: env.VERDA_BASE_URL || undefined,
  model: env.VERDA_MODEL || undefined,
};
const calls = createDemoCalls({
  transport: env.DEMO_CALL_TRANSPORT || 'playback',
  accountSid: env.TWILIO_ACCOUNT_SID || undefined,
  authToken: env.TWILIO_AUTH_TOKEN || undefined,
  from: env.DEMO_CALL_FROM || undefined,
  to: env.DEMO_CALL_TO || undefined,
  allowlist: (env.DEMO_CALL_ALLOWLIST ?? '').split(',').map(s => s.trim()).filter(Boolean),
  publicBaseURL: env.PUBLIC_BASE_URL || undefined,
  mediaSecret: env.MEDIA_SIGNING_SECRET || undefined,
});
const guardian = new GuardianService({
  store,
  calls,
  detect: createDetector(provider),
  voice: createVoiceProvider({
    apiKey: env.ELEVENLABS_API_KEY || undefined,
    voiceId: env.ELEVENLABS_VOICE_ID || undefined,
    ttsModel: env.ELEVENLABS_TTS_MODEL || undefined,
    sttModel: env.ELEVENLABS_STT_MODEL || undefined,
    enableLogging: env.ELEVENLABS_ENABLE_LOGGING !== 'false',
  }),
  mediaLibrary: await loadReplays(env.REPLAY_DIRECTORY || resolve(directory, '../ios/RayGuardian/Resources/ReplayMedia')),
  providerStatus: {
    nemotron: { configured: Boolean(env.VERDA_INFERENCE_KEY) },
    elevenlabs: { configured: Boolean(env.ELEVENLABS_API_KEY) },
  },
});

const server = createGuardianHTTP({
  guardian,
  dispatchStore: createDispatchStore(),
  speak: createElevenLabs({
    apiKey: env.ELEVENLABS_API_KEY || undefined,
    voiceId: env.ELEVENLABS_VOICE_ID || undefined,
    modelId: env.ELEVENLABS_MODEL_ID || env.ELEVENLABS_TTS_MODEL || undefined,
  }),
  clientToken: env.RAY_GUARDIAN_CLIENT_TOKEN,
  analyze: createNemotron(provider),
});

server.listen(port, host, () => {
  const actualPort = server.address()?.port ?? port;
  console.log(`Ray Guardian demo API listening on ${host}:${actualPort}`);
});

let shuttingDown = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    const drained = new Promise(resolveClose => server.close(resolveClose));
    await guardian.close();
    await drained;
    store.close();
  });
}
