#!/usr/bin/env node
// Live, authenticated end-to-end smoke test. --demo-call enables only configured DEMO transport.
import {readFileSync,mkdirSync,writeFileSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('..',import.meta.url)),args=process.argv.slice(2),option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
const base=option('--url','http://127.0.0.1:8787'),token=process.env.RAY_GUARDIAN_CLIENT_TOKEN;
if(!token)throw new Error('Load the root .env into this process. The client token is required.');
const request=async(path,body)=>{const r=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(85000)});if(!r.ok)throw new Error(`API ${r.status}: ${(await r.json()).error}`);return r;};
const manifestPath=resolve(option('--manifest','ios/RayGuardian/Resources/ReplayMedia/manifest.json')),manifest=JSON.parse(readFileSync(manifestPath,'utf8')),clip=manifest.clips[Number(option('--index','0'))];
if(!clip)throw new Error('Prepare replay media before running a live smoke test.');
const framesResult=spawnSync(option('--ffmpeg','ffmpeg'),['-hide_banner','-loglevel','error','-i',resolve(dirname(manifestPath),clip.video),'-vf','fps=0.75,scale=640:-2','-frames:v','6','-q:v','8','-f','image2pipe','-vcodec','mjpeg','-'],{maxBuffer:2*1024*1024});
if(framesResult.error||framesResult.status!==0)throw new Error('A working --ffmpeg is required.');
const frames=[];let p=0;while(p<framesResult.stdout.length){const start=framesResult.stdout.indexOf(Buffer.from([255,216]),p),end=framesResult.stdout.indexOf(Buffer.from([255,217]),start+2);if(start<0||end<0)break;frames.push({offsetMs:frames.length*1000/0.75,imageDataUrl:'data:image/jpeg;base64,'+framesResult.stdout.subarray(start,end+2).toString('base64')});p=end+2;}
const health=await (await request('/health')).json();if(!health.ready)throw new Error('Provider credentials still require local configuration.');
const session=await (await request('/v1/sessions',{mode:'demo',source:'file_replay',consent:{capture:true,cloud:true,audio:Boolean(clip.audio),voice:true,demoCalls:args.includes('--demo-call')}})).json();
let heartbeat;
try{
  await request(`/v1/sessions/${session.id}/arm`,{});
  heartbeat=setInterval(()=>request(`/v1/sessions/${session.id}/heartbeat`,{}).catch(()=>{}),5000);
  const trigger=await (await request(`/v1/sessions/${session.id}/triggers`,{signal:'motion'})).json();
  const audio=clip.audio?{format:'wav_pcm_s16le_16000_mono',source:'source_dataset_audio',base64:readFileSync(resolve(dirname(manifestPath),clip.audio)).toString('base64')}:undefined;
  const result=await (await request(`/v1/sessions/${session.id}/observations`,{windowId:trigger.window.id,frames,audio,source:'file_replay'})).json();
  console.log(`Nemotron detected: ${result.detection.label}; source=${result.detection.source}; frames=${result.framesAnalyzed}; audio=${result.audioTranscriptionSource??'none'}`);
  if(result.detection.source!=='nemotron')throw new Error('The live assessment did not complete with a real Nemotron response.');
  if(audio&&result.audioTranscriptionSource!=='elevenlabs_scribe')throw new Error('The live audio did not complete real ElevenLabs Scribe transcription.');
  if(result.incident){
    const output=resolve(option('--output',resolve(root,'validation/results/live-smoke')));mkdirSync(output,{recursive:true});
    const prompt=await request('/v1/voice/prompts',{purpose:'check_in',incidentId:result.incident.id});writeFileSync(resolve(output,'check-in.mp3'),Buffer.from(await prompt.arrayBuffer()));
    console.log('Saved genuine ElevenLabs check-in audio under ignored validation/results/live-smoke/.');
    if(args.includes('--demo-call')){
      const deadline=Date.now()+90000;
      let completed=false;
      while(Date.now()<deadline){await new Promise(r=>setTimeout(r,2000));const incident=await (await request(`/v1/incidents/${result.incident.id}`)).json();console.log(`Demo incident: ${incident.state}`);
        if(incident.state==='awaiting_foreground_confirmation'){await request(`/v1/incidents/${incident.id}/escalate`,{token:incident.escalationToken});continue;}
        if(incident.state==='demo_call_active'){const audio=await request(`/v1/demo-calls/${incident.id}/audio`);writeFileSync(resolve(output,'demo-dispatch.mp3'),Buffer.from(await audio.arrayBuffer()));await request(`/v1/incidents/${incident.id}/acknowledge`,{});completed=true;break;}
        if(['acknowledged','call_completed'].includes(incident.state)){completed=true;break;}
        if(['call_failed','call_unknown','cancelled','demo_call_limited','needs_demo_call_consent'].includes(incident.state))throw new Error(`Demo transport was not verified: ${incident.state}`);
      }
      if(!completed)throw new Error('Demo transport did not reach completion or acknowledgment before the smoke-test deadline.');
    }else console.log('Demo calling was disabled for this run. Check-in detection and real speech were exercised.');
  }else console.log('No check-in was warranted by the actual result; no positive detection was fabricated.');
}finally{clearInterval(heartbeat);await request(`/v1/sessions/${session.id}/disarm`,{cancelPending:true}).catch(()=>{});}
