import {existsSync,readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
const root=fileURLToPath(new URL('..',import.meta.url));
const path=resolve(root,'.env'),env={...process.env};
if(existsSync(path))for(const line of readFileSync(path,'utf8').split('\n')){const match=line.match(/^([A-Z_0-9]+)=(.*)$/);if(match&&!env[match[1]])env[match[1]]=match[2].trim().replace(/^['"]|['"]$/g,'');}
let missing=0;
for(const key of ['RAY_GUARDIAN_CLIENT_TOKEN','DATA_ENCRYPTION_KEY','MEDIA_SIGNING_SECRET','VERDA_INFERENCE_KEY','ELEVENLABS_API_KEY']){const ready=Boolean(env[key]);console.log(`${key}: ${ready?'configured':'manual setup required'}`);if(!ready)missing++;}
const transport=env.DEMO_CALL_TRANSPORT??'playback';console.log(`Demo call transport: ${transport}`);
if(transport==='twilio')for(const key of ['TWILIO_ACCOUNT_SID','TWILIO_AUTH_TOKEN','DEMO_CALL_FROM','DEMO_CALL_TO','DEMO_CALL_ALLOWLIST','PUBLIC_BASE_URL']){const ready=Boolean(env[key]);console.log(`${key}: ${ready?'configured':'manual setup required'}`);if(!ready)missing++;}
const manifest=JSON.parse(readFileSync(resolve(root,'ios/RayGuardian/Resources/ReplayMedia/manifest.json'),'utf8'));
console.log(`Replay index: ${manifest.clips.length} entries; ${manifest.clips.filter(c=>existsSync(resolve(root,'ios/RayGuardian/Resources/ReplayMedia',c.video))).length} local videos available`);
console.log(`${missing} external configuration values remain. Values and secrets are never printed.`);
if(process.argv.includes('--require-ready')&&missing)process.exitCode=1;
