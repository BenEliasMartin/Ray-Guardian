class GuardianPCM extends AudioWorkletProcessor {
 constructor(){super();this.left=Math.floor(sampleRate*6.2);this.buffer=new Float32Array(4096);this.used=0;}
 flush(){if(!this.used)return;const chunk=this.buffer.slice(0,this.used);this.port.postMessage(chunk,[chunk.buffer]);this.used=0;}
 process(inputs){const channels=inputs[0];if(!channels?.length)return this.left>0;const length=Math.min(channels[0].length,this.left);
  for(let i=0;i<length;i++){let mono=0;for(const channel of channels)mono+=channel[i]??0;this.buffer[this.used++]=mono/channels.length;if(this.used===this.buffer.length)this.flush();}
  this.left-=length;if(this.left<=0){this.flush();this.port.postMessage({done:true});return false;}return true;
 }
}
registerProcessor('guardian-pcm',GuardianPCM);
