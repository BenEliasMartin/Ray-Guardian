#!/usr/bin/env node
// Assess genuine prepared replay sequences with the production detector. Never initiates a call.
import {readFileSync,mkdirSync,writeFileSync,existsSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createDetector,shouldCheckIn} from '../server/detection.mjs';
import {createVoiceProvider} from '../server/elevenlabs.mjs';
import {inspectWAV} from '../server/media.mjs';
const root=fileURLToPath(new URL('..',import.meta.url)),args=process.argv.slice(2);
const arg=(key,fallback)=>{const i=args.indexOf(key);return i>=0?args[i+1]:fallback;};
const manifestPath=resolve(arg('--manifest',resolve(root,'ios/RayGuardian/Resources/ReplayMedia/manifest.json'))),directory=dirname(manifestPath);
const manifest=JSON.parse(readFileSync(manifestPath,'utf8')),ffmpeg=arg('--ffmpeg','ffmpeg'),live=args.includes('--live'),includeAudio=args.includes('--audio');
const detector=createDetector({apiKey:process.env.VERDA_INFERENCE_KEY,baseURL:process.env.VERDA_BASE_URL,model:process.env.VERDA_MODEL});
const voice=createVoiceProvider({apiKey:process.env.ELEVENLABS_API_KEY,sttModel:process.env.ELEVENLABS_STT_MODEL,enableLogging:process.env.ELEVENLABS_ENABLE_LOGGING!=='false'});
if(live&&!process.env.VERDA_INFERENCE_KEY)throw new Error('Live evaluation needs VERDA_INFERENCE_KEY; load the root .env locally.');
if(live&&includeAudio&&!process.env.ELEVENLABS_API_KEY)throw new Error('Audio evaluation needs ELEVENLABS_API_KEY.');
export function framesFromVideo(path,executable=ffmpeg){
  const result=spawnSync(executable,['-hide_banner','-loglevel','error','-i',path,'-vf','fps=0.75,scale=640:-2','-frames:v','6','-q:v','8','-f','image2pipe','-vcodec','mjpeg','-'],{maxBuffer:2*1024*1024});
  if(result.error||result.status!==0)throw new Error('FFmpeg could not decode the replay. Pass --ffmpeg with a working executable.');
  const frames=[];let position=0;
  while(position<result.stdout.length){const start=result.stdout.indexOf(Buffer.from([255,216]),position);if(start<0)break;const end=result.stdout.indexOf(Buffer.from([255,217]),start+2);if(end<0)throw new Error('Truncated JPEG from FFmpeg.');const jpeg=result.stdout.subarray(start,end+2);if(jpeg.length>131072)throw new Error('Evaluation frame exceeds production limit.');frames.push({offsetMs:frames.length*1000/0.75,imageDataUrl:'data:image/jpeg;base64,'+jpeg.toString('base64')});position=end+2;}
  if(!frames.length)throw new Error('No decoded visual evidence.');return frames;
}
const rows=[];
for(const clip of manifest.clips.slice(0,Number(arg('--limit','100')))){
  const path=resolve(directory,clip.video);if(!existsSync(path))throw new Error('Prepare replay media before evaluation.');
  const frames=framesFromVideo(path);let transcript='',audioDurationMs=0;
  try{
    if(includeAudio&&clip.audio){const wav=readFileSync(resolve(directory,clip.audio));audioDurationMs=inspectWAV(wav).durationMs;if(live)transcript=(await voice.transcribe(wav)).text;}
    const detection=live?await detector({frames,transcript,trigger:'motion',source:'meta_mock'}):null;
    if(live&&detection.source!=='nemotron')throw Object.assign(new Error('Nemotron did not complete the assessment.'),{code:'nemotron_unavailable'});
    rows.push({id:clip.id,gold:clip.expected,sourceSplit:clip.sourceSplit??'unknown',labelScope:clip.labelScope??'unreviewed',frames:frames.length,audioDurationMs,detection,checkIn:detection?shouldCheckIn(detection):null,error:null});
    console.log(`${live?'Assessed':'Prepared'} ${clip.id}: ${detection?.label??`${frames.length} real frames`}`);
  }catch(error){rows.push({id:clip.id,gold:clip.expected,detection:null,error:error.code??'provider_error'});console.log(`Provider error for ${clip.id}; kept in denominator.`);}
}
if(!rows.length)throw new Error('No replay entries. Run prepare_demo_media.py first.');
const summary={mode:live?'live':'dry_run',total:rows.length,errors:rows.filter(r=>r.error).length,abstentions:rows.filter(r=>r.detection?.label==='uncertain'||r.detection?.confidence==='low').length,
  fallCount:rows.filter(r=>r.gold==='fall').length,nonFallCount:rows.filter(r=>r.gold==='nonfall').length,
  fallCheckIns:rows.filter(r=>r.gold==='fall'&&r.checkIn===true).length,nonFallCheckIns:rows.filter(r=>r.gold==='nonfall'&&r.checkIn===true).length,
  readinessCertified:false,limitations:['Replay crops have publisher full-clip labels; independently adjudicate cropped windows.','No assault or real emergency readiness is established.','Component evaluation does not measure local-trigger recall or background coverage.']};
const output=resolve(arg('--output',resolve(root,'validation/results/guardian-'+Date.now()+'.json')));mkdirSync(dirname(output),{recursive:true});writeFileSync(output,JSON.stringify({summary,rows},null,2)+'\n');console.log(JSON.stringify(summary));console.log(`Saved ${output}`);
if(live&&summary.errors)process.exitCode=1;
