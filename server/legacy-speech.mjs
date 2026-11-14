import { ApiError } from './nemotron.mjs';

export const API_URL = 'https://api.elevenlabs.io/v1/text-to-speech';
export const MODEL_ID = 'eleven_multilingual_v2';
export const VOICE_ID = '7EzWGsX10sAS4c9m9cPf'; // Jack John - Conversational and Upbeat
export const OUTPUT_FORMAT = 'mp3_44100_128';
const MAX_AUDIO_BYTES = 1024 * 1024;

/**
 * The only sentences the backend will synthesize. Clients choose a phrase ID, never free text, so the
 * ElevenLabs key cannot be used for arbitrary speech and the cost is bounded by this list.
 * Wording must stay honest: rehearsal alerts contact no one.
 */
export const PHRASES = Object.freeze({
  check_in: "Are you okay? I noticed something that might need attention. Tap I'm okay on your phone to cancel. Otherwise, I'll create an alert in fifteen seconds.",
  check_in_heart_rate: "Are you okay? Your watch reported an unusual heart rate. Tap I'm okay on your phone to cancel. Otherwise, I'll create an alert in fifteen seconds.",
  check_in_cancelled: "Okay, glad you're alright. The check-in is cancelled.",
  alert_created: 'This is a rehearsal. A simulated alert has been created. No one has been contacted.',
});

export function validatePhrase(id) {
  if (typeof id !== 'string' || !Object.hasOwn(PHRASES, id)) {
    throw new ApiError(404, 'unknown_phrase', 'Unknown speech phrase.');
  }
  return id;
}

export function createElevenLabs({ apiKey, voiceId = VOICE_ID, modelId = MODEL_ID, timeoutMs = 30_000, fetchImpl = fetch }) {
  if (!/^[A-Za-z0-9]{8,64}$/.test(voiceId)) throw new Error('ELEVENLABS_VOICE_ID is invalid.');
  if (!/^[a-z0-9_]{3,64}$/.test(modelId)) throw new Error('ELEVENLABS_MODEL_ID is invalid.');
  const endpoint = `${API_URL}/${voiceId}?output_format=${OUTPUT_FORMAT}`;
  const cache = new Map(); // phrase ID -> Promise<Buffer>; failures are evicted so a later call can retry

  async function synthesize(id) {
    if (!apiKey) throw new ApiError(503, 'speech_not_configured', 'Speech is not configured.');
    try {
      const response = await fetchImpl(endpoint, {
        method: 'POST',
        redirect: 'error',
        signal: AbortSignal.timeout(timeoutMs),
        headers: { 'xi-api-key': apiKey, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg' },
        body: JSON.stringify({ text: PHRASES[id], model_id: modelId }),
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

  // Generation is shared and not cancelled by one client disconnecting; the result is cached.
  return id => {
    validatePhrase(id);
    let pending = cache.get(id);
    if (!pending) {
      pending = synthesize(id);
      cache.set(id, pending);
      pending.catch(() => cache.delete(id));
    }
    return pending;
  };
}
