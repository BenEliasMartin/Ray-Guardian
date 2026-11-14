// Port of GuardianCore/LocalSignals.swift. Checked against the same speech corpus.
export function voiceIntent(text,{isFinal=true,confidence=-1,isPlayingVoice=false}={}) {
 if(isPlayingVoice)return null;
 const words=String(text).toLowerCase().replace(/['’]/g,'').replace(/[^\p{L}\p{N}]/gu,' ').trim().split(/\s+/).filter(Boolean);
 const direct=words.join(' '),value=` ${direct} `;
 if(isFinal&&(confidence<0||confidence>=.55)){
  if(value.includes(' guardian cancel ')||value.includes(' guardian i am okay '))return 'cancel';
  if(value.includes(' guardian sos ')||value.includes(' guardian call for help '))return 'sos';
 }
 if(!((confidence===0&&!isFinal)||confidence<0||confidence>=.55))return null;
 const threats=['im going to kill you','i am going to kill you','im gonna kill you','i will kill you','ill kill you','im going to shoot you','im gonna shoot you','i will shoot you','ill shoot you','im going to stab you','im gonna stab you','i will stab you','ill stab you'];
 if(threats.some(p=>value.includes(` ${p} `)))return 'threat';
 const first='(?:i am|im|i m)';
 const reports=[`${first} (?:in (?:immediate )?danger(?! of\\b)|not safe|unsafe|under attack|being (?:attacked|followed|threatened)|trapped|hurt|injured|bleeding|choking)`,
  'i (?:cant|cannot|can not) (?:breathe|get up|move)','i (?:dont|do not) feel safe|i fear for my life|my life is in danger','i need (?:an ambulance|the police|medical help)',
  '(?:someone|somebody) is (?:attacking|following|threatening|hurting|choking) me','(?:ive|i have) been attacked','(?:ive|i have) fallen(?: down)?(?: and i (?:cant|cannot|can not) get up)?$|i fell(?: down| over)?$','(?:call (?:an ambulance|the police)|send help)'];
 const distress=reports.some(p=>new RegExp(`^(?:guardian )?(?:please )?(?:${p})(?: |$)`).test(direct));
 const refusal=/^(?:guardian )?(?:(?:no )+(?:please )?(?:dont|do not)(?: do that)?|please (?:dont|do not)(?: do that)?|(?:no )*(?:please )?(?:dont|do not) (?:hurt|touch|hit|kill|shoot|stab|grab|follow) me|(?:no )*(?:please )?(?:let me go|leave me alone|get off me|get away from me)|no (?:please )?stop|please stop(?: it)?|stop please)(?: (?:no|please|stop))*$/.test(direct);
 const negated=/\b(?:dont|do not|no need to) (?:please )?help\b/.test(direct),routine=/\b(?:help me|need help|please help) with\b/.test(direct);
 const help=!negated&&!routine&&(direct==='help'||['help me','somebody help','someone help','i need help','please help'].some(p=>value.includes(` ${p} `)));
 return (distress||refusal||help)&&(isFinal||!value.includes(' guardian '))?'distress':null;
}

export function recordingKind(incident){
 if(!incident||['cancelled','acknowledged','closed'].includes(incident.state))return null;
 if(incident.trigger==='spoken_threat'||incident.detection?.label==='possible_assault')return 'patrol';
 if(incident.detection?.label==='possible_fall'||['motion','motion_phone','heart_rate'].includes(incident.trigger))return 'pulse';
 return null;
}

export function pcmWav(samples,rate){
 if(!(samples instanceof Float32Array)||!Number.isFinite(rate)||rate<8000||rate>192000)throw new Error('Invalid microphone PCM.');
 const count=Math.min(128000,Math.floor(samples.length*16000/rate)),bytes=new Uint8Array(44+count*2),v=new DataView(bytes.buffer);
 const str=(offset,s)=>{for(let i=0;i<s.length;i++)v.setUint8(offset+i,s.charCodeAt(i));};
 str(0,'RIFF');v.setUint32(4,bytes.length-8,true);str(8,'WAVE');str(12,'fmt ');v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,1,true);v.setUint32(24,16000,true);v.setUint32(28,32000,true);v.setUint16(32,2,true);v.setUint16(34,16,true);str(36,'data');v.setUint32(40,count*2,true);
 const ratio=rate/16000;
 for(let i=0;i<count;i++){const from=i*ratio,to=Math.min(samples.length,(i+1)*ratio);let sum=0,weight=0;for(let j=Math.floor(from);j<Math.ceil(to);j++){const w=Math.max(0,Math.min(to,j+1)-Math.max(from,j));sum+=(samples[j]??0)*w;weight+=w;}const x=Math.max(-1,Math.min(1,sum/(weight||1)));v.setInt16(44+i*2,Math.round(x*(x<0?32768:32767)),true);}
 return bytes;
}
