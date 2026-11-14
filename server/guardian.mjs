import { randomUUID } from 'node:crypto';
import { ApiError } from './nemotron.mjs';
import { shouldCheckIn } from './detection.mjs';
import { validateObservation,clearObservation } from './media.mjs';
import { VOICE_PROMPTS } from './elevenlabs.mjs';

const MINUTE=60_000,SESSION_MS=15*MINUTE,RECORD_TTL=24*60*MINUTE;
const SIGNALS=['manual_sos','keyword_sos','keyword_distress','motion','heart_rate','loud_voice'];
const TERMINAL=new Set(['cancelled','acknowledged','closed']);
const CONSENTS=['capture','cloud','audio','voice','demoCalls','location','backgroundEscalation'];
const fail=(status,code,message)=>{throw new ApiError(status,code,message);};

export class GuardianService {
  constructor({store,detect,voice,calls,now=Date.now,checkInMs=15000,providerStatus={},mediaLibrary=null}) {
    this.store=store;this.detect=detect;this.voice=voice;this.calls=calls;this.now=now;this.checkInMs=checkInMs;
    this.providerStatus=providerStatus;this.mediaLibrary=mediaLibrary;
    this.processing=new Map();this.callTasks=new Map();this.audioCache=new Map();this.audioPending=new Map();this.closed=false;
    // A process restart after an ambiguous POST must NEVER automatically redial.
    for(const job of store.list('call_job'))if(job.state==='sending'){
      const incident=store.get('incident',job.id,job.owner);
      if(incident&&!TERMINAL.has(incident.state))this.saveIncident({...incident,state:'call_unknown',call:{...incident.call,status:'unknown_after_restart'}});
      this.store.put('call_job',{...job,state:'unknown'},{owner:job.owner,expires:job.expiresAt});
    }
  }
  health(){return {mode:'demo',providers:this.providerStatus,callTransport:this.calls.transport,ready:Object.values(this.providerStatus).every(p=>p.configured!==false)};}
  requireSession(owner,id){return this.store.get('session',id,owner)??fail(404,'not_found','Session not found.');}
  requireIncident(owner,id){return this.store.get('incident',id,owner)??fail(404,'not_found','Incident not found.');}
  saveSession(value){return this.store.put('session',value,{owner:value.owner,expires:value.expiresAt,expectedRevision:value.revision??0});}
  saveIncident(value){return this.store.put('incident',{...value,updatedAt:this.now()},{owner:value.owner,expires:value.expiresAt,expectedRevision:value.revision??0});}
  createSession(owner,body={}){
    if(body.mode!==undefined&&body.mode!=='demo')fail(403,'demo_only','Only demonstration sessions are supported.');
    const consent=Object.fromEntries(CONSENTS.map(key=>[key,body.consent?.[key]===true]));
    if(consent.audio&&!consent.cloud)fail(400,'invalid_consent','Cloud audio requires cloud consent.');
    const source=['meta_mock','meta_glasses','phone','file_replay'].includes(body.source)?body.source:'meta_mock';
    const enabledSignals=body.enabledSignals??['manual_sos','keyword_sos','keyword_distress','motion','heart_rate'];
    if(!Array.isArray(enabledSignals)||enabledSignals.some(s=>!SIGNALS.includes(s)))fail(400,'invalid_signals','Unknown trigger source.');
    return this.saveSession({id:randomUUID(),owner,mode:'demo',source,consent,enabledSignals:[...new Set(enabledSignals)],
      armed:false,armedUntil:null,createdAt:this.now(),expiresAt:this.now()+RECORD_TTL,heartbeatAt:this.now(),
      windows:[],activeWindow:null,lastAutomaticAt:null,incidentId:null});
  }
  arm(owner,id){
    const s=this.requireSession(owner,id);
    return this.saveSession({...s,armed:true,armedUntil:this.now()+SESSION_MS,heartbeatAt:this.now()});
  }
  heartbeat(owner,id){const s=this.requireSession(owner,id);return this.saveSession({...s,heartbeatAt:this.now()});}
  async disarm(owner,id,{cancelPending=true}={}){
    let s=this.requireSession(owner,id);
    this.processing.get(id)?.abort();
    s=this.saveSession({...s,armed:false,armedUntil:null,activeWindow:null});
    if(cancelPending&&s.incidentId){const i=this.store.get('incident',s.incidentId,owner);if(i&&!TERMINAL.has(i.state))await this.cancel(owner,i.id);}
    return this.requireSession(owner,id);
  }
  requireArmed(s){if(!s.armed||this.now()>=s.armedUntil||this.now()-s.heartbeatAt>30_000)fail(409,'not_armed','Session is disarmed, expired, or has lost its foreground heartbeat.');}
  trigger(owner,id,body={}){
    let s=this.requireSession(owner,id);this.requireArmed(s);
    if(!SIGNALS.includes(body.signal))fail(400,'invalid_signal','Unknown trigger.');
    const intentional=['manual_sos','keyword_sos'].includes(body.signal);
    if(!intentional&&!s.enabledSignals.includes(body.signal))return {accepted:false,reason:'source_disabled',session:s};
    if(body.signal==='loud_voice')return {accepted:false,reason:'loudness_alone_is_not_an_incident',session:s};
    if(!intentional&&s.lastAutomaticAt!==null&&this.now()-s.lastAutomaticAt<60_000)return {accepted:false,reason:'trigger_cooldown',session:s};
    let incident=s.incidentId?this.store.get('incident',s.incidentId,owner):null;
    if(incident&&TERMINAL.has(incident.state))incident=null;
    if(intentional&&!incident){incident=this.newIncident(s,null,body.signal,true);s=this.requireSession(owner,id);}
    if(intentional&&incident?.state==='check_in')incident=this.queueCall({...incident,checkInDeadline:null});
    if(s.activeWindow&&['capturing','processing'].includes(s.activeWindow.state))return {accepted:true,reason:'window_already_active',session:s,incident};
    const recent=s.windows.filter(t=>this.now()-t<10*MINUTE);
    const canCapture=s.consent.capture&&s.consent.cloud&&recent.length<3&&(!recent.length||this.now()-recent.at(-1)>=MINUTE);
    const window=canCapture?{id:randomUUID(),startedAt:this.now(),captureEndsAt:this.now()+8000,uploadEndsAt:this.now()+28000,
      signal:body.signal,state:'capturing',result:null}:null;
    s=this.saveSession({...s,lastAutomaticAt:intentional?s.lastAutomaticAt:this.now(),windows:window?[...recent,this.now()]:recent,
      activeWindow:window,incidentId:incident?.id??s.incidentId});
    return {accepted:true,reason:window?'capture_allowed':!s.consent.capture||!s.consent.cloud?'capture_or_cloud_consent_missing':'capture_budget',
      session:s,incident,window,limits:{maxFrames:6,maxFrameBytes:131072,maxAudioMs:8000,audioAllowed:s.consent.audio}};
  }
  async observe(owner,id,body,disconnectSignal){
    let s=this.requireSession(owner,id);this.requireArmed(s);
    if(!s.consent.capture||!s.consent.cloud)fail(403,'consent_required','Capture and cloud consent are required.');
    const observation=validateObservation(body);
    const window=s.activeWindow;
    try{
      if(!window||window.id!==observation.windowId)fail(409,'window_mismatch','Capture window is no longer current.');
      if(window.state==='complete')return window.result;
      if(window.state==='processing')fail(409,'already_processing','This observation is already processing; poll the session.');
      if(window.state!=='capturing'||this.now()>window.uploadEndsAt)fail(409,'window_expired','Capture upload window expired.');
      if((observation.audio||observation.transcript)&&!s.consent.audio)fail(403,'audio_consent_required','Audio upload is not enabled.');
      if(this.processing.size>=2)fail(503,'busy','Two observations are already processing.');
      const controller=new AbortController();
      const abort=()=>controller.abort();
      disconnectSignal?.addEventListener('abort',abort,{once:true});
      if(disconnectSignal?.aborted)controller.abort();
      this.processing.set(id,controller);
      s=this.saveSession({...s,activeWindow:{...window,state:'processing'}});
      try{
        let transcript=observation.transcript;
        let audioSource=null;
        if(observation.audio){const recognized=await this.voice.transcribe(observation.audio.bytes,controller.signal);transcript=recognized.text;audioSource=recognized.source;}
        if(controller.signal.aborted)fail(499,'request_cancelled','Observation cancelled.');
        const detection=await this.detect({frames:observation.frames,transcript,trigger:window.signal,source:observation.source},controller.signal);
        if(controller.signal.aborted)fail(499,'request_cancelled','Observation cancelled.');
        s=this.requireSession(owner,id);
        if(!s.armed||s.activeWindow?.id!==window.id||!s.consent.cloud)fail(409,'window_cancelled','The session changed during analysis.');
        let incident=s.incidentId?this.store.get('incident',s.incidentId,owner):null;
        if(incident&&TERMINAL.has(incident.state))incident=null;
        if(!incident&&shouldCheckIn(detection)){incident=this.newIncident(s,detection,window.signal,false);s=this.requireSession(owner,id);}
        else if(incident){incident=this.saveIncident({...incident,detection,detectedBy:detection.source});}
        const result={detection,incident,audioTranscriptionSource:audioSource,framesAnalyzed:observation.frames.length,
          audioDurationMs:observation.audio?.durationMs??0,rawMediaRetained:false};
        s=this.requireSession(owner,id);
        this.saveSession({...s,activeWindow:{...s.activeWindow,state:'complete',result},incidentId:incident?.id??s.incidentId});
        return result;
      }catch(error){
        const current=this.store.get('session',id,owner);
        if(current?.activeWindow?.id===window.id)this.saveSession({...current,activeWindow:{...current.activeWindow,state:controller.signal.aborted?'cancelled':'failed',error:error instanceof ApiError?error.code:'analysis_failed'}});
        throw error;
      }finally{
        disconnectSignal?.removeEventListener('abort',abort);
        if(this.processing.get(id)===controller)this.processing.delete(id);
      }
    }finally{clearObservation(observation);}
  }
  newIncident(session,detection,trigger,intentional){
    if(this.store.list('incident',session.owner).filter(i=>this.now()-i.createdAt<10*MINUTE).length>=3)fail(429,'incident_budget','Three demonstration incidents per ten minutes are allowed.');
    const incident=this.saveIncident({id:randomUUID(),owner:session.owner,sessionId:session.id,mode:'demo',state:'check_in',
      trigger,detection,detectedBy:detection?.source??null,createdAt:this.now(),updatedAt:this.now(),expiresAt:this.now()+RECORD_TTL,
      checkInDeadline:intentional?this.now():this.now()+this.checkInMs,call:null,acknowledgedAt:null,cancelledAt:null,location:null,
      voiceConsent:session.consent.voice,demoCallConsent:session.consent.demoCalls});
    this.saveSession({...session,incidentId:incident.id});
    return intentional?this.queueCall(incident):incident;
  }
  queueCall(incident){
    if(TERMINAL.has(incident.state))return incident;
    if(!incident.demoCallConsent||!incident.voiceConsent)return this.saveIncident({...incident,state:'needs_demo_call_consent',checkInDeadline:null});
    const queued=this.saveIncident({...incident,state:'call_queued',checkInDeadline:null,call:{transport:this.calls.transport,status:'queued',providerCallId:null}});
    if(!this.store.get('call_job',incident.id,incident.owner))this.store.put('call_job',{
      id:incident.id,owner:incident.owner,state:'ready',createdAt:this.now(),expiresAt:incident.expiresAt,
    },{owner:incident.owner,expires:incident.expiresAt,expectedRevision:0});
    return queued;
  }
  async cancel(owner,id){
    let incident=this.requireIncident(owner,id);
    if(incident.state==='cancelled')return incident;
    this.processing.get(incident.sessionId)?.abort();
    incident=this.saveIncident({...incident,state:'cancelled',cancelledAt:this.now(),checkInDeadline:null,call:incident.call&&!incident.call.providerCallId&&incident.call.transport==='twilio'?{...incident.call,status:'cancellation_unconfirmed'}:incident.call});
    const job=this.store.get('call_job',id,owner);
    if(job)this.store.put('call_job',{...job,state:job.state==='sending'?'cancel_requested':'cancelled'},{owner,expires:job.expiresAt});
    if(incident.call?.providerCallId){
      try{await this.calls.cancel(incident.call.providerCallId);incident=this.saveIncident({...this.requireIncident(owner,id),call:{...incident.call,status:'cancellation_requested'}});}
      catch{incident=this.saveIncident({...this.requireIncident(owner,id),call:{...incident.call,status:'cancellation_unconfirmed'}});}
    }
    const s=this.store.get('session',incident.sessionId,owner);
    if(s)this.saveSession({...s,activeWindow:null});
    this.audioCache.delete(id);
    return incident;
  }
  acknowledge(owner,id){
    const i=this.requireIncident(owner,id);
    if(i.state==='cancelled')fail(409,'incident_cancelled','A cancelled incident cannot be acknowledged.');
    if(!['demo_call_active','call_queued','call_ringing','call_in_progress','call_completed','acknowledged'].includes(i.state))fail(409,'invalid_state','The demo call is not awaiting acknowledgment.');
    return this.saveIncident({...i,state:'acknowledged',acknowledgedAt:this.now(),checkInDeadline:null});
  }
  location(owner,id,location){
    const i=this.requireIncident(owner,id),s=this.requireSession(owner,i.sessionId);
    if(!s.consent.location)fail(403,'location_consent_required','Location sharing is disabled.');
    if(!Number.isFinite(location?.latitude)||Math.abs(location.latitude)>90||!Number.isFinite(location.longitude)||Math.abs(location.longitude)>180||
      !Number.isFinite(location.accuracyMeters)||location.accuracyMeters<0||location.accuracyMeters>10000||!Number.isFinite(location.timestamp)||Math.abs(this.now()-location.timestamp)>120000)fail(400,'invalid_location','Send a fresh location with accuracy and timestamp.');
    return this.saveIncident({...i,location:{latitude:location.latitude,longitude:location.longitude,accuracyMeters:location.accuracyMeters,timestamp:location.timestamp}});
  }
  callScript(i){
    const summary=(i.detection?.summary??'The wearer deliberately requested help.').slice(0,600);
    const location=i.location?`Reported coordinates: ${i.location.latitude.toFixed(4)}, ${i.location.longitude.toFixed(4)}. Accuracy ${Math.round(i.location.accuracyMeters)} meters.`:'No location was shared.';
    return `This is a Ray Guardian demonstration, not an emergency call. No police or ambulance have been dispatched. ${summary} ${location} Press one to acknowledge this demonstration, or two to repeat this message.`;
  }
  async callAudio(id,owner=null,signal){
    const i=this.store.get('incident',id,owner)??fail(404,'not_found','Demo incident not found.');
    if(i.state==='cancelled')fail(410,'incident_cancelled','Demo call was cancelled.');
    if(!i.voiceConsent||!i.demoCallConsent)fail(403,'voice_consent_required','Demo call audio requires voice and demo-call consent.');
    if(!i.call)fail(409,'call_not_started','Demo call has not started.');
    const cached=this.audioCache.get(id);
    if(cached&&cached.expires>this.now())return cached.audio;
    if(this.audioPending.has(id))return this.audioPending.get(id);
    const pending=(async()=>{
      const audio=await this.voice.speak(this.callScript(i),signal);
      if(this.requireIncident(i.owner,id).state==='cancelled')fail(410,'incident_cancelled','Demo call was cancelled.');
      this.audioCache.set(id,{expires:this.now()+10*MINUTE,audio});
      while(this.audioCache.size>32)this.audioCache.delete(this.audioCache.keys().next().value);
      return audio;
    })();
    this.audioPending.set(id,pending);
    try{return await pending;}finally{this.audioPending.delete(id);}
  }

  async prompt(owner,{purpose,incidentId,sessionId},signal){
    if(!Object.hasOwn(VOICE_PROMPTS,purpose))fail(400,'invalid_prompt','Unknown voice prompt.');
    if(incidentId){const i=this.requireIncident(owner,incidentId);if(!i.voiceConsent)fail(403,'voice_consent_required','Voice output is disabled for this incident.');}
    else if(!sessionId||!this.requireSession(owner,sessionId).consent.voice)fail(403,'voice_consent_required','Voice output requires consent.');
    return this.voice.speak(VOICE_PROMPTS[purpose],signal);
  }
  async sweep(){
    if(this.closed)return;
    this.store.purge();
    for(const [key,value] of this.audioCache)if(value.expires<=this.now())this.audioCache.delete(key);
    for(let s of this.store.list('session')){
      if(s.armed&&(this.now()>=s.armedUntil||this.now()-s.heartbeatAt>30000))await this.disarm(s.owner,s.id,{cancelPending:!s.consent.backgroundEscalation});
    }
    for(const i of this.store.list('incident'))if(i.state==='check_in'&&this.now()>=i.checkInDeadline)this.queueCall(i);
    for(const job of this.store.list('call_job')){
      if(job.state!=='ready'||this.callTasks.has(job.id))continue;
      const task=this.runCall(job).catch(()=>{}).finally(()=>this.callTasks.delete(job.id));
      this.callTasks.set(job.id,task);
    }
  }
  async runCall(job){
    let i=this.requireIncident(job.owner,job.id);let dialAttempted=false;
    if(i.state!=='call_queued'){this.store.put('call_job',{...job,state:'cancelled'},{owner:job.owner,expires:job.expiresAt});return;}
    this.store.put('call_job',{...job,state:'sending'},{owner:job.owner,expires:job.expiresAt});
    try{
      // Prepare genuine ElevenLabs speech before placing a phone call, so it cannot silently use fake audio.
      if(this.calls.transport==='twilio')await this.callAudio(i.id,i.owner);
      if(this.requireIncident(i.owner,i.id).state==='cancelled'){this.store.put('call_job',{...job,state:'cancelled'},{owner:job.owner,expires:job.expiresAt});return;}
      dialAttempted=true;
      const result=await this.calls.place(i);
      const current=this.requireIncident(i.owner,i.id);
      if(current.state==='cancelled'){
        let status='cancelled_before_delivery';
        if(result.providerCallId)try{await this.calls.cancel(result.providerCallId);status='cancellation_requested';}catch{status='cancellation_unconfirmed';}
        this.saveIncident({...current,call:{...result,status}});
      }else this.saveIncident({...current,state:current.state==='call_queued'?(result.transport==='playback'?'demo_call_active':'call_queued'):current.state,call:{...result,...(current.call?.providerCallId?current.call:{})}});
      this.store.put('call_job',{...job,state:'sent'},{owner:job.owner,expires:job.expiresAt});
    }catch(error){
      i=this.requireIncident(job.owner,job.id);
      // A lost response may hide a successful dial. No automatic retry.
      if(i.state!=='cancelled')this.saveIncident({...i,state:dialAttempted?'call_unknown':'call_failed',call:{transport:this.calls.transport,status:dialAttempted?'unconfirmed':'not_placed',error:error instanceof ApiError?error.code:'call_failed',providerCallId:null}});
      this.store.put('call_job',{...job,state:dialAttempted?'unknown':'failed'},{owner:job.owner,expires:job.expiresAt});
    }
  }
  async twilioStatus(id,body){
    const i=this.store.get('incident',id)??fail(404,'not_found','Incident not found.');
    if(i.call?.providerCallId&&i.call.providerCallId!==body.CallSid)fail(403,'call_mismatch','Callback is for a different call.');
    const states={queued:'call_queued',initiated:'call_queued',ringing:'call_ringing','in-progress':'call_in_progress',completed:'call_completed',busy:'call_failed',failed:'call_failed','no-answer':'call_failed',canceled:'call_failed'};
    const next=states[body.CallStatus];if(!next)fail(400,'invalid_call_status','Unknown call status.');
    if(i.state==='cancelled'){
      let status=body.CallStatus;
      if(['queued','initiated','ringing','in-progress'].includes(body.CallStatus)){
        try{await this.calls.cancel(body.CallSid);status='cancellation_requested';}catch{status='cancellation_unconfirmed';}
      }
      return this.saveIncident({...this.requireIncident(i.owner,id),call:{...i.call,transport:'twilio',providerCallId:body.CallSid,status}});
    }
    const order={call_queued:0,call_ringing:1,call_in_progress:2,call_completed:3,call_failed:3};
    if(TERMINAL.has(i.state)||(order[i.state]??-1)>order[next])return i;
    return this.saveIncident({...i,state:next,call:{...i.call,transport:'twilio',status:body.CallStatus,providerCallId:body.CallSid}});
  }
  async close(){this.closed=true;for(const c of this.processing.values())c.abort();await Promise.allSettled(this.callTasks.values());this.audioCache.clear();}
}
