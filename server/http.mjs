import {createServer} from 'node:http';
import {createHash,timingSafeEqual} from 'node:crypto';
import {ApiError,validateInput} from './nemotron.mjs';
import {createSimulatedDispatch} from './simulated-dispatch.mjs';
import {readBody,readJSON,sendJSON} from './lib/transport.mjs';
const equal=(a,b)=>{const x=Buffer.from(a??''),y=Buffer.from(b);return x.length===y.length&&timingSafeEqual(x,y);};
const clean=value=>JSON.parse(JSON.stringify(value,(key,item)=>key==='owner'?undefined:item));
const binary=(res,audio)=>{res.writeHead(200,{'Content-Type':audio.contentType,'Content-Length':audio.bytes.length,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(audio.bytes);};
export function createGuardianHTTP({guardian,clientToken,analyze,speak,now=Date.now}){
  if(!clientToken||clientToken.length<32)throw new Error('RAY_GUARDIAN_CLIENT_TOKEN needs at least 32 characters.');
  const dispatch=createSimulatedDispatch();
  const owner=createHash('sha256').update(clientToken).digest('hex');
  let requests=0,voiceRequests=0,legacyRequests=0,legacyInFlight=0,windowStart=now(),sweeping=false;
  const server=createServer(async(req,res)=>{
    const abort=new AbortController();res.on('close',()=>{if(!res.writableFinished)abort.abort();});
    try{
      const url=new URL(req.url,'http://localhost'),path=url.pathname;
      if(req.method==='GET'&&path==='/health')return sendJSON(res,200,{status:'ok',aiConfigured:guardian.providerStatus.nemotron?.configured??false,speechConfigured:guardian.providerStatus.elevenlabs?.configured??false,...guardian.health()});
      const callback=path.match(/^\/v1\/twilio\/(status|ack)\/([a-f0-9-]{36})$/);
      if(callback&&req.method==='POST'){
        if(!/^application\/x-www-form-urlencoded(?:;|$)/i.test(req.headers['content-type']??''))throw new ApiError(415,'form_required','Send a signed form.');
        const form=new URLSearchParams((await readBody(req,16384)).toString()),params={};
        for(const [key,value] of form){if(Object.hasOwn(params,key))throw new ApiError(400,'duplicate_parameter','Duplicate callback parameter.');params[key]=value;}
        if(!guardian.calls.verifyWebhook(req.url,params,req.headers['x-twilio-signature']))throw new ApiError(403,'invalid_signature','Invalid callback signature.');
        if(!/^CA[a-fA-F0-9]{32}$/.test(params.CallSid??''))throw new ApiError(400,'invalid_call','Invalid call identifier.');
        const incident=guardian.store.get('incident',callback[2]);
        if(!incident)throw new ApiError(404,'not_found','Incident not found.');
        if(incident.call?.providerCallId&&incident.call.providerCallId!==params.CallSid)throw new ApiError(403,'call_mismatch','Different call identifier.');
        if(callback[1]==='status'){await guardian.twilioStatus(incident.id,params);res.writeHead(204);return res.end();}
        let xml;
        if(incident.state==='cancelled')xml='<?xml version="1.0"?><Response><Say>This demonstration was cancelled.</Say><Hangup/></Response>';
        else if(params.Digits==='1'){guardian.acknowledge(incident.owner,incident.id);xml=guardian.calls.twiml(incident.id,{acknowledged:true});}
        else xml=guardian.calls.twiml(incident.id);
        res.writeHead(200,{'Content-Type':'application/xml','Cache-Control':'no-store'});return res.end(xml);
      }
      const media=path.match(/^\/v1\/demo-calls\/([a-f0-9-]{36})\/audio$/);
      const authenticated=equal(req.headers.authorization,`Bearer ${clientToken}`);
      if(media&&req.method==='GET'&&!authenticated){
        if(!guardian.calls.verifyMedia(media[1],url.searchParams.get('expires'),url.searchParams.get('signature')))throw new ApiError(403,'invalid_signature','Expired or invalid audio link.');
        return binary(res,await guardian.callAudio(media[1],null,abort.signal));
      }
      if(!authenticated)throw new ApiError(401,'unauthorized','Bearer authentication is required.');
      if(req.headers.origin)throw new ApiError(403,'browser_origin_not_allowed','Native clients only.');
      if(now()-windowStart>=60000){requests=0;voiceRequests=0;legacyRequests=0;windowStart=now();}
      if(++requests>300)throw new ApiError(429,'rate_limited','Request budget exceeded.');
      const speech=path.match(/^\/v1\/speech\/([a-z_]{1,40})$/);
      if(speech&&req.method==='GET'){
        if(!speak)throw new ApiError(503,'speech_not_configured','Legacy speech is not configured.');
        return binary(res,{bytes:await speak(speech[1]),contentType:'audio/mpeg'});
      }
      if(path==='/v1/simulated-dispatch'&&req.method==='POST')return sendJSON(res,200,dispatch(await readJSON(req)));
      if(req.method==='POST'&&path==='/v1/sessions')return sendJSON(res,201,clean(guardian.createSession(owner,await readJSON(req))));
      if(req.method==='GET'&&path==='/v1/incidents')return sendJSON(res,200,clean({incidents:guardian.store.list('incident',owner)}));
      const session=path.match(/^\/v1\/sessions\/([a-f0-9-]{36})(?:\/(arm|disarm|heartbeat|triggers|observations))?$/);
      if(session){
        const [,id,action]=session;
        if(req.method==='GET'&&!action)return sendJSON(res,200,clean(guardian.requireSession(owner,id)));
        if(req.method==='DELETE'&&!action){await guardian.disarm(owner,id);guardian.store.delete('session',id,owner);return sendJSON(res,200,{deleted:true});}
        if(req.method==='POST'){
          const body=await readJSON(req);let result;
          switch(action){
            case 'arm':result=guardian.arm(owner,id);break;
            case 'disarm':result=await guardian.disarm(owner,id,{cancelPending:body.cancelPending!==false});break;
            case 'heartbeat':result=guardian.heartbeat(owner,id);break;
            case 'triggers':result=guardian.trigger(owner,id,body);break;
            case 'observations':result=await guardian.observe(owner,id,body,abort.signal);break;
            default:throw new ApiError(404,'not_found','Endpoint not found.');
          }return sendJSON(res,200,clean(result));
        }
      }
      const incident=path.match(/^\/v1\/incidents\/([a-f0-9-]{36})(?:\/(cancel|acknowledge|location))?$/);
      if(incident){
        const [,id,action]=incident;
        if(req.method==='GET'&&!action)return sendJSON(res,200,clean(guardian.requireIncident(owner,id)));
        if(req.method==='DELETE'&&!action){await guardian.cancel(owner,id);await guardian.callTasks.get(id);guardian.store.delete('call_job',id,owner);guardian.store.delete('incident',id,owner);return sendJSON(res,200,{deleted:true});}
        if(req.method==='POST'){
          const body=await readJSON(req);let result;
          if(action==='cancel')result=await guardian.cancel(owner,id);
          else if(action==='acknowledge')result=guardian.acknowledge(owner,id);
          else if(action==='location')result=guardian.location(owner,id,body);
          else throw new ApiError(404,'not_found','Endpoint not found.');
          return sendJSON(res,200,clean(result));
        }
      }
      if(media&&req.method==='GET')return binary(res,await guardian.callAudio(media[1],owner,abort.signal));
      if(path==='/v1/voice/prompts'&&req.method==='POST'){if(++voiceRequests>20)throw new ApiError(429,'voice_budget','Voice prompt budget reached.');return binary(res,await guardian.prompt(owner,await readJSON(req),abort.signal));}
      if(path==='/v1/analyze'&&req.method==='POST'&&analyze){
        if(legacyRequests>=10)throw new ApiError(429,'rate_limited','Summary request budget reached.');
        if(legacyInFlight>=2)throw new ApiError(503,'busy','Summary processing is busy.');
        const input=validateInput(await readJSON(req));legacyRequests++;legacyInFlight++;
        try{return sendJSON(res,200,{...await analyze(input,abort.signal),advisoryOnly:true});}finally{legacyInFlight--;}
      }
      if(path==='/v1/replays'&&req.method==='GET')return sendJSON(res,200,guardian.mediaLibrary?.manifest??{clips:[]});
      const replay=path.match(/^\/v1\/replays\/([a-zA-Z0-9_-]+)\/(video|audio)$/);
      if(replay&&req.method==='GET'&&guardian.mediaLibrary)return binary(res,await guardian.mediaLibrary.read(replay[1],replay[2]));
      throw new ApiError(404,'not_found','Endpoint not found.');
    }catch(error){sendJSON(res,error instanceof ApiError?error.status:500,{error:error instanceof ApiError?error.code:'internal_error',message:error instanceof ApiError?error.message:'Request could not be completed.'});}
  });
  const timer=setInterval(async()=>{if(sweeping)return;sweeping=true;try{await guardian.sweep();}catch{console.error('Incident maintenance failed; inspect service configuration.');}finally{sweeping=false;}},500);timer.unref();
  server.on('close',()=>clearInterval(timer));server.requestTimeout=15000;server.headersTimeout=10000;server.timeout=90000;
  return server;
}
