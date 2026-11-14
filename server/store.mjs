import { DatabaseSync } from 'node:sqlite';
import { createCipheriv,createDecipheriv,randomBytes } from 'node:crypto';
import { mkdirSync,chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import { ApiError } from './nemotron.mjs';

/** Encrypted metadata; explicitly sealed originals use a separate immutable BLOB table. */
export class EncryptedStore {
  constructor({path='data/guardian.sqlite',key,now=Date.now}) {
    if(typeof key!=='string'||!/^[a-fA-F0-9]{64}$/.test(key))throw new Error('DATA_ENCRYPTION_KEY must contain 64 hexadecimal characters.');
    this.key=Buffer.from(key,'hex'); this.now=now;
    if(path!==':memory:')mkdirSync(dirname(path),{recursive:true,mode:0o700});
    this.db=new DatabaseSync(path);
    if(path!==':memory:')chmodSync(path,0o600);
    this.db.exec('PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA busy_timeout=5000;');
    this.db.exec(`CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL,id TEXT NOT NULL,owner TEXT NOT NULL,revision INTEGER NOT NULL,
      expires INTEGER NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(kind,id)); CREATE INDEX IF NOT EXISTS records_owner ON records(kind,owner);
      CREATE INDEX IF NOT EXISTS records_expiry ON records(expires);`);
  }
  encrypt(value,kind,id,owner) {
    const plain=Buffer.from(JSON.stringify(value));
    try{return this.encryptBytes(plain,kind,id,owner);}finally{plain.fill(0);}
  }
  encryptBytes(plain,kind,id,owner) {
    const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',this.key,iv);
    cipher.setAAD(Buffer.from(`${kind}:${id}:${owner}`));
    return Buffer.concat([iv,cipher.update(plain),cipher.final(),cipher.getAuthTag()]);
  }
  decryptBytes(payload,kind,id,owner) {
    const bytes=Buffer.from(payload),decipher=createDecipheriv('aes-256-gcm',this.key,bytes.subarray(0,12));
    decipher.setAAD(Buffer.from(`${kind}:${id}:${owner}`));decipher.setAuthTag(bytes.subarray(-16));
    return Buffer.concat([decipher.update(bytes.subarray(12,-16)),decipher.final()]);
  }
  decrypt(row) {
    const plain=this.decryptBytes(row.payload,row.kind,row.id,row.owner);
    try{return {...JSON.parse(plain.toString()),revision:Number(row.revision)};}finally{plain.fill(0);}
  }
  get(kind,id,owner) {
    const row=this.db.prepare('SELECT * FROM records WHERE kind=? AND id=?').get(kind,id);
    if(!row||owner!=null&&row.owner!==owner)return null;
    if(Number(row.expires)<=this.now()){this.db.prepare('DELETE FROM records WHERE kind=? AND id=?').run(kind,id);return null;}
    return this.decrypt(row);
  }
  put(kind,value,{owner,expires,expectedRevision=null}) {
    if(!value?.id||!owner||!Number.isFinite(expires))throw new Error('Missing record identity or expiry.');
    const row=this.db.prepare('SELECT revision,owner FROM records WHERE kind=? AND id=?').get(kind,value.id);
    const revision=row?Number(row.revision)+1:1;
    if(row&&row.owner!==owner||expectedRevision!==null&&(row?Number(row.revision):0)!==expectedRevision)throw new ApiError(409,'revision_conflict','The record changed; refresh and retry.');
    const body={...value};delete body.revision;
    const payload=this.encrypt(body,kind,value.id,owner);
    this.db.prepare('INSERT INTO records(kind,id,owner,revision,expires,payload) VALUES(?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision,expires=excluded.expires,payload=excluded.payload')
      .run(kind,value.id,owner,revision,expires,payload);
    return {...body,revision};
  }
  list(kind,owner=null) {
    this.purge();
    const rows=owner===null?this.db.prepare('SELECT * FROM records WHERE kind=? ORDER BY rowid DESC').all(kind):this.db.prepare('SELECT * FROM records WHERE kind=? AND owner=? ORDER BY rowid DESC').all(kind,owner);
    return rows.map(row=>this.decrypt(row));
  }
  delete(kind,id,owner) {return this.db.prepare('DELETE FROM records WHERE kind=? AND id=? AND owner=?').run(kind,id,owner).changes>0;}
  transaction(operation) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result=operation();this.db.exec('COMMIT');return result; }
    catch(error) { this.db.exec('ROLLBACK');throw error; }
  }
  purge(){return this.db.prepare('DELETE FROM records WHERE expires<=?').run(this.now()).changes;}
  close(){this.db.close();this.key.fill(0);}
}
