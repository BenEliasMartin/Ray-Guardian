import { ApiError } from './nemotron.mjs';
import { normalizeTrigger } from './dispatch.mjs';

const triggers = new Set([
  'staged-collapse',
  'ai-check-in',
  'ai-hazard',
  'manual-sos',
  'live-vision',
  'loud-sound',
  'elderly-fall',
  'fire-hazard',
  'safety-threat',
  'heart-rate-anomaly',
  'trembling',
  'crash',
]);

export function createSimulatedDispatch() {
  const receipts = new Map();
  return report => {
    const normalizedTrigger = normalizeTrigger(report?.trigger);
    if (typeof report?.id !== 'string' ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(report.id) ||
        !triggers.has(normalizedTrigger) ||
        (report.context != null && (typeof report.context !== 'string' || report.context.length > 1000))) {
      throw new ApiError(400, 'invalid_incident', 'Invalid incident report.');
    }
    const id = report.id.toLowerCase();
    let receipt = receipts.get(id);
    if (!receipt) {
      receipt = {
        callId: `SIM-${id.slice(0, 8).toUpperCase()}`,
        status: 'simulated-accepted',
        location: 'Helsinki demo point · 60.1699, 24.9384',
        trigger: normalizedTrigger,
        receivedAt: new Date().toISOString(),
      };
      receipts.set(id, receipt);
      if (receipts.size > 200) receipts.delete(receipts.keys().next().value);
    }
    if (report.context) receipt.context = report.context;
    const { context, ...metadata } = receipt;
    return { ...metadata, contextIncluded: Boolean(context) };
  };
}
