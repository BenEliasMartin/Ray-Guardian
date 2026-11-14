import XCTest
@testable import GuardianCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
final class GuardianCoreTests: XCTestCase {
    func testKeywordsRequireFinalLocalRecognitionAndIgnorePlayback() {
        XCTAssertEqual(KeywordDetector.intent("Guardian, help me!",isFinal: true,confidence: 0.9),.distress)
        XCTAssertEqual(KeywordDetector.intent("Guardian SOS",isFinal: true,confidence: -1),.sos)
        XCTAssertEqual(KeywordDetector.intent("Guardian I am okay",isFinal: true,confidence: 0.9),.cancel)
        XCTAssertNil(KeywordDetector.intent("Guardian help me",isFinal: false,confidence: 0.9))
        XCTAssertNil(KeywordDetector.intent("Guardian help me",isFinal: true,confidence: 0.1))
        XCTAssertNil(KeywordDetector.intent("Guardian help me",isFinal: true,confidence: 0.9,isPlayingVoice: true))
        XCTAssertNil(KeywordDetector.intent("The lifeguardian helped me",isFinal: true,confidence: 0.9))
        XCTAssertNil(KeywordDetector.intent("It is loud here",isFinal: true,confidence: 0.9))
        XCTAssertEqual(KeywordDetector.intent("I’m going to kill you",isFinal: false,confidence: 0),.threat)
        XCTAssertEqual(KeywordDetector.intent("im going to kill you",isFinal: true,confidence: 0.9),.threat)
        XCTAssertNil(KeywordDetector.intent("I’m going to kill the lights",isFinal: true,confidence: 0.9))
        XCTAssertEqual(KeywordDetector.intent("Help!",isFinal: true,confidence: -1),.distress)
        XCTAssertEqual(KeywordDetector.intent("Somebody help me!",isFinal: false,confidence: 0),.distress)
    }
    func testMotionRequiresTimedFreeFallThenImpactAndCoolsDown() {
        var detector = FallCandidateDetector()
        func p(_ time: Double,_ g: Double) -> MotionPoint { MotionPoint(time:time,x:0,y:0,z:g*9.80665) }
        XCTAssertFalse(detector.consume(p(1,1))); XCTAssertFalse(detector.consume(p(2,3)))
        XCTAssertFalse(detector.consume(p(2.1,0.2))); XCTAssertTrue(detector.consume(p(2.3,3)))
        XCTAssertFalse(detector.consume(p(2.4,0.2))); XCTAssertFalse(detector.consume(p(2.6,3)))
        XCTAssertFalse(detector.consume(p(64,0.2))); XCTAssertTrue(detector.consume(p(64.2,3)))
    }
    func testConsecutiveFreeFallSamplesAtThirtyHertzPreserveTheStart() {
        var detector = FallCandidateDetector()
        XCTAssertFalse(detector.consume(MotionPoint(time:1,x:0,y:0,z:1)))
        XCTAssertFalse(detector.consume(MotionPoint(time:1.033,x:0,y:0,z:1)))
        XCTAssertTrue(detector.consume(MotionPoint(time:1.066,x:0,y:0,z:30)))
    }
    func testMotionRejectsStaleSamplesAndGaps() {
        var detector = FallCandidateDetector()
        XCTAssertFalse(detector.consume(MotionPoint(time:3,x:0,y:0,z:1)))
        XCTAssertFalse(detector.consume(MotionPoint(time:2,x:0,y:0,z:30)))
        XCTAssertFalse(detector.consume(MotionPoint(time:8,x:0,y:0,z:30)))
    }
    func testGateRequiresConsentAndInvalidatesInFlightEpoch() {
        var gate = PrivacyGate(), consent = Consent(); gate.arm(consent:consent,now:1)
        XCTAssertNil(gate.beginCapture(now:2)); consent.capture = true; consent.cloud = true; gate.arm(consent:consent,now:3)
        let token = gate.beginCapture(now:4)!; XCTAssertTrue(gate.accepts(token,now:5)); XCTAssertFalse(gate.accepts(token,now:13)); XCTAssertNil(gate.beginCapture(now:6)); gate.invalidate(); XCTAssertFalse(gate.accepts(token,now:6)); XCTAssertNil(gate.beginCapture(now:7))
    }
    func testGateExpiresWithoutRenewal() { var g = PrivacyGate(), c = Consent(); c.capture = true; c.cloud = true; g.arm(consent:c,now:0); XCTAssertNotNil(g.beginCapture(now:1799)); g.endCapture(); XCTAssertNil(g.beginCapture(now:1800)); g.arm(consent:c,now:0,duration:900); XCTAssertNil(g.beginCapture(now:900)) }
    func testWAVRoundTripBoundsAndMalformedFiles() throws {
        let samples: [Int16] = (0..<3200).map { Int16($0-1600) }; XCTAssertEqual(try PCM16WAV.decode(PCM16WAV.encode(samples)),samples)
        XCTAssertEqual(try PCM16WAV.decode(PCM16WAV.encode(Array(repeating:1,count:140000))).count,128000)
        var bad = PCM16WAV.encode(samples); bad[22] = 2; XCTAssertThrowsError(try PCM16WAV.decode(bad)); XCTAssertThrowsError(try PCM16WAV.decode(Data("hello".utf8)))
        XCTAssertThrowsError(try PCM16WAV.decode(PCM16WAV.encode([1,2])))
    }
    func testLoudnessIsOnlyAnIndicator() { var loud = LoudnessDetector(); XCTAssertFalse(loud.consume([Int16](repeating:30000,count:320),time:1)); XCTAssertTrue(loud.consume([Int16](repeating:30000,count:320),time:1.7)); XCTAssertFalse(loud.consume([Int16](repeating:1,count:320),time:2)) }
    func testConfigurationRequiresHTTPSOutsideLocalDevelopment() throws {
        XCTAssertThrowsError(try GuardianAPI(url:"http://public.example",token:String(repeating:"a",count:32)))
        XCTAssertThrowsError(try GuardianAPI(url:"https://user:password@example.com",token:String(repeating:"a",count:32)))
        XCTAssertNoThrow(try GuardianAPI(url:"http://127.0.0.1:8787",token:String(repeating:"a",count:32)))
        XCTAssertNoThrow(try GuardianAPI(url:"https://guardian.example",token:String(repeating:"a",count:32)))
    }
    func testBackendContractDecode() throws {
        let json = """
        {"id":"session","mode":"demo","source":"meta_mock","consent":{"capture":true,"cloud":true,"audio":false,"voice":true,"demoCalls":true,"location":false,"backgroundEscalation":false},"armed":true,"armedUntil":123456,"activeWindow":null,"incidentId":null}
        """
        let session = try JSONDecoder().decode(GuardianSession.self,from:Data(json.utf8)); XCTAssertTrue(session.armed); XCTAssertEqual(session.source,.meta_mock); XCTAssertFalse(session.consent.audio)
    }
    private func pose(_ t: Double,_ degrees: Double,g: Double = 1,spin: Double = 0) -> MotionPoint {
        let r = degrees*Double.pi/180, a = 9.80665*g
        return MotionPoint(time: t,x: a*sin(r),y: 0,z: a*cos(r),rotationX: 0,rotationY: spin,rotationZ: 0)
    }
    private func timeline(_ from: Double,_ to: Double,_ make: (Double) -> MotionPoint) -> [MotionPoint] { stride(from: from,to: to,by: 1.0/30).map(make) }
    func testGyroscopeAndOrientationDetectFallsWithoutFreeFall() {
        var detector = FallCandidateDetector()
        let fall = timeline(0,3) { self.pose($0,0) } + timeline(3,3.4) { self.pose($0,($0-3)/0.4*85,g: 1.1,spin: 6) } + [pose(3.42,88,g: 2.6,spin: 3)] + timeline(3.45,7) { self.pose($0,90) }
        XCTAssertEqual(fall.compactMap { detector.detect($0) },[.rapidTilt])
        var slumping = FallCandidateDetector()
        let slump = timeline(0,6) { self.pose($0,0) } + timeline(6,8) { self.pose($0,($0-6)/2*80,spin: 0.7) } + timeline(8,12) { self.pose($0,80) }
        XCTAssertEqual(slump.compactMap { slumping.detect($0) },[.slump])
        var nodding = FallCandidateDetector()
        let nod = timeline(0,3) { self.pose($0,0) } + timeline(3,3.3) { self.pose($0,($0-3)/0.3*45,spin: 3) } + timeline(3.3,8) { self.pose($0,0) }
        XCTAssertTrue(nod.compactMap { nodding.detect($0) }.isEmpty)
    }
    func testMotionSummaryAndKeyframesCoverTheFall() throws {
        var recorder = MotionRecorder()
        for p in timeline(0,3,{ pose($0,0) }) + timeline(3,3.4,{ pose($0,($0-3)/0.4*85,spin: 6) }) + [pose(3.42,88,g: 2.6)] + timeline(3.45,7,{ pose($0,90) }) { recorder.append(p) }
        let summary = try XCTUnwrap(recorder.summary(triggerAt: 3.42,endAt: 7,fallPattern: .rapidTilt))
        XCTAssertGreaterThan(summary.tiltDegrees,80); XCTAssertGreaterThanOrEqual(summary.peakImpactG,2.5); XCTAssertGreaterThanOrEqual(summary.stillSecondsAtEnd,3)
        let json = String(decoding: try JSONEncoder().encode(summary),as: UTF8.self)
        XCTAssertTrue(json.contains("\"fallPattern\":\"rapid_tilt\""))
        let offsets = stride(from: -2.8,through: 7.9,by: 0.35).map { $0 }
        let picked = KeyframeSelector.select(offsets: offsets,sharpness: offsets.indices.map { Double($0 % 5) })
        XCTAssertEqual(picked.count,6); XCTAssertTrue(picked.contains { offsets[$0] < 0 })
    }
}
