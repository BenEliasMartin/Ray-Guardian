export const stories = [
  { id:'threat', number:'01', name:'A voice in the dark', category:'Spoken threat', quote:'“I’ll kill you.”', cue:'An explicit threat is recognized.', signal:'spoken_threat', kind:'patrol', checkAt:3, assessAt:9, end:23,
    summary:'A spoken threat starts a check-in immediately. Visual assessment adds context; it does not erase the original request.', result:'Possible assault', prompt:'Are you okay? If you’re safe, say “Guardian cancel.”', steps:[0,2,3,7,9,18,23] },
  { id:'fall', number:'02', name:'An unexpected fall', category:'Motion + scene', quote:'A sudden drop. An impact. Stillness.', cue:'A fall candidate requests a short scene check.', signal:'motion', kind:'pulse', checkAt:10, assessAt:10, end:30,
    summary:'A local motion candidate opens a bounded capture. A qualifying fall assessment starts the check-in.', result:'Possible fall', prompt:'That looked like a fall. Are you okay? If you’re safe, say “Guardian cancel.”', steps:[0,2,3,7,10,25,30] },
  { id:'cancel', number:'03', name:'A false alarm, resolved', category:'Wearer in control', quote:'“No, please don’t.”', cue:'A refusal plea starts a check-in.', signal:'keyword_distress', kind:null, checkAt:3, assessAt:9, autoCancel:8, end:12,
    summary:'The wearer cancels a precautionary check-in. Pending analysis cannot reopen the cancelled incident.', result:'Check-in cancelled', prompt:'Are you okay? If you’re safe, say “Guardian cancel.”', steps:[0,2,3,7,8,12] },

];
export function frameAt(story, time, cancelledAt=null) {
  const t=Math.max(0,time);
  const cancel=cancelledAt ?? story.autoCancel;
  const cancelled=cancel!=null && t>=cancel;
  const deadline=story.checkAt==null?null:story.checkAt+15;
  const alert=!cancelled && deadline!=null && t>=deadline;
  const check=!cancelled && story.checkAt!=null && t>=story.checkAt && !alert;
  const captured=t>=3, assessed=t>=story.assessAt && !cancelled;
  const phase=cancelled?'cancelled':alert?'alert':check?'check-in':assessed?'clear':t>=7?'assessing':captured?'capture':t>=2?'trigger':'standby';
  const title={standby:'Ready when you need it.',trigger:'A signal worth checking.',capture:'A brief look at the scene.',assessing:'Making sense of the scene.','check-in':'Are you okay?',alert:'Demo alert active.',cancelled:'You’re in control.',clear:'Carry on with your day.'}[phase];
  return { t,phase,title,cancelled,cancelledAt:cancelled?cancel:null,alert,check,captured,assessed,recording:captured&&t<7&&!cancelled,
    countdown:check?Math.max(0,Math.ceil(deadline-t)):null,
    kind:check||alert?story.kind:null, complete:cancelled?t>=Math.min(story.end,cancel+4):t>=story.end,
    pipeline:cancelled?4:alert?4:assessed?3:t>=7?2:captured?1:t>=2?0:-1 };
}
export function eventsAt(story,time,cancelledAt=null) {
  const f=frameAt(story,time,cancelledAt), events=[{at:0,title:'Guardian armed',detail:'Camera off. Waiting for a local indicator.'}];
  if(time>=2)events.push({at:2,title:'Trigger received',detail:story.cue});
  if(time>=3)events.push({at:3,title:'Bounded capture opened',detail:'Illustrated capture; no camera or microphone is accessed.'});
  if(story.checkAt!=null&&time>=story.checkAt)events.push({at:story.checkAt,title:'Check-in started',detail:'15 seconds to respond in this rehearsal.'});
  const stoppedAt=cancelledAt??story.autoCancel??Infinity;
  if(time>=7&&stoppedAt>=7)events.push({at:7,title:'Capture stopped',detail:'Context goes to assessment. No ongoing recording.'});
  if(time>=story.assessAt&&stoppedAt>=story.assessAt)events.push({at:story.assessAt,title:'Scripted assessment',detail:story.id==='ordinary'?'Ordinary activity. No incident created.':story.result+'. Illustrative result, not live inference.'});
  if(f.cancelled)events.push({at:cancelledAt??story.autoCancel,title:'Wearer cancelled',detail:'Countdown stopped. Pending results cannot reopen the incident.'});
  if(f.alert)events.push({at:story.checkAt+15,title:'Demo alert activated',detail:'Illustrated escalation. No call was placed.'});
  return events.sort((a,b)=>a.at-b.at);
}

// Presentation beats describe the replay; the incident clock above still owns outcomes.
export function sceneAt(story,time,f,opening=0){
 if(story.id==='fall')return null;
 const base={tag:'',quote:'',detail:'',caption:'',speaker:'SCENE NARRATION',role:'narrator',beat:f.phase};
 const scene=(values)=>({...base,...values});
 if(story.id==='threat'){
  if(opening>0)return scene({beat:opening>3?'night':'behind',tag:'ON YOUR WAY HOME',quote:opening>3?'The long<br><mark>way home.</mark>':'Footsteps.<br><mark>Behind you.</mark>',detail:'Your phone stays in your pocket.',caption:opening>3?'You’re walking home.':'Then, footsteps behind you.'});
  if(time<1.6)return scene({tag:'A VOICE, JUST OUT OF VIEW',quote:'Then someone<br><mark>speaks.</mark>',detail:'Guardian is armed. The camera is still off.',caption:'A voice behind you.'});
  if(time<3)return scene({beat:'threat-line',tag:'OFFSCREEN / FICTIONAL DIALOGUE',quote:'“I’ll<br><mark>kill you.”</mark>',detail:'A spoken threat wakes Guardian.',caption:'I’ll kill you.',speaker:'VOICE BEHIND YOU',role:'offscreen'});
  if(f.cancelled)return scene({tag:'YOU HAVE THE LAST WORD',quote:'One answer.<br><mark>Guardian stops.</mark>',caption:'Check-in cancelled.',speaker:'GLASSES AUDIO',role:'guardian'});
  if(f.alert)return scene({tag:'THE CHECK-IN WENT UNANSWERED',quote:'No answer.<br><mark>An alert begins.</mark>',detail:'Illustrated escalation. No emergency call is placed.',caption:'Your alert is active. Say “Guardian cancel” to stop it.',speaker:'GLASSES AUDIO',role:'guardian'});
  return scene({tag:'HELP DOESN’T WAIT FOR A PICTURE',quote:'A threat.<br><mark>Already heard.</mark>',detail:'The spoken cue starts a check-in before scene assessment finishes.',caption:story.prompt,speaker:'GLASSES AUDIO',role:'guardian',phoneTitle:'Are you safe?',phoneDetail:'Say “Guardian cancel” if you’re safe.'});
 }
 if(story.id==='cancel'){
  if(time<1.6)return scene({tag:'A MOMENT ON YOUR WAY',quote:'An ordinary<br><mark>walk.</mark>',detail:'Then a phrase worth checking.',caption:'An ordinary walk.'});
  if(time<3)return scene({beat:'plea',tag:'SCRIPTED DISTRESS CUE',quote:'“No,<br><mark>please don’t.”</mark>',detail:'A precautionary check-in begins.',caption:'No, please don’t.',speaker:'SCRIPTED VOICE',role:'wearer'});
  if(f.cancelled){const sayingCancel=time<(f.cancelledAt??story.autoCancel??8)+1.6;return scene({beat:sayingCancel?'wearer-cancels':'stopped',tag:'YOUR VOICE. YOUR CHOICE.',quote:sayingCancel?'“Guardian<br><mark>cancel.”</mark>':'You’re safe.<br><mark>It stops here.</mark>',detail:'Your reply ends the check-in. No alert follows.',caption:sayingCancel?'Guardian, cancel.':'Check-in cancelled.',speaker:sayingCancel?'YOU':'GLASSES AUDIO',role:sayingCancel?'wearer':'guardian',phoneTitle:'Check-in cancelled.',phoneDetail:'No alert follows.'});}
  return scene({tag:'A CHECK-IN, NOT AN ASSUMPTION',quote:'Guardian asks.<br><mark>You decide.</mark>',detail:'You can cancel now, or watch the scripted voice cancellation.',caption:story.prompt,speaker:'GLASSES AUDIO',role:'guardian',phoneDetail:'Say “Guardian cancel” if you’re safe.'});
 }

 return null;
}
