import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {createStudioServer} from '../server.mjs';
import {GuardianService} from '../../server/guardian.mjs';
import {EncryptedStore} from '../../server/store.mjs';
import {createGuardianHTTP} from '../../server/http.mjs';
import {voiceIntent,recordingKind} from '../public/free-signals.js';
import {incidentSeconds} from '../public/free.js';
const png='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1i8AAAAASUVORK5CYII=';
const evidence={frames:[{offsetMs:100,imageDataUrl:png}]};
async function fixture(t,{label='ordinary_activity',pending=false}={}){
 let now=Date.now(),placed=0;const observed=[];let resolve;
 const deferred=new Promise(r=>resolve=r),store=new EncryptedStore({path:':memory:',key:randomBytes(32).toString('hex'),now:()=>now});
 const guardian=new GuardianService({store,now:()=>now,detect:async input=>{observed.push(input);if(pending)await deferred;return {label,confidence:'high',summary:'Integration-test fixture assessment.',observations:['Integration-test visual evidence.'],uncertainties:[],wearerInvolved:label!=='ordinary_activity',source:'nemotron'};},voice:{},calls:{transport:'playback',place:async()=>{placed++;throw Error('Calls must not run.');},cancel:async()=>{}}});
 const backend=createGuardianHTTP({guardian,clientToken:'fixture-token-for-local-integration-only-0001'});await new Promise(r=>backend.listen(0,'127.0.0.1',r));
 const studio=createStudioServer({backend:`http://127.0.0.1:${backend.address().port}`,token:'fixture-token-for-local-integration-only-0001'});await new Promise(r=>studio.listen(0,'127.0.0.1',r));
 t.after(async()=>{resolve();await studio.stopSessions();await new Promise(r=>studio.close(r));await new Promise(r=>backend.close(r));await guardian.close();store.close();});
 const base=`http://127.0.0.1:${studio.address().port}`,post=(route,data={})=>fetch(base+route,{method:'POST',headers:{'Content-Type':'application/json',Origin:base},body:JSON.stringify(data)});
 const start=async(source='phone')=>{const response=await post('/api/free/start',{capture:true,cloud:true,source});assert.equal(response.status,200);return (await response.json()).session.id;};
 return {base,post,start,guardian,observed,resolve,advance:async ms=>{now+=ms;await guardian.sweep();},placed:()=>placed};
}
test('free phrases recognize direct danger and pleas, without treating routine help as distress',()=>{
 for(const text of ["I'm in danger",'please help me I’m in danger',"no please don't",'please stop','I cannot breathe'])assert.equal(voiceIntent(text),'distress',text);
 assert.equal(voiceIntent("I'll kill you"),'threat');assert.equal(voiceIntent('Guardian cancel'),'cancel');
 for(const text of ['help me with my homework','ordinary conversation',"don't help me"])assert.equal(voiceIntent(text),null,text);
 assert.equal(incidentSeconds({state:'check_in',checkInDeadline:12000},9000),3);
 assert.equal(incidentSeconds({state:'check_in',checkInDeadline:12000},13000),0);
 assert.equal(incidentSeconds({state:'cancelled',checkInDeadline:12000},9000),null);
});
test('real service: manual scene check preserves file source and ordinary result creates no incident',async t=>{
 const f=await fixture(t),id=await f.start('file_replay');
 const trigger=await (await f.post(`/api/free/${id}/trigger`,{action:'check'})).json();assert.ok(trigger.window);assert.equal(trigger.incident,null);
 const result=await (await f.post(`/api/free/${id}/observe`,{...evidence,source:'meta_glasses',signature:'not-trusted'})).json();
 assert.equal(result.detection.label,'ordinary_activity');assert.equal(result.incident,null);assert.equal(f.observed[0].source,'file_replay');
 const current=await (await fetch(f.base+`/api/free/${id}/state`)).json();assert.equal(current.session.consent.demoCalls,false);assert.equal(current.session.consent.audio,false);assert.equal(current.session.consent.voice,false);
 assert.equal((await f.post(`/api/free/${id}/cancel`)).status,200);assert.equal(f.placed(),0);
});
test('real service: typed threat creates early check-in; cancelling aborts pending analysis',async t=>{
 const f=await fixture(t,{label:'possible_assault',pending:true}),id=await f.start();
 const cue=await (await f.post(`/api/free/${id}/trigger`,{action:'speech',input:'typed',utterance:"I'll kill you"})).json();
 assert.equal(cue.incident.state,'check_in');assert.equal(recordingKind(cue.incident),'patrol');assert.equal(f.observed.length,0);
 const request=f.post(`/api/free/${id}/observe`,evidence);
 for(let n=0;!f.observed.length&&n<200;n++)await new Promise(r=>setTimeout(r,5));assert.equal(f.observed.length,1);
 assert.equal((await f.post(`/api/free/${id}/cancel`)).status,200);f.resolve();assert.equal((await request).status,499);
 await f.advance(20000);const incidents=f.guardian.store.list('incident');assert.equal(incidents.length,1);assert.equal(incidents[0].state,'cancelled');assert.equal(f.placed(),0);
 assert.equal((await fetch(f.base+`/api/free/${id}/state`)).status,404);
});
test('real service: unmatched phrase opens no capture and fall result uses backend deadline',async t=>{
 const f=await fixture(t,{label:'possible_fall'}),id=await f.start();
 const unmatched=await (await f.post(`/api/free/${id}/trigger`,{action:'speech',input:'typed',utterance:'help me with homework'})).json();assert.equal(unmatched.accepted,false);assert.equal(f.observed.length,0);
 const cue=await (await f.post(`/api/free/${id}/trigger`,{action:'check'})).json();assert.ok(cue.window);
 const result=await (await f.post(`/api/free/${id}/observe`,evidence)).json();assert.equal(result.incident.state,'check_in');assert.equal(recordingKind(result.incident),'pulse');assert.equal(result.incident.checkInDeadline-result.incident.createdAt,30000);assert.equal(incidentSeconds(result.incident,result.incident.createdAt+4000),26);
 await f.advance(20000);assert.equal((await f.post(`/api/free/${id}/heartbeat`)).status,200);
 await f.advance(11000);const state=await (await fetch(f.base+`/api/free/${id}/state`)).json();assert.equal(state.incident.state,'needs_demo_call_consent');assert.equal(f.placed(),0);
});
test('free adapter rejects spoofed input, extra audio, oversized frames, and foreign sessions',async t=>{
 const f=await fixture(t);
 assert.equal((await f.post('/api/free/start',{source:'meta_glasses',capture:true,cloud:true})).status,400);
 assert.equal((await f.post('/api/free/start',{source:'phone',capture:false,cloud:true})).status,403);
 const id=await f.start();
 assert.equal((await f.post(`/api/free/${id}/trigger`,{action:'speech',input:'on_device_speech',utterance:'help'})).status,400);
 assert.equal((await f.post(`/api/free/${id}/trigger`,{action:'sos'})).status,400);
 await f.post(`/api/free/${id}/trigger`,{action:'check'});
 assert.equal((await f.post(`/api/free/${id}/observe`,{...evidence,audio:{base64:'AA=='}})).status,403);
 assert.equal((await f.post(`/api/free/${id}/observe`,{frames:Array(7).fill(evidence.frames[0])})).status,400);
 assert.equal((await f.post('/api/free/11111111-1111-4111-8111-111111111111/cancel')).status,404);
 const cross=await fetch(f.base+'/api/free/start',{method:'POST',headers:{Origin:'https://example.com','Content-Type':'application/json'},body:'{}'});assert.equal(cross.status,403);
 assert.equal(f.observed.length,0);
});
