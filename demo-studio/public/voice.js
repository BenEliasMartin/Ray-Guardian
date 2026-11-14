import {voiceLines} from './voice-lines.js';
const normalize=text=>String(text).replace(/[“”"‘’']/g,'').replace(/\s+/g,' ').trim();
export function voiceClip(text,role='guardian'){
 return voiceLines.find(line=>line.role===role&&normalize(line.text)===normalize(text));
}
export class DemoVoice {
 constructor({createAudio=src=>new Audio(src),synth=globalThis.speechSynthesis,Utterance=globalThis.SpeechSynthesisUtterance}={}){
  this.createAudio=createAudio;this.synth=synth;this.Utterance=Utterance;this.generation=0;
 }
 get available(){return Boolean(globalThis.Audio||this.synth);}
 stop(){this.generation++;if(this.audio){this.audio.pause();this.audio.removeAttribute('src');this.audio.load();this.audio=null;}this.synth?.cancel();}
 async speak(text,role='guardian'){
  this.stop();const generation=this.generation,line=voiceClip(text,role);
  if(line){
   const audio=this.createAudio(`/assets/voice/${line.id}.wav`);this.audio=audio;audio.volume=.9;
   try{await audio.play();return;}catch(error){
    if(generation!==this.generation||error.name==='NotAllowedError')return;
    audio.pause();this.audio=null;
   }
  }
  if(generation!==this.generation||!this.synth||!this.Utterance)return;
  // Only a fallback for a missing clip or an unexpected runtime message.
  const utterance=new this.Utterance(normalize(text));utterance.lang='en-US';
  const voices=this.synth.getVoices();
  utterance.voice=voices.find(v=>v.lang.startsWith('en')&&/natural|premium|enhanced|Samantha|Google US English/i.test(v.name))??voices.find(v=>v.lang==='en-US')??null;
  utterance.rate=1;utterance.pitch=1;utterance.volume=.9;this.synth.speak(utterance);
 }
}
