import { ApiError } from './nemotron.mjs';

export const DEFAULT_TEST_LOCATION = 'Helsinki demo point · 60.1699, 24.9384';

export const SERVICES = Object.freeze({
  ambulance: Object.freeze({
    id: 'ambulance',
    label: 'Ambulance / Emergency Medical Services',
    shortLabel: 'Ambulance Services',
    spokenName: 'Ambulance and Emergency Medical Services',
    defaultHazard: 'medical',
  }),
  fire_department: Object.freeze({
    id: 'fire_department',
    label: 'Fire & Rescue Services',
    shortLabel: 'Fire & Rescue',
    spokenName: 'Fire and Rescue Services',
    defaultHazard: 'fire',
  }),
  police: Object.freeze({
    id: 'police',
    label: 'Police Emergency Dispatch',
    shortLabel: 'Police Dispatch',
    spokenName: 'Police Emergency Services',
    defaultHazard: 'police',
  }),
});

export const HAZARD_TO_SERVICE = Object.freeze({
  medical: 'ambulance',
  fire: 'fire_department',
  police: 'police',
});

export const VALID_TRIGGERS = Object.freeze([
  'manual-sos',
  'staged-collapse',
  'ai-check-in',
  'ai-hazard',
  'elderly-fall',
  'fire-hazard',
  'safety-threat',
  'heart-rate-anomaly',
]);

const BLOCKED_SHORTCODES = new Set([
  '000', '08', '100', '101', '102', '103', '107', '108',
  '110', '111', '112', '113', '114', '115', '116', '117', '118', '119',
  '120', '122', '190', '192', '193', '911', '988', '999',
]);

export function isBlockedEmergencyNumber(rawNumber) {
  if (typeof rawNumber !== 'string') return false;
  const trimmed = rawNumber.trim();
  if (!trimmed) return false;
  const digits = trimmed.replace(/\D+/g, '');
  if (!digits) return false;
  if (BLOCKED_SHORTCODES.has(digits)) return true;
  if (/^\d{3}$/.test(digits)) return true;
  return false;
}

export function sanitizeSpeechField(value, maxLength = 300) {
  if (typeof value !== 'string') return '';
  const cleaned = value
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/[`*_#<>[\]{}|\\]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (cleaned.length <= maxLength) return cleaned;
  return `${cleaned.slice(0, maxLength - 1).trimEnd()}.`;
}

export function resolveHazardType(hazardType, trigger, service) {
  if (hazardType === 'medical' || hazardType === 'fire' || hazardType === 'police') return hazardType;
  if (trigger === 'fire-hazard') return 'fire';
  if (trigger === 'safety-threat') return 'police';
  if (['staged-collapse', 'elderly-fall', 'heart-rate-anomaly', 'ai-check-in'].includes(trigger)) return 'medical';
  if (service && Object.hasOwn(SERVICES, service)) return SERVICES[service].defaultHazard;
  return 'medical';
}

export function resolveService(hazardType, trigger, requestedService) {
  if (requestedService && Object.hasOwn(SERVICES, requestedService)) return requestedService;
  const resolvedHazard = resolveHazardType(hazardType, trigger, null);
  return HAZARD_TO_SERVICE[resolvedHazard] ?? 'ambulance';
}

export function buildBriefingScript({
  service = 'ambulance',
  hazardType = 'medical',
  trigger = 'manual-sos',
  location = DEFAULT_TEST_LOCATION,
  context = '',
  heartRateBpm = null,
} = {}) {
  const resolvedService = resolveService(hazardType, trigger, service);
  const resolvedHazard = resolveHazardType(hazardType, trigger, resolvedService);
  const serviceInfo = SERVICES[resolvedService];

  let hazardSentence;
  if (resolvedHazard === 'fire') {
    hazardSentence = 'Hazard detected: large open fire or heavy smoke.';
  } else if (resolvedHazard === 'medical' && trigger === 'heart-rate-anomaly') {
    const bpmText = Number.isInteger(heartRateBpm) ? ` at ${heartRateBpm} beats per minute` : '';
    hazardSentence = `Hazard detected: sustained abnormal heart rate${bpmText} with no wearer response.`;
  } else if (resolvedHazard === 'medical' && trigger === 'elderly-fall') {
    hazardSentence = 'Hazard detected: fallen person requiring immediate medical attention.';
  } else if (resolvedHazard === 'medical') {
    hazardSentence = 'Hazard detected: fall or acute medical emergency.';
  } else if (resolvedHazard === 'police') {
    hazardSentence = 'Hazard detected: acute personal safety threat.';
  } else {
    hazardSentence = 'Immediate emergency help requested by smart glasses wearer.';
  }

  const cleanLocation = sanitizeSpeechField(location, 140) || 'Location pending GPS confirmation';
  const cleanContext = sanitizeSpeechField(context, 240);
  const contextWithPeriod = cleanContext
    ? `Smart glasses report: ${/[.!?]$/.test(cleanContext) ? cleanContext : `${cleanContext}.`}`
    : '';

  const parts = [
    `Automated Ray Guardian emergency call for ${serviceInfo.spokenName}.`,
    hazardSentence,
    `Location: ${/[.!?]$/.test(cleanLocation) ? cleanLocation : `${cleanLocation}.`}`,
    contextWithPeriod,
    `Please dispatch ${serviceInfo.shortLabel} immediately.`,
  ].filter(Boolean);

  return parts.join(' ').slice(0, 620);
}

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function validateDispatchInput(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new ApiError(400, 'invalid_dispatch', 'Expected a JSON dispatch payload.');
  }
  if (typeof body.id !== 'string' || !UUID_V4_RE.test(body.id)) {
    throw new ApiError(400, 'invalid_incident_id', 'Provide a valid UUID v4 incident id.');
  }
  const trigger = body.trigger ?? 'manual-sos';
  if (typeof trigger !== 'string' || !VALID_TRIGGERS.includes(trigger)) {
    throw new ApiError(400, 'invalid_trigger', 'Unsupported incident trigger.');
  }
  if (body.hazardType != null && !['none', 'medical', 'fire', 'police'].includes(body.hazardType)) {
    throw new ApiError(400, 'invalid_hazard_type', 'Unsupported hazard type.');
  }
  if (body.service != null && !Object.hasOwn(SERVICES, body.service)) {
    throw new ApiError(400, 'invalid_service', 'Unsupported emergency service.');
  }
  if (body.context != null && (typeof body.context !== 'string' || body.context.length > 1000)) {
    throw new ApiError(400, 'invalid_context', 'Incident context must be at most 1000 characters.');
  }
  if (body.location != null && (typeof body.location !== 'string' || body.location.length > 240)) {
    throw new ApiError(400, 'invalid_location', 'Location must be at most 240 characters.');
  }
  let heartRateBpm = null;
  if (body.heartRateBpm != null) {
    if (!Number.isInteger(body.heartRateBpm) || body.heartRateBpm < 25 || body.heartRateBpm > 240) {
      throw new ApiError(400, 'invalid_heart_rate', 'Heart rate must be between 25 and 240 bpm.');
    }
    heartRateBpm = body.heartRateBpm;
  }
  if (body.dialNumber != null) {
    if (typeof body.dialNumber !== 'string' || body.dialNumber.length > 32) {
      throw new ApiError(400, 'invalid_phone_number', 'Invalid phone number.');
    }
    if (isBlockedEmergencyNumber(body.dialNumber)) {
      throw new ApiError(400, 'blocked_emergency_shortcode', 'Public emergency shortcodes (112/911/999) are blocked in SDK builds. Configure a dedicated test or dispatch phone number.');
    }
  }
  const resolvedService = resolveService(body.hazardType, trigger, body.service);
  const resolvedHazard = resolveHazardType(body.hazardType, trigger, resolvedService);
  return {
    id: body.id.toLowerCase(),
    trigger,
    hazardType: resolvedHazard,
    service: resolvedService,
    location: typeof body.location === 'string' && body.location.trim() ? body.location.trim() : null,
    context: typeof body.context === 'string' && body.context.trim() ? body.context.trim() : null,
    heartRateBpm,
  };
}

export function validateBriefingRequest(body, getIncident) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new ApiError(400, 'invalid_briefing_request', 'Expected a JSON briefing request.');
  }
  if (body.incidentId != null) {
    if (typeof body.incidentId !== 'string' || !UUID_V4_RE.test(body.incidentId)) {
      throw new ApiError(400, 'invalid_incident_id', 'Provide a valid incident id.');
    }
    const existing = getIncident?.(body.incidentId.toLowerCase());
    if (!existing) throw new ApiError(404, 'incident_not_found', 'Incident record was not found.');
    return existing.briefingScript;
  }
  const trigger = body.trigger ?? 'manual-sos';
  if (typeof trigger !== 'string' || !VALID_TRIGGERS.includes(trigger)) {
    throw new ApiError(400, 'invalid_trigger', 'Unsupported incident trigger.');
  }
  if (body.hazardType != null && !['none', 'medical', 'fire', 'police'].includes(body.hazardType)) {
    throw new ApiError(400, 'invalid_hazard_type', 'Unsupported hazard type.');
  }
  if (body.service != null && !Object.hasOwn(SERVICES, body.service)) {
    throw new ApiError(400, 'invalid_service', 'Unsupported emergency service.');
  }
  if (body.context != null && (typeof body.context !== 'string' || body.context.length > 1000)) {
    throw new ApiError(400, 'invalid_context', 'Incident context must be at most 1000 characters.');
  }
  if (body.location != null && (typeof body.location !== 'string' || body.location.length > 240)) {
    throw new ApiError(400, 'invalid_location', 'Location must be at most 240 characters.');
  }
  const heartRateBpm = Number.isInteger(body.heartRateBpm) && body.heartRateBpm >= 25 && body.heartRateBpm <= 240
    ? body.heartRateBpm
    : null;
  return buildBriefingScript({
    service: body.service,
    hazardType: body.hazardType,
    trigger,
    location: body.location || DEFAULT_TEST_LOCATION,
    context: body.context || '',
    heartRateBpm,
  });
}

export function createDispatchStore({ defaultLocation = DEFAULT_TEST_LOCATION, now = () => new Date().toISOString() } = {}) {
  const incidents = new Map();

  function record(rawBody) {
    const input = validateDispatchInput(rawBody);
    let entry = incidents.get(input.id);
    if (!entry) {
      const prefix = input.service === 'fire_department' ? 'FIRE' : input.service === 'police' ? 'POL' : 'MED';
      entry = {
        id: input.id,
        callId: `${prefix}-${input.id.slice(0, 8).toUpperCase()}`,
        status: 'dispatched',
        service: input.service,
        serviceLabel: SERVICES[input.service].label,
        shortServiceLabel: SERVICES[input.service].shortLabel,
        hazardType: input.hazardType,
        trigger: input.trigger,
        location: input.location ?? defaultLocation,
        context: input.context ?? null,
        heartRateBpm: input.heartRateBpm,
        receivedAt: now(),
      };
      incidents.set(input.id, entry);
      if (incidents.size > 200) incidents.delete(incidents.keys().next().value);
    } else {
      if (input.context) entry.context = input.context;
      if (input.location) entry.location = input.location;
      if (input.heartRateBpm != null) entry.heartRateBpm = input.heartRateBpm;
      if (rawBody.service || rawBody.hazardType) {
        entry.service = input.service;
        entry.serviceLabel = SERVICES[input.service].label;
        entry.shortServiceLabel = SERVICES[input.service].shortLabel;
        entry.hazardType = input.hazardType;
      }
    }
    entry.briefingScript = buildBriefingScript({
      service: entry.service,
      hazardType: entry.hazardType,
      trigger: entry.trigger,
      location: entry.location,
      context: entry.context ?? '',
      heartRateBpm: entry.heartRateBpm,
    });
    const { context, ...publicReceipt } = entry;
    return { ...publicReceipt, contextIncluded: Boolean(context) };
  }

  function get(id) {
    return incidents.get(String(id).toLowerCase()) ?? null;
  }

  return { record, get };
}
