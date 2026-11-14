import { ApiError } from './nemotron.mjs';
import { httpsEndpoint, providerRequest } from './lib/transport.mjs';

export const VOICE_PROMPTS = Object.freeze({
  check_in:'Ray Guardian noticed a possible incident. Are you okay? Use the cancel button if you are okay, or the SOS button to continue. This is a demonstration.',
  cancelled:'The demonstration incident has been cancelled. No emergency services have been contacted.',
  acknowledged:'The demo operator acknowledged the demonstration. No real emergency responders have been dispatched.',
  demo_dispatch:'This is the Ray Guardian demonstration dispatch line. This is not an emergency service. The demonstration operator is receiving your incident report.',
});

export function createElevenLabs({ apiKey, voiceId='JBFqnCBsd6RMkjVDRZzb', ttsModel='eleven_multilingual_v2', sttModel='scribe_v2',
  baseURL='https://api.elevenlabs.io', enableLogging=true, fetchImpl=fetch }) {
  const base=httpsEndpoint(baseURL,'');
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(voiceId)) throw new Error('Invalid ELEVENLABS_VOICE_ID.');
  const requireKey=()=>{if(!apiKey)throw new ApiError(503,'elevenlabs_not_configured','Set ELEVENLABS_API_KEY on the backend.');};
  return {
    async transcribe(wav,signal) {
      requireKey();
      const body=new FormData();
      body.set('model_id',sttModel); body.set('file',new Blob([wav],{type:'audio/wav'}),'incident-window.wav');
      body.set('tag_audio_events','true'); body.set('diarize','false'); body.set('timestamps_granularity','word');
      const {bytes}=await providerRequest(fetchImpl,`${base}/v1/speech-to-text?enable_logging=${enableLogging}`,{
        method:'POST',headers:{'xi-api-key':apiKey},body,
      },{signal,timeoutMs:30000,limit:128*1024});
      let result;
      try{result=JSON.parse(bytes.toString('utf8'));}catch{throw new ApiError(502,'invalid_transcript','ElevenLabs returned an invalid transcript.');}
      if(typeof result.text!=='string'||result.text.length>8000)throw new ApiError(502,'invalid_transcript','ElevenLabs returned an invalid transcript.');
      return {text:result.text.slice(0,4000),language:typeof result.language_code==='string'?result.language_code:null,source:'elevenlabs_scribe'};
    },
    async speak(text,signal) {
      requireKey();
      if(typeof text!=='string'||!text.trim()||text.length>1800)throw new ApiError(400,'invalid_speech','Speech text must be 1–1800 characters.');
      const {bytes,contentType}=await providerRequest(fetchImpl,`${base}/v1/text-to-speech/${voiceId}?output_format=mp3_44100_128&enable_logging=${enableLogging}`,{
        method:'POST',headers:{'xi-api-key':apiKey,'Content-Type':'application/json','Accept':'audio/mpeg'},
        body:JSON.stringify({text,model_id:ttsModel,voice_settings:{stability:0.6,similarity_boost:0.75}}),
      },{signal,timeoutMs:25000,limit:3*1024*1024});
      if(!/^audio\//i.test(contentType)||bytes.length<4)throw new ApiError(502,'invalid_speech_audio','ElevenLabs returned no usable speech audio.');
      return {bytes,contentType:'audio/mpeg',source:'elevenlabs',voiceId};
    },
  };
}
