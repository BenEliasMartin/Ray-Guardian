import {randomBytes} from 'node:crypto';
import {existsSync,readFileSync,writeFileSync,chmodSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
const root=fileURLToPath(new URL('..',import.meta.url)),path=resolve(root,'server/.env');
let text=existsSync(path)?readFileSync(path,'utf8'):readFileSync(resolve(root,'server/.env.example'),'utf8');
function setMissing(key,value){const line=new RegExp(`^${key}=(.*)$`,'m'),match=text.match(line);if(!match)text+=`\n${key}=${value}\n`;else if(!match[1].trim())text=text.replace(line,`${key}=${value}`);}
setMissing('RAY_GUARDIAN_CLIENT_TOKEN',randomBytes(32).toString('hex'));setMissing('DATA_ENCRYPTION_KEY',randomBytes(32).toString('hex'));setMissing('MEDIA_SIGNING_SECRET',randomBytes(32).toString('hex'));
writeFileSync(path,text,{mode:0o600});chmodSync(path,0o600);
const local=resolve(root,'ios/Config/Local.xcconfig');
if(!existsSync(local)){
  const index=process.argv.indexOf('--api-url'),url=index>=0?process.argv[index+1]:'http://127.0.0.1:8787';
  if(!/^https?:\/\/[^\r\n]+$/.test(url))throw new Error('Invalid --api-url.');
  const token=text.match(/^RAY_GUARDIAN_CLIENT_TOKEN=(.*)$/m)[1].trim();
  writeFileSync(local,`// Local development configuration. Provider keys stay in server/.env.\nDEVELOPMENT_TEAM =\nMETA_APP_ID = 0\nMETA_CLIENT_TOKEN =\nGUARDIAN_API_URL = ${url.replace('://',':/$()/')}\nGUARDIAN_CLIENT_TOKEN = ${token}\n`,{mode:0o600});
}
console.log('Prepared ignored server/.env and ios/Config/Local.xcconfig. Existing values preserved. Add provider keys and Apple/Meta identifiers to these files.');
