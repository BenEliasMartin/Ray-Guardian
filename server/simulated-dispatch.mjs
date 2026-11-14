import { ApiError } from './nemotron.mjs';

const triggers = new Set([
  'staged-collapse', 'ai-check-in', 'manual-sos', 'live-vision', 'loud-sound',
]);

export function createSimulatedDispatch() {
  const receipts = new Map();
  return report => {
    if (typeof report?.id !== 'string' ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(report.id) ||
        !triggers.has(report.trigger) ||
        (report.context != null && (typeof report.context !== 'string' || report.context.length > 1000))) {
      throw new ApiError(400, 'invalid_incident', 'Invalid incident report.');
    }
    let receipt = receipts.get(report.id);
    if (!receipt) {
      receipt = {
        callId: `SIM-${report.id.slice(0, 8).toUpperCase()}`,
        status: 'simulated-accepted',
        location: 'Helsinki demo point · 60.1699, 24.9384',
        trigger: report.trigger,
        receivedAt: new Date().toISOString(),
      };
      receipts.set(report.id, receipt);
      if (receipts.size > 200) receipts.delete(receipts.keys().next().value);
    }
    if (report.context) receipt.context = report.context;
    const { context, ...metadata } = receipt;
    return { ...metadata, contextIncluded: Boolean(context) };
  };
}
