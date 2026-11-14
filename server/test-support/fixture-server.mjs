// Native UI-test support ONLY. Never imported by the production entry point.
// Real SDK frames/WAV are required, but provider classification is explicitly a test fixture.
import {EncryptedStore} from '../store.mjs';
import {GuardianService} from '../guardian.mjs';
import {createGuardianHTTP} from '../http.mjs';
import {createDemoCalls} from '../demo-calls.mjs';
const store=new EncryptedStore({path:':memory:',key:'f'.repeat(64)});
const guardian=new GuardianService({store,calls:createDemoCalls({transport:'playback'}),voice:{
  async transcribe(wav){if(wav.length<3244)throw new Error('UI test did not supply real PCM audio.');return {text:'Test fixture transcript. This is not live provider output.',source:'test_fixture_stt'};},
  async speak(){throw new Error('UI test must not request synthesized provider voice.');},
},detect:async({frames})=>{
  if(!frames.length||frames[0].bytes.length<1000)throw new Error('UI test did not supply genuine camera frames.');
  return {label:'ordinary_activity',confidence:'medium',summary:'UI routing fixture: actual SDK frames received. No real provider classification was performed.',observations:[`${frames.length} camera frames received.`],uncertainties:['Test fixture provider response.'],wearerInvolved:true,source:'test_fixture'};
},providerStatus:{testFixture:{configured:true}}});
const server=createGuardianHTTP({guardian,clientToken:'ui-test-only-client-token-never-production-12345'});
server.listen(8787,'127.0.0.1',()=>console.log('UI TEST FIXTURE server ready; no live providers or calls.'));
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{server.close();await guardian.close();store.close();});
