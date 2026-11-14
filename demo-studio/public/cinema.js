// Local films only. This player never opens a camera, microphone, or backend session.
export const films={
 threat:{src:'/assets/night-pov.mp4',poster:'/assets/night-pov.jpg',label:'Stock POV · Fictional threat scenario',prelude:5},
 fall:{src:'/assets/fall-pov.mp4',poster:'/assets/fall-pov.jpg',label:'Wearable POV · Staged research fall',prelude:0},
 cancel:{src:'/assets/courtyard-pov.mp4',poster:'/assets/courtyard-pov.jpg',label:'Wearable POV · Fictional dialogue',prelude:0},
};
export function filmPosition(story,time,duration,reduced=false){
 if(!films[story]||!Number.isFinite(duration)||duration<=0)return 0;
 return reduced?0:Math.max(0,Math.min(duration-.08,time+films[story].prelude));
}
export class CinematicScene {
 constructor(root){
  this.root=root;this.video=root.querySelector('video');this.reduce=matchMedia('(prefers-reduced-motion: reduce)');
  for(const event of ['loadeddata','seeked','canplay'])this.video.addEventListener(event,()=>this.sync());
  this.video.addEventListener('error',()=>{this.failed=true;this.waiting=false;this.root.classList.add('film-failed');});
  this.reduce.addEventListener('change',()=>this.sync());
 }
 update({active,running,time,story}){
  if(!active||!films[story]){this.stop();return;}
  const film=films[story];this.state={running,time,story};this.root.hidden=false;
  if(this.story!==story){
   this.story=story;this.failed=false;this.waiting=true;this.root.classList.remove('film-failed');
   this.video.poster=film.poster;this.video.src=film.src;this.video.load();
  }
  this.sync();
 }
 sync(){
  if(!this.state)return;
  const v=this.video,s=this.state;this.root.classList.toggle('film-still',this.reduce.matches);
  this.waiting=!this.failed&&(v.readyState<2||v.seeking);
  if(this.failed||v.readyState<1)return;
  const target=filmPosition(s.story,s.time,v.duration,this.reduce.matches);
  // Story time owns the film: presenter skips/restarts seek instead of looping the fall.
  if(!v.seeking&&Math.abs(v.currentTime-target)>.45)v.currentTime=target;
  const shouldPlay=s.running&&!this.reduce.matches&&target<v.duration-.12;
  if(shouldPlay&&v.paused&&!this.playPending){
   this.playPending=true;
   v.play().catch(()=>{if(this.state&&this.story===s.story)this.blocked=true;}).finally(()=>this.playPending=false);
  }else if(!shouldPlay)v.pause();
 }
 resume(){this.blocked=false;this.sync();}
 stop(){this.state=null;this.waiting=false;this.blocked=false;this.video.pause();this.root.hidden=true;}
}
