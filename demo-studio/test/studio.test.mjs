import test from 'node:test';
import assert from 'node:assert/strict';
import {createStudioServer} from '../server.mjs';
import {stories,frameAt,eventsAt,sceneAt} from '../public/stories.js';
import {filmPosition} from '../public/cinema.js';
const story=id=>stories.find(s=>s.id===id);
test('speech check-in precedes scene assessment',()=>{
 const threat=frameAt(story('threat'),3);assert.equal(threat.check,true);assert.equal(threat.assessed,false);assert.equal(threat.kind,'patrol');
});
test('cancellation stops countdown and artwork, including after the old deadline',()=>{
 for(const t of [8,18,40]){const f=frameAt(story('cancel'),t);assert.equal(f.cancelled,true);assert.equal(f.countdown,null);assert.equal(f.kind,null);assert.equal(f.alert,false);}
 const manual=frameAt(story('threat'),21,6);assert.equal(manual.alert,false);assert.equal(manual.cancelled,true);
 assert.ok(!eventsAt(story('threat'),21,6).some(e=>e.title==='Demo alert activated'));
 assert.ok(!eventsAt(story('threat'),21,6).some(e=>e.title==='Scripted assessment'));
 assert.ok(eventsAt(story('threat'),21,12).some(e=>e.title==='Scripted assessment'));
});
test('fall assessment gates its check-in and the countdown reaches the illustrated alert',()=>{
 assert.equal(frameAt(story('fall'),9).check,false);assert.equal(frameAt(story('fall'),10).countdown,15);
 assert.equal(frameAt(story('fall'),24.1).countdown,1);assert.equal(frameAt(story('fall'),25).alert,true);
 assert.equal(frameAt(story('fall'),3).recording,true);assert.equal(frameAt(story('fall'),8).recording,false);
});
test('POV clock follows skips and holds the end of a fall instead of looping',()=>{
 assert.equal(filmPosition('threat',-5,30),0);
 assert.equal(filmPosition('threat',0,30),5);
 assert.equal(filmPosition('threat',18,30),23);
 assert.equal(filmPosition('fall',3,8),3);
 assert.equal(filmPosition('fall',25,8),7.92);
 assert.equal(filmPosition('fall',0,8),0);
 assert.equal(filmPosition('fall',25,8,true),0);
 assert.equal(filmPosition('fall',25,NaN),0);
 assert.equal(filmPosition('cancel',8,10),8);
});
test('dialogue, wearer cancellation, and confirmation follow the actual cancellation time',()=>{
 const threat=story('threat');assert.equal(sceneAt(threat,2,frameAt(threat,2)).role,'offscreen');
 assert.equal(sceneAt(threat,3,frameAt(threat,3)).role,'guardian');
 const cancel=story('cancel');
 assert.equal(sceneAt(cancel,8,frameAt(cancel,8)).role,'wearer');
 assert.equal(sceneAt(cancel,9.7,frameAt(cancel,9.7)).caption,'Check-in cancelled.');
 assert.equal(sceneAt(cancel,4,frameAt(cancel,4,4)).role,'wearer');
 assert.equal(sceneAt(cancel,5.7,frameAt(cancel,5.7,4)).caption,'Check-in cancelled.');
});
const sessionId='11111111-1111-4111-8111-111111111111',windowId='22222222-2222-4222-8222-222222222222';
async function setup(t){const calls=[];const server=createStudioServer({token:'private-test-token',fetchUpstream:async(url,init)=>{const payload=init.body?JSON.parse(init.body):null;calls.push({path:url.pathname,payload,headers:init.headers});const response=url.pathname==='/health'?{aiConfigured:true}:url.pathname==='/v1/sessions'?{id:sessionId}:url.pathname.endsWith('/triggers')?{session:{id:sessionId},window:{id:windowId,captureEndsAt:Date.now()+8000}}:url.pathname.endsWith('/observations')?{detection:{label:'ordinary_activity',source:'test_only'},incident:null}:{id:sessionId};return new Response(JSON.stringify(response),{headers:{'Content-Type':'application/json'}});}});await new Promise(r=>server.listen(0,'127.0.0.1',r));const base=`http://127.0.0.1:${server.address().port}`;t.after(async()=>{await server.stopSessions();await new Promise(r=>server.close(r));});const post=(route,data={},origin=base)=>fetch(base+route,{method:'POST',headers:{'Content-Type':'application/json',Origin:origin},body:JSON.stringify(data)});return {base,post,calls};}
test('local proxy owns its sessions, disables calls/audio, and preserves source',async t=>{
 const {post,calls}=await setup(t);assert.equal((await post('/api/live/start',{source:'file_replay',signal:'manual_check',consent:{demoCalls:true}})).status,200);
 const create=calls.find(c=>c.path==='/v1/sessions');assert.equal(create.payload.source,'file_replay');assert.equal(create.payload.consent.demoCalls,false);assert.equal(create.payload.consent.audio,false);assert.equal(create.payload.consent.voice,false);
 const unknown=await post('/api/live/99999999-9999-4999-8999-999999999999/cancel');assert.equal(unknown.status,404);
 const frames=[{offsetMs:10,imageDataUrl:'data:image/jpeg;base64,/9j/AA=='}];assert.equal((await post(`/api/live/${sessionId}/observe`,{frames,source:'meta_glasses',signature:'forged'})).status,200);
 const observation=calls.find(c=>c.path.endsWith('/observations'));assert.equal(observation.payload.source,'file_replay');assert.equal(observation.payload.windowId,windowId);assert.equal(observation.payload.signature,undefined);assert.equal(observation.headers.Authorization,'Bearer private-test-token');
 assert.equal((await post(`/api/live/${sessionId}/cancel`)).status,200);assert.equal(calls.at(-1).payload.cancelPending,true);
});
test('cross-origin writes and glasses source spoofing are rejected',async t=>{
 const {post,calls}=await setup(t);assert.equal((await post('/api/live/start',{source:'file_replay',signal:'manual_check'},'https://example.com')).status,403);
 assert.equal((await post('/api/live/start',{source:'meta_glasses',signal:'manual_check'})).status,400);assert.equal(calls.length,0);
});
test('unbounded or out-of-order frames never reach the backend',async t=>{
 const {post,calls}=await setup(t);await post('/api/live/start',{source:'phone',signal:'motion'});
 const frame={offsetMs:10,imageDataUrl:'data:image/jpeg;base64,/9j/AA=='};
 for(const frames of [[frame,frame],Array(7).fill(frame),[{...frame,offsetMs:9000}]])assert.equal((await post(`/api/live/${sessionId}/observe`,{frames})).status,400);
 assert.equal(calls.filter(c=>c.path.endsWith('/observations')).length,0);
});
test('studio serves all offline assets without exposing the root environment',async t=>{
 const {base}=await setup(t);for(const route of ['/','/app.js','/art.js','/stories.js','/cinema.js','/free.js','/free-signals.js','/voice.js','/voice-lines.js','/style.css']){const res=await fetch(base+route);assert.equal(res.status,200);assert.ok(!(await res.text()).includes('private-test-token'));}
 const clip=await fetch(base+'/assets/voice/check-in.wav',{headers:{Range:'bytes=0-31'}});assert.equal(clip.status,206);assert.equal(clip.headers.get('content-type'),'audio/wav');assert.equal(Buffer.from(await clip.arrayBuffer()).toString('ascii',0,4),'RIFF');
 const scene=await fetch(base+'/assets/rain-runner-v1.png');assert.equal(scene.headers.get('content-type'),'image/png');assert.deepEqual([...new Uint8Array(await scene.arrayBuffer()).slice(0,8)],[137,80,78,71,13,10,26,10]);
 assert.equal((await fetch(base+'/.env')).status,404);assert.equal((await fetch(base+'/server.mjs')).status,404);
});
test('offline films support seeking, suffix ranges, HEAD, and reject invalid ranges',async t=>{
 const {base}=await setup(t);
 for(const film of ['corridor','fall','night','courtyard','woods']){
  const url=base+`/assets/${film}-pov.mp4`;
  const head=await fetch(url,{method:'HEAD'});assert.equal(head.status,200);assert.equal(head.headers.get('content-type'),'video/mp4');
  const size=Number(head.headers.get('content-length'));assert.ok(size>10000);assert.equal((await head.arrayBuffer()).byteLength,0);
  const first=await fetch(url,{headers:{Range:'bytes=0-31'}});assert.equal(first.status,206);assert.equal(first.headers.get('content-range'),`bytes 0-31/${size}`);
  const bytes=Buffer.from(await first.arrayBuffer());assert.equal(bytes.length,32);assert.equal(bytes.subarray(4,8).toString(),'ftyp');
  const suffix=await fetch(url,{headers:{Range:'bytes=-16'}});assert.equal(suffix.status,206);assert.equal((await suffix.arrayBuffer()).byteLength,16);
  const bounded=await fetch(url,{headers:{Range:`bytes=${size-10}-${size+100}`}});assert.equal(bounded.status,206);assert.equal((await bounded.arrayBuffer()).byteLength,10);
  for(const range of [`bytes=${size}-`,'bytes=40-10','bytes=0-1,5-6','bytes=-0','garbage']){
   const res=await fetch(url,{headers:{Range:range}});assert.equal(res.status,416);assert.equal(res.headers.get('content-range'),`bytes */${size}`);await res.arrayBuffer();
  }
  assert.equal((await fetch(base+`/assets/${film}-pov.jpg`)).status,200);
 }
});
