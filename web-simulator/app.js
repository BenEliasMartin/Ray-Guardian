const $ = selector => document.querySelector(selector);
const video = $('#feed');
const synthCanvas = $('#synthetic-feed');
const synthCtx = synthCanvas.getContext('2d');
const displayPreview = new URLSearchParams(location.search).has('display');
const videoSamplesAt = [1, 3.5, 6];
const synthSamplesAt = [1.0, 3.0, 4.8];
const synthDurationSec = 5.4;

let phase = 'ready';
let videoReady = false;
let customVideoLoaded = false;
let objectUrl;
let activeAudio;
let activeAudioUrl;
let drill;

document.body.classList.toggle('display-preview', displayPreview);

const SERVICE_NAMES = {
  ambulance: 'Ambulance / EMS',
  fire_department: 'Fire & Rescue Services',
  police: 'Police Emergency Dispatch',
};

const FALLBACK_PHRASES = {
  hazard_medical: 'Medical hazard detected. A person appears to have fallen or needs urgent medical attention. Cancel now if everyone is okay, otherwise calling Ambulance Services.',
  hazard_fire: 'Warning! Large open fire detected ahead. Move to safety immediately. Calling Fire and Rescue Services unless you cancel.',
  hazard_police: 'Safety threat detected. Calling Police Emergency Services shortly unless you cancel.',
  emergency_cancelled: 'Emergency call cancelled. Monitoring resumed.',
};

const copy = {
  ready: ['Hazard detection ready', 'Scan the smart-glasses POV for falls, large open fires, or safety threats and route the call automatically.'],
  watching: ['Monitoring glasses POV', 'Sampling first-person frames from the smart-glasses feed.'],
  assessing: ['Analyzing with Nemotron…', 'Classifying medical, fire, or safety hazards and determining the needed help service.'],
  clear: ['No active hazard detected', 'Nemotron did not flag an emergency in this scene. Review observations or start another scan.'],
  unavailable: ['AI backend unreachable', 'Start the server for live Nemotron + ElevenLabs, or use Direct SOS / unchecked AI trigger for local drill.'],
  'check-in': ['Hazard detected — Check-in', 'Cancel if safe, or wait for automatic emergency dispatch.'],
  calling: ['Calling help service…', 'Connecting to emergency dispatch and preparing ElevenLabs spoken report.'],
  dispatched: ['Help call active', 'Incident dispatched and spoken briefing delivered.'],
  cancelled: ['Emergency call cancelled', 'Check-in cancelled by wearer. No help call was placed.'],
  failed: ['Dispatch request failed', 'Retry the help call or start a new scan.'],
};

function currentScenario() {
  return $('#scenario').value;
}

function isSyntheticScenario(scenario = currentScenario()) {
  return scenario === 'elderly-fall' || scenario === 'open-fire';
}

function scenarioDefaults(scenario = currentScenario()) {
  if (scenario === 'open-fire') {
    return { hazardType: 'fire', service: 'fire_department', trigger: 'fire-hazard', checkInMs: 8_000 };
  }
  if (scenario === 'elderly-fall') {
    return { hazardType: 'medical', service: 'ambulance', trigger: 'elderly-fall', checkInMs: 10_000 };
  }
  return { hazardType: 'medical', service: 'ambulance', trigger: 'staged-collapse', checkInMs: 10_000 };
}

function setServiceBadge(hazardType = 'none', text = 'STANDBY') {
  const badge = $('#service-badge');
  badge.className = 'badge';
  if (hazardType === 'fire') badge.classList.add('fire');
  else if (hazardType === 'medical') badge.classList.add('medical');
  else if (hazardType === 'police') badge.classList.add('police');
  badge.textContent = text;
}

function setVoiceBadge(text, live = false) {
  const badge = $('#voice-badge');
  badge.textContent = text;
  badge.classList.toggle('muted', !live);
}

function stopVoice() {
  if (activeAudio) {
    activeAudio.pause();
    activeAudio.src = '';
    activeAudio = undefined;
  }
  if (activeAudioUrl) {
    URL.revokeObjectURL(activeAudioUrl);
    activeAudioUrl = undefined;
  }
  if ('speechSynthesis' in window) window.speechSynthesis.cancel();
}

function speakLocalFallback(text) {
  if (!text || !$('#voice-enabled').checked || !('speechSynthesis' in window)) return;
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.rate = 1.02;
  setVoiceBadge('LOCAL TTS', false);
  window.speechSynthesis.speak(utterance);
}

async function playAudioBlob(blob, badgeText) {
  stopVoice();
  const url = URL.createObjectURL(blob);
  activeAudioUrl = url;
  const audio = new Audio(url);
  activeAudio = audio;
  setVoiceBadge(badgeText, true);
  audio.addEventListener('ended', () => {
    if (activeAudio === audio) setVoiceBadge('ELEVENLABS READY', true);
  }, { once: true });
  await audio.play();
}

async function speakPhrase(phraseId) {
  if (!$('#voice-enabled').checked) return;
  stopVoice();
  try {
    const res = await fetch(`/api/speech/${phraseId}`);
    if (res.ok && (res.headers.get('content-type') ?? '').startsWith('audio/mpeg')) {
      await playAudioBlob(await res.blob(), 'ELEVENLABS SPEAKING');
      return;
    }
    const body = await res.json().catch(() => ({}));
    speakLocalFallback(body.fallbackText ?? FALLBACK_PHRASES[phraseId]);
  } catch {
    speakLocalFallback(FALLBACK_PHRASES[phraseId]);
  }
}

async function speakIncidentBriefing(current) {
  if (!$('#voice-enabled').checked || !current) return;
  if (current.briefingBlob) {
    try {
      await playAudioBlob(current.briefingBlob, 'ELEVENLABS CALL');
      return;
    } catch {
      speakLocalFallback(current.briefingScript);
      return;
    }
  }
  stopVoice();
  setVoiceBadge('SYNTHESIZING…', true);
  try {
    const res = await fetch('/api/speech/briefing', {
      method: 'POST',
      signal: AbortSignal.any([current.controller.signal, AbortSignal.timeout(22_000)]),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ incidentId: current.id }),
    });
    if (drill !== current) return;
    if (res.ok && (res.headers.get('content-type') ?? '').startsWith('audio/mpeg')) {
      const blob = await res.blob();
      current.briefingBlob = blob;
      await playAudioBlob(blob, 'ELEVENLABS CALL');
      return;
    }
    const body = await res.json().catch(() => ({}));
    speakLocalFallback(body.fallbackText ?? current.briefingScript);
  } catch {
    if (drill === current) speakLocalFallback(current.briefingScript);
  }
}

function drawRoomBackground(ctx, w, h, warmSmoke = 0) {
  const wallGrad = ctx.createLinearGradient(0, 0, 0, h * 0.62);
  wallGrad.addColorStop(0, warmSmoke > 0 ? `rgb(${55 + warmSmoke * 60}, ${42 + warmSmoke * 15}, 38)` : '#d8ddd8');
  wallGrad.addColorStop(1, warmSmoke > 0 ? `rgb(${85 + warmSmoke * 90}, ${52 + warmSmoke * 20}, 40)` : '#bfc7c0');
  ctx.fillStyle = wallGrad;
  ctx.fillRect(0, 0, w, h * 0.62);

  // Floor with perspective lines
  const floorGrad = ctx.createLinearGradient(0, h * 0.62, 0, h);
  floorGrad.addColorStop(0, '#8c6d4f');
  floorGrad.addColorStop(1, '#5e452e');
  ctx.fillStyle = floorGrad;
  ctx.fillRect(0, h * 0.62, w, h * 0.38);

  ctx.strokeStyle = 'rgba(40,25,12,0.28)';
  ctx.lineWidth = 1.5;
  for (let i = -3; i <= 9; i++) {
    ctx.beginPath();
    ctx.moveTo(w * 0.5 + (i - 3) * 45, h * 0.62);
    ctx.lineTo(w * 0.5 + (i - 3) * 135, h);
    ctx.stroke();
  }

  // Baseboard & doorframe
  ctx.fillStyle = '#e8ece8';
  ctx.fillRect(0, h * 0.60, w, 6);
  ctx.fillStyle = '#a4aea6';
  ctx.fillRect(w * 0.12, h * 0.12, 74, h * 0.48);
  ctx.fillStyle = '#6f7972';
  ctx.fillRect(w * 0.135, h * 0.14, 56, h * 0.46);
}

function renderElderlyFallScene(ctx, w, h, sec) {
  drawRoomBackground(ctx, w, h, 0);
  // Progress of fall between t=1.6s and t=3.6s
  const progress = Math.max(0, Math.min(1, (sec - 1.6) / 1.9));
  const cx = w * 0.52;
  const floorY = h * 0.80;

  ctx.save();
  // Walking frame (silver)
  ctx.save();
  ctx.translate(cx + 46 + progress * 34, floorY - 4);
  ctx.rotate(progress * 1.15);
  ctx.strokeStyle = '#d9e2ec';
  ctx.lineWidth = 4;
  ctx.strokeRect(-22, -68, 44, 68);
  ctx.beginPath();
  ctx.moveTo(-22, -36);
  ctx.lineTo(22, -36);
  ctx.stroke();
  ctx.fillStyle = '#222';
  ctx.beginPath();
  ctx.arc(-22, 0, 5, 0, Math.PI * 2);
  ctx.arc(22, 0, 5, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  // Elderly person figure transitioning from standing upright to lying horizontal on the floor
  ctx.translate(cx - progress * 24, floorY - 6 + progress * 10);
  ctx.rotate(-progress * 1.46);

  // Legs (dark trousers)
  ctx.strokeStyle = '#2f3e4e';
  ctx.lineWidth = 14;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(-8, -52);
  ctx.lineTo(-12, 0);
  ctx.moveTo(10, -52);
  ctx.lineTo(14 + progress * 10, -2);
  ctx.stroke();

  // Torso (cardigan sweater)
  ctx.fillStyle = '#4a6fa5';
  ctx.beginPath();
  ctx.roundRect(-20, -112, 40, 64, 12);
  ctx.fill();

  // Arms reaching out
  ctx.strokeStyle = '#4a6fa5';
  ctx.lineWidth = 11;
  ctx.beginPath();
  ctx.moveTo(-16, -102);
  ctx.lineTo(-36, -68 - progress * 18);
  ctx.moveTo(16, -102);
  ctx.lineTo(38, -72);
  ctx.stroke();

  // Head & grey hair
  ctx.fillStyle = '#f0c8a8';
  ctx.beginPath();
  ctx.arc(0, -130, 16, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = '#dcdfe3';
  ctx.beginPath();
  ctx.arc(0, -134, 16.5, Math.PI, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

function renderOpenFireScene(ctx, w, h, sec) {
  const intensity = Math.max(0.2, Math.min(1, 0.22 + (sec / 4.2) * 0.85));
  drawRoomBackground(ctx, w, h, intensity * 0.75);

  const baseX = w * 0.52;
  const baseY = h * 0.84;
  const spread = 55 + intensity * 155;
  const maxFlameH = 48 + intensity * 165;

  // Heavy rising smoke clouds
  for (let i = 0; i < 14; i++) {
    const drift = Math.sin(sec * 2.2 + i) * 22;
    const sx = baseX + ((i % 5) - 2) * (spread * 0.42) + drift;
    const sy = baseY - maxFlameH * 0.65 - i * 13 * intensity;
    const radius = 26 + i * 5 * intensity;
    ctx.fillStyle = `rgba(28, 28, 30, ${0.24 + intensity * 0.32})`;
    ctx.beginPath();
    ctx.arc(sx, sy, radius, 0, Math.PI * 2);
    ctx.fill();
  }

  // Radiant floor glow
  const glow = ctx.createRadialGradient(baseX, baseY, 10, baseX, baseY, spread * 1.4);
  glow.addColorStop(0, `rgba(255, 120, 20, ${0.55 * intensity})`);
  glow.addColorStop(1, 'rgba(255, 60, 0, 0)');
  ctx.fillStyle = glow;
  ctx.fillRect(0, h * 0.4, w, h * 0.6);

  // Layered roaring open flames (outer red-orange, middle bright orange, inner yellow-white)
  const layers = [
    { color: '#d92b04', scaleW: 1.0, scaleH: 1.0, tongues: 11 },
    { color: '#ff6a00', scaleW: 0.82, scaleH: 0.82, tongues: 9 },
    { color: '#ffc400', scaleW: 0.58, scaleH: 0.62, tongues: 7 },
    { color: '#fff6cc', scaleW: 0.34, scaleH: 0.38, tongues: 5 },
  ];
  for (const layer of layers) {
    ctx.fillStyle = layer.color;
    for (let i = 0; i < layer.tongues; i++) {
      const frac = layer.tongues === 1 ? 0 : (i / (layer.tongues - 1)) - 0.5;
      const flicker = Math.sin(sec * 9 + i * 1.7) * 12 * intensity;
      const fx = baseX + frac * spread * 1.5 * layer.scaleW;
      const fw = (28 + intensity * 34) * layer.scaleW;
      const fh = (maxFlameH * (1 - Math.abs(frac) * 0.55) + flicker) * layer.scaleH;
      ctx.beginPath();
      ctx.moveTo(fx - fw, baseY);
      ctx.quadraticCurveTo(fx - fw * 0.4, baseY - fh * 0.65, fx + flicker * 0.4, baseY - fh);
      ctx.quadraticCurveTo(fx + fw * 0.4, baseY - fh * 0.65, fx + fw, baseY);
      ctx.closePath();
      ctx.fill();
    }
  }
}

function renderSyntheticFrame(scenario, sec) {
  const w = synthCanvas.width;
  const h = synthCanvas.height;
  synthCtx.clearRect(0, 0, w, h);
  if (scenario === 'open-fire') renderOpenFireScene(synthCtx, w, h, sec);
  else renderElderlyFallScene(synthCtx, w, h, sec);
}

function syncSourceDisplay() {
  const scenario = currentScenario();
  const synthetic = isSyntheticScenario(scenario);
  video.hidden = synthetic;
  synthCanvas.hidden = !synthetic;
  if (synthetic) {
    renderSyntheticFrame(scenario, 0.4);
    $('#hud-label').textContent = scenario === 'open-fire' ? '◉ GLASSES POV · FIRE SCENE' : '◉ GLASSES POV · FALL SCENE';
    $('#video-message').hidden = true;
    $('#start').disabled = phase !== 'ready';
  } else {
    $('#hud-label').textContent = '◉ GLASSES POV · VIDEO';
    const ready = scenario === 'custom' ? customVideoLoaded && videoReady : videoReady;
    $('#start').disabled = phase !== 'ready' || !ready;
    $('#video-message').textContent = scenario === 'custom' && !customVideoLoaded
      ? 'Click Upload video to select a custom MP4 or MOV clip.'
      : 'Choose a POV video your browser can play.';
    $('#video-message').hidden = ready;
  }
}

function show(next) {
  const previous = phase;
  phase = next;
  const [title, detail] = copy[next];
  $('#incident').dataset.phase = next;
  $('#incident').dataset.hazard = drill?.hazardType ?? 'none';
  $('#headline').textContent = title;
  $('#detail').textContent = detail;
  $('#start').hidden = next !== 'ready';
  $('#cancel').hidden = next !== 'check-in';
  $('#call-now').hidden = next !== 'check-in';
  $('#countdown').hidden = next !== 'check-in';
  $('#sos').hidden = !['ready', 'watching', 'assessing', 'clear', 'unavailable', 'failed'].includes(next);
  $('#sos').textContent = next === 'failed' ? 'Retry help call' : 'Direct SOS call';
  $('#replay-voice').hidden = next !== 'dispatched';
  $('#reset').hidden = !['dispatched', 'cancelled', 'failed', 'clear', 'unavailable'].includes(next);
  $('#settings').hidden = next !== 'ready';
  $('#receipt').hidden = next !== 'dispatched';
  syncSourceDisplay();
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

function captureFrame(timestamp, fromCanvas = false) {
  const source = fromCanvas ? synthCanvas : video;
  const srcW = fromCanvas ? synthCanvas.width : video.videoWidth;
  const srcH = fromCanvas ? synthCanvas.height : video.videoHeight;
  const canvas = document.createElement('canvas');
  const scale = Math.min(1, 512 / Math.max(srcW, srcH));
  canvas.width = Math.round(srcW * scale);
  canvas.height = Math.round(srcH * scale);
  canvas.getContext('2d').drawImage(source, 0, 0, canvas.width, canvas.height);
  return { timestamp, jpeg: canvas.toDataURL('image/jpeg', 0.75) };
}

async function analyze(current) {
  if (current.analysisStarted) return;
  if (current.frames.length < 1) {
    if (phase === 'assessing') show('unavailable');
    return;
  }
  current.analysisStarted = true;
  const frames = current.frames.splice(0);
  showAnalysis('Nemotron analyzing POV…', `Inspecting ${frames.length} smart-glasses POV frame(s) for medical, fire, or safety hazards.`);
  try {
    const response = await fetch('/api/analyze', {
      method: 'POST',
      signal: current.controller.signal,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        consent: true,
        description: `First-person Meta smart-glasses POV stream. Ordered frames captured at seconds ${frames.map(f => f.timestamp.toFixed(1)).join(', ')}. Classify any acute medical fall/collapse, large open fire, or personal safety hazard.`,
        imageDataUrls: frames.map(frame => frame.jpeg),
        assessHazards: true,
      }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message ?? 'Analysis could not be completed.');
    if (drill !== current || current.controller.signal.aborted) return;

    current.context = data.summary;
    const serviceNote = data.hazardDetected && data.recommendedService !== 'none'
      ? ` → Routing to ${SERVICE_NAMES[data.recommendedService] ?? data.recommendedService}`
      : '';
    showAnalysis(
      data.hazardDetected ? `Nemotron: ${data.hazardType.toUpperCase()} hazard (${data.severity})` : 'Nemotron: No hazard flagged',
      `${data.summary}${serviceNote}`,
      data.observations,
      data.uncertainties,
    );

    if (phase === 'dispatched') void attachContext(current);
    if (phase === 'assessing') {
      if (data.hazardDetected && data.hazardType !== 'none') {
        current.hazardType = data.hazardType;
        current.service = data.recommendedService;
        current.trigger = 'ai-hazard';
        current.checkInMs = data.urgentImmediate || data.hazardType === 'fire' ? 8_000 : 10_000;
        checkIn(current);
      } else {
        setServiceBadge('none', 'CLEAR');
        show('clear');
      }
    }
  } catch (error) {
    if (drill !== current || current.controller.signal.aborted) return;
    showAnalysis('Nemotron unavailable', error.message);
    if (phase === 'assessing') {
      // Fall back cleanly to scenario cue if backend is offline during a built-in drill
      if (current.scenario !== 'custom') {
        checkIn(current);
      } else {
        show('unavailable');
      }
    }
  }
}

function newDrill() {
  const scenario = currentScenario();
  const defaults = scenarioDefaults(scenario);
  return {
    id: crypto.randomUUID(),
    scenario,
    synthetic: isSyntheticScenario(scenario),
    controller: new AbortController(),
    frames: [],
    nextSample: 0,
    share: $('#share').checked,
    useAI: $('#share').checked && $('#ai-trigger').checked,
    hazardType: defaults.hazardType,
    service: defaults.service,
    trigger: defaults.trigger,
    checkInMs: defaults.checkInMs,
  };
}

function stopDrill() {
  if (!drill) return;
  clearInterval(drill.timer);
  clearInterval(drill.synthTimer);
  drill.controller.abort();
  drill.frames.length = 0;
  video.pause();
}

function reset() {
  stopDrill();
  stopVoice();
  drill = undefined;
  if (video.readyState > 0) video.currentTime = 0;
  $('#clock').textContent = '00:00';
  $('#analysis-panel').open = false;
  setServiceBadge('none', 'STANDBY');
  showAnalysis('Nemotron & ElevenLabs ready', 'Samples up to three glasses POV frames, classifies medical/fire/police hazards, and speaks the help call via ElevenLabs.');
  show('ready');
}

async function dispatch(current) {
  if (drill !== current || !['ready', 'watching', 'assessing', 'check-in', 'clear', 'unavailable', 'failed'].includes(phase)) return;
  clearInterval(current.timer);
  clearInterval(current.synthTimer);
  video.pause();
  show('calling');
  const targetLabel = SERVICE_NAMES[current.service] ?? 'Emergency Services';
  $('#headline').textContent = `Calling ${targetLabel}…`;
  try {
    const receipt = await reportToDispatch(current);
    if (drill !== current || current.controller.signal.aborted) return;
    current.service = receipt.service;
    current.hazardType = receipt.hazardType;
    current.briefingScript = receipt.briefingScript;
    $('#receipt-id').textContent = receipt.callId;
    $('#receipt-service').textContent = receipt.serviceLabel;
    $('#receipt-location').textContent = receipt.location;
    $('#receipt-context').textContent = receipt.contextIncluded ? 'Attached from Nemotron' : 'Pending / sensor trigger only';
    $('#receipt-script').textContent = receipt.briefingScript;
    setServiceBadge(receipt.hazardType, `${receipt.shortServiceLabel} CALLED`);
    show('dispatched');
    $('#headline').textContent = `${receipt.shortServiceLabel} call active`;
    $('#detail').textContent = `Incident routed to ${receipt.serviceLabel} with ElevenLabs voice report.`;
    void speakIncidentBriefing(current);
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
    body: JSON.stringify({
      id: current.id,
      trigger: current.trigger,
      hazardType: current.hazardType,
      service: current.service,
      context: current.context,
    }),
  });
  if (!response.ok) throw new Error('Dispatch failed.');
  return response.json();
}

async function attachContext(current) {
  try {
    const updated = await reportToDispatch(current);
    if (drill === current) {
      current.briefingScript = updated.briefingScript;
      current.briefingBlob = undefined;
      $('#receipt-context').textContent = 'Attached from Nemotron';
      $('#receipt-script').textContent = updated.briefingScript;
    }
  } catch {
    if (drill === current && !current.controller.signal.aborted) {
      $('#receipt-context').textContent = 'Available in analysis panel';
    }
  }
}

function checkIn(current) {
  const serviceName = SERVICE_NAMES[current.service] ?? 'Emergency Services';
  setServiceBadge(current.hazardType, `${current.hazardType.toUpperCase()} ALERT`);
  show('check-in');

  if (current.hazardType === 'fire') {
    $('#headline').textContent = 'Fire hazard detected!';
    $('#detail').textContent = `Calling ${serviceName} automatically unless cancelled.`;
    void speakPhrase('hazard_fire');
  } else if (current.hazardType === 'police') {
    $('#headline').textContent = 'Safety threat detected!';
    $('#detail').textContent = `Calling ${serviceName} automatically unless cancelled.`;
    void speakPhrase('hazard_police');
  } else {
    $('#headline').textContent = 'Medical / fall hazard — Are you OK?';
    $('#detail').textContent = `Calling ${serviceName} automatically unless cancelled.`;
    void speakPhrase('hazard_medical');
  }

  const deadline = performance.now() + current.checkInMs;
  function tick() {
    const remaining = deadline - performance.now();
    $('#countdown').textContent = Math.max(0, Math.ceil(remaining / 1000));
    if (remaining <= 0) void dispatch(current);
  }
  tick();
  current.timer = setInterval(tick, 100);
  if (current.share && !current.analysisStarted) void analyze(current);
}

function formatClock(sec) {
  const whole = Math.floor(sec);
  return `${String(Math.floor(whole / 60)).padStart(2, '0')}:${String(whole % 60).padStart(2, '0')}`;
}

function startSyntheticPlayback(current) {
  const startedAt = performance.now();
  current.synthTimer = setInterval(() => {
    if (drill !== current || phase !== 'watching') {
      clearInterval(current.synthTimer);
      return;
    }
    const elapsed = (performance.now() - startedAt) / 1000;
    $('#clock').textContent = formatClock(elapsed);
    renderSyntheticFrame(current.scenario, elapsed);
    if (current.nextSample < synthSamplesAt.length && elapsed >= synthSamplesAt[current.nextSample]) {
      if (current.share) current.frames.push(captureFrame(elapsed, true));
      current.nextSample++;
    }
    if (elapsed >= synthDurationSec) {
      clearInterval(current.synthTimer);
      if (current.useAI) {
        show('assessing');
        void analyze(current);
      } else {
        checkIn(current);
      }
    }
  }, 33);
}

function updateVideoPlayback() {
  $('#clock').textContent = formatClock(video.currentTime);
  if (phase !== 'watching' || !drill || drill.synthetic || video.readyState < 2 || video.seeking) return;
  const sampleAt = videoSamplesAt[drill.nextSample] * drill.scale;
  if (video.currentTime < sampleAt && !video.ended) return;
  if (drill.share) drill.frames.push(captureFrame(video.currentTime, false));
  drill.nextSample++;
  if (drill.nextSample === videoSamplesAt.length || video.ended) {
    video.pause();
    if (drill.useAI) {
      show('assessing');
      void analyze(drill);
    } else {
      checkIn(drill);
    }
  }
}

function markVideoReady() {
  videoReady = true;
  syncSourceDisplay();
}

video.addEventListener('loadeddata', markVideoReady);
video.addEventListener('timeupdate', updateVideoPlayback);
video.addEventListener('ended', updateVideoPlayback);
video.addEventListener('error', () => {
  videoReady = false;
  syncSourceDisplay();
  if (phase === 'watching' && drill && !drill.synthetic) reset();
});

$('#scenario').addEventListener('change', () => {
  const scenario = currentScenario();
  if (scenario === 'clip' && customVideoLoaded) {
    customVideoLoaded = false;
    videoReady = false;
    if (objectUrl) {
      URL.revokeObjectURL(objectUrl);
      objectUrl = undefined;
    }
    video.src = '/clip.mp4';
  }
  syncSourceDisplay();
});

$('#file').addEventListener('change', event => {
  const file = event.target.files[0];
  if (!file) return;
  videoReady = false;
  customVideoLoaded = true;
  $('#scenario').value = 'custom';
  reset();
  if (objectUrl) URL.revokeObjectURL(objectUrl);
  objectUrl = URL.createObjectURL(file);
  video.src = objectUrl;
});

$('#start').addEventListener('click', async () => {
  if (phase !== 'ready') return;
  const current = drill = newDrill();
  show('watching');
  setServiceBadge(current.hazardType, 'MONITORING');
  showAnalysis(
    current.share ? 'Sampling POV for Nemotron' : 'Nemotron off',
    current.share ? 'Capturing ordered first-person frames from smart-glasses view.' : 'Enable Nemotron to classify scenes visually.',
  );

  if (current.synthetic) {
    startSyntheticPlayback(current);
    return;
  }
  current.scale = Math.min(1, (video.duration || 7) / 7);
  video.currentTime = 0;
  try {
    await video.play();
  } catch {
    if (drill === current && phase === 'watching') {
      reset();
      $('#detail').textContent = 'The video could not play. Choose another clip or select a built-in POV scene.';
    }
  }
});

$('#call-now').addEventListener('click', () => {
  if (phase === 'check-in' && drill) void dispatch(drill);
});

$('#sos').addEventListener('click', () => {
  if (phase === 'failed' && drill) {
    void dispatch(drill);
    return;
  }
  drill ??= newDrill();
  drill.trigger = 'manual-sos';
  if (drill.share) {
    if (!drill.frames.length) {
      if (drill.synthetic) {
        renderSyntheticFrame(drill.scenario, 4.8);
        drill.frames.push(captureFrame(4.8, true));
      } else if (video.readyState >= 2) {
        drill.frames.push(captureFrame(video.currentTime, false));
      }
    }
    if (drill.frames.length) void analyze(drill);
  }
  void dispatch(drill);
});

$('#replay-voice').addEventListener('click', () => {
  if (phase === 'dispatched' && drill) void speakIncidentBriefing(drill);
});

$('#cancel').addEventListener('click', () => {
  if (phase !== 'check-in') return;
  stopDrill();
  void speakPhrase('emergency_cancelled');
  setServiceBadge('none', 'CANCELLED');
  if (!drill.context && drill.analysisStarted) showAnalysis('Scan cancelled', 'Stopped during check-in.');
  show('cancelled');
});

$('#reset').addEventListener('click', reset);
$('#share').addEventListener('change', event => {
  $('#ai-trigger').disabled = !event.target.checked;
  if (!event.target.checked) $('#ai-trigger').checked = false;
});
if ($('#share').checked) $('#ai-trigger').disabled = false;

window.addEventListener('pagehide', () => { stopDrill(); stopVoice(); });
window.addEventListener('pageshow', event => { if (event.persisted) reset(); });

if (displayPreview) {
  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    const active = document.activeElement;
    if ((event.key === 'Enter' || event.key === 'Return') &&
        active.matches('main button, main input, main select, main summary')) {
      if (active.tagName === 'SELECT') return;
      event.preventDefault();
      if (!event.repeat) active.click();
      return;
    }
    if (event.key === 'Escape' && phase === 'check-in') {
      event.preventDefault();
      $('#cancel').click();
      return;
    }
    const step = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 }[event.key];
    if (!step) return;
    const controls = [...document.querySelectorAll('main button, main input, main select, main summary')]
      .filter(control => !control.disabled && control.getClientRects().length);
    if (!controls.length) return;
    const current = controls.indexOf(active);
    event.preventDefault();
    controls[current < 0 ? 0 : (current + step + controls.length) % controls.length].focus();
  });
}

async function checkBackendStatus() {
  try {
    const res = await fetch('/api/health');
    if (!res.ok) return;
    const health = await res.json();
    if (health.backendOnline && health.speechConfigured) {
      setVoiceBadge('ELEVENLABS READY', true);
    } else if (health.backendOnline) {
      setVoiceBadge('AI SERVER ONLINE', false);
    } else {
      setVoiceBadge('STANDALONE TTS', false);
    }
  } catch {
    setVoiceBadge('STANDALONE TTS', false);
  }
}

if (video.readyState >= 2) markVideoReady();
void checkBackendStatus();
show('ready');
