import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {DemoVoice,voiceClip} from '../public/voice.js';
import {voiceLines} from '../public/voice-lines.js';
import {stories,frameAt,sceneAt} from '../public/stories.js';

test('each spoken rehearsal beat has a local recording in the correct role',()=>{
 for(const story of stories){
  for(let time=0;time<=story.end;time+=.2){
   const frame=frameAt(story,time),scene=sceneAt(story,time,frame);
   if(scene)assert.ok(voiceClip(scene.caption,scene.role),`${story.id}: ${scene.caption}`);
   else if(frame.check)assert.ok(voiceClip(story.prompt));
  }
 }
 const threat=stories.find(s=>s.id==='threat');
 for(const opening of [1,4]){const scene=sceneAt(threat,0,frameAt(threat,0),opening);assert.ok(voiceClip(scene.caption,scene.role));}
 assert.equal(voiceClip('“Guardian, cancel.”','wearer').id,'wearer-cancel');
});

test('fixed audio is playable PCM and cancellation fits between scripted dialogue beats',async()=>{
 const provenance=JSON.parse(await readFile(new URL('../public/assets/voice/provenance.json',import.meta.url)));
 for(const line of voiceLines){
  const bytes=await readFile(new URL(`../public/assets/voice/${line.id}.wav`,import.meta.url));
  assert.equal(bytes.toString('ascii',0,4),'RIFF');assert.equal(bytes.toString('ascii',8,12),'WAVE');
  assert.ok(provenance.lines.find(item=>item.id===line.id)?.durationSeconds>0);
 }
 assert.ok(provenance.lines.find(line=>line.id==='check-in').durationSeconds<5);
 assert.ok(provenance.lines.find(line=>line.id==='wearer-cancel').durationSeconds<1.6);
});

test('a stopped or replaced clip cannot start stale synthesized speech',async()=>{
 const audio=[],spoken=[];let rejectFirst;
 const voice=new DemoVoice({
  createAudio:src=>{const clip={src,pause(){this.paused=true;},removeAttribute(){},load(){},play(){return audio.length===1?new Promise((_,reject)=>rejectFirst=reject):Promise.resolve();}};audio.push(clip);return clip;},
  synth:{cancel(){},getVoices(){return[];},speak(line){spoken.push(line);}},Utterance:class{constructor(text){this.text=text;}}
 });
 const pending=voice.speak('No, please don’t.','wearer');
 await voice.speak('Check-in cancelled.');
 rejectFirst(new Error('Late decode error'));await pending;
 assert.equal(audio[0].paused,true);assert.equal(spoken.length,0);
 assert.match(audio[1].src,/cancelled.wav$/);voice.stop();assert.equal(audio[1].paused,true);
});
