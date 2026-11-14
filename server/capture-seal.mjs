import { createHash, createPublicKey, randomBytes, randomUUID, verify } from 'node:crypto';
import { TextDecoder } from 'node:util';
import { ApiError } from './nemotron.mjs';

export const MAX_CLIP_BYTES=16*1024*1024;
const DAY=86400000, NONCE_MS=5*60000, REGISTRY_EXPIRY=253402300799999;
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const KEY=/^p256_[a-f0-9]{64}$/;
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const fail=(status,code,message)=>{throw new ApiError(status,code,message);};
const result=(status,extra={})=>({status,label:{matches:'Matches signed recording',file_differs:'File differs from signed recording',untrusted:'No trusted capture signature'}[status],...extra});
export function decodeSealBase64(value,maxBytes) {
  if(typeof value!=='string'||value.length>Math.ceil(maxBytes/3)*4||!value.length||!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value))fail(400,'invalid_receipt','Invalid receipt encoding.');
  const bytes=Buffer.from(value,'base64');
  if(bytes.length>maxBytes||bytes.toString('base64')!==value)fail(400,'invalid_receipt','Invalid receipt encoding.');
  return bytes;
}
function parseReceipt(bytes) {
  let value;
  try{value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{fail(400,'invalid_receipt','Receipt must be valid UTF-8 JSON.');}
  if(!value||['incidentId','installationId','keyId','nonce','videoSha256'].some(field=>typeof value[field]!=='string'))fail(400,'invalid_receipt','Receipt fields must be strings.');
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).sort().join(',')!=='incidentId,installationId,keyId,nonce,version,videoSha256'||value.version!==1||!UUID.test(value.incidentId)||!UUID.test(value.installationId)||!KEY.test(value.keyId)||typeof value.nonce!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(value.nonce)||typeof value.videoSha256!=='string'||!/^[a-f0-9]{64}$/.test(value.videoSha256))fail(400,'invalid_receipt','Unsupported capture receipt.');
  return value;
}
function publicKey(spkiBase64) {
  try {
    const bytes=decodeSealBase64(spkiBase64,512),key=createPublicKey({key:bytes,format:'der',type:'spki'});
    if(key.asymmetricKeyType!=='ec'||key.asymmetricKeyDetails?.namedCurve!=='prime256v1')throw Error();
    const canonical=key.export({format:'der',type:'spki'});
    if(!canonical.equals(bytes))throw Error();
    return {key,bytes};
  }catch{fail(400,'invalid_capture_key','Enrollment requires an X.509 SPKI P-256 public key.');}
}

/** No upload or public enrollment endpoint can add a trusted key. Admin CLI only. */
export class CaptureSealService {
  constructor({store,now=Date.now}) {
    this.store=store;this.now=now;
    store.db.exec(`CREATE TABLE IF NOT EXISTS capture_originals(incident_id TEXT PRIMARY KEY,owner TEXT NOT NULL,expires INTEGER NOT NULL,payload BLOB NOT NULL);`);
  }
  enroll(owner,{installationId,keyId,publicKeySpki}) {
    if(!UUID.test(installationId)||!KEY.test(keyId))fail(400,'invalid_capture_key','Invalid installation or key identity.');
    const {bytes}=publicKey(publicKeySpki);
    if(keyId!==`p256_${sha(bytes)}`)fail(400,'invalid_capture_key','keyId must identify the enrolled public key.');
    return this.store.transaction(()=>{
      const existing=this.store.get('capture_key',keyId);
      if(existing){if(existing.owner!==owner||existing.installationId!==installationId||existing.publicKeySpki!==publicKeySpki||existing.revoked)fail(409,'key_already_enrolled','Key enrollment is immutable.');return {keyId,installationId,enrolled:true};}
      if(this.store.list('capture_key',owner).some(k=>k.installationId===installationId&&!k.revoked))fail(409,'installation_already_enrolled','This installation already has an enrolled key.');
      this.store.put('capture_key',{id:keyId,owner,installationId,publicKeySpki,enrolledAt:this.now(),revoked:false},{owner,expires:REGISTRY_EXPIRY,expectedRevision:0});
      return {keyId,installationId,enrolled:true};
    });
  }
  requireKey(owner,keyId,installationId) {
    const key=this.store.get('capture_key',keyId,owner);
    return key&&!key.revoked&&key.installationId===installationId?key:null;
  }
  challenge(owner,{keyId,installationId,incidentId=randomUUID()}) {
    if(!KEY.test(keyId)||!UUID.test(installationId)||!this.requireKey(owner,keyId,installationId))fail(403,'capture_key_not_enrolled','An administrator must enroll this installation signing key first.');
    if(!UUID.test(incidentId))fail(400,'invalid_incident','Invalid incident ID.');
    if(this.store.get('capture_acceptance',incidentId))fail(409,'capture_already_accepted','An accepted recording cannot be replaced.');
    const nonce=randomBytes(32).toString('base64url'),id=sha(nonce),expiresAt=this.now()+NONCE_MS;
    const recent=this.store.list('capture_attempt',owner).filter(a=>a.createdAt>this.now()-10*60000);
    if(recent.length>=12)fail(429,'capture_attempt_limit','Capture attempt limit reached.');
    this.store.put('capture_attempt',{id,incidentId,owner,keyId,installationId,nonceSha256:id,createdAt:this.now(),expiresAt,accepted:false},{owner,expires:this.now()+DAY,expectedRevision:0});
    return {version:1,incidentId,keyId,installationId,nonce,expiresAt};
  }
  accept(owner,incidentId,video,receiptBytes=null,signature=null) {
    if(!UUID.test(incidentId))fail(400,'invalid_incident','Invalid incident ID.');
    if(!Buffer.isBuffer(video)||video.length<12||video.length>MAX_CLIP_BYTES||video.toString('ascii',4,8)!=='ftyp')fail(400,'invalid_video','Send a bounded original MP4.');
    // No receipt, unknown enrollment, or invalid signature can ever create a seal.
    if(!receiptBytes||!signature)return result('untrusted');
    if(receiptBytes.length>4096||signature.length>80)fail(400,'invalid_receipt','Receipt or signature exceeds the limit.');
    const receipt=parseReceipt(receiptBytes);
    if(receipt.incidentId!==incidentId)fail(409,'capture_incident_mismatch','Receipt belongs to a different incident.');
    const enrolled=this.requireKey(owner,receipt.keyId,receipt.installationId);
    if(!enrolled)return result('untrusted');
    let valid=false;
    try{valid=verify('sha256',receiptBytes,{key:publicKey(enrolled.publicKeySpki).key,dsaEncoding:'der'},signature);}catch{}
    if(!valid)return result('untrusted');
    const videoSha256=sha(video);
    const attemptId=sha(receipt.nonce),attempt=this.store.get('capture_attempt',attemptId,owner);
    if(!attempt||attempt.incidentId!==incidentId||attempt.keyId!==receipt.keyId||attempt.installationId!==receipt.installationId)fail(409,'capture_attempt_mismatch','Receipt does not belong to the issued capture attempt.');
    if(videoSha256!==receipt.videoSha256)return result('file_differs');
    const receiptSha256=sha(receiptBytes),signatureSha256=sha(signature);
    return this.store.transaction(()=>{
      // Read under the same write transaction as insertion: retries cannot race replacements.
      const current=this.store.get('capture_attempt',attemptId,owner);
      const accepted=this.store.get('capture_acceptance',incidentId,owner);
      if(accepted){
        if(accepted.receiptSha256!==receiptSha256||accepted.signatureSha256!==signatureSha256||accepted.videoSha256!==videoSha256)fail(409,'capture_already_accepted','An accepted recording cannot be replaced.');
        return accepted.result;
      }
      if(!current||current.accepted||current.expiresAt<=this.now())fail(410,'capture_nonce_expired','Capture attempt expired or was consumed.');
      // Recheck revocation inside the acceptance transaction.
      if(!this.requireKey(owner,receipt.keyId,receipt.installationId))return result('untrusted');
      const acceptedAt=this.now(),expires=acceptedAt+DAY;
      const acceptedResult=result('matches',{incidentId,keyId:receipt.keyId,videoSha256,acceptedAt,expiresAt:expires,seal:'Signed by the capture app'});
      const payload=this.store.encryptBytes(video,'capture_original',incidentId,owner);
      this.store.db.prepare('INSERT INTO capture_originals(incident_id,owner,expires,payload) VALUES(?,?,?,?)').run(incidentId,owner,expires,payload);
      this.store.put('capture_acceptance',{id:incidentId,owner,receiptBase64:receiptBytes.toString('base64'),signatureBase64:signature.toString('base64'),receiptSha256,signatureSha256,videoSha256,result:acceptedResult},{owner,expires,expectedRevision:0});
      this.store.put('capture_attempt',{...current,accepted:true},{owner,expires,expectedRevision:current.revision});
      return acceptedResult;
    });
  }
  status(owner,id) {
    const accepted=this.store.get('capture_acceptance',id,owner);
    return accepted?.result??result('untrusted');
  }
  original(owner,id) {
    const acceptance=this.store.get('capture_acceptance',id,owner);
    const row=this.store.db.prepare('SELECT * FROM capture_originals WHERE incident_id=? AND owner=? AND expires>?').get(id,owner,this.now());
    if(!acceptance||!row)fail(404,'capture_not_found','No accepted original recording.');
    const bytes=this.store.decryptBytes(row.payload,'capture_original',id,owner);
    if(sha(bytes)!==acceptance.videoSha256){bytes.fill(0);fail(500,'capture_integrity_error','Stored original failed its integrity check.');}
    return {bytes,contentType:'video/mp4'};
  }
  delete(owner,id) {
    this.store.transaction(()=>{
      this.store.db.prepare('DELETE FROM capture_originals WHERE incident_id=? AND owner=?').run(id,owner);
      this.store.delete('capture_acceptance',id,owner);
      for(const attempt of this.store.list('capture_attempt',owner))if(attempt.incidentId===id)this.store.delete('capture_attempt',attempt.id,owner);
    });
  }
  purge(){this.store.db.prepare('DELETE FROM capture_originals WHERE expires<=?').run(this.now());}
}
