import {voiceIntent} from './public/free-signals.js';
import {validateObservation,clearObservation} from '../server/media.mjs';
export class FreeError extends Error{constructor(status,message){super(message);this.status=status;}}
const fail=(status,message)=>{throw new FreeError(status,message);};
export function freeAPI({sessions,upstream,disarm,body,json,hasToken,now=Date.now}){
 const reply=(res,data)=>json(res,200,{...data,serverNow:now()});
 return async(req,res,url)=>{
  if(req.method==='POST'&&url.pathname==='/api/free/start'){
   if(!hasToken())fail(503,'Configure the backend connection before starting a test.');
   if(sessions.size>=3)fail(429,'Finish the current session before starting another.');
   const data=await body(req);if(data.capture!==true||data.cloud!==true)fail(403,'Capture and cloud-assessment consent are required.');
   if(!['phone','file_replay'].includes(data.source))fail(400,'Choose the browser camera or a local video.');
   const session=await upstream('/v1/sessions',{mode:'demo',source:data.source,automaticSceneChecks:false,speechMonitoring:false,enabledSignals:['manual_check','spoken_threat','keyword_distress'],consent:{capture:true,cloud:true,audio:false,voice:false,demoCalls:false,location:false,backgroundEscalation:false}});
   if(!/^[a-f0-9-]{36}$/.test(session.id))fail(502,'The backend did not return a valid session.');
   sessions.set(session.id,{kind:'free',source:data.source,window:null,incident:null,touched:Date.now()});
   try{const armed=await upstream(`/v1/sessions/${session.id}/arm`,{});reply(res,{session:armed});}catch(error){await disarm(session.id).catch(()=>{});throw error;}return true;
  }
  const match=url.pathname.match(/^\/api\/free\/([a-f0-9-]{36})\/(trigger|observe|state|heartbeat|cancel)$/);if(!match)return false;
  const [,id,action]=match,s=sessions.get(id);if(!s||s.kind!=='free')fail(404,'This session does not belong to this test.');
  if(req.method!=='POST'&&!(action==='state'&&req.method==='GET'))fail(405,'Unsupported request.');
  s.touched=Date.now();
  if(action==='state'){
   const session=await upstream(`/v1/sessions/${id}`,null,6000);
   const incident=session.incidentId?await upstream(`/v1/incidents/${session.incidentId}`,null,6000):null;
   s.incident=incident?.id??null;reply(res,{session,incident});return true;
  }
  const data=await body(req);
  if(action==='cancel'){await disarm(id);reply(res,{disarmed:true,cancelPending:true});return true;}
  if(action==='heartbeat'){reply(res,{session:await upstream(`/v1/sessions/${id}/heartbeat`,{})});return true;}
  if(action==='trigger'){
   let signal;
   if(data.action==='check')signal='manual_check';
   else if(data.action==='speech'){
    if(typeof data.utterance!=='string'||data.utterance.length>300||data.input!=='typed')fail(400,'Provide a short typed phrase.');
    const intent=voiceIntent(data.utterance);
    if(intent==='cancel'){await disarm(id);reply(res,{cancelled:true});return true;}
    signal={threat:'spoken_threat',distress:'keyword_distress'}[intent];
    if(!signal){reply(res,{accepted:false,reason:'no_matching_local_cue'});return true;}
   }else fail(400,'Choose a scene check or a typed wake phrase.');
   const result=await upstream(`/v1/sessions/${id}/triggers`,{signal});
   s.window=result.window?.id??null;s.incident=result.incident?.id??s.incident;
   reply(res,{...result,cueSource:data.action==='speech'?'typed_local_match':'manual_request'});return true;
  }
  if(action==='observe'){
   if(!s.window)fail(409,'There is no accepted capture window.');
   if(data.audio!=null||data.transcript!=null)fail(403,'Audio and transcript uploads are disabled in this browser test.');
   if(!Array.isArray(data.frames)||data.frames.length<1)fail(400,'Provide captured scene frames.');
   let validated;
   try{validated=validateObservation({windowId:s.window,source:s.source,frames:data.frames});}catch(error){fail(error.status??400,error.message);}
   try{
    const result=await upstream(`/v1/sessions/${id}/observations`,{windowId:s.window,source:s.source,frames:validated.frames.map(f=>({offsetMs:f.offsetMs,imageDataUrl:f.imageDataUrl}))});
    s.incident=result.incident?.id??s.incident;reply(res,result);
   }finally{clearObservation(validated);}return true;
  }
  return false;
 };
}
