import { createServer } from 'node:http';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { ApiError, validateInput } from './nemotron.mjs';
import { createDispatchStore, validateBriefingRequest } from './dispatch.mjs';
import { createSimulatedDispatch } from './simulated-dispatch.mjs';
import { readBody, readJSON, sendJSON } from './lib/transport.mjs';
import { EncryptedStore } from './store.mjs';
import { GuardianService } from './guardian.mjs';
import { createDemoCalls } from './demo-calls.mjs';
import { createDetector } from './detection.mjs';
import { createVoiceProvider } from './elevenlabs.mjs';
import { CaptureSealService, decodeSealBase64, MAX_CLIP_BYTES } from './capture-seal.mjs';

const MAX_ANALYZE_BODY = 1100 * 1024;
const MAX_SMALL_BODY = 16 * 1024;

const equal = (a, b) => {
  const x = Buffer.from(a ?? '');
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
};

const clean = value => JSON.parse(JSON.stringify(value, (key, item) => (key === 'owner' ? undefined : item)));

const binary = (res, audio) => {
  if (res.destroyed || res.writableEnded) return;
  res.writeHead(200, {
    'Content-Type': audio.contentType,
    'Content-Length': audio.bytes.length,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(audio.bytes);
};

export function createGuardianHTTP({
  guardian = null,
  clientToken,
  analyze = null,
  speak = null,
  dispatchStore = createDispatchStore(),
  simulatedDispatch = createSimulatedDispatch(),
  configured,
  speechConfigured,
  now = Date.now,
  limits = {},
}) {
  if (!clientToken || clientToken.length < 32) {
    throw new Error('RAY_GUARDIAN_CLIENT_TOKEN needs at least 32 characters.');
  }
  const owner = createHash('sha256').update(clientToken).digest('hex');
  const maxRequestsPerMinute = limits.maxRequestsPerMinute ?? 300;
  const maxVoicePromptsPerMinute = limits.maxVoicePromptsPerMinute ?? 20;
  const maxBriefingsPerMinute = limits.maxBriefingsPerMinute ?? 20;
  const maxAnalyzePerMinute = limits.maxAnalyzePerMinute ?? 10;
  const maxAnalyzeInFlight = limits.maxAnalyzeInFlight ?? 2;

  let requests = 0;
  let voiceRequests = 0;
  let briefingRequests = 0;
  let legacyRequests = 0;
  let legacyInFlight = 0;
  let windowStart = now();
  let briefingWindowStart = now();
  let legacyWindowStart = now();
  let sweeping = false;

  let ownedStore = null;
  let ownedGuardian = null;
  let sweepTimer = null;
  // Persistent originals must expire after a restart even without another upload.
  let captureSeals = guardian ? new CaptureSealService({store:guardian.store,now}) : null;
  function ensureCaptureSeals() {
    return captureSeals ??= new CaptureSealService({store:ensureGuardian().store,now});
  }

  const aiReady = () => configured ?? (guardian ?? ownedGuardian)?.providerStatus?.nemotron?.configured ?? Boolean(analyze);
  const speechReady = () => speechConfigured ?? (guardian ?? ownedGuardian)?.providerStatus?.elevenlabs?.configured ?? Boolean(speak);

  function startSweepTimer(service) {
    if (sweepTimer) return;
    sweepTimer = setInterval(async () => {
      if (sweeping) return;
      sweeping = true;
      try {
        await service.sweep();
        captureSeals?.purge();
      } catch {
        console.error('Incident maintenance failed; inspect service configuration.');
      } finally {
        sweeping = false;
      }
    }, 500);
    sweepTimer.unref();
  }

  function ensureGuardian() {
    if (guardian) return guardian;
    if (!ownedGuardian) {
      ownedStore = new EncryptedStore({
        path: ':memory:',
        key: randomBytes(32).toString('hex'),
        now,
      });
      ownedGuardian = new GuardianService({
        store: ownedStore,
        calls: createDemoCalls({ transport: 'playback', now }),
        detect: createDetector({}),
        voice: createVoiceProvider({}),
        now,
        providerStatus: {
          nemotron: { configured: aiReady() },
          elevenlabs: { configured: speechReady() },
        },
      });
      startSweepTimer(ownedGuardian);
    }
    return ownedGuardian;
  }

  if (guardian) {
    startSweepTimer(guardian);
  }

  const server = createServer(async (req, res) => {
    const abort = new AbortController();
    res.on('close', () => {
      if (!res.writableFinished) abort.abort();
    });
    try {
      const rawPath = (req.url ?? '').split('?')[0];
      if (rawPath.includes('..')) {
        throw new ApiError(404, 'not_found', 'Endpoint not found.');
      }
      const url = new URL(req.url ?? '/', 'http://localhost');
      const path = url.pathname;

      if (req.method === 'GET' && path === '/health') {
        const activeGuardian = guardian ?? ownedGuardian;
        return sendJSON(res, 200, {
          status: 'ok',
          aiConfigured: aiReady(),
          speechConfigured: speechReady(),
          dispatchConfigured: true,
          ...(activeGuardian ? activeGuardian.health() : {}),
        });
      }

      const callback = path.match(/^\/v1\/twilio\/(status|ack)\/([a-f0-9-]{36})$/);
      if (callback && req.method === 'POST') {
        const g = ensureGuardian();
        if (!/^application\/x-www-form-urlencoded(?:;|$)/i.test(req.headers['content-type'] ?? '')) {
          throw new ApiError(415, 'form_required', 'Send a signed form.');
        }
        const form = new URLSearchParams((await readBody(req, MAX_SMALL_BODY)).toString());
        const params = {};
        for (const [key, value] of form) {
          if (Object.hasOwn(params, key)) throw new ApiError(400, 'duplicate_parameter', 'Duplicate callback parameter.');
          params[key] = value;
        }
        if (!g.calls.verifyWebhook(req.url, params, req.headers['x-twilio-signature'])) {
          throw new ApiError(403, 'invalid_signature', 'Invalid callback signature.');
        }
        if (!/^CA[a-fA-F0-9]{32}$/.test(params.CallSid ?? '')) {
          throw new ApiError(400, 'invalid_call', 'Invalid call identifier.');
        }
        const incident = g.store.get('incident', callback[2]);
        if (!incident) throw new ApiError(404, 'not_found', 'Incident not found.');
        if (incident.call?.providerCallId && incident.call.providerCallId !== params.CallSid) {
          throw new ApiError(403, 'call_mismatch', 'Different call identifier.');
        }
        if (callback[1] === 'status') {
          await g.twilioStatus(incident.id, params);
          res.writeHead(204);
          return res.end();
        }
        let xml;
        if (incident.state === 'cancelled') {
          xml = '<?xml version="1.0"?><Response><Say>This demonstration was cancelled.</Say><Hangup/></Response>';
        } else if (params.Digits === '1') {
          g.acknowledge(incident.owner, incident.id);
          xml = g.calls.twiml(incident.id, { acknowledged: true });
        } else {
          xml = g.calls.twiml(incident.id);
        }
        res.writeHead(200, { 'Content-Type': 'application/xml', 'Cache-Control': 'no-store' });
        return res.end(xml);
      }

      const media = path.match(/^\/v1\/demo-calls\/([a-f0-9-]{36})\/audio$/);
      const authenticated = equal(req.headers.authorization, `Bearer ${clientToken}`);
      if (media && req.method === 'GET' && !authenticated) {
        const g = ensureGuardian();
        if (!g.calls.verifyMedia(media[1], url.searchParams.get('expires'), url.searchParams.get('signature'))) {
          throw new ApiError(403, 'invalid_signature', 'Expired or invalid audio link.');
        }
        return binary(res, await g.callAudio(media[1], null, abort.signal));
      }

      if (!path.startsWith('/v1/')) {
        throw new ApiError(404, 'not_found', 'Endpoint not found.');
      }
      if (!authenticated) {
        throw new ApiError(401, 'unauthorized', 'Bearer authentication is required.');
      }
      if (req.headers.origin) {
        throw new ApiError(403, 'browser_origin_not_allowed', 'Native clients only.');
      }

      if (now() - windowStart >= 60_000) {
        requests = 0;
        voiceRequests = 0;
        windowStart = now();
      }
      if (++requests > maxRequestsPerMinute) {
        throw new ApiError(429, 'rate_limited', 'Request budget exceeded.');
      }

      if(path==='/v1/capture-attempts'&&req.method==='POST') {
        return sendJSON(res,200,ensureCaptureSeals().challenge(owner,await readJSON(req,MAX_SMALL_BODY)));
      }
      const recording=path.match(/^\/v1\/incidents\/([a-f0-9-]{36})\/recording(?:\/(original))?$/);
      if(recording) {
        const seals=ensureCaptureSeals(),[,id,original]=recording;
        if(req.method==='GET')return original?binary(res,seals.original(owner,id)):sendJSON(res,200,seals.status(owner,id));
        if(req.method==='DELETE'&&!original){seals.delete(owner,id);return sendJSON(res,200,{deleted:true});}
        if(req.method==='POST'&&!original){
          if(!/^video\/mp4(?:;|$)/i.test(req.headers['content-type']??''))throw new ApiError(415,'mp4_required','Send video/mp4 with the original file as the body.');
          const rawReceipt=req.headers['x-guardian-receipt'],rawSignature=req.headers['x-guardian-signature'];
          const receipt=rawReceipt==null?null:decodeSealBase64(rawReceipt,4096);
          const signature=rawSignature==null?null:decodeSealBase64(rawSignature,80);
          const video=await readBody(req,MAX_CLIP_BYTES);
          try{return sendJSON(res,200,seals.accept(owner,id,video,receipt,signature));}
          finally{video.fill(0);receipt?.fill(0);signature?.fill(0);}
        }
      }

      if (path === '/v1/speech/briefing' && req.method === 'POST') {
        if (!speak || typeof speak.briefing !== 'function') {
          throw new ApiError(503, 'speech_not_configured', 'Speech briefing synthesis is not configured.');
        }
        const body = await readJSON(req, MAX_SMALL_BODY);
        const script = validateBriefingRequest(body, dispatchStore.get);
        if (now() - briefingWindowStart >= 60_000) {
          briefingWindowStart = now();
          briefingRequests = 0;
        }
        if (briefingRequests >= maxBriefingsPerMinute) {
          throw new ApiError(429, 'rate_limited', 'Speech briefing limit reached. Wait a moment before retrying.');
        }
        briefingRequests++;
        const audio = await speak.briefing(script);
        return binary(res, { bytes: audio, contentType: 'audio/mpeg' });
      }

      const speech = path.match(/^\/v1\/speech\/([a-z_]{1,40})$/);
      if (speech && req.method === 'GET') {
        if (!speak) throw new ApiError(503, 'speech_not_configured', 'Speech is not configured.');
        return binary(res, { bytes: await speak(speech[1]), contentType: 'audio/mpeg' });
      }

      if (path === '/v1/dispatch' && req.method === 'POST') {
        const body = await readJSON(req, MAX_SMALL_BODY);
        return sendJSON(res, 200, dispatchStore.record(body));
      }

      const dispatchRoute = path.match(/^\/v1\/dispatch\/([0-9a-fA-F-]{36})(?:\/(cancel))?$/);
      if (dispatchRoute) {
        const [, id, action] = dispatchRoute;
        if (!action && req.method === 'GET') {
          const record = dispatchStore.get(id);
          if (!record) throw new ApiError(404, 'incident_not_found', 'Incident record was not found.');
          const { context, ...publicReceipt } = record;
          return sendJSON(res, 200, { ...publicReceipt, contextIncluded: Boolean(context) });
        }
        if (action === 'cancel' && req.method === 'POST') {
          const cancelled = dispatchStore.cancel(id);
          if (!cancelled) throw new ApiError(404, 'incident_not_found', 'Incident record was not found.');
          return sendJSON(res, 200, cancelled);
        }
      }

      if (path === '/v1/simulated-dispatch' && req.method === 'POST') {
        return sendJSON(res, 200, simulatedDispatch(await readJSON(req, MAX_SMALL_BODY)));
      }

      if (path === '/v1/analyze' && req.method === 'POST') {
        const input = validateInput(await readJSON(req, MAX_ANALYZE_BODY));
        if (abort.signal.aborted) return;
        if (!analyze) {
          throw new ApiError(503, 'ai_not_configured', 'The AI service is not configured.');
        }
        if (now() - legacyWindowStart >= 60_000) {
          legacyWindowStart = now();
          legacyRequests = 0;
        }
        if (legacyRequests >= maxAnalyzePerMinute) {
          throw new ApiError(429, 'rate_limited', 'Limit reached. Wait a minute before retrying.');
        }
        if (legacyInFlight >= maxAnalyzeInFlight) {
          throw new ApiError(503, 'busy', 'The AI server is busy. Try again shortly.');
        }
        legacyRequests++;
        legacyInFlight++;
        try {
          const analysis = await analyze(input, abort.signal);
          return sendJSON(res, 200, { ...analysis, advisoryOnly: true });
        } finally {
          legacyInFlight--;
        }
      }

      if (req.method === 'POST' && path === '/v1/sessions') {
        const g = ensureGuardian();
        return sendJSON(res, 201, clean(g.createSession(owner, await readJSON(req))));
      }
      if (req.method === 'GET' && path === '/v1/incidents') {
        const g = ensureGuardian();
        return sendJSON(res, 200, clean({ incidents: g.store.list('incident', owner) }));
      }

      const session = path.match(/^\/v1\/sessions\/([a-f0-9-]{36})(?:\/(arm|disarm|heartbeat|triggers|observations|speech))?$/);
      if (session) {
        const g = ensureGuardian();
        const [, id, action] = session;
        if (req.method === 'GET' && !action) return sendJSON(res, 200, clean(g.requireSession(owner, id)));
        if (req.method === 'DELETE' && !action) {
          await g.disarm(owner, id);
          g.store.delete('session', id, owner);
          return sendJSON(res, 200, { deleted: true });
        }
        if (req.method === 'POST') {
          const body = await readJSON(req);
          let result;
          switch (action) {
            case 'arm': result = g.arm(owner, id); break;
            case 'disarm': result = await g.disarm(owner, id, { cancelPending: body.cancelPending !== false }); break;
            case 'heartbeat': result = g.heartbeat(owner, id); break;
            case 'triggers': result = g.trigger(owner, id, body); break;
            case 'observations': result = await g.observe(owner, id, body, abort.signal); break;
            case 'speech': result = await g.monitorSpeech(owner, id, body, abort.signal); break;
            default: throw new ApiError(404, 'not_found', 'Endpoint not found.');
          }
          return sendJSON(res, 200, clean(result));
        }
      }

      const incident = path.match(/^\/v1\/incidents\/([a-f0-9-]{36})(?:\/(cancel|acknowledge|location|escalate))?$/);
      if (incident) {
        const g = ensureGuardian();
        const [, id, action] = incident;
        if (req.method === 'GET' && !action) return sendJSON(res, 200, clean(g.requireIncident(owner, id)));
        if (req.method === 'DELETE' && !action) {
          await g.cancel(owner, id);
          await g.callTasks.get(id);
          g.store.delete('call_job', id, owner);
          g.store.delete('incident', id, owner);
          captureSeals?.delete(owner,id);
          return sendJSON(res, 200, { deleted: true });
        }
        if (req.method === 'POST') {
          const body = await readJSON(req);
          let result;
          if (action === 'cancel') result = await g.cancel(owner, id);
          else if (action === 'acknowledge') result = g.acknowledge(owner, id);
          else if (action === 'location') result = g.location(owner, id, body);
          else if (action === 'escalate') result = g.confirmEscalation(owner, id, body.token);
          else throw new ApiError(404, 'not_found', 'Endpoint not found.');
          return sendJSON(res, 200, clean(result));
        }
      }

      if (media && req.method === 'GET') {
        const g = ensureGuardian();
        return binary(res, await g.callAudio(media[1], owner, abort.signal));
      }
      if (path === '/v1/voice/prompts' && req.method === 'POST') {
        const g = ensureGuardian();
        if (++voiceRequests > maxVoicePromptsPerMinute) {
          throw new ApiError(429, 'voice_budget', 'Voice prompt budget reached.');
        }
        return binary(res, await g.prompt(owner, await readJSON(req), abort.signal));
      }
      if (path === '/v1/replays' && req.method === 'GET') {
        const g = ensureGuardian();
        return sendJSON(res, 200, g.mediaLibrary?.manifest ?? { clips: [] });
      }
      const replay = path.match(/^\/v1\/replays\/([a-zA-Z0-9_-]+)\/(video|audio)$/);
      if (replay && req.method === 'GET') {
        const g = ensureGuardian();
        if (g.mediaLibrary) return binary(res, await g.mediaLibrary.read(replay[1], replay[2]));
      }

      throw new ApiError(404, 'not_found', 'Endpoint not found.');
    } catch (error) {
      sendJSON(
        res,
        error instanceof ApiError ? error.status : 500,
        {
          error: error instanceof ApiError ? error.code : 'internal_error',
          message: error instanceof ApiError ? error.message : 'Request could not be completed.',
        },
      );
    }
  });

  server.on('close', () => {
    if (sweepTimer) {
      clearInterval(sweepTimer);
      sweepTimer = null;
    }
    if (ownedGuardian) {
      Promise.resolve(ownedGuardian.close()).finally(() => {
        ownedStore?.close();
        ownedStore = null;
      });
      ownedGuardian = null;
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.timeout = 90_000;
  return server;
}
