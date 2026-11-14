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
var continuousMotion = FallCandidateDetector()
verify(!continuousMotion.consume(MotionPoint(time:1,x:0,y:0,z:1)),"Initial free-fall sample")
verify(!continuousMotion.consume(MotionPoint(time:1.033,x:0,y:0,z:1)),"Consecutive free-fall sample")
verify(continuousMotion.consume(MotionPoint(time:1.066,x:0,y:0,z:30)),"30 Hz impact uses start of free fall")
var gate = PrivacyGate(), consent = Consent(); gate.arm(consent:consent,now:0)
verify(gate.beginCapture(now:1) == nil,"Default capture denied")
consent.capture = true; consent.cloud = true; gate.arm(consent:consent,now:2)
let epoch = gate.beginCapture(now:3)!
verify(gate.accepts(epoch,now:4),"Current capture accepted")
verify(!gate.accepts(epoch,now:12),"Capture expires")
gate.invalidate(); verify(!gate.accepts(epoch,now:4),"Disarm invalidates callbacks")
gate.arm(consent:consent,now:0); verify(gate.beginCapture(now:1800) == nil,"Arming expires")
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

// Glasses IMU scenarios at 30 Hz. Angle is head pitch in degrees (0 upright, 90 lying on the side).
func pose(_ t: Double, _ degrees: Double, g: Double = 1, spin: Double = 0) -> MotionPoint {
    let r = degrees*Double.pi/180, a = 9.80665*g
    return MotionPoint(time: t, x: a*sin(r), y: 0, z: a*cos(r), rotationX: 0, rotationY: spin, rotationZ: 0)
}
func run(_ points: [MotionPoint]) -> [FallPattern] { var d = FallCandidateDetector(); return points.compactMap { d.detect($0) } }
func timeline(_ from: Double, _ to: Double, _ make: (Double) -> MotionPoint) -> [MotionPoint] { stride(from: from, to: to, by: 1.0/30).map(make) }
let tiltFall = timeline(0,3) { pose($0,0) } + timeline(3,3.4) { pose($0,($0-3)/0.4*85,g:1.1,spin:6) } + [pose(3.42,88,g:2.6,spin:3)] + timeline(3.45,7) { pose($0,90) }
verify(run(tiltFall) == [.rapidTilt],"Fast head rotation to lying with impact triggers without free fall")
let slump = timeline(0,6) { pose($0,0) } + timeline(6,8) { pose($0,($0-6)/2*80,spin:0.7) } + timeline(8,12) { pose($0,80) }
verify(run(slump) == [.slump],"Slow collapse followed by stillness triggers")
let nod = timeline(0,3) { pose($0,0) } + timeline(3,3.3) { pose($0,($0-3)/0.3*45,spin:3) } + timeline(3.3,3.6) { pose($0,45-($0-3.3)/0.3*45,spin:3) } + timeline(3.6,8) { pose($0,0) }
verify(run(nod).isEmpty,"Quick nod and look back up is ignored")
let walking = timeline(0,10) { pose($0,5*sin($0*2),g:1+0.45*sin($0*12)) }
verify(run(walking).isEmpty,"Walking bounce is ignored")
let lookDownRunning = timeline(0,3) { pose($0,0,g:1+0.6*sin($0*15)) } + timeline(3,6) { pose($0,40,g:1+1.3*max(0,sin($0*15))) }
verify(run(lookDownRunning).isEmpty,"Running with a moderate downward glance is ignored")
var recorder = MotionRecorder()
for p in tiltFall { recorder.append(p.retimed(p.time+100)) }
if let summary = recorder.summary(triggerAt: 103.42,endAt: 107,fallPattern: .rapidTilt) {
    verify(summary.tiltDegrees > 80 && summary.peakImpactG >= 2.5,"Summary captures tilt and impact")
    verify(summary.stillSecondsAtEnd >= 3,"Summary captures stillness after the fall")
    verify(summary.coveredFromMs == -3000 || summary.coveredFromMs > -3010,"Summary starts three seconds before the trigger")
    verify((summary.peakRotationDegPerSec ?? 0) > 300,"Summary converts rotation rate to degrees per second")
} else { verify(false,"Summary is produced") }
verify(MotionRecorder().summary(triggerAt: 1,endAt: 2) == nil,"No summary without samples")
var lateRecorder = MotionRecorder()
for p in timeline(98,111,{ pose($0,0,g: $0 > 108 ? 10 : 1) }) { lateRecorder.append(p) }
if let summary = lateRecorder.summary(triggerAt:100,endAt:111) {
    verify(summary.coveredToMs <= 8000 && summary.peakImpactG == 1,"Delayed capture completion excludes sensor samples after eight seconds")
} else { verify(false,"Bounded delayed summary is produced") }
verify(lateRecorder.summary(triggerAt:.nan,endAt:111) == nil,"Nonfinite motion window is rejected")
let offsets = stride(from: -2.8, through: 7.9, by: 0.35).map { $0 }
var sharp = offsets.map { _ in 1.0 }; sharp[3] = 50; sharp[9] = 80
let picked = KeyframeSelector.select(offsets: offsets,sharpness: sharp)
verify(picked.count == 6 && picked.contains(3) && picked.contains(9),"Keyframes keep the sharpest frame in each period")
verify(picked.map { offsets[$0] } == picked.map { offsets[$0] }.sorted(),"Keyframes are chronological")
verify(picked.contains { offsets[$0] < 0 } && picked.contains { offsets[$0] >= 0 && offsets[$0] < 1.5 },"Keyframes cover before and right after the trigger")
verify(KeyframeSelector.select(offsets: [0.1,0.5],sharpness: [1,2]).count == 2 && KeyframeSelector.select(offsets: [0.1,0.2],sharpness: [1,2]) == [1],"Few candidates are kept unless near-duplicates")
let flat = [UInt8](repeating: 128,count: 100), edges = (0..<100).map { UInt8(($0 % 2) * 255) }
verify(FrameSharpness.laplacianVariance(flat,width: 10,height: 10) == 0 && FrameSharpness.laplacianVariance(edges,width: 10,height: 10) > 1000,"Sharpness separates flat and detailed images")
print("Passed \(checks) GuardianCore checks")
