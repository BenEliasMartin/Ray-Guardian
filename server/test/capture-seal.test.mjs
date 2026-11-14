import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash,generateKeyPairSync,randomBytes,randomUUID,sign } from 'node:crypto';
import { mkdtempSync,readFileSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EncryptedStore } from '../store.mjs';
import { CaptureSealService,MAX_CLIP_BYTES } from '../capture-seal.mjs';
import { GuardianService } from '../guardian.mjs';
import { createGuardianHTTP } from '../http.mjs';
import { createPublicKey, verify } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const hash=b=>createHash('sha256').update(b).digest('hex');
const token='capture-seal-test-only-client-token-123456789';
const owner=hash(token);
const original=Buffer.concat([Buffer.from([0,0,0,24]),Buffer.from('ftypisom'),Buffer.alloc(12),Buffer.from('original-test-mdat-content')]);
test('Java SHA256withECDSA receipt and SPKI are interoperable with the backend verifier',()=>{
 const fixture=JSON.parse(readFileSync(new URL('fixtures/capture-java-v1.json',import.meta.url),'utf8'));
 const bytes=Buffer.from(fixture.receiptBase64,'base64'),receipt=JSON.parse(bytes);
 const spki=Buffer.from(fixture.publicKeySpki,'base64');
 assert.equal(receipt.keyId,`p256_${hash(spki)}`);
 assert.equal(receipt.videoSha256,hash(Buffer.from(fixture.videoBase64,'base64')));
 const key=createPublicKey({key:spki,format:'der',type:'spki'});
 assert.equal(key.asymmetricKeyDetails.namedCurve,'prime256v1');
 const signature=Buffer.from(fixture.signatureBase64,'base64');
 assert.equal(verify('sha256',bytes,{key,dsaEncoding:'der'},signature),true);
 assert.equal(verify('sha256',Buffer.concat([bytes,Buffer.from(' ')]),{key,dsaEncoding:'der'},signature),false);
});
function identity() {
 const {publicKey,privateKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'}),spki=publicKey.export({format:'der',type:'spki'});
 return {privateKey,installationId:randomUUID(),keyId:`p256_${hash(spki)}`,publicKeySpki:spki.toString('base64')};
}
function fixture(t,{path=':memory:',key=randomBytes(32).toString('hex')}={}) {
 let now=100000;
 const store=new EncryptedStore({path,key,now:()=>now}),seals=new CaptureSealService({store,now:()=>now}),phone=identity();
 seals.enroll(owner,phone);
 t.after(()=>store.close());
 const attempt=()=>seals.challenge(owner,{keyId:phone.keyId,installationId:phone.installationId});
 function packet(challenge,video=original,overrides={},pretty=false) {
  const receipt={version:1,incidentId:challenge.incidentId,keyId:phone.keyId,installationId:phone.installationId,nonce:challenge.nonce,videoSha256:hash(video),...overrides};
  const bytes=Buffer.from(JSON.stringify(receipt,null,pretty?2:undefined));
  return {receipt:bytes,signature:sign('sha256',bytes,phone.privateKey)};
 }
 const accept=(a,p,video=original)=>seals.accept(owner,a.incidentId,video,p.receipt,p.signature);
 return {store,seals,phone,attempt,packet,accept,advance:ms=>{now+=ms;}};
}

test('trusted exact original matches, original receipt bytes and encrypted MP4 are retained',t=>{
 const {store,seals,attempt,packet,accept}=fixture(t),a=attempt(),p=packet(a,original,{},true);
 const result=accept(a,p);assert.equal(result.status,'matches');assert.equal(result.seal,'Signed by the capture app');assert.equal(result.label,'Matches signed recording');
 const accepted=store.get('capture_acceptance',a.incidentId,owner);
 assert.deepEqual(Buffer.from(accepted.receiptBase64,'base64'),p.receipt);
 assert.deepEqual(Buffer.from(accepted.signatureBase64,'base64'),p.signature);
 assert.deepEqual(seals.original(owner,a.incidentId).bytes,original);
 const persisted=Buffer.from(store.db.prepare('SELECT payload FROM capture_originals').get().payload);
 assert.equal(persisted.includes(original),false);
});
test('edited copy with the original receipt differs and never overwrites acceptance',t=>{
 const {seals,attempt,packet,accept}=fixture(t),a=attempt(),p=packet(a);const accepted=accept(a,p);
 const edited=Buffer.from(original);edited[edited.length-1]^=1;
 assert.equal(accept(a,p,edited).label,'File differs from signed recording');assert.deepEqual(seals.status(owner,a.incidentId),accepted);assert.deepEqual(seals.original(owner,a.incidentId).bytes,original);
});
test('missing receipt, unknown key, invalid signature and upload-provided key establish no trust',t=>{
 const {seals,attempt,packet,accept}=fixture(t),a=attempt();
 assert.equal(seals.accept(owner,a.incidentId,original).label,'No trusted capture signature');
 const stranger=identity();const p=packet(a,original,{keyId:stranger.keyId});p.signature=sign('sha256',p.receipt,stranger.privateKey);
 assert.equal(accept(a,p).status,'untrusted');
 const forged=packet(a);forged.signature=sign('sha256',forged.receipt,stranger.privateKey);assert.equal(accept(a,forged).status,'untrusted');
 assert.equal(seals.status(owner,a.incidentId).status,'untrusted');
});
test('valid receipt is rejected under another incident',t=>{
 const {seals,attempt,packet}=fixture(t),a=attempt(),p=packet(a);
 assert.throws(()=>seals.accept(owner,randomUUID(),original,p.receipt,p.signature),{code:'capture_incident_mismatch'});
});
test('identical retries including after nonce expiry return the same persisted result',t=>{
 const {store,seals,attempt,packet,accept,advance}=fixture(t),a=attempt(),p=packet(a),first=accept(a,p);
 advance(6*60000);assert.deepEqual(accept(a,p),first);assert.deepEqual(seals.status(owner,a.incidentId),first);
 assert.equal(store.db.prepare('SELECT count(*) AS n FROM capture_originals').get().n,1);
 assert.equal(store.list('capture_acceptance',owner).length,1);
});
test('a consumed nonce cannot accept a replacement, even signed by the enrolled phone',t=>{
 const {seals,attempt,packet,accept}=fixture(t),a=attempt();accept(a,packet(a));
 const altered=Buffer.concat([original,Buffer.from('edit')]);assert.throws(()=>accept(a,packet(a,altered),altered),{code:'capture_already_accepted'});
 assert.deepEqual(seals.original(owner,a.incidentId).bytes,original);
});
test('nonce is bound to incident, installation, key and authenticated owner',t=>{
 const {seals,phone,attempt,packet,accept}=fixture(t),a=attempt(),b=attempt();
 assert.throws(()=>accept(b,packet(b,original,{nonce:a.nonce})),{code:'capture_attempt_mismatch'});
 assert.equal(accept(a,packet(a,original,{installationId:randomUUID()})).status,'untrusted');
 const p=packet(a);assert.equal(seals.accept('another-owner',a.incidentId,original,p.receipt,p.signature).status,'untrusted');
 assert.throws(()=>seals.challenge('another-owner',phone),{code:'capture_key_not_enrolled'});
});
test('expired or invented nonce cannot create acceptance',t=>{
 const {attempt,packet,accept,advance}=fixture(t),a=attempt(),p=packet(a);advance(300001);
 assert.throws(()=>accept(a,p),{code:'capture_nonce_expired'});
 assert.throws(()=>accept(a,packet(a,original,{nonce:randomBytes(32).toString('base64url')})),{code:'capture_attempt_mismatch'});
});
test('registry rejects non P-256 keys, identity replacement, and revoked keys',t=>{
 const {store,seals,phone,attempt,packet,accept}=fixture(t),a=attempt(),p=packet(a);
 const rsa=generateKeyPairSync('rsa',{modulusLength:2048}).publicKey.export({format:'der',type:'spki'});
 assert.throws(()=>seals.enroll(owner,{...phone,publicKeySpki:rsa.toString('base64')}),{code:'invalid_capture_key'});
 assert.throws(()=>seals.enroll(owner,{...phone,installationId:randomUUID()}),{code:'key_already_enrolled'});
 assert.throws(()=>seals.enroll(owner,{...identity(),installationId:phone.installationId}),{code:'installation_already_enrolled'});
 const key=store.get('capture_key',phone.keyId,owner);store.put('capture_key',{...key,revoked:true},{owner,expires:253402300799999,expectedRevision:key.revision});
 assert.equal(accept(a,p).status,'untrusted');
});
test('malformed receipts, invalid bytes and oversized uploads fail without a seal',t=>{
 const {seals,attempt,packet,accept}=fixture(t),a=attempt(),p=packet(a);
 assert.throws(()=>seals.accept(owner,a.incidentId,Buffer.from('not an MP4'),p.receipt,p.signature),{code:'invalid_video'});
 assert.throws(()=>seals.accept(owner,a.incidentId,Buffer.alloc(MAX_CLIP_BYTES+1),p.receipt,p.signature),{code:'invalid_video'});
 assert.throws(()=>seals.accept(owner,a.incidentId,original,Buffer.from([0xff]),p.signature),{code:'invalid_receipt'});
 assert.throws(()=>seals.accept(owner,a.incidentId,original,Buffer.alloc(4097),p.signature),{code:'invalid_receipt'});
 assert.throws(()=>seals.accept(owner,a.incidentId,original,Buffer.from('{"version":2}'),p.signature),{code:'invalid_receipt'});
 assert.throws(()=>accept(a,packet(a,original,{installationId:[randomUUID()]})),{code:'invalid_receipt'});
});
test('a failed commit rolls back original, receipt and nonce consumption together',t=>{
 const {store,seals,attempt,packet,accept}=fixture(t),a=attempt(),p=packet(a);
 store.db.exec("CREATE TRIGGER reject_receipt BEFORE INSERT ON records WHEN NEW.kind='capture_acceptance' BEGIN SELECT RAISE(ABORT,'test failure'); END;");
 assert.throws(()=>accept(a,p));assert.equal(store.db.prepare('SELECT count(*) AS n FROM capture_originals').get().n,0);assert.equal(store.list('capture_attempt',owner)[0].accepted,false);
 store.db.exec('DROP TRIGGER reject_receipt;');assert.equal(accept(a,p).status,'matches');
});
test('retention and deletion remove the original without allowing stale nonce reuse',t=>{
 const {seals,attempt,packet,accept,advance}=fixture(t),a=attempt(),p=packet(a);accept(a,p);
 seals.delete(owner,a.incidentId);assert.equal(seals.status(owner,a.incidentId).status,'untrusted');assert.throws(()=>seals.original(owner,a.incidentId),{code:'capture_not_found'});assert.throws(()=>accept(a,p),{code:'capture_attempt_mismatch'});
 const b=attempt();accept(b,packet(b));advance(86400001);seals.purge();assert.equal(seals.status(owner,b.incidentId).status,'untrusted');assert.throws(()=>seals.original(owner,b.incidentId),{code:'capture_not_found'});
});
test('registry and accepted bytes survive a backend restart',t=>{
 const dir=mkdtempSync(join(tmpdir(),'guardian-seal-')),path=join(dir,'sealed.sqlite'),key=randomBytes(32).toString('hex');t.after(()=>rmSync(dir,{recursive:true,force:true}));
 const store=new EncryptedStore({path,key}),seals=new CaptureSealService({store}),phone=identity();seals.enroll(owner,phone);
 const a=seals.challenge(owner,phone),bytes=Buffer.from(JSON.stringify({version:1,incidentId:a.incidentId,keyId:phone.keyId,installationId:phone.installationId,nonce:a.nonce,videoSha256:hash(original)})),signature=sign('sha256',bytes,phone.privateKey);
 const first=seals.accept(owner,a.incidentId,original,bytes,signature);store.close();
 const reopened=new EncryptedStore({path,key});try {const verifier=new CaptureSealService({store:reopened});assert.deepEqual(verifier.accept(owner,a.incidentId,original,bytes,signature),first);assert.deepEqual(verifier.original(owner,a.incidentId).bytes,original);}finally{reopened.close();}
 assert.equal(readFileSync(path).includes(original),false);
});
test('one-time admin CLI enrolls into the shared persistent registry without exposing an enrollment route',t=>{
 const dir=mkdtempSync(join(tmpdir(),'guardian-enrollment-')),path=join(dir,'registry.sqlite'),key=randomBytes(32).toString('hex'),phone=identity();
 t.after(()=>rmSync(dir,{recursive:true,force:true}));
 const bundle=JSON.stringify({installationId:phone.installationId,keyId:phone.keyId,publicKeySpki:phone.publicKeySpki});
 const output=execFileSync(process.execPath,['server/enroll-capture-key.mjs','-'],{input:bundle,encoding:'utf8',env:{...process.env,DATA_PATH:path,DATA_ENCRYPTION_KEY:key,RAY_GUARDIAN_CLIENT_TOKEN:token}});
 assert.equal(JSON.parse(output).enrolled,true);
 const store=new EncryptedStore({path,key});try {const verifier=new CaptureSealService({store});assert.equal(verifier.challenge(owner,phone).keyId,phone.keyId);}finally{store.close();}
});
test('HTTP route verifies original bytes, never trusts an upload key, and leaves SOS independent',async t=>{
 const {store,seals,phone,packet}=fixture(t);
 const g=new GuardianService({store,now:()=>100000,detect:async()=>{},voice:{},calls:{transport:'playback'}});
 const server=createGuardianHTTP({guardian:g,clientToken:token,now:()=>100000});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(async()=>{await new Promise(resolve=>server.close(resolve));await g.close();});
 const base=`http://127.0.0.1:${server.address().port}`,headers={authorization:`Bearer ${token}`};
 let response=await fetch(base+'/v1/capture-attempts',{method:'POST',headers:{...headers,'content-type':'application/json'},body:JSON.stringify(phone)});
 const a=await response.json(),p=packet(a);
 const upload=(video=original,extra={})=>fetch(`${base}/v1/incidents/${a.incidentId}/recording`,{method:'POST',headers:{...headers,'content-type':'video/mp4','x-guardian-receipt':p.receipt.toString('base64'),'x-guardian-signature':p.signature.toString('base64'),...extra},body:video});
 const replies=await Promise.all([upload(),upload()]);const results=await Promise.all(replies.map(r=>r.json()));assert.deepEqual(results[0],results[1]);assert.equal(results[0].label,'Matches signed recording');
 const downloaded=await fetch(`${base}/v1/incidents/${a.incidentId}/recording/original`,{headers});assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()),original);
 response=await fetch(`${base}/v1/incidents/${a.incidentId}/recording`,{method:'POST',headers:{...headers,'content-type':'video/mp4','x-guardian-public-key':phone.publicKeySpki},body:original});assert.equal((await response.json()).status,'untrusted');
 assert.equal((await fetch(base+'/v1/capture-attempts',{method:'POST',headers:{'content-type':'application/json'},body:'{}'})).status,401);
 response=await fetch(base+'/v1/simulated-dispatch',{method:'POST',headers:{...headers,'content-type':'application/json'},body:JSON.stringify({id:a.incidentId,trigger:'manual-sos'})});assert.equal(response.status,200);assert.equal((await response.json()).status,'simulated-accepted');
 assert.equal(seals.status(owner,a.incidentId).status,'matches');
});
