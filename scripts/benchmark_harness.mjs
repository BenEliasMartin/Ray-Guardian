// Small, paired benchmark. No incident creation, telephone calls, or live device access.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { createDetector, shouldCheckIn } from '../server/detection.mjs';
import { BASE_URL, MODEL } from '../server/nemotron.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const { values: args } = parseArgs({ options: {
  'clips-dir': { type: 'string', default: join(root, 'validation/data/raw') },
  ffmpeg: { type: 'string', default: 'ffmpeg' },
  output: { type: 'string', default: join(root, 'validation/results/harness-benchmark.json') },
} });
const apiKey = process.env.VERDA_INFERENCE_KEY;
if (!apiKey) throw new Error('Load VERDA_INFERENCE_KEY with --env-file=.env.');
const baseURL = process.env.VERDA_BASE_URL || BASE_URL;
const model = process.env.VERDA_MODEL || MODEL;
const endpoint = new URL(baseURL.replace(/\/$/, '') + '/chat/completions');
if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password) {
  throw new Error('Benchmark requires an HTTPS inference endpoint.');
}
const detector = createDetector({ apiKey, baseURL, model });

const utteranceCases = [
  ['I’m in danger. Someone is following me.', 'check_in'],
  ['Could you help me with the projector?', 'no_check_in'],
  ['I can’t get up.', 'check_in'],
  ['I said “I can’t get up” when we rehearsed the scene.', 'no_check_in'],
  ['Please don’t rob me.', 'check_in'],
  ['We’re in danger of missing our train.', 'no_check_in'],
  ['Someone has locked me in here and won’t let me out.', 'check_in'],
  ['No, please don’t forget the keys.', 'no_check_in'],
  ['I’ll stab you if you move.', 'check_in'],
  ['In the movie he says “I’ll stab you if you move.”', 'no_check_in'],
  ['Send help now.', 'check_in'],
  ['No need to help me, I’ve got it.', 'no_check_in'],
  ['My chest feels like it’s being crushed.', 'check_in'],
  ['Call an ambulance if this ever happens again.', 'no_check_in'],
  ['I need an ambulance.', 'check_in'],
  ['She asked for medical help yesterday.', 'no_check_in'],
];

const speechPrompt = 'From the transcript, would you start an immediate safety check-in with the wearer? A current serious distress plea, urgent medical symptom or credible threat warrants a check-in. Ordinary help, jokes, quotes, hypotheticals and past events do not. Output only check_in, no_check_in, or uncertain.';
const visualPrompt = 'These chronological images come from a first-person wearable camera. Is there evidence that the wearer fell? Output only fall, nonfall, or uncertain. Use uncertain if the evidence is insufficient.';

async function plainNemotron(prompt, evidence, allowed) {
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(40_000),
    body: JSON.stringify({
      model,
      temperature: 0,
      max_tokens: 35,
      chat_template_kwargs: { enable_thinking: false },
      messages: [
        { role: 'system', content: prompt },
        { role: 'user', content: evidence },
      ],
    }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const { choices } = await response.json();
  const choice = choices?.[0];
  const decision = choice?.message?.content?.trim().toLowerCase();
  if (choice?.finish_reason !== 'stop' || !allowed.includes(decision)) {
    throw new Error('Unusable baseline response');
  }
  return { decision };
}

async function measure(run) {
  const start = performance.now();
  try {
    return { ...await run(), ms: performance.now() - start };
  } catch (error) {
    return { decision: 'error', error: error.name === 'TimeoutError' ? 'Provider timeout' : error.message, ms: performance.now() - start };
  }
}

async function nativeDecisions() {
  const folder = await mkdtemp(join(tmpdir(), 'guardian-benchmark-'));
  const executable = join(folder, 'benchmark-speech');
  const sources = join(root, 'ios/GuardianCore/Sources/GuardianCore');
  try {
    execFileSync('swiftc', [
      '-O', '-module-cache-path', join(folder, 'module-cache'),
      ...['LocalSignals.swift', 'Models.swift', 'Motion.swift', 'DemoDispatch.swift', 'IncidentAnimation.swift']
        .map(file => join(sources, file)),
      join(root, 'scripts/benchmark_speech.swift'), '-o', executable,
    ], { stdio: 'inherit' });
    return JSON.parse(execFileSync(executable, {
      input: JSON.stringify(utteranceCases.map(([text]) => text)), encoding: 'utf8',
    }));
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
}

function extractFrame(path, offsetMs) {
  const result = spawnSync(args.ffmpeg, [
    '-hide_banner', '-loglevel', 'error', '-ss', String(offsetMs / 1000),
    '-i', path, '-frames:v', '1', '-vf', 'scale=640:-2',
    '-q:v', '6', '-f', 'image2pipe', '-vcodec', 'mjpeg', '-',
  ], { maxBuffer: 512 * 1024 });
  if (result.status !== 0 || !result.stdout?.length || result.stdout.length > 131072) {
    throw new Error(`Could not extract a bounded JPEG from ${basename(path)} at ${offsetMs} ms`);
  }
  return { offsetMs, imageDataUrl: 'data:image/jpeg;base64,' + result.stdout.toString('base64') };
}

const manifest = (await readFile(join(root, 'validation/manifest.jsonl'), 'utf8'))
  .trim().split('\n').map(line => JSON.parse(line));
const fractions = JSON.parse(await readFile(join(root, 'validation/protocol.json'), 'utf8'))
  .preparation.fractions_of_clip_duration;
const visualCases = [];
for (const label of ['fall', 'nonfall']) {
  for (const clip of manifest.filter(row => row.split === 'test' && row.label === label).slice(0, 3)) {
    const path = resolve(args['clips-dir'], basename(clip.raw_path));
    const digest = createHash('sha256').update(await readFile(path)).digest('hex');
    if (digest !== clip.raw_sha256) throw new Error(`Replay hash differs from the frozen manifest for ${clip.id}`);
    const frames = fractions.map(fraction => extractFrame(path, Math.round(fraction * clip.duration_seconds * 1000)));
    visualCases.push({ id: clip.id, expected: clip.label, frames });
  }
}

const native = await nativeDecisions();
const speech = [];
const visual = [];
for (const [index, [text, expected]] of utteranceCases.entries()) {
  const baseline = await measure(() => plainNemotron(speechPrompt, text, ['check_in', 'no_check_in', 'uncertain']));
  speech.push({ text, expected, guardian: { decision: native[index].decision, ms: native[index].medianMs }, baseline });
  console.log(`Speech ${index + 1}/${utteranceCases.length}: ${native[index].decision} vs ${baseline.decision}`);
}

for (const [index, { id, expected, frames }] of visualCases.entries()) {
  const baselineRun = () => measure(() => plainNemotron(visualPrompt, frames.map(frame => ({
    type: 'image_url', image_url: { url: frame.imageDataUrl },
  })), ['fall', 'nonfall', 'uncertain']));
  const guardianRun = () => measure(async () => {
    const result = await detector({ frames, transcript: '', trigger: 'manual_check', source: 'file_replay' });
    if (result.source !== 'nemotron') throw new Error(result.source);
    const decision = result.label === 'ordinary_activity' ? 'nonfall'
      : result.label === 'possible_fall' && shouldCheckIn(result) ? 'fall' : 'uncertain';
    return { decision, label: result.label, confidence: result.confidence, summary: result.summary };
  });
  // Alternate order within paired clips to reduce warm-up and provider load effects.
  let guardian, baseline;
  if (index % 2 === 0) {
    baseline = await baselineRun();
    guardian = await guardianRun();
  } else {
    guardian = await guardianRun();
    baseline = await baselineRun();
  }
  visual.push({ id, expected, guardian, baseline, offsetsMs: frames.map(frame => frame.offsetMs) });
  console.log(`Visual ${id}: ${guardian.decision} vs ${baseline.decision}`);
}

function summarize(rows, arm, positive) {
  const timings = rows.filter(row => row[arm].decision !== 'error').map(row => row[arm].ms).sort((a, b) => a - b);
  const midpoint = Math.floor(timings.length / 2);
  const medianMs = !timings.length ? null : timings.length % 2 ? timings[midpoint]
    : (timings[midpoint - 1] + timings[midpoint]) / 2;
  return {
    total: rows.length,
    correct: rows.filter(row => row.expected === row[arm].decision).length,
    correctlyFlagged: rows.filter(row => row.expected === positive && row[arm].decision === positive).length,
    falseAlarms: rows.filter(row => row.expected !== positive && row[arm].decision === positive).length,
    abstentions: rows.filter(row => row[arm].decision === 'uncertain').length,
    errors: rows.filter(row => row[arm].decision === 'error').length,
    medianMs,
  };
}

const results = {
  date: new Date().toISOString(),
  model,
  speech: { guardian: summarize(speech, 'guardian', 'check_in'), baseline: summarize(speech, 'baseline', 'check_in'), rows: speech },
  visual: { guardian: summarize(visual, 'guardian', 'fall'), baseline: summarize(visual, 'baseline', 'fall'), rows: visual },
};
await mkdir(dirname(resolve(args.output)), { recursive: true });
await writeFile(resolve(args.output), JSON.stringify(results, null, 2) + '\n');
console.log(JSON.stringify({
  speech: { guardian: results.speech.guardian, baseline: results.speech.baseline },
  visual: { guardian: results.visual.guardian, baseline: results.visual.baseline },
}, null, 2));
