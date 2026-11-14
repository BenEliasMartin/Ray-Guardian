import {artwork,guardianMark} from './art.js';
import {recordingKind,voiceIntent} from './free-signals.js';
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function incidentSeconds(incident,now=Date.now()){
 return incident?.state==='check_in'&&Number.isFinite(incident.checkInDeadline)?Math.max(0,Math.ceil((incident.checkInDeadline-now)/1000)):null;
}
const delay=(ms,signal)=>new Promise((resolve,reject)=>{if(signal.aborted)return reject(new Error('Stopped.'));const timer=setTimeout(done,ms);function done(){signal.removeEventListener('abort',abort);resolve();}function abort(){clearTimeout(timer);reject(new Error('Stopped.'));}signal.addEventListener('abort',abort,{once:true});});
export class FreeExperience{
 constructor(root,{speak=()=>{},stopSpeech=()=>{},onBack=()=>{}}={}){
  this.root=root;this.$=s=>root.querySelector(s);this.speak=speak;this.stopSpeech=stopSpeech;this.onBack=onBack;this.epoch=0;this.source='phone';this.events=[];this.offset=0;this.phase='ready';this.online=false;
  this.$('#free-back').onclick=onBack;
  this.$('#free-camera').onclick=()=>this.selectCamera();
  this.$('#free-file').onchange=e=>this.selectFile(e.target.files?.[0]);
  this.$('#free-consent').onchange=()=>this.controls();
  this.$('#free-run').onclick=()=>this.begin();
  this.$('#free-stop').onclick=()=>this.stop('Test ended.');
  this.$('#free-safe').onclick=()=>this.stop('Check-in cancelled.');
  this.$('#free-again').onclick=()=>{this.phase='ready';this.render();};
  document.addEventListener('visibilitychange',()=>{if(document.hidden)this.stop('Stopped when the tab left the foreground.',true);});
  addEventListener('pagehide',()=>{this.stopMedia();if(this.session)navigator.sendBeacon(`/api/free/${this.session}/cancel`,new Blob(['{}'],{type:'application/json'}));});
  this.render();
 }
 event(title,detail){this.events.push({at:this.started?(Date.now()-this.started)/1000:0,title,detail});}
 async api(path,payload,signal){
  const res=await fetch(path,{method:payload?'POST':'GET',headers:payload?{'Content-Type':'application/json'}:{},body:payload?JSON.stringify(payload):undefined,signal});
  const data=await res.json();if(!res.ok)throw new Error(data.message??'The backend request failed.');
  if(Number.isFinite(data.serverNow))this.offset=data.serverNow-Date.now();return data;
 }
 async enter(){this.render();await this.health();}
 async health(){
  this.$('#free-connection').textContent='Connecting…';
  try{const h=await this.api('/api/health');this.online=h.online&&h.clientConfigured;
   this.$('#free-connection').textContent=!h.online?'Backend offline':!h.clientConfigured?'Connection not configured':h.aiConfigured?'Connected':'AI not connected';
   this.$('#free-offline').hidden=this.online;
   this.$('#free-offline').textContent=!h.online?'Connect the backend to try this.':'The backend connection needs configuring.';
  }catch{this.online=false;this.$('#free-connection').textContent='Backend unavailable';this.$('#free-offline').hidden=false;}
  this.controls();
 }
 async selectCamera(){await this.stop('',true);this.source='phone';if(this.fileURL)URL.revokeObjectURL(this.fileURL);this.fileURL=null;this.$('#free-video').removeAttribute('src');this.$('#free-file').value='';this.phase='ready';this.$('#free-file-name').textContent='Camera starts when you tap Start.';this.render();}
 async selectFile(file){if(!file)return;await this.stop('',true);if(this.fileURL)URL.revokeObjectURL(this.fileURL);this.source='file_replay';this.fileURL=URL.createObjectURL(file);const video=this.$('#free-video');video.src=this.fileURL;video.load();this.phase='ready';this.$('#free-file-name').textContent=file.name;this.render();}
 controls(){
  const busy=['starting','capturing','analyzing','monitoring','stopping'].includes(this.phase);
  this.$('#free-run').disabled=busy||!this.online||!this.$('#free-consent').checked;
  for(const id of ['free-camera','free-file','free-consent','free-phrase'])this.$('#'+id).disabled=busy;
  this.$('#free-camera').setAttribute('aria-pressed',String(this.source==='phone'));
  this.$('#free-video-source').classList.toggle('selected',this.source==='file_replay');
  this.$('#free-stop').hidden=!busy||this.phase==='stopping';
 }
 stopMedia(){clearTimeout(this.captureTimer);this.stream?.getTracks().forEach(t=>t.stop());this.stream=null;this.$('#free-video').pause();this.$('#free-video').srcObject=null;this.capturing=false;}
 async stop(message='Test ended.',silent=false){
  this.stopSpeech();
  const epoch=++this.epoch,id=this.session;this.session=null;this.controller?.abort();this.stopMedia();this.clearTimers();
  if(!id){if(!silent&&message){this.phase='stopped';this.message=message;this.render();}return;}
  this.phase='stopping';this.render();
  try{await this.api(`/api/free/${id}/cancel`,{});if(this.incident)this.incident={...this.incident,state:'cancelled',checkInDeadline:null};this.event('Test ended','Backend confirmed disarm and cancellation of pending check-in.');if(epoch!==this.epoch)return;this.message=message||'Test ended.';this.phase='stopped';if(!silent)this.speak(this.message);}
  catch{if(epoch!==this.epoch)return;this.phase='error';this.message='Camera stopped. Backend cancellation could not be confirmed; it will be retried by server cleanup.';this.event('Cancellation unconfirmed',this.message);}
  if(epoch===this.epoch)this.render();
 }
 clearTimers(){clearInterval(this.pollTimer);clearInterval(this.uiTimer);clearInterval(this.heartbeat);clearTimeout(this.sessionTimer);}
 async finish(epoch){
  const id=this.session;if(!id)return;
  await this.api(`/api/free/${id}/cancel`,{});
  if(epoch!==this.epoch)return;this.session=null;this.clearTimers();this.event('Session disarmed','The one-shot test is complete. Camera and microphone are off.');this.phase='complete';this.render();
 }
 updateIncident(incident){
  if(!incident)return;const previous=this.incident?.id+':'+this.incident?.state;this.incident=incident;
  if(previous!==incident.id+':'+incident.state){this.event('Backend incident state',incident.state);
   if(incident.state==='check_in')this.speak('Are you okay? Tap “I’m okay” to cancel this test.');
   if(incident.state==='needs_demo_call_consent')this.speak('The check-in has ended. This demo won’t make any calls.');
  }
  this.renderCompanion();
 }
 async begin(){
  if(!this.online||!this.$('#free-consent').checked||['starting','capturing','analyzing','monitoring','stopping'].includes(this.phase))return;
  await this.stop('',true);const epoch=++this.epoch;this.controller=new AbortController();const signal=this.controller.signal;
  this.started=Date.now();this.events=[];this.result=null;this.incident=null;this.artKey='';this.pollErrors=0;this.recordSession=null;this.still=null;this.phase='starting';this.message='Connecting to Guardian…';this.render();
  const phrase=this.$('#free-phrase').value.trim();
  try{
   // Always collect the create response so a late start can be disarmed after Stop.
   const start=await this.api('/api/free/start',{capture:true,cloud:true,source:this.source});
   const id=start.session.id;if(epoch!==this.epoch){await this.api(`/api/free/${id}/cancel`,{});return;}
   this.session=id;this.recordSession=id;this.event('Real session armed',`Source: ${this.source}. Calls and microphone disabled.`);
   const trigger=await this.api(`/api/free/${id}/trigger`,phrase?{action:'speech',input:'typed',utterance:phrase}:{action:'check'},signal);
   if(epoch!==this.epoch)return;
   this.event('Wake request',phrase?`Typed cue matched locally: ${voiceIntent(phrase)??'none'}. No speech recognition is running.`:'Explicit manual scene check.');
   this.updateIncident(trigger.incident);
   if(trigger.cancelled){this.session=null;this.phase='stopped';this.message='Cancellation phrase accepted. Camera stayed off.';this.render();return;}
   if(!trigger.accepted){this.message='No wake phrase matched. Camera stayed off.';await this.finish(epoch);return;}
   this.startTimers(epoch);
   if(!trigger.window){this.message=`No capture opened: ${String(trigger.reason).replaceAll('_',' ')}.`;this.phase=this.incident?'monitoring':'complete';this.render();if(!this.incident)await this.finish(epoch);return;}
   this.phase='capturing';this.capturing=true;this.message='Capturing…';this.render();
   const window=trigger.window,remaining=()=>window.captureEndsAt-(Date.now()+this.offset),video=this.$('#free-video');
   this.captureTimer=setTimeout(()=>{if(epoch!==this.epoch)return;if(this.incident){this.stopMedia();this.phase='monitoring';this.message='Capture window ended. Your check-in is still active.';this.render();}else this.stop('Capture window expired. Camera stopped.',true);},Math.max(0,remaining()));
   if(this.source==='phone'){
    const pending=navigator.mediaDevices?.getUserMedia({video:{width:{ideal:640},height:{ideal:480}},audio:false});
    if(!pending)throw new Error('Camera access is unavailable. Choose a local video instead.');
    const stream=await pending;
    if(epoch!==this.epoch||remaining()<=0){stream.getTracks().forEach(t=>t.stop());if(epoch===this.epoch)throw new Error('The capture window expired while awaiting camera permission. Try again.');return;}
    this.stream=stream;video.srcObject=stream;
   }else{video.currentTime=0;}
   await video.play();const until=Date.now()+Math.max(0,remaining());
   while(video.readyState<2||!video.videoWidth){if(Date.now()>=until)throw new Error('The video did not become ready inside the capture window.');await delay(50,signal);}
   const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d'),scale=Math.min(1,640/Math.max(video.videoWidth,video.videoHeight));canvas.width=Math.round(video.videoWidth*scale);canvas.height=Math.round(video.videoHeight*scale);
   const frames=[];
   for(let i=0;i<6;i++){
    if(epoch!==this.epoch||signal.aborted)return;
    const offsetMs=Math.max(0,Math.round(Date.now()+this.offset-window.startedAt));
    if(remaining()<=0||offsetMs>8000)throw new Error('The capture window expired. No late frames were uploaded.');
    ctx.drawImage(video,0,0,canvas.width,canvas.height);let imageDataUrl=canvas.toDataURL('image/jpeg',.6);if(imageDataUrl.length>174000)imageDataUrl=canvas.toDataURL('image/jpeg',.3);
    frames.push({offsetMs,imageDataUrl});this.still=imageDataUrl;this.$('#free-capture-status').textContent=`Capturing · ${i+1}/6`;if(i<5)await delay(550,signal);
   }
   this.stopMedia();this.event('Capture stopped','Six scene frames captured. No audio recorded.');this.phase='analyzing';this.message='Camera off. Assessing…';this.render();
   const result=await this.api(`/api/free/${id}/observe`,{frames},signal);if(epoch!==this.epoch)return;
   this.result=result;this.updateIncident(result.incident);this.event('Actual assessment',`${result.detection?.label??'No label'} · ${result.detection?.source??'unspecified'}`);
   this.phase=this.incident?'monitoring':'complete';this.message='';this.render();
   if(!this.incident)await this.finish(epoch);else await this.poll(epoch);
  }catch(error){
   if(epoch!==this.epoch)return;this.stopMedia();
   if(this.incident&&this.session){this.phase='monitoring';this.message=(error.message.includes('VERDA_INFERENCE_KEY')?'Scene AI is not configured on the connected backend.':error.message)+' Your check-in remains active.';this.event('Scene check incomplete',error.message);this.render();await this.poll(epoch);return;}
   this.clearTimers();this.phase='error';this.message=error.message;this.event('Test incomplete',error.message);this.render();
   const id=this.session;
   if(id)try{await this.api(`/api/free/${id}/cancel`,{});if(epoch===this.epoch){this.session=null;if(this.incident)this.incident={...this.incident,state:'cancelled',checkInDeadline:null};this.render();}}catch{if(epoch===this.epoch){this.message+=' Camera is off; backend cancellation could not be confirmed.';this.render();}}
  }
 }
 startTimers(epoch){
  this.pollTimer=setInterval(()=>this.poll(epoch),1000);this.uiTimer=setInterval(()=>this.renderCompanion(),200);
  this.heartbeat=setInterval(()=>{const id=this.session;if(id)this.api(`/api/free/${id}/heartbeat`,{}).catch(()=>this.stop('Connection lost. Camera stopped.',true));},10000);
  this.sessionTimer=setTimeout(()=>this.stop('The test reached its time limit.',true),90000);
 }
 async poll(epoch){
  if(this.polling||!this.session||epoch!==this.epoch)return;this.polling=true;
  try{const state=await this.api(`/api/free/${this.session}/state`);if(epoch!==this.epoch)return;this.pollErrors=0;this.updateIncident(state.incident);
   if(!state.session.armed){await this.stop('The backend ended this session.',true);return;}
   if(this.phase==='monitoring'&&this.incident&&this.incident.state!=='check_in')await this.finish(epoch);
  }catch{if(epoch===this.epoch&&++this.pollErrors>=3)await this.stop('Connection lost. Camera stopped.',true);}
  finally{this.polling=false;}
 }
 renderCompanion(){
  const incident=this.incident,panel=this.$('#free-companion');panel.hidden=!incident||['ready','stopped','error'].includes(this.phase);
  if(panel.hidden)return;
  const kind=recordingKind(incident),key=incident.id+':'+kind;
  if(key!==this.artKey){this.artKey=key;this.$('#free-art').innerHTML=kind?artwork(kind):guardianMark();}
  const count=incidentSeconds(incident,Date.now()+this.offset);
  this.$('#free-count-wrap').hidden=count===null;this.$('#free-count').textContent=count??'';
  this.$('#free-response-title').textContent=incident.state==='check_in'?(count===0?'Confirming outcome…':'Are you okay?'):incident.state==='needs_demo_call_consent'?'Demo alert paused':String(incident.state).replaceAll('_',' ');
  this.$('#free-response-detail').textContent=incident.state==='check_in'?'':'Calls disabled for this demo.';
  this.$('#free-safe').hidden=!this.session;
 }
 render(){
  this.root.dataset.phase=this.phase;this.root.classList.toggle('has-assessment',Boolean(this.result));const ready=this.phase==='ready';this.$('#free-setup').hidden=!ready;this.$('#free-stage').hidden=ready;
  const media=this.$('#free-media');media.hidden=ready||(!this.still&&!this.capturing);
  this.$('#free-video').hidden=!this.capturing;this.$('#free-still').hidden=this.capturing||!this.still;if(this.still)this.$('#free-still').src=this.still;
  this.$('#free-capture-status').textContent=this.capturing?'Capturing':'Camera off';
  const detection=this.result?.detection,unavailable=detection?.source==='nemotron_unavailable';
  const titles={starting:'Waking Guardian.',capturing:'Checking the scene',analyzing:'Assessing scene',monitoring:this.incident?.state==='check_in'?'Check-in':'Check-in ended',complete:unavailable?'Assessment unavailable.':detection?String(detection.label).replaceAll('_',' '):'Test complete.',stopped:this.message||'Test ended.',stopping:'Stopping the test.',error:'The test didn’t finish.'};
  this.$('#free-title').textContent=titles[this.phase]??'Your turn.';
  const detail=this.message||detection?.summary||'';
  this.$('#free-detail').textContent=detail===this.$('#free-title').textContent?'':detail;
  this.$('#free-result-source').textContent=detection?`ACTUAL ASSESSMENT / ${detection.source??'UNSPECIFIED SOURCE'}`:'REAL BACKEND / YOUR INPUT';
  this.$('#free-again').hidden=!['complete','stopped','error'].includes(this.phase);
  this.renderCompanion();this.controls();
 }
 record(){return {source:'real_backend',input:this.source,sessionId:this.recordSession,incident:this.incident,result:this.result,events:this.events,captureSignature:'not_issued_by_browser',callsEnabled:false};}
}
