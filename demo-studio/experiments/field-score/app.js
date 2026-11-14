import {stories,frameAt,eventsAt} from './stories.js';
import {artwork} from './art.js';
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const clock=s=>`${String(Math.floor(s/60)).padStart(2,'0')}:${String(Math.floor(s%60)).padStart(2,'0')}`;
let story=stories[0],time=0,running=false,cancelledAt=null,voice=false,phaseKey='',artKey='',sessionNumber=1,mode='rehearsal';
let spoken='',lastTick=performance.now(),lastRender=0,toastTimer;
let live={source:null,url:null,stream:null,session:null,recordSession:null,incident:null,result:null,events:[],busy:false,controller:null,epoch:0,started:null};
function toast(message){$('#toast').textContent=message;$('#toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').hidden=true,3500);}
function stopSpeech(){window.speechSynthesis?.cancel();}
function speak(text,explicit=false){if((!voice&&!explicit)||!('speechSynthesis' in window))return;stopSpeech();const utterance=new SpeechSynthesisUtterance(text.replace(/[“”]/g,''));utterance.rate=.9;utterance.volume=.85;window.speechSynthesis.speak(utterance);}
function showView(view){if(view!=='experience'){running=false;stopSpeech();render();if(live.busy||live.session)cancelLive('Stopped when leaving the live capture view.').finally(()=>{if(!$('#record').hidden)renderRecord();});}$$('.page').forEach(p=>p.hidden=p.id!==view);$$('.nav').forEach(b=>{b.classList.toggle('active',b.dataset.view===view);if(b.dataset.view===view)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});if(view==='record')renderRecord();}
$$('[data-view]').forEach(b=>b.addEventListener('click',()=>showView(b.dataset.view)));
$('#voice').addEventListener('click',()=>{if(!('speechSynthesis' in window)){toast('Device speech is unavailable in this browser. The prompt remains visible.');return;}voice=!voice;$('#voice').textContent=voice?'Voice on':'Voice off';$('#voice').setAttribute('aria-pressed',voice);if(voice)speak($('#heard').textContent);else stopSpeech();});
$('#hear').addEventListener('click',()=>{if(!('speechSynthesis' in window)){toast('Device speech is unavailable. Read the prompt beside this button.');return;}speak($('#heard').textContent,true);});
$('#fullscreen').addEventListener('click',async()=>{try{if(document.fullscreenElement)await document.exitFullscreen();else await document.documentElement.requestFullscreen();}catch{toast('Fullscreen is unavailable. Use your browser’s presentation controls.');}});
document.addEventListener('fullscreenchange',()=>$('#fullscreen').textContent=document.fullscreenElement?'Exit ↙':'Expand ↗');
$('#stories').innerHTML=stories.map(s=>`<button class="story-card ${s===story?'selected':''}" data-story="${s.id}" aria-pressed="${s===story}"><span class="story-number">${s.number}</span><span class="story-copy"><span class="story-category">${escape(s.category)}</span><strong>${escape(s.name)}</strong><span class="story-meta">${s.id==='threat'?'Immediate check-in':s.id==='fall'?'Assessment before check-in':s.id==='cancel'?'Wearer cancels':'No escalation'}</span></span></button>`).join('');
$$('.story-card[data-story]').forEach(b=>b.addEventListener('click',()=>{story=stories.find(s=>s.id===b.dataset.story);reset();$$('.story-card[data-story]').forEach(el=>{const selected=el.dataset.story===story.id;el.classList.toggle('selected',selected);el.setAttribute('aria-pressed',selected);});}));
function reset(){time=0;running=false;cancelledAt=null;spoken='';phaseKey='';artKey='';sessionNumber++;stopSpeech();$('#world-art').innerHTML='';document.body.dataset.story=story.id;$('#canvas-title').textContent=story.name;$('#input-source-label').textContent=story.id==='fall'?'Injected motion':story.id==='ordinary'?'Manual request':'Scripted speech';$('#story-counter').textContent=`SCENARIO ${story.number} / 04`;$('#scrub').max=story.end;$('#duration').textContent=clock(story.end);render();}
$('#play').addEventListener('click',()=>{if(frameAt(story,time,cancelledAt).complete)reset();running=!running;if(!running)stopSpeech();render();});
$('#next').addEventListener('click',()=>{running=false;stopSpeech();const next=story.steps.find(t=>t>time+.15);time=next??story.end;render(true);});
$('#reset').addEventListener('click',reset);
$('#scrub').addEventListener('input',e=>{time=Number(e.target.value);running=false;cancelledAt=null;stopSpeech();artKey='';render();});
$('#cancel').addEventListener('click',()=>{cancelledAt=time;running=true;render(true);});
$('#explain').addEventListener('click',()=>{const open=$('#explanation').hidden;$('#explanation').hidden=!open;$('#explain').setAttribute('aria-expanded',open);$('#explain span').textContent=open?'−':'＋';renderExplanation();});
function renderExplanation(){const f=frameAt(story,time,cancelledAt);$('#explanation').innerHTML=`<strong>${escape(story.summary)}</strong><br>${f.cancelled?'The cancellation is final for this rehearsal. No alert or call follows.':story.id==='threat'?'Notice that the check-in begins before the scripted visual assessment. The car illustrates a safety check; it does not mean police were dispatched.':story.id==='fall'?'Motion is a candidate cue, not a diagnosis. This story supplies a scripted qualifying assessment. The pulse is an illustration, not a vital-sign measurement.':story.id==='ordinary'?'The scripted assessment is ordinary activity, so no check-in appears. Live mode can produce a different result for actual evidence.':'The refusal plea requests a precautionary check-in. The wearer can cancel at any point before the illustrated escalation.'}`;}
function render(forceSpeech=false){
 const f=frameAt(story,time,cancelledAt);document.body.dataset.phase=f.phase;if(f.complete)running=false;const key=`${story.id}:${f.phase}`;
 $('#play').textContent=f.complete?'Replay full flow':running?'Pause flow':time>0?'Play from here':'Play full flow';
 const nextTime=story.steps.find(t=>t>time+.15);$('#next').disabled=f.complete;$('#next').textContent=f.complete?'Scenario complete':nextTime===2?'Send trigger →':nextTime===3?(story.checkAt===3?'Open check-in →':'Capture context →'):nextTime===7?'Finish capture →':nextTime===story.autoCancel?'Wearer cancels →':nextTime===story.assessAt?'Show assessment →':nextTime===story.checkAt+15?'Let countdown expire →':'Finish scenario →';
 $('#scrub').value=Math.min(time,story.end);$('#elapsed').textContent=clock(time);$('#response-title').textContent=f.title;
 const details={standby:'A local signal wakes a short capture. Your camera isn’t recording in standby.',trigger:story.cue,capture:'A few seconds of context. Capture stops before assessment. No ongoing recording.',assessing:'The camera is off again. A scripted assessment is being illustrated.','check-in':f.assessed?'A check-in is active. Respond or cancel before the countdown ends.':story.id==='fall'?'The scripted assessment suggests a possible fall. The wearer has time to respond.':'The local speech cue starts a check-in before visual assessment finishes.',alert:'This is an illustrated demo alert. No responder was dispatched and no call was placed.',cancelled:'Check-in cancelled. The countdown and illustrated escalation have stopped.',clear:'The scripted assessment is ordinary activity. No check-in or alert was created.'};
 $('#response-detail').textContent=details[f.phase];
 $('#response-tag').textContent={standby:'ARMED & READY',trigger:'LOCAL INDICATOR',capture:'BOUNDED CONTEXT',assessing:'SCRIPTED ASSESSMENT','check-in':'CHECKING ON YOU',alert:'ILLUSTRATED ESCALATION',cancelled:'CHECK-IN CANCELLED',clear:'NO ESCALATION'}[f.phase];
 $('#camera-status').textContent=f.recording?'Capture active':'Camera off';$('#camera-status').classList.toggle('recording',f.recording);
 $('#capture-clock').textContent=f.recording?`${(time-3).toFixed(1)}s · active`:'Camera off';
 $('#world-art').classList.toggle('awake',f.captured&&!f.cancelled);
 $('#signal-chip').textContent=time<2?'WAITING FOR A TRIGGER':f.cancelled?'WEARER RESPONSE · CANCELLED':f.alert?'COUNTDOWN COMPLETE · DEMO ALERT':`${story.category.toUpperCase()} · TRIGGER RECEIVED`;
 $('#scene-quote').innerHTML=f.cancelled?'GUARDIAN<br><mark>CANCEL.</mark>':story.id==='threat'?'“I’M GOING TO<br><mark>HURT YOU.</mark>”':story.id==='fall'?'DROP.<br>IMPACT.<br><mark>STILLNESS.</mark>':story.id==='cancel'?'“NO,<br><mark>PLEASE DON’T.</mark>”':'JUST ANOTHER<br><mark>AFTERNOON.</mark>';
 $('#scene-detail').textContent=time<2?'Send the cue to begin. Guardian’s camera is off in standby.':f.cancelled?'The countdown has stopped. Pending assessment cannot reopen this check-in.':time<3?story.cue:time<7?'A bounded context window is open. The speech check-in can run in parallel.':time<story.assessAt?'Capture has stopped. Context is being assessed.':story.id==='ordinary'?'Scripted result: ordinary activity. No check-in was created.':`Scripted result: ${story.result.toLowerCase()}. The wearer can still cancel.`;
 const nextArt=f.cancelled||f.phase==='clear'?'success':f.kind??'halo';
 if(artKey!==nextArt){artKey=nextArt;$('#response-art').innerHTML=nextArt==='success'?'<div class="halo success">✓</div>':artwork(f.kind);$('#response-art').classList.toggle('art-active',Boolean(f.kind));}
 $('#response-art').classList.toggle('static-art',!running);
 renderScore(f);
 $('#countdown-wrap').hidden=!f.check;$('#countdown').textContent=f.countdown??15;$('#countdown-ring').style.strokeDashoffset=276.46*(1-(f.countdown??15)/15);$('#countdown-wrap').style.setProperty('--remaining',`${(f.countdown??15)/15*100}%`);
 $('#cancel').hidden=!(f.check||f.alert);$('#voice-hint').hidden=!(f.check||f.alert);$('#cancel').textContent=f.alert?'Silence demo alert':'I’m okay · Cancel check-in';
 $$('[data-step]').forEach(el=>{const i=Number(el.dataset.step);el.classList.toggle('current',i===f.pipeline||(i===3&&f.check));el.classList.toggle('past',i<f.pipeline&&!(i===3&&f.check));});
 const heard=f.cancelled?'Check-in cancelled.':f.alert?'Guardian alert active. Say Guardian cancel to silence the alert.':f.check?story.prompt:f.phase==='clear'?story.prompt:f.phase==='standby'?'Guardian is armed.':f.phase==='trigger'?'Guardian received a local indicator.':'Guardian is checking the scene.';
 $('#heard').textContent=`“${heard}”`;
 if(key!==phaseKey){phaseKey=key;if((running||forceSpeech)&&heard!==spoken){spoken=heard;speak(heard);}}
 if(!$('#explanation').hidden)renderExplanation();
 if(f.complete)running=false;
}
function renderScore(f){
 const stop=cancelledAt??story.autoCancel??Infinity;
 const rows=[['SIGNAL',2,2.6],['CAMERA',3,Math.min(7,stop)],['ASSESSMENT',7,Math.max(7,Math.min(story.assessAt,stop))],['CHECK-IN',story.checkAt??null,story.checkAt==null?null:Math.min(story.checkAt+15,stop)]];
 $('#score-time').innerHTML=`${time.toFixed(1).padStart(4,'0')}<span>SECONDS</span>`;
 $('#score-tracks').innerHTML=`<div class="score-axis"><span></span><div>${[0,5,10,15,20,25,30].map(n=>`<span style="left:${n/30*100}%">${String(n).padStart(2,'0')}</span>`).join('')}</div></div>`+rows.map(([name,start,end])=>{
  const exists=start!==null&&end>start,active=exists&&time>=start&&time<end,done=exists&&time>=end;
  const elapsed=exists?Math.max(0,Math.min(time,end)-start):0;
  return `<div class="score-row ${active?'active':''} ${done?'done':''}"><span>${name}</span><div class="score-plot" aria-label="${name}: ${exists?`${start} to ${end} seconds, ${active?'active':done?'complete':'pending'}`:'not used in this scenario'}"><div class="score-playhead" style="left:${Math.min(time,30)/30*100}%"></div>${exists?`<div class="score-window" style="left:${start/30*100}%;width:${(end-start)/30*100}%"></div><div class="score-fill" style="left:${start/30*100}%;width:${elapsed/30*100}%"></div>`:'<span class="score-unused">NOT REQUESTED</span>'}</div></div>`;
 }).join('');
}
function tick(now){const delta=Math.min(.25,(now-lastTick)/1000);lastTick=now;if(running&&mode==='rehearsal'){time=Math.min(story.end,time+delta);if(now-lastRender>90){render();lastRender=now;}}requestAnimationFrame(tick);}requestAnimationFrame(tick);
document.addEventListener('visibilitychange',()=>{if(document.hidden){running=false;stopSpeech();render();if(live.busy||live.session)cancelLive('Stopped when the studio left the foreground.');}});
document.addEventListener('keydown',e=>{if(['INPUT','SELECT','TEXTAREA','BUTTON','A'].includes(document.activeElement?.tagName))return;if(e.code==='Space'&&mode==='rehearsal'&&!$('#experience').hidden){e.preventDefault();$('#play').click();}if(e.key==='ArrowRight'&&mode==='rehearsal'&&!$('#experience').hidden){e.preventDefault();$('#next').click();}});
const pipeline=[
 ['Local signal','Only when something matters.','A small indicator wakes Guardian.','In the capture app, local speech, motion, an intentional gesture, or SOS can request action. A browser button substitutes for that input in this studio.','Selected local speech may listen while the app is explicitly armed in the foreground. Standby audio is not uploaded for continuous cloud transcription.'],
 ['Brief capture','Context with a boundary.','A short window, then camera off.','An accepted trigger can open up to eight seconds of capture. Up to six selected frames and optional consented audio provide the assessment context.','Continuous camera preview and gesture recognition are optional modes. The camera-off standby claim applies when those modes are disabled.'],
 ['Assessment','Evidence before assumptions.','The model adds context.','Consent-enabled incident audio can be transcribed by ElevenLabs. The configured Nemotron detector assesses chronological frames, trigger context, and available evidence.','A qualifying result can start a check-in. Uncertain or ordinary results are not shown as confirmed emergencies. Rehearsal results are scripted; live mode shows actual backend output.'],
 ['Check-in','Give the wearer a voice.','“Are you okay?”','The capture app gives a spoken prompt and time to respond. Recognized direct distress or threats can open this check-in before scene assessment finishes.','Say “Guardian cancel” in the capture app or use its cancel control. This web rehearsal uses a button and device speech synthesis; it does not run the phone’s recognizer.'],
 ['Outcome','Care without overclaiming.','Cancel, resolve, or raise an alert.','Cancellation stops the check-in. If it goes unanswered, the app can activate an audible alert; consented demo dispatch is a separate configured path.','This studio places no calls. Its live sessions disable demo calls. A patrol car is a safety illustration, and the pulse is not a measured heart rate.']
];
$('#pipeline-cards').innerHTML=pipeline.map((p,i)=>`<button class="pipeline-card ${i===0?'selected':''}" data-pipeline="${i}" aria-pressed="${i===0}"><span class="micro">0${i+1} / ${i===0?'WAKE':i===1?'CAPTURE':i===2?'UNDERSTAND':i===3?'RESPOND':'RESOLVE'}</span><h3>${p[0]}</h3><p>${p[1]}</p></button>`).join('');
function showPipeline(i){const p=pipeline[i];$$('[data-pipeline]').forEach(b=>{const selected=Number(b.dataset.pipeline)===i;b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',selected);});$('#pipeline-detail').innerHTML=`<div><span class="micro">INSIDE GUARDIAN / 0${i+1}</span><h2>${p[2]}</h2></div><div><p>${p[3]}</p><p class="detail-note">${p[4]}</p></div>`;}
$$('[data-pipeline]').forEach(b=>b.addEventListener('click',()=>showPipeline(Number(b.dataset.pipeline))));showPipeline(0);
function recordData(){return mode==='live'?{source:'live_backend',input:live.source??'none',sessionId:live.recordSession,incident:live.incident,result:live.result,events:live.events,captureSignature:'not_issued_by_browser',callsEnabled:false}:{source:'scripted_rehearsal',story:story.id,id:`REHEARSAL-${String(sessionNumber).padStart(3,'0')}`,positionSeconds:Number(time.toFixed(1)),outcome:frameAt(story,time,cancelledAt).phase,events:eventsAt(story,time,cancelledAt),captureSignature:'not_issued_by_browser',callsPlaced:0};}
function renderRecord(){const data=recordData(),isLive=mode==='live';$('#record-source').textContent=isLive?'LIVE BACKEND · BROWSER INPUT':'SCRIPTED REHEARSAL';$('#record-id').textContent=isLive?(live.recordSession??'NO SESSION YET'):data.id;$('#record-name').textContent=isLive?'Browser analysis session':story.name;$('#record-summary').textContent=isLive?'Actual backend responses and studio actions. Browser trigger buttons are injected cues, not glasses sensor detections.':story.summary;const events=data.events;$('#event-log').innerHTML=events.length?events.map(e=>`<li><time>${clock(e.at)}</time><div><strong>${escape(e.title)}</strong><p>${escape(e.detail)}</p></div></li>`).join(''):'<li><time>—</time><div><strong>No live session yet</strong><p>Choose an input in Live analysis, consent, and explicitly start a check.</p></div></li>';}
$('#export').addEventListener('click',()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(recordData(),null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=`ray-guardian-${mode}-session.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('Session exported with source labels.');});
$$('[data-mode]').forEach(b=>b.addEventListener('click',async()=>{if(mode===b.dataset.mode)return;running=false;stopSpeech();if(live.busy||live.session)await cancelLive('Session stopped when switching mode.');mode=b.dataset.mode;$$('[data-mode]').forEach(el=>{const active=el.dataset.mode===mode;el.classList.toggle('active',active);el.setAttribute('aria-pressed',active);});$('#rehearsal-content').hidden=mode!=='rehearsal';$('#live-content').hidden=mode!=='live';if(mode==='live')checkBackend();else render();}));
async function api(path,body,signal){const res=await fetch(path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal});const data=await res.json();if(!res.ok)throw new Error(data.message??'The backend request failed.');return data;}
async function checkBackend(){try{const data=await api('/api/health');$('#backend-status').textContent=data.online?(data.aiConfigured?'Backend connected · AI configured':'Backend connected · AI not configured'):'Backend offline · rehearsal available';$('#backend-status').classList.toggle('online',Boolean(data.online));}catch{$('#backend-status').textContent='Backend unavailable · rehearsal available';}}
function stopCamera(){live.stream?.getTracks().forEach(t=>t.stop());live.stream=null;$('#live-video').srcObject=null;$('#live-video').classList.remove('camera-on');}
function liveControls(){const busy=live.busy;$('#analyze').disabled=busy||!live.source||!$('#live-consent').checked;$('#live-file').disabled=busy;$('#camera-source').disabled=busy;$('#live-trigger').disabled=busy;$('#live-consent').disabled=busy;$('#live-cancel').hidden=!busy&&!live.session;}
function setLiveResult(tag,title,detail){$('#live-result').innerHTML=`<span class="micro">${escape(tag)}</span><h3>${escape(title)}</h3><p>${escape(detail)}</p>`;}
function liveEvent(title,detail){live.events.push({at:live.started?(Date.now()-live.started)/1000:0,title,detail});}
$('#live-consent').addEventListener('change',liveControls);
$('#live-file').addEventListener('change',async e=>{const file=e.target.files?.[0];if(!file)return;if(live.session)await cancelLive('Previous session cancelled before changing input.');stopCamera();if(live.url)URL.revokeObjectURL(live.url);live.url=URL.createObjectURL(file);live.source='file_replay';$('#live-video').src=live.url;$('#live-video').load();$('#live-placeholder').hidden=true;$('#file-name').textContent=file.name;$('#live-source').hidden=false;$('#live-source').textContent='LOCAL VIDEO · FILE REPLAY';$('#camera-source').setAttribute('aria-pressed','false');liveControls();});
$('#camera-source').addEventListener('click',async()=>{if(live.session)await cancelLive('Previous session cancelled before changing input.');stopCamera();if(live.url)URL.revokeObjectURL(live.url);live.url=null;live.source='phone';$('#live-video').removeAttribute('src');$('#live-video').load();$('#live-placeholder').hidden=false;$('#live-placeholder h3').textContent='Camera selected';$('#live-placeholder p').textContent='Access starts only when you press Capture & analyze.';$('#file-name').textContent='Laptop camera · event-driven';$('#live-file').value='';$('#live-source').hidden=false;$('#live-source').textContent='BROWSER CAMERA · NO GLASSES';$('#camera-source').setAttribute('aria-pressed','true');liveControls();});
async function cancelLive(reason='Stopped by the presenter.'){
 const id=live.session;live.epoch++;live.controller?.abort();live.controller=null;live.busy=false;live.session=null;stopCamera();$('#live-video').pause();if(id){try{await api(`/api/live/${id}/cancel`,{});}catch{toast('Local capture stopped. Backend cancellation could not be confirmed.');}}
 liveEvent('Studio stopped',reason);setLiveResult('CAPTURE STOPPED','Session stopped.',reason);liveControls();
}
$('#live-cancel').addEventListener('click',()=>cancelLive());
const wait=(ms,signal)=>new Promise((resolve,reject)=>{if(signal.aborted){reject(signal.reason);return;}const done=()=>{signal.removeEventListener('abort',abort);resolve();};const timer=setTimeout(done,ms);const abort=()=>{clearTimeout(timer);reject(signal.reason);};signal.addEventListener('abort',abort,{once:true});});
async function readyVideo(video,signal){if(video.readyState>=2&&video.videoWidth)return;await new Promise((resolve,reject)=>{const timer=setTimeout(()=>finish(new Error('Video could not be decoded. Choose a playable MP4 or use the camera.')),6000);const cleanup=()=>{clearTimeout(timer);video.removeEventListener('loadeddata',loaded);video.removeEventListener('error',error);signal.removeEventListener('abort',abort);};const finish=err=>{cleanup();err?reject(err):resolve();};const loaded=()=>finish();const error=()=>finish(new Error('This video format cannot be played in this browser.'));const abort=()=>finish(new Error('Capture cancelled.'));video.addEventListener('loadeddata',loaded,{once:true});video.addEventListener('error',error,{once:true});signal.addEventListener('abort',abort,{once:true});});}
$('#analyze').addEventListener('click',async()=>{
 if(live.busy||!live.source||!$('#live-consent').checked)return;
 if(live.session)await cancelLive('Previous session cancelled before a new check.');
 const epoch=++live.epoch,controller=new AbortController(),signal=controller.signal;live.controller=controller;live.busy=true;live.started=Date.now();live.events=[];live.result=null;live.incident=null;live.recordSession=null;liveControls();
 const video=$('#live-video');let heartbeat;
 try{
  setLiveResult('EXPLICIT CAPTURE REQUEST','Preparing the input…','Camera permission is requested only for a camera check.');
  if(live.source==='phone'){
   if(!navigator.mediaDevices?.getUserMedia)throw new Error('Camera access is unavailable here. Use a local video or open this studio on localhost.');
   const stream=await navigator.mediaDevices.getUserMedia({video:{width:{ideal:640},height:{ideal:480}},audio:false});
   if(epoch!==live.epoch){stream.getTracks().forEach(t=>t.stop());return;}
   live.stream=stream;video.srcObject=stream;video.classList.add('camera-on');$('#live-placeholder').hidden=true;
  }else{if(video.ended)video.currentTime=0;}
  await video.play();await readyVideo(video,signal);
  if(epoch!==live.epoch)return;
  const start=await api('/api/live/start',{source:live.source,signal:$('#live-trigger').value},signal);
  if(epoch!==live.epoch)return;
  live.session=start.session.id;live.recordSession=start.session.id;live.incident=start.incident??null;
  liveEvent('Server accepted trigger',`Source: ${live.source}. Trigger: ${$('#live-trigger').value}.`);
  if(start.incident)liveEvent('Check-in started by backend',`Incident ${start.incident.id}. State: ${start.incident.state}.`);
  if(!start.window)throw new Error(`Capture not permitted: ${start.reason}. Wait for the capture cooldown before trying again.`);
  heartbeat=setInterval(()=>api(`/api/live/${live.session}/heartbeat`,{}).catch(()=>{}),10000);
  const frames=[],canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');const scale=Math.min(1,640/Math.max(video.videoWidth,video.videoHeight));canvas.width=Math.round(video.videoWidth*scale);canvas.height=Math.round(video.videoHeight*scale);
  const captureStart=performance.now();
  for(let i=0;i<6;i++){
   if(signal.aborted||epoch!==live.epoch)return;
   const offsetMs=Math.round(performance.now()-captureStart);
   if(offsetMs>6500||Date.now()>start.window.captureEndsAt)throw new Error('The capture window expired. No late frames were uploaded.');
   ctx.drawImage(video,0,0,canvas.width,canvas.height);let imageDataUrl=canvas.toDataURL('image/jpeg',.62);
   if(imageDataUrl.length>174000)imageDataUrl=canvas.toDataURL('image/jpeg',.35);
   frames.push({offsetMs,imageDataUrl});
   setLiveResult('BOUNDED CAPTURE',`Frame ${i+1} of 6`,start.incident?'A check-in already exists from the speech cue. Visual analysis will add context.':'The backend has accepted a short window. Camera capture stops before upload.');
   if(i<5)await wait(550,signal);
  }
  stopCamera();video.pause();liveEvent('Capture stopped',`${frames.length} compressed frames. No microphone or cloud audio.`);
  setLiveResult('REAL PROVIDER REQUEST','Assessing the scene…','The camera is off. Waiting for the backend’s actual response.');
  const result=await api(`/api/live/${live.session}/observe`,{frames},signal);
  if(epoch!==live.epoch)return;
  live.result=result;live.incident=result.incident??live.incident;
  liveEvent('Backend assessment returned',`${result.detection?.label??'No label'} · ${result.detection?.source??'Unknown source'} · ${result.detection?.confidence??'Unspecified confidence'}`);
  if(live.incident)liveEvent('Incident state',live.incident.state);
  const d=result.detection??{},kind=live.incident?.trigger==='spoken_threat'||d.label==='possible_assault'?'patrol':d.label==='possible_fall'?'pulse':null;
  const label=String(d.label??'No assessment label').replaceAll('_',' ');
  setLiveResult('ACTUAL BACKEND RESPONSE',label.charAt(0).toUpperCase()+label.slice(1),d.summary??'The backend returned no summary.');
  if(kind&&live.incident)$('#live-result').insertAdjacentHTML('afterbegin',artwork(kind));
  $('#live-result').insertAdjacentHTML('beforeend',`<div class="result-facts"><span>SOURCE: ${escape(d.source??'unspecified')}</span><span>CONFIDENCE: ${escape(d.confidence??'unspecified')}</span><span>INCIDENT: ${escape(live.incident?.state??'none created')}</span><span>${result.framesAnalyzed??frames.length} FRAMES · CAMERA OFF · CALLS DISABLED</span></div>`);
  // This studio never presents itself as a background monitor or keeps demo sessions armed.
  const id=live.session;await api(`/api/live/${id}/cancel`,{},signal);live.session=null;
  liveEvent('Demo session ended','Session disarmed and any pending check-in cancelled after showing the response. No calls enabled.');
  $('#live-result').insertAdjacentHTML('beforeend','<p class="small-note" style="margin:14px 0 0">The demo session is now disarmed. Any pending check-in was cancelled after this response.</p>');
 }catch(error){if(epoch===live.epoch){stopCamera();video.pause();liveEvent('Request did not complete',error.message);setLiveResult('LIVE CHECK INCOMPLETE','No result was invented.',error.message);const id=live.session;live.session=null;if(id)try{await api(`/api/live/${id}/cancel`,{});}catch{toast('Capture stopped; server cancellation could not be confirmed.');}}}
 finally{clearInterval(heartbeat);if(epoch===live.epoch){live.busy=false;live.controller=null;liveControls();}}
});
window.addEventListener('pagehide',()=>{stopCamera();if(live.session)navigator.sendBeacon(`/api/live/${live.session}/cancel`,new Blob(['{}'],{type:'application/json'}));});
reset();
