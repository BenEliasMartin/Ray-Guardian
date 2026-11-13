import test from 'node:test';
import assert from 'node:assert/strict';
import { classifierPayload, parsePrediction, score, wilson } from '../../scripts/evaluate_pov.mjs';

test('POV scoring keeps abstentions, missing results and errors in denominators', () => {
  const rows = [
    { id: 'a', label: 'fall' }, { id: 'b', label: 'fall' }, { id: 'c', label: 'fall' },
    { id: 'd', label: 'nonfall' }, { id: 'e', label: 'nonfall' }, { id: 'f', label: 'nonfall' },
  ];
  const result = score(rows, [
    { id: 'a', prediction: { label: 'fall' } }, { id: 'b', prediction: { label: 'uncertain' } },
    { id: 'd', prediction: { label: 'fall' } }, { id: 'e', prediction: { label: 'nonfall' } },
    { id: 'f', error: 'provider_error' },
  ]);
  assert.equal(result.fall_recall, 1/3);
  assert.equal(result.false_positive_rate, 1/3);
  assert.equal(result.nonfall_specificity, 1/3);
  assert.equal(result.missed_or_unresolved_falls, 2);
  assert.equal(result.abstentions, 1);
  assert.equal(result.errors, 2);
  assert.equal(result.decision_coverage, 0.5);
  assert.equal(result.readiness, 'not_established');
  assert.equal(result.false_alerts_per_armed_hour, null);
});

test('perfect six-event screening still has a wide interval and never certifies readiness', () => {
  const ci = wilson(6,6);
  assert.ok(ci[0] > 0.60 && ci[0] < 0.62);
  assert.ok(Math.abs(ci[1]-1) < 1e-12);
  const result = score([{ id: 'a', label: 'fall' }], [{ id: 'a', prediction: { label: 'fall' } }]);
  assert.equal(result.balanced_accuracy_conservative, null);
  assert.equal(result.readiness, 'not_established');
});

test('classification input contains only neutral instructions and imagery', () => {
  const payload = classifierPayload('data:image/jpeg;base64,/9j/', 'test-model');
  assert.deepEqual(payload.messages[1].content.map(p=>p.type), ['text','image_url']);
  assert.equal(payload.messages[1].content[1].image_url.url, 'data:image/jpeg;base64,/9j/');
  assert.equal(payload.tools, undefined);
  assert.equal(payload.messages[1].content[0].text.includes('S_FI'), false);
  assert.equal(payload.messages[1].content[0].text.includes('falls/'), false);
});

test('invalid classification outputs and mismatched evaluation records fail closed', () => {
  assert.throws(()=>parsePrediction('{"label":"safe","observations":[],"limitations":[]}'));
  assert.throws(()=>parsePrediction('{"label":"fall","observations":null,"limitations":[]}'));
  assert.deepEqual(parsePrediction('```json\n{"label":"uncertain","observations":[],"limitations":["blur"]}\n```'),
    { label: 'uncertain', observations: [], limitations: ['blur'] });
  assert.throws(()=>score([{id:'a',label:'fall'}],[{id:'a'},{id:'a'}]), /Duplicate/);
  assert.throws(()=>score([{id:'a',label:'fall'},{id:'a',label:'fall'}],[]), /Duplicate manifest/);
  assert.throws(()=>score([{id:'a',label:'fall'}],[{id:'b'}]), /outside/);
  assert.throws(()=>score([{id:'a',label:'unknown'}],[]), /ground-truth/);
});
