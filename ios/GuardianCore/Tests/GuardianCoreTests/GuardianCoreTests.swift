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
    func testGateExpiresWithoutRenewal() { var g = PrivacyGate(), c = Consent(); c.capture = true; c.cloud = true; g.arm(consent:c,now:0); XCTAssertNil(g.beginCapture(now:900)) }
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
}
