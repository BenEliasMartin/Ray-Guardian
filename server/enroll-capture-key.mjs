#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { EncryptedStore } from './store.mjs';
import { CaptureSealService } from './capture-seal.mjs';

// Run locally on the backend host with its .env; no admin endpoint or APK admin secret.
const file=process.argv[2];
if(!file){console.error('Usage: node --env-file=.env server/enroll-capture-key.mjs phone-public-key.json');process.exit(1);}
const token=process.env.RAY_GUARDIAN_CLIENT_TOKEN;
if(!token||token.length<32)throw Error('Set the backend client token in the environment.');
const store=new EncryptedStore({path:process.env.DATA_PATH||resolve('server/data/guardian.sqlite'),key:process.env.DATA_ENCRYPTION_KEY});
try{
  const bundle=JSON.parse(readFileSync(file==='-'?0:file,'utf8'));
  console.log(JSON.stringify(new CaptureSealService({store}).enroll(createHash('sha256').update(token).digest('hex'),bundle)));
}finally{store.close();}
