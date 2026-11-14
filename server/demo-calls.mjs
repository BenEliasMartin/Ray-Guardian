import { createHmac,timingSafeEqual } from 'node:crypto';
import { ApiError } from './nemotron.mjs';
import { providerRequest } from './lib/transport.mjs';

export const xmlEscape=value=>String(value).replace(/[<>&"']/g,char=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[char]));
export function validateDemoNumber(value) {
  // Only full ordinary E.164 numbers. Short emergency/service dial strings cannot pass.
  if(typeof value!=='string'||!/^\+[1-9]\d{7,14}$/.test(value)||/^\+?0+$/.test(value))throw new Error('Demo destinations must be complete, explicitly allowlisted E.164 test numbers.');
  return value;
}
export function validTwilioSignature({url,params,signature,authToken}) {
  if(!authToken||typeof signature!=='string')return false;
  const input=url+Object.keys(params).sort().map(key=>key+params[key]).join('');
  const expected=Buffer.from(createHmac('sha1',authToken).update(input).digest('base64'));
  const received=Buffer.from(signature);
  return received.length===expected.length&&timingSafeEqual(received,expected);
}

export function createDemoCalls({transport='playback',accountSid,authToken,from,to,allowlist=[],publicBaseURL,mediaSecret,fetchImpl=fetch,now=Date.now}) {
  if(!['playback','twilio'].includes(transport))throw new Error('DEMO_CALL_TRANSPORT must be playback or twilio.');
  let publicURL;
  if(publicBaseURL){publicURL=new URL(publicBaseURL);if(publicURL.protocol!=='https:'||publicURL.username||publicURL.password||publicURL.search||publicURL.hash)throw new Error('PUBLIC_BASE_URL must be HTTPS without credentials or query.');}
  if(transport==='twilio'){
    if(!/^AC[a-fA-F0-9]{32}$/.test(accountSid??'')||!authToken||!publicURL||!mediaSecret||mediaSecret.length<32)throw new Error('Twilio demo calls need account credentials, HTTPS PUBLIC_BASE_URL, and MEDIA_SIGNING_SECRET.');
    validateDemoNumber(from);validateDemoNumber(to);
    if(!allowlist.map(validateDemoNumber).includes(to))throw new Error('DEMO_CALL_TO must appear in DEMO_CALL_ALLOWLIST.');
  }
  const base=publicURL?.href.replace(/\/$/,'');
  const sign=(id,expires)=>createHmac('sha256',mediaSecret??'disabled').update(`${id}:${expires}`).digest('hex');
  return {
    transport,
    mediaURL(id){
      if(!base||!mediaSecret||mediaSecret.length<32)throw new ApiError(503,'public_url_missing','Configure PUBLIC_BASE_URL for telephone playback.');
      const expires=now()+10*60_000;
      return `${base}/v1/demo-calls/${id}/audio?expires=${expires}&signature=${sign(id,expires)}`;
    },
    verifyMedia(id,expires,signature){
      if(transport!=='twilio'||!mediaSecret||mediaSecret.length<32)return false;
      const expiry=Number(expires);
      if(!Number.isSafeInteger(expiry)||expiry<now()||expiry>now()+10*60_000||typeof signature!=='string')return false;
      const expected=Buffer.from(sign(id,expiry)),actual=Buffer.from(signature);
      return actual.length===expected.length&&timingSafeEqual(actual,expected);
    },
    verifyWebhook(path,params,signature){return transport==='twilio'&&validTwilioSignature({url:base+path,params,signature,authToken});},
    twiml(id,{acknowledged=false,audioURL}={}){
      if(acknowledged)return '<?xml version="1.0"?><Response><Say>Demonstration acknowledged. No emergency services were dispatched.</Say><Hangup/></Response>';
      return `<?xml version="1.0"?><Response><Gather numDigits="1" timeout="8" action="${xmlEscape(base+'/v1/twilio/ack/'+id)}" method="POST"><Play>${xmlEscape(audioURL??this.mediaURL(id))}</Play></Gather><Say>No acknowledgement received. This demonstration has ended.</Say><Hangup/></Response>`;
    },
    async place(incident,signal){
      if(incident.mode!=='demo')throw new ApiError(403,'demo_only','Only demonstration calls are implemented.');
      if(transport==='playback')return {transport:'playback',status:'in_app',providerCallId:null};
      const body=new URLSearchParams({To:to,From:from,Twiml:this.twiml(incident.id),
        StatusCallback:`${base}/v1/twilio/status/${incident.id}`,StatusCallbackMethod:'POST',Timeout:'20',TimeLimit:'120'});
      ['initiated','ringing','answered','completed'].forEach(event=>body.append('StatusCallbackEvent',event));
      const {bytes}=await providerRequest(fetchImpl,`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Calls.json`,{
        method:'POST',headers:{Authorization:'Basic '+Buffer.from(`${accountSid}:${authToken}`).toString('base64'),'Content-Type':'application/x-www-form-urlencoded'},body,
      },{signal,timeoutMs:15000,limit:64*1024});
      let result;
      try{result=JSON.parse(bytes.toString());}catch{throw new ApiError(502,'invalid_call_response','The call provider returned an invalid response.');}
      if(!/^CA[a-fA-F0-9]{32}$/.test(result.sid??''))throw new ApiError(502,'invalid_call_response','The call provider returned no call identifier.');
      return {transport:'twilio',status:result.status??'queued',providerCallId:result.sid};
    },
    async cancel(providerCallId,signal){
      if(transport!=='twilio'||!/^CA[a-fA-F0-9]{32}$/.test(providerCallId??''))return;
      const update=async status=>providerRequest(fetchImpl,`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Calls/${providerCallId}.json`,{
        method:'POST',headers:{Authorization:'Basic '+Buffer.from(`${accountSid}:${authToken}`).toString('base64'),'Content-Type':'application/x-www-form-urlencoded'},
        body:new URLSearchParams({Status:status}),
      },{signal,timeoutMs:10000,limit:64*1024});
      // Twilio cancels queued/ringing calls and completes answered calls. Handle an answer racing cancellation.
      try{await update('canceled');}catch(error){if(signal?.aborted)throw error;await update('completed');}

    },
  };
}
