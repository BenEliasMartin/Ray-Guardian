import { createGuardianHTTP } from './http.mjs';
import { createDispatchStore } from './dispatch.mjs';
import { createSimulatedDispatch } from './simulated-dispatch.mjs';

export function createApp({
  analyze = null,
  speak = null,
  dispatchStore = createDispatchStore(),
  simulatedDispatch = createSimulatedDispatch(),
  guardian = null,
  clientToken,
  configured = guardian ? undefined : true,
  speechConfigured = guardian ? undefined : Boolean(speak),
  now = Date.now,
  limits = {},
}) {
  return createGuardianHTTP({
    guardian,
    clientToken,
    analyze,
    speak,
    dispatchStore,
    simulatedDispatch,
    configured,
    speechConfigured,
    now,
    limits,
  });
}
