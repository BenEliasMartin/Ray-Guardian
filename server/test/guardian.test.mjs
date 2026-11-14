import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,createHmac} from 'node:crypto';
import {mkdtempSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {EncryptedStore} from '../store.mjs';
import {GuardianService} from '../guardian.mjs';
import {createGuardianHTTP} from '../http.mjs';
import {createDetector,parseDetection,shouldCheckIn} from '../detection.mjs';
import {createVoiceProvider} from '../elevenlabs.mjs';
import {createDemoCalls,validTwilioSignature} from '../demo-calls.mjs';
import {inspectWAV,validateObservation} from '../media.mjs';
const png='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1i8AAAAASUVORK5CYII=';
const fall={label:'possible_fall',confidence:'medium',summary:'The view drops toward the floor.',observations:['Abrupt downward view.'],uncertainties:['No pre-event video.'],wearerInvolved:true,source:'nemotron'};
const ordinary={...fall,label:'ordinary_activity'};
test('Nemotron retries malformed output and returns an inconclusive result if both attempts fail', async () => {
  let attempts = 0;
  const response = content => new Response(JSON.stringify({ choices: [{ finish_reason: 'stop', message: { content } }] }));
  const detect = createDetector({
    apiKey: 'test',
    fetchImpl: async (_, options) => {
      const request = JSON.parse(options.body);
      assert.equal(request.response_format.type, 'json_schema');
      return response(++attempts === 2 ? JSON.stringify(fall) : 'not JSON');
    },
  });
  const input = { frames: [{ offsetMs: 0, imageDataUrl: png }] };
  assert.equal((await detect(input)).label, 'possible_fall');
  assert.equal(attempts, 2);
  const unavailable = createDetector({ apiKey: 'test', fetchImpl: async () => response('not JSON') });
  const result = await unavailable(input);
  assert.equal(result.source, 'nemotron_unavailable');
  assert.equal(result.label, 'uncertain');
  assert.equal(shouldCheckIn(result), false);
});
test('Nemotron timeout is inconclusive and does not open a check-in', async () => {
  const detect = createDetector({
    apiKey: 'test',
    fetchImpl: async () => { throw new DOMException('Provider timed out', 'TimeoutError'); },
  });
  const result = await detect({frames: [{offsetMs: 0, imageDataUrl: png}]});
  assert.equal(result.source, 'nemotron_unavailable');
  assert.match(result.uncertainties[0], /timed out/);
  assert.equal(shouldCheckIn(result), false);
});
function wav(ms=1000){const b=Buffer.alloc(44+ms*32);b.write('RIFF');b.writeUInt32LE(b.length-8,4);b.write('WAVEfmt ',8);b.writeUInt32LE(16,16);b.writeUInt16LE(1,20);b.writeUInt16LE(1,22);b.writeUInt32LE(16000,24);b.writeUInt32LE(32000,28);b.writeUInt16LE(2,32);b.writeUInt16LE(16,34);b.write('data',36);b.writeUInt32LE(b.length-44,40);return b;}
function fixture(t,overrides={}){
  let time=100000,placed=0;
  const store=new EncryptedStore({path:':memory:',key:randomBytes(32).toString('hex'),now:()=>time});
  const g=new GuardianService({store,now:()=>time,detect:async()=>fall,voice:{transcribe:async()=>({text:'help',source:'elevenlabs_scribe'}),speak:async()=>({bytes:Buffer.from('genuine-test-provider-audio'),contentType:'audio/mpeg'})},calls:{transport:'playback',place:async()=>{placed++;return {transport:'playback',status:'in_app'};},cancel:async()=>{}},...overrides});
  t.after(async()=>{await g.close();store.close();});
  const s=g.createSession('owner',{consent:{capture:true,cloud:true,audio:true,voice:true,demoCalls:true,backgroundEscalation:true}});g.arm('owner',s.id);
  return {g,s,store,advance:ms=>{time+=ms;},placed:()=>placed,observation:window=>({windowId:window.id,frames:[{offsetMs:0,imageDataUrl:png}],source:'meta_mock'})};
}
test('encrypted store enforces owner/revision/expiry and does not write plaintext',()=>{
  const dir=mkdtempSync(join(tmpdir(),'guardian-store-')),path=join(dir,'db.sqlite');let now=1;
  const store=new EncryptedStore({path,key:'a'.repeat(64),now:()=>now});
  try{const row=store.put('incident',{id:'x',summary:'unique-secret-incident'},{owner:'a',expires:100});assert.equal(store.get('incident','x','b'),null);assert.throws(()=>store.put('incident',row,{owner:'a',expires:100,expectedRevision:0}),{code:'revision_conflict'});assert.equal(store.get('incident','x','a').summary,row.summary);store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');assert.equal(readFileSync(path).includes('unique-secret-incident'),false);now=101;assert.equal(store.get('incident','x','a'),null);}finally{store.close();rmSync(dir,{recursive:true,force:true});}
});
test('screenless voice check-in gives spoken commands without requiring a display', async t => {
  const {g,s}=fixture(t);
  const incident=g.trigger('owner',s.id,{signal:'keyword_distress'}).incident;
  assert.equal(incident.state,'check_in');
  const {VOICE_PROMPTS}=await import('../elevenlabs.mjs');
  assert.match(VOICE_PROMPTS.check_in,/Say Guardian cancel/);
  assert.match(VOICE_PROMPTS.check_in,/Guardian SOS/);
  assert.doesNotMatch(VOICE_PROMPTS.check_in,/Use the cancel button/);
  assert.equal((await g.prompt('owner',{purpose:'check_in',incidentId:incident.id})).contentType,'audio/mpeg');
});
test('real glasses allow capture teardown and an audible response without extending recording', async t => {
  const {g,advance,placed}=fixture(t);
  const session=g.createSession('real-owner',{source:'meta_glasses',consent:{capture:true,cloud:true,voice:true,demoCalls:true,backgroundEscalation:true}});
  g.arm('real-owner',session.id);
  const reply=g.trigger('real-owner',session.id,{signal:'keyword_distress'});
  assert.equal(reply.incident.checkInDeadline-reply.incident.createdAt,30000);
  assert.equal(reply.window.captureEndsAt-reply.window.startedAt,8000);
  advance(15001);await g.sweep();
  assert.equal(g.requireIncident('real-owner',reply.incident.id).state,'check_in');
  assert.equal(placed(),0);
  await g.cancel('real-owner',reply.incident.id);
  advance(16000);await g.sweep();
  assert.equal(g.requireIncident('real-owner',reply.incident.id).state,'cancelled');
  assert.equal(placed(),0);
});
test('strict bounded audio and media validation rejects malformed data',()=>{
  assert.equal(inspectWAV(wav()).durationMs,1000);assert.throws(()=>inspectWAV(wav(8001)));const b=wav();b.writeUInt16LE(2,22);assert.throws(()=>inspectWAV(b));assert.throws(()=>validateObservation({windowId:'a'.repeat(36),frames:[]}));assert.throws(()=>validateObservation({windowId:'a'.repeat(36),frames:Array(7).fill({offsetMs:0,imageDataUrl:png})}));
  assert.throws(()=>validateObservation({windowId:'a'.repeat(36),frames:[{offsetMs:-1,imageDataUrl:png}]}),{code:'invalid_media'});
});
test('fall result starts check-in then one demo call; completed upload is idempotent',async t=>{
  const {g,s,advance,placed,observation}=fixture(t);const trigger=g.trigger('owner',s.id,{signal:'motion'});
  const result=await g.observe('owner',s.id,observation(trigger.window));assert.equal(result.incident.state,'check_in');assert.equal(result.incident.detectedBy,'nemotron');assert.equal(result.rawMediaRetained,false);
  assert.deepEqual(await g.observe('owner',s.id,observation(trigger.window)),result);
  advance(16000);await g.sweep();await Promise.all(g.callTasks.values());assert.equal(placed(),1);await g.sweep();assert.equal(placed(),1);assert.equal(g.requireIncident('owner',result.incident.id).state,'demo_call_active');
});
test('arming lasts 30 minutes without renewal from heartbeats',t=>{
  const {g,s,advance}=fixture(t);
  advance(29*60_000+59_000);
  assert.doesNotThrow(()=>g.requireArmed(g.heartbeat('owner',s.id)));
  advance(1000);
  assert.throws(()=>g.requireArmed(g.heartbeat('owner',s.id)),{code:'not_armed'});
});
test('normal activity and uncertain low confidence do not auto-escalate',async t=>{
  const {g,s,observation}=fixture(t,{detect:async()=>ordinary});const tr=g.trigger('owner',s.id,{signal:'motion'});assert.equal((await g.observe('owner',s.id,observation(tr.window))).incident,null);
  assert.equal(shouldCheckIn({...fall,confidence:'low'}),false);assert.equal(shouldCheckIn({...fall,wearerInvolved:false}),false);assert.equal(shouldCheckIn({...fall,label:'uncertain'}),false);assert.throws(()=>parseDetection('{"label":"fall"}'));
});
test('speech check-in keeps its reason when later visuals look ordinary',async t=>{
  const {g,s,observation,placed}=fixture(t,{detect:async()=>ordinary});
  const tr=g.trigger('owner',s.id,{signal:'keyword_distress'});
  assert.equal(tr.incident.state,'check_in');assert.equal(tr.incident.detectedBy,'speech_trigger');
  assert.equal(tr.incident.checkInDeadline,115000);assert.equal(tr.incident.detection,null);assert.equal(placed(),0);
  const duplicate=g.trigger('owner',s.id,{signal:'keyword_distress'});
  assert.equal(duplicate.incident.id,tr.incident.id);assert.equal(g.store.list('incident').length,1);
  const result=await g.observe('owner',s.id,observation(tr.window));
  assert.equal(result.detection.label,'ordinary_activity');assert.equal(result.incident.state,'check_in');
  assert.equal(result.incident.detectedBy,'speech_trigger');
  assert.match(g.callScript(result.incident),/report of danger/);
  await g.cancel('owner',tr.incident.id);await g.sweep();assert.equal(placed(),0);
});
test('speech triggers work without capture, respect source selection, and preserve demo consent',async t=>{
  const {g,advance,placed}=fixture(t);
  for(const signal of ['keyword_distress','spoken_threat']){
    const owner=`local-${signal}`,s=g.createSession(owner,{});g.arm(owner,s.id);
    const tr=g.trigger(owner,s.id,{signal});
    assert.equal(tr.window,null);assert.equal(tr.incident.state,'check_in');assert.equal(tr.incident.detectedBy,'speech_trigger');
    advance(16000);await g.sweep();assert.equal(g.requireIncident(owner,tr.incident.id).state,'needs_demo_call_consent');
  }
  assert.equal(placed(),0);
  const disabled=g.createSession('disabled',{enabledSignals:['motion']});g.arm('disabled',disabled.id);
  assert.equal(g.trigger('disabled',disabled.id,{signal:'keyword_distress'}).reason,'source_disabled');
  assert.equal(g.requireSession('disabled',disabled.id).incidentId,null);
});
test('speech during an existing scene capture survives an ordinary visual result',async t=>{
  const {g,observation}=fixture(t,{detect:async()=>ordinary});
  const s=g.createSession('scene-speech',{consent:{capture:true,cloud:true}});g.arm('scene-speech',s.id);
  const scene=g.trigger('scene-speech',s.id,{signal:'manual_check'});
  const speech=g.trigger('scene-speech',s.id,{signal:'keyword_distress'});
  assert.equal(speech.reason,'window_already_active');assert.equal(speech.incident.trigger,'keyword_distress');
  const result=await g.observe('scene-speech',s.id,observation(scene.window));
  assert.equal(result.incident.id,speech.incident.id);assert.equal(result.incident.detectedBy,'speech_trigger');
  assert.equal(result.incident.state,'check_in');assert.equal(result.detection.label,'ordinary_activity');
});
test('provider failure and subsequent cancellation cannot erase or recreate speech check-in',async t=>{
  const {g,s,observation,placed}=fixture(t,{detect:async()=>{throw new Error('Provider offline');}});
  const tr=g.trigger('owner',s.id,{signal:'keyword_distress'});
  await assert.rejects(g.observe('owner',s.id,observation(tr.window)),/Provider offline/);
  assert.equal(g.requireIncident('owner',tr.incident.id).state,'check_in');
  await g.cancel('owner',tr.incident.id);
  assert.equal(g.requireIncident('owner',tr.incident.id).state,'cancelled');await g.sweep();assert.equal(placed(),0);
});
test('phone motion requires Mock opt-in and remains an unconfirmed phone event',async t=>{
  const {g,observation}=fixture(t,{detect:async()=>ordinary});
  for(const [owner,body] of [['off',{source:'meta_mock',enabledSignals:['motion_phone']}],['real',{source:'meta_glasses',phoneMotionTesting:true}]]){
    const s=g.createSession(owner,body);g.arm(owner,s.id);
    assert.equal(g.trigger(owner,s.id,{signal:'motion_phone'}).reason,'source_disabled');
  }
  const s=g.createSession('phone-owner',{source:'meta_mock',phoneMotionTesting:true,consent:{capture:true,cloud:true}});g.arm('phone-owner',s.id);
  const tr=g.trigger('phone-owner',s.id,{signal:'motion_phone'});
  assert.equal(tr.incident.state,'check_in');assert.equal(tr.incident.detectedBy,'phone_motion');assert.equal(tr.incident.detection,null);
  const result=await g.observe('phone-owner',s.id,observation(tr.window));
  assert.equal(result.incident.detectedBy,'phone_motion');assert.equal(result.detection.label,'ordinary_activity');
  assert.match(g.callScript(result.incident),/wearer fall is unconfirmed/);
});
test('manual scene requests replace expired empty windows and assess visible threats',async t=>{
  const danger={...fall,label:'immediate_danger',confidence:'high',observations:['A weapon is pointed toward the wearer.']};
  const {g,s,advance,observation}=fixture(t,{detect:async()=>danger});
  assert.throws(()=>g.trigger('owner',s.id,{signal:'scene_check'}),{code:'invalid_signal'});
  const optedIn=g.createSession('owner',{consent:{capture:true,cloud:true}});
  g.arm('owner',optedIn.id);
  const empty=g.trigger('owner',optedIn.id,{signal:'manual_check'}).window;
  assert.ok(empty);
  advance(65_000);
  g.heartbeat('owner',optedIn.id);
  const next=g.trigger('owner',optedIn.id,{signal:'manual_check'}).window;
  assert.notEqual(next.id,empty.id);
  assert.equal((await g.observe('owner',optedIn.id,observation(next))).incident.state,'check_in');
  assert.equal(shouldCheckIn({...danger,wearerInvolved:null}),false);
  assert.equal(shouldCheckIn({...danger,confidence:'medium'}),true);
  assert.equal(shouldCheckIn({...danger,confidence:'low'}),false);
});
test('loudness alone rejected, consent and capture budgets enforced',async t=>{
  const {g,s,advance,observation}=fixture(t);assert.equal(g.trigger('owner',s.id,{signal:'loud_voice'}).accepted,false);
  for(let n=0;n<3;n++){g.heartbeat('owner',s.id);const tr=g.trigger('owner',s.id,{signal:'motion'});assert.ok(tr.window);await g.observe('owner',s.id,observation(tr.window));await g.cancel('owner',g.requireSession('owner',s.id).incidentId);advance(61000);}
  g.heartbeat('owner',s.id);assert.ok(g.trigger('owner',s.id,{signal:'motion'}).window);
  assert.equal(g.trigger('owner',s.id,{signal:'manual_sos'}).incident.state,'call_queued');
  const no=g.createSession('fresh-owner',{});g.arm('fresh-owner',no.id);assert.equal(g.trigger('fresh-owner',no.id,{signal:'manual_sos'}).incident.state,'needs_demo_call_consent');assert.throws(()=>g.requireSession('other',s.id),{status:404});
});
test('disarming during provider work aborts and cannot resurrect incident',async t=>{
  let release;const pending=new Promise(r=>release=r);const {g,s,observation}=fixture(t,{detect:async()=>{await pending;return fall;}});
  const tr=g.trigger('owner',s.id,{signal:'motion'}),work=g.observe('owner',s.id,observation(tr.window));await g.disarm('owner',s.id);release();await assert.rejects(work,{code:'request_cancelled'});assert.equal(g.store.list('incident').length,0);assert.equal(g.requireSession('owner',s.id).activeWindow,null);
});
test('armed standby never opens capture or invokes providers; manual checks are bounded',async t=>{
  let detections=0,transcriptions=0;
  const {g,s,advance,observation}=fixture(t,{detect:async()=>{detections++;return ordinary;},voice:{transcribe:async()=>{transcriptions++;return {text:'help'};}}});
  for(let i=0;i<30;i++){
    g.heartbeat('owner',s.id);await g.sweep();
    assert.equal(g.requireSession('owner',s.id).activeWindow,null);
    advance(20_000);
  }
  assert.equal(detections,0);assert.equal(transcriptions,0);
  assert.equal(g.recentBudget('owner','capture').length,0);
  g.heartbeat('owner',s.id);
  const check=g.trigger('owner',s.id,{signal:'manual_check'});
  assert.ok(check.window);assert.equal(check.window.captureEndsAt-check.window.startedAt,8000);
  await g.observe('owner',s.id,observation(check.window));assert.equal(detections,1);
  assert.equal(g.trigger('owner',s.id,{signal:'manual_check'}).reason,'trigger_cooldown');
});
test('standby recording opt-ins and legacy speech uploads are rejected without providers',async t=>{
  let transcriptions=0;
  const {g,s}=fixture(t,{voice:{transcribe:async()=>{transcriptions++;return {text:'no please dont'};}}});
  for(const flags of [{automaticSceneChecks:true},{speechMonitoring:true}]){
    assert.throws(()=>g.createSession('owner',{consent:{capture:true,cloud:true,audio:true},...flags}),{code:'event_trigger_required'});
  }
  await assert.rejects(g.monitorSpeech('owner',s.id,{base64:wav().toString('base64')}),{code:'event_trigger_required'});
  assert.equal(transcriptions,0);assert.equal(g.requireSession('owner',s.id).activeWindow,null);
  await assert.rejects(g.observe('owner',s.id,{windowId:'a'.repeat(36),frames:[{offsetMs:0,imageDataUrl:png}]}),{code:'window_mismatch'});
});
test('cancel during check-in prevents dispatch; stale heartbeat disarms',async t=>{
  const {g,s,observation,advance,placed}=fixture(t);const tr=g.trigger('owner',s.id,{signal:'motion'}),r=await g.observe('owner',s.id,observation(tr.window));await g.cancel('owner',r.incident.id);advance(40000);await g.sweep();assert.equal(placed(),0);assert.equal(g.requireSession('owner',s.id).armed,false);
});
test('ambiguous dial failure is not automatically retried',async t=>{
  let n=0;const {g,s}=fixture(t,{calls:{transport:'twilio',place:async()=>{n++;throw new Error('network after dial');},cancel:async()=>{}}});const r=g.trigger('owner',s.id,{signal:'manual_sos'});await g.sweep();await Promise.all(g.callTasks.values());await g.sweep();assert.equal(n,1);assert.equal(g.requireIncident('owner',r.incident.id).state,'call_unknown');
});
test('restart marks in-flight jobs unknown without redial',async t=>{
  const {g,s,store}=fixture(t);const r=g.trigger('owner',s.id,{signal:'manual_sos'});const job=store.get('call_job',r.incident.id,'owner');store.put('call_job',{...job,state:'sending'},{owner:'owner',expires:job.expiresAt});
  const restarted=new GuardianService({store,calls:{transport:'playback'},voice:{},detect:async()=>fall});assert.equal(restarted.requireIncident('owner',r.incident.id).state,'call_unknown');await restarted.close();
});
test('provider wire contracts use real multimodal content, multipart audio and MP3 speech',async()=>{
  let detectionBody;const detect=createDetector({apiKey:'test',fetchImpl:async(_,o)=>{detectionBody=JSON.parse(o.body);return new Response(JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(fall)}}]}));}});
  assert.equal((await detect({frames:[{offsetMs:0,imageDataUrl:png}],transcript:'Help me',trigger:'motion',source:'meta_mock'})).source,'nemotron');assert.equal(detectionBody.messages[1].content[1].image_url.url,png);assert.equal(detectionBody.tools,undefined);
  const seen=[];const voice=createVoiceProvider({apiKey:'test',fetchImpl:async(url,o)=>{seen.push({url,o});return url.includes('speech-to-text')?new Response(JSON.stringify({text:'help',language_code:'eng'})):new Response(Buffer.alloc(100),{headers:{'content-type':'audio/mpeg'}});}});
  assert.equal((await voice.transcribe(wav())).text,'help');assert.equal(seen[0].o.body.get('file').type,'audio/wav');assert.equal((await voice.speak('Demo only.')).source,'elevenlabs');assert.match(seen[1].url,/text-to-speech/);
});
test('Twilio only uses configured allowlist, signed expiring audio and callbacks',async()=>{
  const config={transport:'twilio',accountSid:'AC'+'a'.repeat(32),authToken:'secret',from:'+15551234567',to:'+15557654321',allowlist:['+15557654321'],publicBaseURL:'https://demo.example',mediaSecret:'test-signing-secret-at-least-32-characters',now:()=>1000};let request;
  assert.throws(()=>createDemoCalls({...config,to:'112'}));assert.throws(()=>createDemoCalls({...config,allowlist:[]}));
  const calls=createDemoCalls({...config,fetchImpl:async(url,o)=>{request={url,o};return new Response(JSON.stringify({sid:'CA'+'b'.repeat(32),status:'queued'}));}});
  const link=new URL(calls.mediaURL('id'));assert.equal(calls.verifyMedia('id',link.searchParams.get('expires'),link.searchParams.get('signature')),true);assert.equal(calls.verifyMedia('different',link.searchParams.get('expires'),link.searchParams.get('signature')),false);
  await calls.place({id:'id',mode:'demo',to:'911'});assert.equal(request.o.body.get('To'),config.to);assert.equal(request.o.body.get('TimeLimit'),'120');assert.equal(request.o.body.get('Timeout'),'20');assert.match(request.o.body.get('Twiml'),/<Play>/);
  const params={CallSid:'CA'+'b'.repeat(32),CallStatus:'completed'},url='https://demo.example/v1/twilio/status/id';const signature=createHmac('sha1','secret').update(url+Object.keys(params).sort().map(k=>k+params[k]).join('')).digest('base64');assert.equal(validTwilioSignature({url,params,signature,authToken:'secret'}),true);assert.equal(validTwilioSignature({url,params:{...params,CallStatus:'failed'},signature,authToken:'secret'}),false);
});
test('HTTP authentication, bounded observation, voice consent and full demo flow',async t=>{
  const {g}=fixture(t),token='test-client-token-at-least-thirty-two-characters',server=createGuardianHTTP({guardian:g,clientToken:token});await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>new Promise(r=>server.close(r)));const base=`http://127.0.0.1:${server.address().port}`;
  const request=async(path,body)=>fetch(base+path,{method:body===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});
  assert.equal((await fetch(base+'/v1/incidents')).status,401);
  const s=await (await request('/v1/sessions',{consent:{capture:true,cloud:true,voice:true,demoCalls:true}})).json();assert.equal(s.owner,undefined);await request(`/v1/sessions/${s.id}/arm`,{});
  const tr=await (await request(`/v1/sessions/${s.id}/triggers`,{signal:'motion'})).json();const result=await (await request(`/v1/sessions/${s.id}/observations`,{windowId:tr.window.id,frames:[{offsetMs:0,imageDataUrl:png}]})).json();assert.equal(result.incident.detectedBy,'nemotron');
  assert.equal((await request('/v1/voice/prompts',{purpose:'check_in'})).status,403);assert.equal((await request('/v1/voice/prompts',{purpose:'check_in',incidentId:result.incident.id})).headers.get('content-type'),'audio/mpeg');assert.equal((await (await request(`/v1/incidents/${result.incident.id}/cancel`,{})).json()).state,'cancelled');
});
test('real-provider adapters connect through capture, STT, detection, TTS, Twilio and signed acknowledgment',async t=>{
  let time=100000;const seen=[];const sid='CA'+'d'.repeat(32),secret='twilio-test-secret';
  const providerFetch=async(url,options)=>{seen.push({url,options});
    if(url.includes('speech-to-text'))return new Response(JSON.stringify({text:'I am on the floor and need help.',language_code:'eng'}));
    if(url.includes('chat/completions')){const body=JSON.parse(options.body);assert.match(body.messages[1].content[0].text,/I am on the floor/);assert.equal(body.messages[1].content[1].image_url.url,png);return new Response(JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(fall)}}]}));}
    if(url.includes('text-to-speech'))return new Response(Buffer.alloc(100,1),{headers:{'content-type':'audio/mpeg'}});
    if(url.includes('Calls.json')){assert.match(options.body.get('Twiml'),/<Play>https:\/\/demo.example/);return new Response(JSON.stringify({sid,status:'queued'}));}
    return new Response('{}');
  };
  const store=new EncryptedStore({path:':memory:',key:'b'.repeat(64),now:()=>time});
  const calls=createDemoCalls({transport:'twilio',accountSid:'AC'+'a'.repeat(32),authToken:secret,from:'+15551234567',to:'+15557654321',allowlist:['+15557654321'],publicBaseURL:'https://demo.example',mediaSecret:'m'.repeat(32),fetchImpl:providerFetch,now:()=>time});
  const g=new GuardianService({store,calls,now:()=>time,voice:createVoiceProvider({apiKey:'test-eleven',fetchImpl:providerFetch}),detect:createDetector({apiKey:'test-nemotron',fetchImpl:providerFetch})});
  t.after(async()=>{await g.close();store.close();});
  const session=g.createSession('owner',{consent:{capture:true,cloud:true,audio:true,voice:true,demoCalls:true}});g.arm('owner',session.id);const trigger=g.trigger('owner',session.id,{signal:'motion'});
  const result=await g.observe('owner',session.id,{windowId:trigger.window.id,source:'meta_mock',frames:[{offsetMs:0,imageDataUrl:png}],audio:{format:'wav_pcm_s16le_16000_mono',base64:wav().toString('base64')}});
  assert.equal(result.audioTranscriptionSource,'elevenlabs_scribe');assert.equal(result.incident.detectedBy,'nemotron');time+=16000;await g.sweep();const pending=g.requireIncident('owner',result.incident.id);assert.equal(pending.state,'awaiting_foreground_confirmation');g.confirmEscalation('owner',pending.id,pending.escalationToken);await g.sweep();await Promise.all(g.callTasks.values());
  assert.equal(seen.filter(r=>r.url.includes('Calls.json')).length,1);assert.equal(seen.filter(r=>r.url.includes('text-to-speech')).length,1);
  const server=createGuardianHTTP({guardian:g,clientToken:'client-token-with-at-least-thirty-two-characters',now:()=>time});await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>new Promise(r=>server.close(r)));const base=`http://127.0.0.1:${server.address().port}`;
  const path=`/v1/twilio/ack/${result.incident.id}`,params={CallSid:sid,Digits:'1'},input='https://demo.example'+path+Object.keys(params).sort().map(k=>k+params[k]).join('');
  const signature=createHmac('sha1',secret).update(input).digest('base64');
  const bad=await fetch(base+path,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(params)});assert.equal(bad.status,403);
  const ok=await fetch(base+path,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded','X-Twilio-Signature':signature},body:new URLSearchParams(params)});assert.equal(ok.status,200);assert.match(await ok.text(),/Demonstration acknowledged/);assert.equal(g.requireIncident('owner',result.incident.id).state,'acknowledged');
  await g.twilioStatus(result.incident.id,{CallSid:sid,CallStatus:'ringing'});assert.equal(g.requireIncident('owner',result.incident.id).state,'acknowledged');
});
test('cancel racing a successful dial immediately cancels the returned provider call',async t=>{
  let resolveDial,cancelled=0;const dial=new Promise(r=>resolveDial=r);
  const {g,s}=fixture(t,{calls:{transport:'twilio',place:async()=>dial,cancel:async()=>{cancelled++;}}});const trigger=g.trigger('owner',s.id,{signal:'manual_sos'});await g.sweep();await new Promise(r=>setImmediate(r));await g.cancel('owner',trigger.incident.id);resolveDial({transport:'twilio',status:'queued',providerCallId:'CA'+'e'.repeat(32)});await Promise.all(g.callTasks.values());assert.equal(cancelled,1);assert.equal(g.requireIncident('owner',trigger.incident.id).state,'cancelled');
});
test('a valid late callback supplies an unknown call SID and honors prior cancellation',async t=>{
  let cancellations=0;const {g,s}=fixture(t,{calls:{transport:'twilio',place:async()=>{throw new Error('ambiguous');},cancel:async()=>{cancellations++;}}});const tr=g.trigger('owner',s.id,{signal:'manual_sos'});await g.sweep();await Promise.all(g.callTasks.values());await g.cancel('owner',tr.incident.id);const updated=await g.twilioStatus(tr.incident.id,{CallSid:'CA'+'f'.repeat(32),CallStatus:'ringing'});assert.equal(cancellations,1);assert.equal(updated.state,'cancelled');assert.equal(updated.call.status,'cancellation_requested');
});
test('local ASR text cannot be uploaded without separate audio sharing consent',async t=>{
  const {g}=fixture(t);const s=g.createSession('text-owner',{consent:{capture:true,cloud:true,audio:false}});g.arm('text-owner',s.id);const trigger=g.trigger('text-owner',s.id,{signal:'keyword_distress'});
  await assert.rejects(g.observe('text-owner',s.id,{windowId:trigger.window.id,frames:[{offsetMs:0,imageDataUrl:png}],transcript:'A locally recognized phrase.'}),{code:'audio_consent_required'});
});
test('opted-in glasses gesture checks in before AI or capture and can be cancelled',async t=>{
  const {g}=fixture(t,{detect:async()=>{throw new Error('provider unavailable');}});
  const make=(source,handGestures=true,capture=true)=>g.arm('gesture-owner',g.createSession('gesture-owner',{source,handGestures,consent:{capture},enabledSignals:['gesture_distress']}).id);
  for(const s of [make('phone'),make('meta_glasses',false),make('meta_glasses',true,false)]){
    assert.equal(g.trigger('gesture-owner',s.id,{signal:'gesture_distress'}).reason,'source_disabled');
  }
  const s=make('meta_glasses');
  const reply=g.trigger('gesture-owner',s.id,{signal:'gesture_distress'});
  assert.equal(reply.incident.state,'check_in');
  assert.equal(reply.incident.trigger,'gesture_distress');
  assert.equal(reply.window,null);
  assert.equal(g.trigger('gesture-owner',s.id,{signal:'gesture_distress'}).incident.id,reply.incident.id);
  await g.disarm('gesture-owner',s.id);
  assert.equal(g.requireIncident('gesture-owner',reply.incident.id).state,'cancelled');
});
test('capture and demo call budgets survive disarm, new sessions and history deletion',async t=>{
  const {g,advance}=fixture(t);
  for(let n=0;n<3;n++){
    const s=g.createSession('budget-owner',{consent:{capture:true,cloud:true,voice:true,demoCalls:true}});g.arm('budget-owner',s.id);
    const tr=g.trigger('budget-owner',s.id,{signal:'manual_sos'});assert.ok(tr.window);await g.disarm('budget-owner',s.id);g.store.delete('incident',tr.incident.id,'budget-owner');advance(61000);
  }
  const next=g.createSession('budget-owner',{consent:{capture:true,cloud:true,voice:true,demoCalls:true}});g.arm('budget-owner',next.id);
  for(let n=0;n<9;n++){
    g.heartbeat('budget-owner',next.id);
    assert.ok(g.trigger('budget-owner',next.id,{signal:'motion'}).window);
    advance(29_000);
  }
  g.heartbeat('budget-owner',next.id);
  assert.equal(g.trigger('budget-owner',next.id,{signal:'motion'}).reason,'capture_budget');
  assert.equal(g.trigger('budget-owner',next.id,{signal:'manual_sos'}).incident.state,'demo_call_limited');
});
test('repeated practice check-ins remain visible without spending the demo call budget', async t => {
  const {g,s} = fixture(t);
  for(let i=0;i<6;i++){
    const reply=g.trigger('owner',s.id,{signal:'spoken_threat'});
    assert.equal(reply.incident.state,'check_in');
    await g.cancel('owner',reply.incident.id);
  }
  assert.equal(g.recentBudget('owner','demo_call').length,0);
  assert.equal(g.trigger('owner',s.id,{signal:'manual_sos'}).incident.state,'call_queued');
});
test('Twilio cancellation handles an already-answered call without retrying a dial',async()=>{
  const statuses=[];const calls=createDemoCalls({transport:'twilio',accountSid:'AC'+'a'.repeat(32),authToken:'secret',from:'+15551234567',to:'+15557654321',allowlist:['+15557654321'],publicBaseURL:'https://demo.example',mediaSecret:'s'.repeat(32),fetchImpl:async(url,options)=>{assert.match(url,/Calls\/CA/);statuses.push(options.body.get('Status'));return statuses.length===1?new Response('already answered',{status:400}):new Response('{}');}});
  await calls.cancel('CA'+'b'.repeat(32));assert.deepEqual(statuses,['canceled','completed']);
});
test('background continuation off needs a post-deadline foreground challenge before dialing',async t=>{
  const {g,advance,placed}=fixture(t);const s=g.createSession('foreground-owner',{consent:{capture:true,cloud:true,voice:true,demoCalls:true,backgroundEscalation:false}});g.arm('foreground-owner',s.id);
  const tr=g.trigger('foreground-owner',s.id,{signal:'motion'}),r=await g.observe('foreground-owner',s.id,{windowId:tr.window.id,frames:[{offsetMs:0,imageDataUrl:png}]});
  advance(16000);await g.sweep();assert.equal(placed(),0);const waiting=g.requireIncident('foreground-owner',r.incident.id);assert.equal(waiting.state,'awaiting_foreground_confirmation');
  assert.throws(()=>g.confirmEscalation('foreground-owner',waiting.id,'old-token'),{code:'confirmation_expired'});
  await g.disarm('foreground-owner',s.id);assert.throws(()=>g.confirmEscalation('foreground-owner',waiting.id,waiting.escalationToken),{code:'not_armed'});await g.sweep();assert.equal(placed(),0);
});

test('glasses motion summary is validated, bounded and forwarded to Nemotron with post-trigger frames',async()=>{
  const motion={fallPattern:'rapid_tilt',peakImpactG:2.91,minG:0.12,tiltDegrees:84.6,peakRotationDegPerSec:401.1,stillSecondsAtEnd:4.2,coveredFromMs:-3000,coveredToMs:7900,samples:300};
  const base={windowId:'a'.repeat(36),frames:[{offsetMs:0,imageDataUrl:png},{offsetMs:400,imageDataUrl:png}],source:'meta_glasses'};
  const parsed=validateObservation({...base,motion});
  assert.deepEqual(parsed.motion,motion);
  assert.equal(validateObservation(base).motion,null);
  assert.equal(validateObservation({...base,motion:{...motion,peakRotationDegPerSec:null}}).motion.peakRotationDegPerSec,null);
  for(const bad of [{...motion,fallPattern:'tripped'},{...motion,tiltDegrees:181},{...motion,peakImpactG:'3'},{...motion,coveredFromMs:-4000},[motion],{...motion,samples:0}])
    assert.throws(()=>validateObservation({...base,motion:bad}),/Motion summary|motion fall pattern/);
  let body;const detect=createDetector({apiKey:'test',fetchImpl:async(_,o)=>{body=JSON.parse(o.body);return new Response(JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(fall)}}]}));}});
  await detect({frames:parsed.frames,transcript:'',trigger:'motion',source:'meta_glasses',motion:parsed.motion});
  const evidence=JSON.parse(body.messages[1].content[0].text);
  assert.deepEqual(evidence.motionSummary,motion);assert.deepEqual(evidence.frameOffsetsMs,[0,400]);
  assert.match(body.messages[0].content,/motionSummary/);assert.match(body.messages[0].content,/possible_fall with at least medium confidence/);
  await detect({frames:parsed.frames,transcript:'',trigger:'manual_check',source:'meta_glasses'});
  assert.equal(JSON.parse(body.messages[1].content[0].text).motionSummary,null);
});

test('observation forwards the motion summary from the iPhone to the detector',async t=>{
  let seen;const time=100000;
  const store=new EncryptedStore({path:':memory:',key:randomBytes(32).toString('hex'),now:()=>time});
  const g=new GuardianService({store,now:()=>time,detect:async input=>{seen=input;return fall;},voice:{transcribe:async()=>({text:'',source:'test'}),speak:async()=>({bytes:Buffer.from('x'),contentType:'audio/mpeg'})},calls:{transport:'playback',place:async()=>({transport:'playback',status:'queued'})}});
  t.after(async()=>{await g.close();store.close();});
  const s=g.createSession('owner',{consent:{capture:true,cloud:true}});g.arm('owner',s.id);
  const reply=g.trigger('owner',s.id,{signal:'motion'});
  const motion={fallPattern:'free_fall_impact',peakImpactG:3,minG:0.1,tiltDegrees:88,peakRotationDegPerSec:null,stillSecondsAtEnd:5,coveredFromMs:-2900,coveredToMs:7800,samples:280};
  await g.observe('owner',s.id,{windowId:reply.window.id,frames:[{offsetMs:100,imageDataUrl:png}],source:'meta_glasses',motion});
  assert.deepEqual(seen.motion,motion);assert.equal(seen.trigger,'motion');
});

test('late location cannot be written after cancellation or disarming',async t=>{
  const {g}=fixture(t);const s=g.createSession('location-owner',{consent:{location:true}});g.arm('location-owner',s.id);const tr=g.trigger('location-owner',s.id,{signal:'manual_sos'}),point={latitude:60,longitude:24,accuracyMeters:8,timestamp:100000};
  assert.equal(g.location('location-owner',tr.incident.id,point).location.latitude,60);await g.cancel('location-owner',tr.incident.id);assert.throws(()=>g.location('location-owner',tr.incident.id,point),{code:'incident_closed'});
});

test('phone motion is accepted in Phone mode and opted-in Mock sessions',async t=>{
  const {g}=fixture(t);
  const consent={capture:true,cloud:true};
  const mock=g.createSession('phone-owner',{consent,source:'meta_mock',phoneMotionTesting:true});g.arm('phone-owner',mock.id);
  const reply=g.trigger('phone-owner',mock.id,{signal:'motion_phone'});
  assert.equal(reply.accepted,true);assert.equal(reply.window.signal,'motion_phone');
  const phone=g.createSession('standalone-phone',{source:'phone'});
  g.arm('standalone-phone',phone.id);
  const checkIn=g.trigger('standalone-phone',phone.id,{signal:'motion_phone'});
  assert.equal(checkIn.incident.state,'check_in');
  assert.equal(checkIn.incident.detectedBy,'phone_motion');
  assert.equal(checkIn.incident.checkInDeadline-checkIn.incident.createdAt,30_000);
  assert.equal(checkIn.window,null);
  const off=g.createSession('phone-owner',{consent,source:'meta_mock'});g.arm('phone-owner',off.id);
  assert.equal(g.trigger('phone-owner',off.id,{signal:'motion_phone'}).reason,'source_disabled');
  const real=g.createSession('phone-owner',{consent,source:'meta_glasses',phoneMotionTesting:true});g.arm('phone-owner',real.id);
  assert.equal(g.trigger('phone-owner',real.id,{signal:'motion_phone'}).reason,'source_disabled');
  assert.throws(()=>g.createSession('phone-owner',{consent,enabledSignals:['motion_phone','bogus']}),{code:'invalid_signals'});
});
