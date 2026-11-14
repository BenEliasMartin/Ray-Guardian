import { ApiError, validateInput } from './nemotron.mjs';

export const MAX_FRAMES = 6;
export const MAX_FRAME_BYTES = 128 * 1024;
export const MAX_AUDIO_BYTES = 300 * 1024;
export const MAX_CAPTURE_MS = 8_000;

function invalid(message) { throw new ApiError(400, 'invalid_media', message); }

export function decodeBase64(value, maxBytes) {
  if (typeof value !== 'string' || value.length > Math.ceil(maxBytes / 3) * 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) invalid('Use bounded, canonical inline base64 data.');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length > maxBytes || bytes.toString('base64') !== value) invalid('Invalid base64 data.');
  return bytes;
}

export function inspectWAV(bytes) {
  if (bytes.length < 44 || bytes.toString('ascii',0,4) !== 'RIFF' || bytes.toString('ascii',8,12) !== 'WAVE' || bytes.readUInt32LE(4) + 8 !== bytes.length) invalid('Expected a complete PCM WAV file.');
  let fmt, data;
  for (let p = 12; p + 8 <= bytes.length;) {
    const name = bytes.toString('ascii',p,p+4), size = bytes.readUInt32LE(p+4), start = p+8;
    if (start + size > bytes.length) invalid('Truncated WAV chunk.');
    if (name === 'fmt ') {
      if (size < 16 || fmt) invalid('Invalid WAV format chunk.');
      fmt = { codec: bytes.readUInt16LE(start), channels: bytes.readUInt16LE(start+2), sampleRate: bytes.readUInt32LE(start+4),
        byteRate: bytes.readUInt32LE(start+8), align: bytes.readUInt16LE(start+12), bits: bytes.readUInt16LE(start+14) };
    }
    if (name === 'data') { if (data) invalid('Multiple WAV data chunks are not supported.'); data = bytes.subarray(start,start+size); }
    p = start + size + (size % 2);
  }
  if (!fmt || !data || fmt.codec !== 1 || fmt.channels !== 1 || fmt.sampleRate !== 16000 || fmt.bits !== 16 || fmt.align !== 2 || fmt.byteRate !== 32000 || data.length % 2) invalid('Audio must be mono 16 kHz signed 16-bit PCM WAV.');
  const durationMs = data.length / 32;
  if (durationMs < 100 || durationMs > MAX_CAPTURE_MS) invalid('Audio must be between 100 ms and 8 seconds.');
  return { durationMs, sampleRate: 16000, channels: 1, pcm: data };
}

export const FALL_PATTERNS = ['free_fall_impact','rapid_tilt','slump'];

/** Optional summary of the wearer's own glasses IMU movement around the trigger. No raw samples are accepted. */
export function validateMotionSummary(value) {
  if (value == null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) invalid('Motion summary must be an object.');
  const number = (key, min, max, optional = false) => {
    const v = value[key];
    if (optional && v == null) return null;
    if (!Number.isFinite(v) || v < min || v > max) invalid(`Motion summary ${key} is out of range.`);
    return Math.round(v * 100) / 100;
  };
  const pattern = value.fallPattern ?? null;
  if (pattern !== null && !FALL_PATTERNS.includes(pattern)) invalid('Unknown motion fall pattern.');
  return {
    fallPattern: pattern,
    peakImpactG: number('peakImpactG', 0, 50), minG: number('minG', 0, 50),
    tiltDegrees: number('tiltDegrees', 0, 180),
    peakRotationDegPerSec: number('peakRotationDegPerSec', 0, 20000, true),
    stillSecondsAtEnd: number('stillSecondsAtEnd', 0, 12),
    coveredFromMs: number('coveredFromMs', -3000, MAX_CAPTURE_MS), coveredToMs: number('coveredToMs', -3000, MAX_CAPTURE_MS),
    samples: Math.trunc(number('samples', 1, 5000)),
  };
}

export function validateObservation(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) invalid('Expected an observation object.');
  if (typeof body.windowId !== 'string' || !/^[a-f0-9-]{36}$/.test(body.windowId)) invalid('Missing capture window.');
  const frames = body.frames ?? [];
  if (!Array.isArray(frames) || frames.length > MAX_FRAMES) invalid('Send at most six frames.');
  let lastOffset = -Infinity;
  const validatedFrames = frames.map(frame => {
    if (!Number.isFinite(frame?.offsetMs) || frame.offsetMs < -3000 || frame.offsetMs > MAX_CAPTURE_MS || frame.offsetMs < lastOffset) invalid('Frame offsets must be ordered between three seconds before and eight seconds after the trigger.');
    lastOffset = frame.offsetMs;
    validateInput({ consent:true, description:'frame', imageDataUrl:frame.imageDataUrl });
    if (frame.imageDataUrl == null) invalid('Every frame must contain inline image data.');
    const encoded = frame.imageDataUrl.slice(frame.imageDataUrl.indexOf(',')+1);
    const bytes = decodeBase64(encoded,MAX_FRAME_BYTES);
    return { offsetMs:frame.offsetMs, imageDataUrl:frame.imageDataUrl, bytes };
  });
  let audio = null;
  if (body.audio != null) {
    if (body.audio.format !== 'wav_pcm_s16le_16000_mono') invalid('Unsupported audio format.');
    const bytes = decodeBase64(body.audio.base64, MAX_AUDIO_BYTES);
    audio = { bytes, ...inspectWAV(bytes), source: String(body.audio.source ?? 'unknown').slice(0,80) };
  }
  const transcript = typeof body.transcript === 'string' ? body.transcript.trim() : '';
  if (transcript.length > 4000) invalid('Transcript exceeds 4000 characters.');
  if (!validatedFrames.length && !audio && !transcript) throw new ApiError(422,'no_evidence','No usable visual or audio evidence was provided.');
  const motion = validateMotionSummary(body.motion);
  return { windowId:body.windowId, frames:validatedFrames, audio, transcript, motion,
    source: ['meta_mock','meta_glasses','phone','file_replay'].includes(body.source) ? body.source : 'unknown' };
}

export function clearObservation(observation) {
  observation.frames.forEach(frame => { frame.bytes.fill(0); frame.imageDataUrl = ''; });
  observation.audio?.bytes.fill(0);
  observation.transcript = '';
}
