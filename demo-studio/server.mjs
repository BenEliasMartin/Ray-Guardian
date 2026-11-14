import {createServer} from 'node:http';
import {freeAPI,FreeError} from './free-api.mjs';
import {voiceLines} from './public/voice-lines.js';
import {readFile,stat} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root=fileURLToPath(new URL('./public/',import.meta.url));
const files=new Map([['/',['index.html','text/html; charset=utf-8']],['/style.css',['style.css','text/css']],['/app.js',['app.js','text/javascript']],['/art.js',['art.js','text/javascript']],['/stories.js',['stories.js','text/javascript']],['/cinema.js',['cinema.js','text/javascript']],['/assets/rain-runner-v1.png',['assets/rain-runner-v1.png','image/png']]]);
for(const name of ['free.js','free-signals.js','voice.js','voice-lines.js'])files.set('/'+name,[name,'text/javascript']);
for(const {id} of voiceLines)files.set(`/assets/voice/${id}.wav`,[`assets/voice/${id}.wav`,'audio/wav']);
const idPattern=/^[a-f0-9-]{36}$/;
for(const name of ['corridor','fall','night','courtyard','woods']){
 files.set(`/assets/${name}-pov.mp4`,[`assets/${name}-pov.mp4`,'video/mp4']);
 files.set(`/assets/${name}-pov.jpg`,[`assets/${name}-pov.jpg`,'image/jpeg']);
}
class StudioError extends Error{constructor(status,message){super(message);this.status=status;}}
const json=(res,status,data)=>{if(res.destroyed)return;res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(data));};
async function body(req,maxBytes=1100*1024){let size=0;const chunks=[];for await(const chunk of req){size+=chunk.length;if(size>maxBytes)throw new StudioError(413,'This check exceeds the bounded frame upload size.');chunks.push(chunk);}try{const data=JSON.parse(Buffer.concat(chunks).toString());if(!data||Array.isArray(data)||typeof data!=='object')throw Error();return data;}catch{throw new StudioError(400,'Send a JSON object.');}}
export function createStudioServer({backend=process.env.DEMO_BACKEND_URL??'http://127.0.0.1:8787',token=process.env.RAY_GUARDIAN_CLIENT_TOKEN??'',fetchUpstream=fetch}={}){
 const sessions=new Map();let serverOffset=0;
 const base=new URL(backend);if(!['http:','https:'].includes(base.protocol)||base.username||base.password)throw new Error('DEMO_BACKEND_URL must be an HTTP(S) URL without credentials.');
 async function upstream(route,payload,timeout=45000){
  let response;try{response=await fetchUpstream(new URL(route,base),{method:payload?'POST':'GET',headers:{Authorization:`Bearer ${token}`,...(payload?{'Content-Type':'application/json'}:{})},body:payload?JSON.stringify(payload):undefined,signal:AbortSignal.timeout(timeout)});}catch{throw new StudioError(502,'The backend could not be reached. Rehearsal remains available.');}
  const serverDate=Date.parse(response.headers.get('date'));if(Number.isFinite(serverDate))serverOffset=serverDate-Date.now();
  let data;try{data=await response.json();}catch{throw new StudioError(502,'The backend returned an unreadable response.');}
  if(!response.ok)throw new StudioError(response.status,String(data.message??'The backend rejected this request.'));
  return data;
 }
 async function disarm(id){if(!sessions.has(id))return;await upstream(`/v1/sessions/${id}/disarm`,{cancelPending:true},5000);sessions.delete(id);}
 const freeRoute=freeAPI({sessions,upstream,disarm,body,json,hasToken:()=>Boolean(token),now:()=>Date.now()+serverOffset});
 const cleanup=setInterval(()=>{for(const [id,s] of sessions)if(Date.now()-s.touched>60000)disarm(id).catch(()=>{});},15000);cleanup.unref();
 const server=createServer(async(req,res)=>{
  res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
  res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
  res.setHeader('Permissions-Policy','camera=(self), microphone=(), geolocation=()');
  try{
   const port=server.address()?.port,allowed=[`127.0.0.1:${port}`,`localhost:${port}`];
   if(!allowed.includes(req.headers.host))throw new StudioError(403,'This studio accepts local access only.');
   const url=new URL(req.url,'http://127.0.0.1');
   if(req.method==='POST'&&!allowed.map(h=>`http://${h}`).includes(req.headers.origin))throw new StudioError(403,'Use the studio page on this local server.');
   if(req.method==='GET'&&url.pathname==='/api/health'){
    try{const health=await upstream('/health',null,2500);return json(res,200,{online:true,clientConfigured:Boolean(token),aiConfigured:health.aiConfigured===true,speechConfigured:health.speechConfigured===true});}
    catch{return json(res,200,{online:false,clientConfigured:Boolean(token),aiConfigured:false,speechConfigured:false});}
   }
   if(await freeRoute(req,res,url))return;
   if(req.method==='POST'&&url.pathname==='/api/live/start'){
    if(!token)throw new StudioError(503,'Configure RAY_GUARDIAN_CLIENT_TOKEN in the root .env and start the backend. Rehearsal works without it.');
    if(sessions.size>=3)throw new StudioError(429,'Finish the current demo check before opening another.');
    const data=await body(req);
    if(!['phone','file_replay'].includes(data.source)||!['manual_check','spoken_threat','keyword_distress','motion'].includes(data.signal))throw new StudioError(400,'Choose a browser input and an available injected cue.');
    const session=await upstream('/v1/sessions',{mode:'demo',source:data.source,automaticSceneChecks:false,speechMonitoring:false,enabledSignals:['manual_check','spoken_threat','keyword_distress','motion'],consent:{capture:true,cloud:true,audio:false,voice:false,demoCalls:false,location:false,backgroundEscalation:false}});
    if(!idPattern.test(session.id))throw new StudioError(502,'The backend did not return a valid session.');
    sessions.set(session.id,{source:data.source,window:null,touched:Date.now()});
    try{await upstream(`/v1/sessions/${session.id}/arm`,{});const reply=await upstream(`/v1/sessions/${session.id}/triggers`,{signal:data.signal});sessions.get(session.id).window=reply.window?.id??null;json(res,200,reply);}catch(error){await disarm(session.id).catch(()=>{});throw error;}
    return;
   }
   const action=url.pathname.match(/^\/api\/live\/([a-f0-9-]{36})\/(observe|heartbeat|cancel)$/);
   if(req.method==='POST'&&action){
    const [,id,verb]=action,s=sessions.get(id);if(!s||s.kind==='free')throw new StudioError(404,'This session does not belong to this studio.');
    const data=await body(req);s.touched=Date.now();
    if(verb==='cancel'){await disarm(id);return json(res,200,{disarmed:true,cancelPending:true});}
    if(verb==='heartbeat')return json(res,200,await upstream(`/v1/sessions/${id}/heartbeat`,{}));
    if(!s.window)throw new StudioError(409,'There is no accepted capture window.');
    if(!Array.isArray(data.frames)||data.frames.length<1||data.frames.length>6)throw new StudioError(400,'Send one to six captured frames.');
    const frames=data.frames.map((frame,i)=>{
     if(!frame||!Number.isInteger(frame.offsetMs)||frame.offsetMs<0||frame.offsetMs>8000||(i&&frame.offsetMs<=data.frames[i-1].offsetMs)||typeof frame.imageDataUrl!=='string'||frame.imageDataUrl.length>175000||!/^data:image\/jpeg;base64,[A-Za-z0-9+/]+=*$/.test(frame.imageDataUrl))throw new StudioError(400,'Frames must be bounded chronological JPEG images.');
     return {offsetMs:frame.offsetMs,imageDataUrl:frame.imageDataUrl};
    });
    const result=await upstream(`/v1/sessions/${id}/observations`,{windowId:s.window,source:s.source,frames});
    return json(res,200,result);
   }
   const file=files.get(url.pathname);
   if(file&&['video/mp4','audio/wav'].includes(file[1])&&['GET','HEAD'].includes(req.method)){
    const filename=path.join(root,file[0]),{size}=await stat(filename);
    let start=0,end=size-1,status=200;
    if(req.headers.range){
     const match=/^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
     if(!match||(!match[1]&&!match[2])){res.writeHead(416,{'Content-Range':`bytes */${size}`});return res.end();}
     if(!match[1])start=Math.max(0,size-Number(match[2]));
     else {start=Number(match[1]);if(match[2])end=Math.min(end,Number(match[2]));}
     if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>end||start>=size){res.writeHead(416,{'Content-Range':`bytes */${size}`});return res.end();}
     status=206;
    }
    res.writeHead(status,{'Content-Type':file[1],'Accept-Ranges':'bytes','Content-Length':end-start+1,'Cache-Control':'no-cache',...(status===206?{'Content-Range':`bytes ${start}-${end}/${size}`}:{})});
    if(req.method==='HEAD')return res.end();
    const stream=createReadStream(filename,{start,end});stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());stream.pipe(res);return;
   }
   if(file&&req.method==='GET'){res.writeHead(200,{'Content-Type':file[1],'Cache-Control':'no-cache'});res.end(await readFile(path.join(root,file[0])));return;}
   throw new StudioError(404,'Not found.');
  }catch(error){json(res,error instanceof StudioError||error instanceof FreeError?error.status:500,{message:error instanceof StudioError||error instanceof FreeError?error.message:'The studio request could not be completed.'});}
 });
 server.on('close',()=>{clearInterval(cleanup);for(const id of sessions.keys())disarm(id).catch(()=>{});});
 server.stopSessions=()=>Promise.allSettled([...sessions.keys()].map(disarm));
 return server;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 const server=createStudioServer();const port=Number(process.env.DEMO_STUDIO_PORT??4174);
 server.listen(port,'127.0.0.1',()=>console.log(`Ray Guardian Demo Studio: http://127.0.0.1:${port}`));
 for(const signal of ['SIGTERM','SIGINT'])process.on(signal,async()=>{await server.stopSessions();server.close(()=>process.exit(0));});
}
