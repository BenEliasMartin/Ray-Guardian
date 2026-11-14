import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createGuardianHTTP} from './http.mjs';
import {createNemotron} from './nemotron.mjs';
import {createDetector} from './detection.mjs';
import {createVoiceProvider,createElevenLabs} from './elevenlabs.mjs';
import {createDemoCalls} from './demo-calls.mjs';
import {EncryptedStore} from './store.mjs';
import {GuardianService} from './guardian.mjs';
import {loadReplays} from './replays.mjs';
const env=process.env,host=env.HOST??'127.0.0.1',port=Number(env.PORT??8787);
if(!Number.isInteger(port)||port<1||port>65535)throw new Error('Invalid PORT.');
const directory=fileURLToPath(new URL('.',import.meta.url));
const store=new EncryptedStore({path:env.DATA_PATH??resolve(directory,'data/guardian.sqlite'),key:env.DATA_ENCRYPTION_KEY});
const provider={apiKey:env.VERDA_INFERENCE_KEY,baseURL:env.VERDA_BASE_URL,model:env.VERDA_MODEL};
const calls=createDemoCalls({transport:env.DEMO_CALL_TRANSPORT??'playback',accountSid:env.TWILIO_ACCOUNT_SID,authToken:env.TWILIO_AUTH_TOKEN,
  from:env.DEMO_CALL_FROM,to:env.DEMO_CALL_TO,allowlist:(env.DEMO_CALL_ALLOWLIST??'').split(',').map(s=>s.trim()).filter(Boolean),publicBaseURL:env.PUBLIC_BASE_URL,mediaSecret:env.MEDIA_SIGNING_SECRET});
const guardian=new GuardianService({store,calls,detect:createDetector(provider),voice:createVoiceProvider({apiKey:env.ELEVENLABS_API_KEY,voiceId:env.ELEVENLABS_VOICE_ID,
  ttsModel:env.ELEVENLABS_TTS_MODEL,sttModel:env.ELEVENLABS_STT_MODEL,enableLogging:env.ELEVENLABS_ENABLE_LOGGING!=='false'}),
  mediaLibrary:await loadReplays(env.REPLAY_DIRECTORY??resolve(directory,'../ios/RayGuardian/Resources/ReplayMedia')),
  providerStatus:{nemotron:{configured:Boolean(env.VERDA_INFERENCE_KEY)},elevenlabs:{configured:Boolean(env.ELEVENLABS_API_KEY)}}});
const server=createGuardianHTTP({guardian,speak:createElevenLabs({apiKey:env.ELEVENLABS_API_KEY,voiceId:env.ELEVENLABS_VOICE_ID,modelId:env.ELEVENLABS_MODEL_ID??env.ELEVENLABS_TTS_MODEL}),clientToken:env.RAY_GUARDIAN_CLIENT_TOKEN,analyze:createNemotron(provider)});
server.listen(port,host,()=>console.log(`Ray Guardian demo API listening on ${host}:${port}`));
let shuttingDown=false;
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{if(shuttingDown)return;shuttingDown=true;const drained=new Promise(resolve=>server.close(resolve));await guardian.close();await drained;store.close();});
