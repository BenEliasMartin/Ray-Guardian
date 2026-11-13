const $ = selector => document.querySelector(selector);
const video = $('#feed');
const samplesAt = [1, 3.5, 6];
const checkInMs = 10_000;
let phase = 'ready';
let sourceReady = false;
let objectUrl;
let drill;

document.body.classList.toggle('display-preview', new URLSearchParams(location.search).has('display'));

const copy = {
  ready: ['Collapse drill ready', 'Replay the glasses POV, check on the wearer, and simulate an emergency call.'],
  watching: ['Monitoring replay', 'Watching for the staged collapse cue.'],
  assessing: ['Assessing replay', 'Nemotron is comparing the sampled frames for a possible fall.'],
  clear: ['No check-in triggered', 'Nemotron did not flag this replay. Review the analysis or run the staged drill.'],
  unavailable: ['AI assessment unavailable', 'You can still simulate an SOS or run the staged drill.'],
  'check-in': ['Are you OK?', 'Possible collapse in this drill. Cancel to stop the test call.'],
  calling: ['Calling test dispatch…', 'Sending the incident to the local simulator.'],
  dispatched: ['Simulated police call accepted', 'Test dispatch received the emergency report.'],
  cancelled: ['Check-in cancelled', 'The simulated call was cancelled.'],
  failed: ['Test call failed', 'Retry the simulated call or start a new drill.'],
};

function show(next) {
  const previous = phase;
  phase = next;
  const [title, detail] = copy[next];
  $('#incident').dataset.phase = next;
  $('#headline').textContent = title;
  $('#detail').textContent = detail;
  $('#start').hidden = next !== 'ready';
  $('#start').disabled = !sourceReady;
  $('#cancel').hidden = next !== 'check-in';
  $('#countdown').hidden = next !== 'check-in';
  $('#sos').hidden = !['ready', 'watching', 'assessing', 'clear', 'unavailable', 'failed'].includes(next);
  $('#sos').textContent = next === 'failed' ? 'Retry test call' : 'Simulate SOS now';
  $('#reset').hidden = !['dispatched', 'cancelled', 'failed', 'clear', 'unavailable'].includes(next);
  $('#settings').hidden = next !== 'ready';
  $('#receipt').hidden = next !== 'dispatched';
  if (next === 'check-in') $('#cancel').focus();
  if (['dispatched', 'cancelled', 'failed', 'clear', 'unavailable'].includes(next)) $('#reset').focus();
  if (next === 'ready' && previous !== 'ready') $('#start').focus();
}

function showAnalysis(status, summary, observations = [], uncertainties = []) {
  $('#analysis-status').textContent = status;
  $('#analysis-summary').textContent = summary;
  for (const [selector, items] of [['#analysis-observations', observations], ['#analysis-uncertainties', uncertainties]]) {
    const list = $(selector);
    list.replaceChildren(...items.map(item => Object.assign(document.createElement('li'), { textContent: item })));
    list.hidden = items.length === 0;
  }
}

function captureFrame(timestamp) {
  const canvas = document.createElement('canvas');
  const scale = Math.min(1, 512 / Math.max(video.videoWidth, video.videoHeight));
  canvas.width = Math.round(video.videoWidth * scale);
  canvas.height = Math.round(video.videoHeight * scale);
  canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
  return { timestamp, jpeg: canvas.toDataURL('image/jpeg', .7) };
}

async function analyze(current) {
  if (current.analysisStarted) return;
  if (current.frames.length < (current.useAI && phase === 'assessing' ? 2 : 1)) {
    if (phase === 'assessing') show('unavailable');
    return;
  }
  current.analysisStarted = true;
  const frames = current.frames.splice(0);
  showAnalysis('Nemotron analyzing…', `Reviewing ${frames.length} ordered POV frames.`);
  try {
    const response = await fetch('/api/analyze', {
      method: 'POST',
      signal: current.controller.signal,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        consent: true,
        description: `Staged first-person safety rehearsal. The attached replay frames, in order, are from seconds ${frames.map(frame => frame.timestamp.toFixed(1)).join(', ')}.`,
        imageDataUrls: frames.map(frame => frame.jpeg),
        assessCollapse: current.useAI && phase === 'assessing',
      }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message ?? 'Analysis could not be completed.');
    if (drill !== current || current.controller.signal.aborted) return;
    current.context = data.summary;
    showAnalysis('Nemotron analysis ready', data.summary, data.observations, data.uncertainties);
    if (phase === 'dispatched') void attachContext(current);
    if (phase === 'assessing') {
      if (data.checkInRecommended) checkIn(current, 'ai-check-in');
      else show('clear');
    }
  } catch (error) {
    if (drill !== current || current.controller.signal.aborted) return;
    showAnalysis('Nemotron unavailable', error.message);
    if (phase === 'assessing') show('unavailable');
  }
}

function newDrill() {
  return {
    id: crypto.randomUUID(), controller: new AbortController(),
    frames: [], nextSample: 0, share: $('#share').checked,
    useAI: $('#share').checked && $('#ai-trigger').checked, trigger: 'manual-sos',
  };
}

function stopDrill() {
  if (!drill) return;
  clearInterval(drill.timer);
  drill.controller.abort();
  drill.frames.length = 0;
  video.pause();
}

function reset() {
  stopDrill();
  drill = undefined;
  if (video.readyState > 0) video.currentTime = 0;
  $('#clock').textContent = '00:00';
  $('#analysis-panel').open = false;
  showAnalysis('Nemotron ready', 'The drill samples up to three frames. The rehearsal uses a staged collapse cue.');
  show('ready');
}

async function dispatch(current) {
  if (drill !== current || !['ready', 'watching', 'assessing', 'check-in', 'clear', 'unavailable', 'failed'].includes(phase)) return;
  clearInterval(current.timer);
  video.pause();
  show('calling');
  try {
    const receipt = await reportToDispatch(current);
    if (drill !== current || current.controller.signal.aborted) return;
    $('#receipt-id').textContent = receipt.callId;
    $('#receipt-location').textContent = receipt.location;
    $('#receipt-context').textContent = receipt.contextIncluded ? 'Attached' : 'None at time of call';
    show('dispatched');
    if (!receipt.contextIncluded && current.context) void attachContext(current);
  } catch {
    if (drill === current && !current.controller.signal.aborted) show('failed');
  }
}

async function reportToDispatch(current) {
  const response = await fetch('/api/dispatch', {
    method: 'POST',
    signal: AbortSignal.any([current.controller.signal, AbortSignal.timeout(5000)]),
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: current.id, trigger: current.trigger, context: current.context }),
  });
  if (!response.ok) throw new Error('Test dispatch failed.');
  return response.json();
}

async function attachContext(current) {
  try {
    await reportToDispatch(current);
    if (drill === current) $('#receipt-context').textContent = 'Attached after the call';
  } catch {
    if (drill === current && !current.controller.signal.aborted) {
      $('#receipt-context').textContent = 'Available in analysis panel';
    }
  }
}

function checkIn(current, trigger) {
  current.trigger = trigger;
  show('check-in');
  if (trigger === 'ai-check-in') $('#detail').textContent = 'Nemotron flagged a possible fall. Cancel to stop the test call.';
  const deadline = performance.now() + checkInMs;
  function tick() {
    const remaining = deadline - performance.now();
    $('#countdown').textContent = Math.max(0, Math.ceil(remaining / 1000));
    if (remaining <= 0) void dispatch(current);
  }
  tick();
  current.timer = setInterval(tick, 100);
  if (current.share && !current.analysisStarted) void analyze(current);
}

function updatePlayback() {
  const seconds = Math.floor(video.currentTime);
  $('#clock').textContent = `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
  if (phase !== 'watching' || video.readyState < 2 || video.seeking) return;
  const sampleAt = samplesAt[drill.nextSample] * drill.scale;
  if (video.currentTime < sampleAt && !video.ended) return;
  if (drill.share) drill.frames.push(captureFrame(video.currentTime));
  drill.nextSample++;
  if (drill.nextSample === samplesAt.length || video.ended) {
    if (drill.useAI) {
      show('assessing');
      void analyze(drill);
    } else checkIn(drill, 'staged-collapse');
  }
}

function markSourceReady() {
  sourceReady = true;
  $('#start').disabled = false;
  $('#video-message').hidden = true;
}

video.addEventListener('loadeddata', markSourceReady);
video.addEventListener('timeupdate', updatePlayback);
video.addEventListener('ended', updatePlayback);
video.addEventListener('error', () => {
  sourceReady = false;
  $('#start').disabled = true;
  $('#video-message').textContent = 'Choose a POV video your browser can play.';
  $('#video-message').hidden = false;
  if (phase === 'watching') reset();
});

$('#file').addEventListener('change', event => {
  const file = event.target.files[0];
  if (!file) return;
  sourceReady = false;
  reset();
  if (objectUrl) URL.revokeObjectURL(objectUrl);
  objectUrl = URL.createObjectURL(file);
  video.src = objectUrl;
});

$('#start').addEventListener('click', async () => {
  if (phase !== 'ready' || !sourceReady) return;
  const current = drill = newDrill();
  current.scale = Math.min(1, video.duration / 7);
  video.currentTime = 0;
  show('watching');
  if (current.useAI) $('#detail').textContent = 'Sampling the replay to ask Nemotron whether to check in.';
  showAnalysis(current.share ? 'Sampling POV for Nemotron' : 'Nemotron off',
    current.share ? 'Sampling up to three frames from the replay.' : 'Enable frame analysis before starting a drill to include Nemotron.');
  try {
    await video.play();
  } catch {
    if (drill === current && phase === 'watching') {
      reset();
      $('#detail').textContent = 'The video could not play. Try again or choose another clip.';
    }
  }
});

$('#sos').addEventListener('click', () => {
  if (phase === 'failed') {
    void dispatch(drill);
    return;
  }
  drill ??= newDrill();
  if (drill.share && video.readyState >= 2) {
    if (!drill.frames.length) drill.frames.push(captureFrame(video.currentTime));
    void analyze(drill);
  }
  void dispatch(drill);
});

$('#cancel').addEventListener('click', () => {
  if (phase !== 'check-in') return;
  stopDrill();
  if (!drill.context && drill.analysisStarted) showAnalysis('Nemotron cancelled', 'The analysis stopped with the drill.');
  show('cancelled');
});

$('#reset').addEventListener('click', reset);
$('#share').addEventListener('change', event => {
  $('#ai-trigger').disabled = !event.target.checked;
  if (!event.target.checked) $('#ai-trigger').checked = false;
});
if ($('#share').checked) $('#ai-trigger').disabled = false;
window.addEventListener('pagehide', stopDrill);
window.addEventListener('pageshow', event => { if (event.persisted) reset(); });
if (video.readyState >= 2) markSourceReady();
show('ready');
