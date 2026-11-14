import Foundation
import GuardianCore
var checks = 0
func verify(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(),message); checks += 1 }
verify(KeywordDetector.intent("Guardian help me",isFinal:true,confidence:0.9) == .distress,"Local distress keyword")
verify(KeywordDetector.intent("Guardian SOS",isFinal:true,confidence:-1) == .sos,"Unknown ASR confidence allowed")
verify(KeywordDetector.intent("Guardian cancel",isFinal:false,confidence:0.9) == nil,"Partial ASR cannot trigger")
verify(KeywordDetector.intent("Guardian SOS",isFinal:true,confidence:0.9,isPlayingVoice:true) == nil,"Voice echo suppressed")
verify(KeywordDetector.intent("Loud concert",isFinal:true,confidence:0.9) == nil,"Everyday speech ignored")
var detector = FallCandidateDetector()
verify(!detector.consume(MotionPoint(time:1,x:0,y:0,z:30)),"Impact alone rejected")
verify(!detector.consume(MotionPoint(time:1.2,x:0,y:0,z:1)),"Free fall is a candidate only")
verify(detector.consume(MotionPoint(time:1.4,x:0,y:0,z:30)),"Free fall then impact triggers")
verify(!detector.consume(MotionPoint(time:1.3,x:0,y:0,z:30)),"Stale device timestamp rejected")
var gate = PrivacyGate(), consent = Consent(); gate.arm(consent:consent,now:0)
verify(gate.beginCapture(now:1) == nil,"Default capture denied")
consent.capture = true; consent.cloud = true; gate.arm(consent:consent,now:2)
let epoch = gate.beginCapture(now:3)!
verify(gate.accepts(epoch,now:4),"Current capture accepted")
verify(!gate.accepts(epoch,now:12),"Capture expires")
gate.invalidate(); verify(!gate.accepts(epoch,now:4),"Disarm invalidates callbacks")
gate.arm(consent:consent,now:0); verify(gate.beginCapture(now:901) == nil,"Arming expires")
let samples = (0..<3200).map { Int16($0-1600) }, wav = PCM16WAV.encode(samples)
let decoded = try PCM16WAV.decode(wav); verify(decoded == samples,"Actual PCM WAV round trip")
let bounded = try PCM16WAV.decode(PCM16WAV.encode(Array(repeating:Int16(1),count:140000))); verify(bounded.count == 128000,"Audio capped at eight seconds")
var malformed = wav; malformed[22] = 2
do { _ = try PCM16WAV.decode(malformed); fatalError("Stereo WAV accepted") } catch { checks += 1 }
do { _ = try GuardianAPI(url:"http://public.example",token:String(repeating:"a",count:32)); fatalError("Public cleartext URL accepted") } catch { checks += 1 }
let json = """
{"id":"s","mode":"demo","source":"meta_mock","consent":{"capture":true,"cloud":true,"audio":false,"voice":true,"demoCalls":true,"location":false,"backgroundEscalation":false},"armed":true,"armedUntil":123456,"activeWindow":null,"incidentId":null}
"""
let session = try JSONDecoder().decode(GuardianSession.self,from:Data(json.utf8)); verify(session.armed && !session.consent.audio,"Backend session contract")
if CommandLine.arguments.contains("--write-wav"), let index = CommandLine.arguments.firstIndex(of:"--write-wav"), index+1 < CommandLine.arguments.count { try wav.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1])) }
verify(HeartRateMeasurement.decode(Data([0,150])) == 150,"8-bit Bluetooth heart rate")
verify(HeartRateMeasurement.decode(Data([1,160,0])) == 160,"16-bit Bluetooth heart rate")
verify(HeartRateMeasurement.decode(Data([1,160])) == nil,"Truncated Bluetooth packet rejected")
verify(HeartRateMeasurement.decode(Data([4,160])) == nil,"No sensor contact rejected")
var hr = SustainedHeartRate()
verify(!hr.consume(bpm:170,threshold:160,time:1),"First elevated reading is insufficient")
verify(!hr.consume(bpm:170,threshold:160,time:5),"Second elevated reading is insufficient")
verify(hr.consume(bpm:170,threshold:160,time:9),"Sustained fresh elevation is a candidate")
verify(!hr.consume(bpm:180,threshold:160,time:10),"Heart-rate trigger cooldown")
print("Passed \(checks) GuardianCore checks")
