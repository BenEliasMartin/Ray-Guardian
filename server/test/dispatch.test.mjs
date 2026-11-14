import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildBriefingScript,
  createDispatchStore,
  isBlockedEmergencyNumber,
  resolveService,
  validateDispatchInput,
} from '../dispatch.mjs';

const sampleId = '550e8400-e29b-41d4-a716-446655440000';

test('routes hazards deterministically to Ambulance, Fire & Rescue, or Police', () => {
  assert.equal(resolveService('medical', 'elderly-fall'), 'ambulance');
  assert.equal(resolveService('fire', 'fire-hazard'), 'fire_department');
  assert.equal(resolveService('police', 'safety-threat'), 'police');
  assert.equal(resolveService(null, 'heart-rate-anomaly'), 'ambulance');
  assert.equal(resolveService(null, 'manual-sos', 'fire_department'), 'fire_department');
});

test('blocks real public emergency shortcodes while permitting dedicated test numbers', () => {
  for (const blocked of ['112', '911', '999', '000', '110', '119', '+112', '911 ', '(112)', '123']) {
    assert.equal(isBlockedEmergencyNumber(blocked), true, `Expected ${blocked} to be blocked`);
  }
  for (const allowed of ['+358 40 123 4567', '+1-555-019-2834', '0401234567', '']) {
    assert.equal(isBlockedEmergencyNumber(allowed), false, `Expected ${allowed} to be allowed`);
  }
  assert.throws(() => validateDispatchInput({
    id: sampleId,
    trigger: 'fire-hazard',
    hazardType: 'fire',
    dialNumber: '112',
  }), { code: 'blocked_emergency_shortcode' });
});

test('dispatch store generates service-specific call IDs, briefings, and attaches late AI context', () => {
  const store = createDispatchStore();
  const initial = store.record({
    id: sampleId,
    trigger: 'elderly-fall',
    hazardType: 'medical',
    location: 'Espoo Care Residence · 60.1841, 24.8301',
  });
  assert.match(initial.callId, /^MED-/);
  assert.equal(initial.service, 'ambulance');
  assert.equal(initial.contextIncluded, false);
  assert.match(initial.briefingScript, /Ambulance and Emergency Medical Services/);
  assert.match(initial.briefingScript, /Espoo Care Residence/);

  const enriched = store.record({
    id: sampleId,
    trigger: 'elderly-fall',
    hazardType: 'medical',
    context: 'Elderly person lying motionless on the hallway floor next to a walker.',
  });
  assert.equal(enriched.callId, initial.callId);
  assert.equal(enriched.contextIncluded, true);
  assert.match(enriched.briefingScript, /walker/);
});

test('briefing script sanitizes untrusted formatting and enforces concise spoken output', () => {
  const script = buildBriefingScript({
    service: 'fire_department',
    hazardType: 'fire',
    trigger: 'fire-hazard',
    location: 'Otaniemi **Lab**\nBuilding 3',
    context: 'Large `open` [fire] spreading across floor ' + 'x'.repeat(500),
  });
  assert.ok(script.length <= 620);
  assert.doesNotMatch(script, /[`*[\]\n]/);
  assert.match(script, /Fire and Rescue Services/);
});
