import { createHash } from 'node:crypto';
import { ApiError } from './nemotron.mjs';

export const API_URL = 'https://api.elevenlabs.io/v1/text-to-speech';
export const MODEL_ID = 'eleven_v4';
export const VOICE_ID = '7EzWGsX10sAS4c9m9cPf'; // Jack John - Conversational and Upbeat
export const OUTPUT_FORMAT = 'mp3_44100_128';
const MAX_AUDIO_BYTES = 1024 * 1024;
const MAX_BRIEFING_CHARS = 650;
const MAX_BRIEFING_CACHE = 64;

/**
 * Canonical wearer prompts synthesized via GET /v1/speech/<phrase> and cached in memory.
 * Dynamic emergency call briefings use POST /v1/speech/briefing with structured incident validation.
 */
export const PHRASES = Object.freeze({
  check_in: "Ray Guardian check in. Tap I'm okay if you do not need help.",
  check_in_heart_rate: "Heart rate check in. Unusual heart rate detected. Tap I'm okay if you feel fine.",
  check_in_cancelled: 'Okay. Check in cancelled.',
  alert_created: 'No response detected. Creating a demo emergency alert.',
  hazard_medical: 'Medical alert. A person appears to have fallen. Calling Ambulance Services unless you cancel.',
  hazard_fire: 'Fire warning! Large open fire detected ahead. Step back now. Calling the Fire Department unless you cancel.',
  hazard_police: 'Safety alert. Urgent threat detected. Calling Police Services unless you cancel.',
  hazard_trembling: "Health alert. Severe trembling detected. Tap I'm okay to cancel, otherwise calling Ambulance Services.",
  hazard_crash: 'Crash alert! High-impact crash detected. Stay still if injured. Calling Ambulance Services unless you cancel.',
  calling_ambulance: 'Calling Ambulance Services now and sharing your location and scene report.',
  calling_fire_department: 'Calling the Fire Department now and sharing your location and fire report.',
  calling_police: 'Calling Police Services now and sharing your location and scene report.',
  emergency_cancelled: 'Emergency call cancelled.',
});

export function validatePhrase(id) {
  if (typeof id !== 'string' || !Object.hasOwn(PHRASES, id)) {
    throw new ApiError(404, 'unknown_phrase', 'Unknown speech phrase.');
  }
  return id;
}

export function validateBriefingText(text) {
  if (typeof text !== 'string') {
    throw new ApiError(400, 'invalid_briefing_text', 'Briefing script must be a string.');
  }
  const cleaned = text.replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!cleaned || cleaned.length > MAX_BRIEFING_CHARS) {
    throw new ApiError(400, 'invalid_briefing_text', `Briefing script must be between 1 and ${MAX_BRIEFING_CHARS} characters.`);
  }
  return cleaned;
}

export function createElevenLabs({ apiKey, voiceId = VOICE_ID, modelId = MODEL_ID, timeoutMs = 30_000, fetchImpl = fetch } = {}) {
  const resolvedVoiceId = voiceId || VOICE_ID;
  const resolvedModelId = modelId || MODEL_ID;
  if (!/^[A-Za-z0-9]{8,64}$/.test(resolvedVoiceId)) throw new Error('ELEVENLABS_VOICE_ID is invalid.');
  if (!/^[a-z0-9_]{3,64}$/.test(resolvedModelId)) throw new Error('ELEVENLABS_MODEL_ID is invalid.');
  const endpoint = `${API_URL}/${resolvedVoiceId}?output_format=${OUTPUT_FORMAT}`;
  const phraseCache = new Map(); // phrase ID -> Promise<Buffer>
  const briefingCache = new Map(); // sha256(text) -> Promise<Buffer>

  async function synthesizeText(text) {
    if (!apiKey) throw new ApiError(503, 'speech_not_configured', 'Speech is not configured.');
    try {
      const response = await fetchImpl(endpoint, {
        method: 'POST',
        redirect: 'error',
        signal: AbortSignal.timeout(timeoutMs),
        headers: { 'xi-api-key': apiKey, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg' },
        body: JSON.stringify({ text, model_id: resolvedModelId }),
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new ApiError(502, 'speech_unavailable', 'ElevenLabs is unavailable. Try again later.');
      }
      const reader = response.body.getReader();
      const chunks = [];
      let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > MAX_AUDIO_BYTES) {
          await reader.cancel();
          throw new ApiError(502, 'speech_unavailable', 'ElevenLabs returned too much audio.');
        }
        chunks.push(value);
      }
      if (size === 0) throw new ApiError(502, 'speech_unavailable', 'ElevenLabs returned no audio.');
      return Buffer.concat(chunks);
    } catch (error) {
      if (error instanceof ApiError) throw error;
      if (error.name === 'TimeoutError') throw new ApiError(504, 'speech_timeout', 'ElevenLabs took too long.');
      // Never expose upstream bodies, URLs, or the credential.
      throw new ApiError(502, 'speech_unavailable', 'ElevenLabs is unavailable. Try again later.');
    }
  }

  function speakPhrase(id) {
    validatePhrase(id);
    let pending = phraseCache.get(id);
    if (!pending) {
      pending = synthesizeText(PHRASES[id]);
      phraseCache.set(id, pending);
      pending.catch(() => phraseCache.delete(id));
    }
    return pending;
  }

  function speakBriefing(rawText) {
    const cleaned = validateBriefingText(rawText);
    const key = createHash('sha256').update(cleaned).digest('hex');
    let pending = briefingCache.get(key);
    if (pending) {
      briefingCache.delete(key);
      briefingCache.set(key, pending);
      return pending;
    }
    pending = synthesizeText(cleaned);
    briefingCache.set(key, pending);
    if (briefingCache.size > MAX_BRIEFING_CACHE) {
      briefingCache.delete(briefingCache.keys().next().value);
    }
    pending.catch(() => briefingCache.delete(key));
    return pending;
  }

  speakPhrase.briefing = speakBriefing;
  return speakPhrase;
}
