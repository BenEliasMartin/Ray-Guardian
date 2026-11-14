import {stories,frameAt,eventsAt,sceneAt} from './stories.js';
import {artwork,guardianMark} from './art.js';
import {CinematicScene,films} from './cinema.js';
import {FreeExperience} from './free.js';
import {DemoVoice} from './voice.js';
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const clock=s=>`${String(Math.floor(s/60)).padStart(2,'0')}:${String(Math.floor(s%60)).padStart(2,'0')}`;
let story=stories[0],time=0,running=false,cancelledAt=null,voice=false,phaseKey='',artKey='',sessionNumber=1,mode='rehearsal';
const cinema=new CinematicScene(document.querySelector('#cinema'));
let opening=0;
let spoken='',lastTick=performance.now(),lastRender=0,toastTimer;
const demoVoice=new DemoVoice();
const free=new FreeExperience($('#free-content'),{speak:text=>speak(text),stopSpeech,onBack:()=>switchMode('rehearsal')});
function toast(message){$('#toast').textContent=message;$('#toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').hidden=true,3500);}
function stopSpeech(){demoVoice.stop();}
function speak(text,explicit=false,role='guardian'){if(!voice&&!explicit)return;void demoVoice.speak(text,role);}
function showView(view){if(view!=='experience'){running=false;stopSpeech();render();if(mode==='free')free.stop('Stopped when leaving the experience.',true).finally(()=>{if(!$('#record').hidden)renderRecord();});}$$('.page').forEach(p=>p.hidden=p.id!==view);$$('.nav').forEach(b=>{b.classList.toggle('active',b.dataset.view===view);if(b.dataset.view===view)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});if(view==='record')renderRecord();if(view!=='experience'){cinema.stop();document.body.classList.remove('cinema-active');}else render();}
$$('[data-view]').forEach(b=>b.addEventListener('click',()=>showView(b.dataset.view)));
$('#voice').addEventListener('click',()=>{if(!demoVoice.available){toast('Audio is unavailable in this browser. The prompt remains visible.');return;}voice=!voice;$('#voice').textContent=voice?'Sound on':'Sound off';$('#voice').setAttribute('aria-pressed',voice);if(voice&&(mode==='free'||document.body.dataset.screen==='stage'))speak(mode==='free'?(free.incident?.state==='check_in'?'Are you okay? Tap “I’m okay” to cancel this test.':'Ready when you are.'):$('#heard').textContent,false,mode==='free'?'guardian':sceneAt(story,time,frameAt(story,time,cancelledAt),opening)?.role??'guardian');else stopSpeech();if(mode==='free')free.render();else render();});
$('#hear').addEventListener('click',()=>{if(!demoVoice.available){toast('Audio is unavailable. Read the prompt beside this button.');return;}speak($('#heard').textContent,true,sceneAt(story,time,frameAt(story,time,cancelledAt),opening)?.role??'guardian');});
$('#fullscreen').addEventListener('click',async()=>{try{if(document.fullscreenElement)await document.exitFullscreen();else await document.documentElement.requestFullscreen();}catch{toast('Fullscreen is unavailable. Use your browser’s presentation controls.');}});
document.addEventListener('fullscreenchange',()=>$('#fullscreen').textContent=document.fullscreenElement?'Exit ↙':'Expand ↗');
$('#stories').innerHTML=stories.map(s=>`<button class="story-card" data-story="${s.id}"><span class="story-number">${s.number}</span><span class="moment-name">${s.id==='threat'?'A voice in the dark.':s.id==='fall'?'An unexpected fall.':'A moment of doubt.'}</span><span class="moment-arrow" aria-hidden="true">↗</span></button>`).join('')+'<button class="story-card real-moment" data-free><span class="story-number">04</span><span class="moment-name">Test it out yourself.</span><span class="moment-arrow" aria-hidden="true">↗</span></button>';
$('[data-free]').addEventListener('click',()=>switchMode('free'));
function showPicker(){$('#source-caption').textContent='Scripted demo · No calls';opening=0;cinema.stop();document.body.classList.remove('cinema-active');running=false;stopSpeech();document.body.dataset.screen='picker';$('#moment-picker').hidden=false;$('#moment-stage').hidden=true;}
function enterMoment(id){story=stories.find(s=>s.id===id);reset();opening=story.id==='threat'?5:0;document.body.dataset.screen='stage';$('#moment-picker').hidden=true;$('#moment-stage').hidden=false;running=true;render();}
$$('.story-card[data-story]').forEach(b=>b.addEventListener('click',()=>enterMoment(b.dataset.story)));
$('#film-play').addEventListener('click',()=>{cinema.resume();running=true;render();});
$('#leave-moment').addEventListener('click',showPicker);$('#choose-another').addEventListener('click',showPicker);
function reset(){opening=0;time=0;running=false;cancelledAt=null;spoken='';phaseKey='';artKey='';sessionNumber++;stopSpeech();$('#world-art').innerHTML='';document.body.dataset.story=story.id;$('#canvas-title').textContent=story.name;$('#input-source-label').textContent=story.id==='fall'?'Injected motion':story.id==='ordinary'?'Manual request':'Scripted speech';$('#story-counter').textContent=`SCENARIO ${story.number} / 03`;$('#scrub').max=story.end;$('#duration').textContent=clock(story.end);render();}
$('#play').addEventListener('click',()=>{if(frameAt(story,time,cancelledAt).complete){reset();opening=story.id==='threat'?5:0;}running=!running;if(!running)stopSpeech();render();});
$('#next').addEventListener('click',()=>{running=false;stopSpeech();if(opening>0){opening=0;render(true);return;}const next=story.steps.find(t=>t>time+.15);time=next??story.end;render(true);});
$('#reset').addEventListener('click',()=>{reset();opening=story.id==='threat'?5:0;running=true;render();});
$('#scrub').addEventListener('input',e=>{time=Number(e.target.value);opening=0;running=false;cancelledAt=null;stopSpeech();artKey='';render();});
$('#cancel').addEventListener('click',()=>{cancelledAt=time;running=true;render(true);});
$('#explain').addEventListener('click',()=>{const open=$('#explanation').hidden;$('#explanation').hidden=!open;$('#explain').setAttribute('aria-expanded',open);$('#explain span').textContent=open?'−':'＋';renderExplanation();});
function renderExplanation(){const f=frameAt(story,time,cancelledAt);$('#explanation').innerHTML=`<strong>${escape(story.summary)}</strong><br>${f.cancelled?'The cancellation is final for this rehearsal. No alert or call follows.':story.id==='threat'?'Notice that the check-in begins before the scripted visual assessment. The car illustrates a safety check; it does not mean police were dispatched.':story.id==='fall'?'Motion is a candidate cue, not a diagnosis. This story supplies a scripted qualifying assessment. The pulse is an illustration, not a vital-sign measurement.':story.id==='ordinary'?'The scripted assessment is ordinary activity, so no check-in appears. Live mode can produce a different result for actual evidence.':'The refusal plea requests a precautionary check-in. The wearer can cancel at any point before the illustrated escalation.'}`;}
function render(forceSpeech=false){
 const f=frameAt(story,time,cancelledAt);document.body.dataset.phase=f.phase;if(f.complete)running=false;const key=opening>0?`opening:${opening>3?'home':'unease'}`:`${story.id}:${f.phase}`;
 $('#play').textContent=f.complete?'Replay':running?'Pause':'Continue';
 $('#next').disabled=f.complete;$('#next').textContent='Skip →';$('#choose-another').hidden=!(f.cancelled||f.phase==='clear'||f.complete);
 $('#scrub').value=Math.min(time,story.end);$('#elapsed').textContent=clock(time);$('#response-title').textContent=f.title;
 $('#response-tag').textContent={standby:'ARMED & READY',trigger:'LOCAL INDICATOR',capture:'BOUNDED CONTEXT',assessing:'SCRIPTED ASSESSMENT','check-in':'CHECKING ON YOU',alert:'ILLUSTRATED ESCALATION',cancelled:'CHECK-IN CANCELLED',clear:'NO ESCALATION'}[f.phase];
 $('#camera-status').textContent=f.recording?'Capture active':'Camera off';$('#camera-status').classList.toggle('recording',f.recording);
 $('#capture-clock').textContent=f.recording?`${(time-3).toFixed(1)}s · active`:'Camera off';
 $('#world-art').classList.toggle('awake',f.captured&&!f.cancelled);
 $('#signal-chip').textContent=time<3?'THE MOMENT':time<7?'A BRIEF CAPTURE':'UNDERSTANDING THE SCENE';
 $('#scene-quote').innerHTML=f.cancelled?'GUARDIAN<br><mark>CANCEL.</mark>':story.id==='threat'?'“I’M GOING TO<br><mark>HURT YOU.</mark>”':story.id==='fall'?'DROP.<br>IMPACT.<br><mark>STILLNESS.</mark>':story.id==='cancel'?'“NO,<br><mark>PLEASE DON’T.</mark>”':'JUST ANOTHER<br><mark>AFTERNOON.</mark>';
 $('#scene-detail').textContent=time<2?'Guardian is armed. The camera is off.':time<3?story.cue:time<7?'A few seconds of context. Then the camera stops.':'The camera is off. Guardian is assessing the scene.';
 if(f.phase==='assessing')$('#scene-quote').innerHTML='CHECKING<br><mark>THE SCENE.</mark>';
 const brief={standby:'Ready.',trigger:'A signal worth checking.',capture:'A short capture for context.',assessing:'The camera is off.','check-in':'Tap below if you’re safe.',alert:'Illustrated demo alert. No call was placed.',cancelled:'The check-in has stopped.',clear:'No check-in needed.'};
 $('#response-detail').textContent=brief[f.phase];
 const nextArt=f.cancelled||f.phase==='clear'?'success':story.id==='cancel'&&f.check?'voice':f.kind??'halo';
 if(artKey!==nextArt){artKey=nextArt;$('#response-art').innerHTML=nextArt==='success'?'<div class="halo success">✓</div>':nextArt==='voice'?guardianMark():artwork(f.kind);$('#response-art').classList.toggle('art-active',Boolean(f.kind));}
 $('#response-art').classList.toggle('static-art',!running);
 renderScore(f);
 $('#countdown-wrap').hidden=!f.check;$('#countdown').textContent=f.countdown??15;$('#countdown-ring').style.strokeDashoffset=276.46*(1-(f.countdown??15)/15);$('#countdown-wrap').style.setProperty('--remaining',`${(f.countdown??15)/15*100}%`);
 $('#cancel').hidden=!(f.check||f.alert);$('#voice-hint').hidden=!(f.check||f.alert);$('#cancel').textContent=f.alert?'Silence alert':'I’m okay';
 $$('[data-step]').forEach(el=>{const i=Number(el.dataset.step);el.classList.toggle('current',i===f.pipeline||(i===3&&f.check));el.classList.toggle('past',i<f.pipeline&&!(i===3&&f.check));});
 let heard=f.cancelled?'Check-in cancelled.':f.alert?'Your alert is active. Say “Guardian cancel” to stop it.':f.check?story.prompt:f.phase==='clear'?story.prompt:f.phase==='standby'?'Guardian is armed.':f.phase==='trigger'?'Guardian received a local indicator.':'Guardian is checking the scene.';
 const cinematic=mode==='rehearsal'&&Boolean(films[story.id])&&document.body.dataset.screen==='stage'&&!$('#experience').hidden;
 document.body.classList.toggle('cinema-active',cinematic);
 cinema.update({active:cinematic,running,time:opening>0?-opening:time,story:story.id});
 $('#pov-meta').hidden=!cinematic;
 $('#pov-capture').textContent=f.recording?'Capturing':time<2?'Camera off':f.cancelled?'Cancelled':time<3?'Waking camera':'Camera off';
 $('#pov-capture').classList.toggle('recording',f.recording);
 $('#caption-speaker').hidden=!cinematic;
 $('#caption-speaker').textContent=f.check||f.alert||f.cancelled?'GLASSES AUDIO':'SCENE NARRATION';
 $('#film-play').hidden=!cinematic||!cinema.blocked;
 $('#film-status').hidden=!cinematic||!(cinema.failed||cinema.waiting||cinema.reduce.matches);
 $('#film-status').textContent=cinema.failed?'Film unavailable. The scripted demonstration continues.':cinema.reduce.matches?'Reduced motion · Footage held still':cinema.waiting?'Loading local footage…':'';
 if(cinematic){
  if(story.id==='fall'){
   $('#signal-chip').textContent=time<2?'A WALK, INTERRUPTED':time<3?'A SUDDEN IMPACT':time<7?'GUARDIAN WAKES':'WAITING FOR CONTEXT';
   $('#scene-quote').innerHTML=time<2?'An ordinary<br>moment.':time<3?'Then the<br><mark>ground moves.</mark>':time<7?'A brief look.<br><mark>For context.</mark>':'A fall?<br><mark>Check first.</mark>';
  }
  if(f.check||f.alert||f.cancelled||f.phase==='clear'){
   $('#scene-quote').innerHTML=f.cancelled?'You answer.<br><mark>Guardian stops.</mark>':f.alert?'No response.<br><mark>An alert begins.</mark>':'You hear<br><mark>“Are you okay?”</mark>';
   $('#scene-detail').textContent=f.cancelled?'The check-in is cancelled.':f.alert?'An illustrated escalation. No calls are placed.':'A spoken check-in through the glasses. Your phone can stay in your pocket.';
   $('#signal-chip').textContent='THE GLASSES SPEAK';
  }
 }

 const scene=sceneAt(story,time,f,opening);
 if(cinematic&&scene){
  $('#signal-chip').textContent=scene.tag;
  $('#scene-quote').innerHTML=scene.quote;
  $('#scene-detail').textContent=scene.detail;
  heard=scene.caption;$('#caption-speaker').textContent=scene.speaker;
  if(scene.phoneTitle)$('#response-title').textContent=scene.phoneTitle;
  if(scene.phoneDetail)$('#response-detail').textContent=scene.phoneDetail;
 }
 if(mode==='rehearsal')$('#source-caption').textContent='Scripted demo · No calls';
 $('#pov-meta .pov-label').textContent=story.id==='threat'?'Stock POV':'Wearable replay';
 if(f.check)$('#response-title').textContent='Are you okay?';
 if(f.cancelled)$('#response-title').textContent='Check-in cancelled';
 if(f.alert)$('#response-title').textContent='Alert active';
 $('#caption-speaker').textContent=($('#caption-speaker').textContent==='GLASSES AUDIO'?'Guardian':$('#caption-speaker').textContent==='YOU'?'You':$('#caption-speaker').textContent==='SCENE NARRATION'?'':$('#caption-speaker').textContent==='VOICE BEHIND YOU'?'Offscreen voice':'Voice');
 $('#heard').textContent=`“${heard}”`;
 const speechKey=`${key}:${scene?.beat??''}`;
 if(speechKey!==phaseKey){phaseKey=speechKey;if((running||forceSpeech)&&heard!==spoken){spoken=heard;if(scene||f.check||f.alert||f.cancelled)speak(heard,false,scene?.role??'guardian');}}
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
function tick(now){const delta=Math.min(.25,(now-lastTick)/1000);lastTick=now;if(running&&mode==='rehearsal'){if(!cinema.waiting&&!cinema.blocked){if(opening>0)opening=Math.max(0,opening-delta);else time=Math.min(story.end,time+delta);}if(now-lastRender>90){render();lastRender=now;}}requestAnimationFrame(tick);}requestAnimationFrame(tick);
document.addEventListener('visibilitychange',()=>{if(document.hidden){running=false;stopSpeech();render();}});
document.addEventListener('keydown',e=>{if(['INPUT','SELECT','TEXTAREA','BUTTON','A'].includes(document.activeElement?.tagName))return;if(e.code==='Space'&&mode==='rehearsal'&&!$('#experience').hidden){e.preventDefault();$('#play').click();}if(e.key==='ArrowRight'&&mode==='rehearsal'&&!$('#experience').hidden){e.preventDefault();$('#next').click();}});
const pipeline=[
 ['Local signal','Only when something matters.','A small indicator wakes Guardian.','In the capture app, local speech, motion, an intentional gesture, or SOS can request action. A browser button substitutes for that input in this studio.','Selected local speech may listen while the app is explicitly armed in the foreground. Standby audio is not uploaded for continuous cloud transcription.'],
 ['Brief capture','Context with a boundary.','A short window, then camera off.','An accepted trigger can open up to eight seconds of capture. Up to six selected frames and optional consented audio provide the assessment context.','Continuous camera preview and gesture recognition are optional modes. The camera-off standby claim applies when those modes are disabled.'],
 ['Assessment','Evidence before assumptions.','The model adds context.','Consent-enabled incident audio can be transcribed by ElevenLabs. The configured Nemotron detector assesses chronological frames, trigger context, and available evidence.','A qualifying result can start a check-in. Uncertain or ordinary results are not shown as confirmed emergencies. Rehearsal results are scripted; live mode shows actual backend output.'],
 ['Check-in','Give the wearer a voice.','“Are you okay?”','The capture app gives a spoken prompt and time to respond. Recognized direct distress or threats can open this check-in before scene assessment finishes.','Say “Guardian cancel” in the capture app or use its cancel control. This web rehearsal uses a button and local voice clips; it does not run the phone’s recognizer.'],
 ['Outcome','Care without overclaiming.','Cancel, resolve, or raise an alert.','Cancellation stops the check-in. If it goes unanswered, the app can activate an audible alert; consented demo dispatch is a separate configured path.','This studio places no calls. Its live sessions disable demo calls. A patrol car is a safety illustration, and the pulse is not a measured heart rate.']
];
$('#pipeline-cards').innerHTML=pipeline.map((p,i)=>`<button class="pipeline-card ${i===0?'selected':''}" data-pipeline="${i}" aria-pressed="${i===0}"><span class="micro">0${i+1} / ${i===0?'WAKE':i===1?'CAPTURE':i===2?'UNDERSTAND':i===3?'RESPOND':'RESOLVE'}</span><h3>${p[0]}</h3><p>${p[1]}</p></button>`).join('');
function showPipeline(i){const p=pipeline[i];$$('[data-pipeline]').forEach(b=>{const selected=Number(b.dataset.pipeline)===i;b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',selected);});$('#pipeline-detail').innerHTML=`<div><span class="micro">INSIDE GUARDIAN / 0${i+1}</span><h2>${p[2]}</h2></div><div><p>${p[3]}</p><p class="detail-note">${p[4]}</p></div>`;}
$$('[data-pipeline]').forEach(b=>b.addEventListener('click',()=>showPipeline(Number(b.dataset.pipeline))));showPipeline(0);
function recordData(){return mode==='free'?free.record():{source:'scripted_rehearsal',story:story.id,id:`REHEARSAL-${String(sessionNumber).padStart(3,'0')}`,positionSeconds:Number(time.toFixed(1)),outcome:frameAt(story,time,cancelledAt).phase,events:eventsAt(story,time,cancelledAt),captureSignature:'not_issued_by_browser',callsPlaced:0};}
function renderRecord(){const data=recordData(),isLive=mode==='free';$('#record-source').textContent=isLive?'LIVE BACKEND · BROWSER INPUT':'SCRIPTED REHEARSAL';$('#record-id').textContent=isLive?(data.sessionId??'NO SESSION YET'):data.id;$('#record-name').textContent=isLive?'Browser analysis session':story.name;$('#record-summary').textContent=isLive?'Actual backend responses and studio actions. Typed phrases use the local matcher. Scene assessments come from the backend.':story.summary;const events=data.events;$('#event-log').innerHTML=events.length?events.map(e=>`<li><time>${clock(e.at)}</time><div><strong>${escape(e.title)}</strong><p>${escape(e.detail)}</p></div></li>`).join(''):'<li><time>—</time><div><strong>No live session yet</strong><p>Choose an input, consent, and explicitly start your test.</p></div></li>';}
$('#export').addEventListener('click',()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(recordData(),null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=`ray-guardian-${mode}-session.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('Session exported with source labels.');});
async function switchMode(next){
 if(next===mode)return;running=false;stopSpeech();cinema.stop();document.body.classList.remove('cinema-active');
 if(mode==='free')await free.stop('Test ended when leaving the experience.',true);
 mode=next;document.body.dataset.mode=mode;$('#rehearsal-content').hidden=mode!=='rehearsal';$('#free-content').hidden=mode!=='free';
 $('#source-caption').textContent=mode==='free'?'Live test · No calls':'Scripted demo · No calls';
 if(mode==='free')free.enter();else {showPicker();render();}
}
reset();showPicker();
