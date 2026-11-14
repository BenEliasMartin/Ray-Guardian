import {readFile,stat} from 'node:fs/promises';
import {resolve,basename} from 'node:path';
import {ApiError} from './nemotron.mjs';
export async function loadReplays(directory){
  const root=resolve(directory);let manifest;
  try{manifest=JSON.parse(await readFile(resolve(root,'manifest.json'),'utf8'));}catch{return null;}
  const entries=new Map();
  for(const item of manifest.clips??[]){
    if(!/^[a-zA-Z0-9_-]+$/.test(item.id))throw new Error('Invalid replay ID.');
    for(const key of ['video','audio'])if(item[key]&&(basename(item[key])!==item[key]))throw new Error('Replay media must be local filenames.');
    entries.set(item.id,item);
  }
  return {manifest,async read(id,kind){
    const name=entries.get(id)?.[kind];if(!name)throw new ApiError(404,'not_found','Replay not prepared.');
    const path=resolve(root,name);if((await stat(path)).size>100*1024*1024)throw new ApiError(413,'replay_too_large','Replay exceeds size limit.');
    return {bytes:await readFile(path),contentType:kind==='video'?'video/mp4':'audio/wav'};
  }};
}
