import XCTest
@testable import GuardianCore
#if canImport(Vision)
import Vision
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
final class GuardianCoreTests: XCTestCase {
    func testSelectedIncidentAnimationsUseSpecificCues() {
        XCTAssertEqual(IncidentAnimation.kind(trigger:"spoken_threat",detectionLabel:nil),.patrol)
        XCTAssertEqual(IncidentAnimation.kind(trigger:"spoken_threat",detectionLabel:"possible_fall"),.patrol)
        XCTAssertEqual(IncidentAnimation.kind(trigger:"manual_check",detectionLabel:"possible_assault"),.patrol)
        XCTAssertEqual(IncidentAnimation.kind(trigger:"manual_check",detectionLabel:"possible_fall"),.pulse)
        XCTAssertEqual(IncidentAnimation.kind(trigger:"motion_phone",detectionLabel:nil),.pulse)
        XCTAssertEqual(IncidentAnimation.kind(trigger:"heart_rate",detectionLabel:nil),.pulse)
        XCTAssertNil(IncidentAnimation.kind(trigger:"keyword_distress",detectionLabel:"uncertain"))
        XCTAssertNil(IncidentAnimation.kind(trigger:"manual_sos",detectionLabel:nil))
        XCTAssertNil(IncidentAnimation.kind(trigger:"manual_check",detectionLabel:"immediate_danger"))
    }
    func testIncidentRefreshDoesNotRestartAnimationAndCancellationRemovesIt() throws {
        func incident(_ state: String) throws -> Incident {
            let object: [String:Any] = ["id":"same-incident","sessionId":"same-session","mode":"demo","state":state,"trigger":"spoken_threat","createdAt":100000,"updatedAt":104000,"voiceConsent":false,"demoCallConsent":false]
            return try JSONDecoder().decode(Incident.self,from:JSONSerialization.data(withJSONObject:object))
        }
        let first = try XCTUnwrap(IncidentAnimation.update(previous:nil,incident:try incident("check_in"),now:100))
        XCTAssertEqual(IncidentAnimation.update(previous:first,incident:try incident("check_in"),now:103),first)
        XCTAssertEqual(IncidentAnimation.update(previous:first,incident:try incident("needs_demo_call_consent"),now:104),first)
        XCTAssertEqual(first.elapsed(at:102),2)
        XCTAssertEqual(first.elapsed(at:120),6)
        XCTAssertEqual(first.elapsed(at:.nan),6)
        XCTAssertNil(IncidentAnimation.update(previous:first,incident:try incident("cancelled"),now:105))
        XCTAssertNil(IncidentAnimation.update(previous:first,incident:nil,now:105))
    }

    func testSimulatedDispatchReadsCurrentCoordinatesAndNeverInventsThem() throws {
        func incident(trigger: String, location: String = "null") throws -> Incident {
            try JSONDecoder().decode(Incident.self, from: Data("""
            {"id":"incident","sessionId":"session","mode":"demo","state":"check_in",
             "trigger":"\(trigger)","createdAt":0,"updatedAt":0,"voiceConsent":false,
             "demoCallConsent":false,"location":\(location)}
            """.utf8))
        }
        let threat = try incident(trigger: "spoken_threat",
                                  location: #"{"latitude":60.17083,"longitude":-24.93750,"accuracyMeters":12}"#)
        let police = DemoDispatch(incident: threat)
        XCTAssertEqual(police.service, .police)
        XCTAssertEqual(police.title, "Calling police…")
        XCTAssertTrue(police.spokenBriefing.hasPrefix("Police dispatch, this is Ray Guardian."))
        let sos = try incident(trigger: "manual_sos")
        let intro = try XCTUnwrap(IncidentAnimation.update(previous: nil, incident: sos, now: 100, fallback: .patrol))
        XCTAssertEqual(intro.kind, .patrol)
        XCTAssertEqual(IncidentAnimation.update(previous: intro, incident: sos, now: 103, fallback: .patrol), intro)
        XCTAssertEqual(police.coordinates?.displayText, "60.17083°, -24.93750°")
        XCTAssertTrue(police.spokenBriefing.contains("60 point 1 7 0 8 3 degrees north"))
        XCTAssertTrue(police.spokenBriefing.contains("24 point 9 3 7 5 0 degrees west"))
        let fall = DemoDispatch(incident: try incident(trigger: "motion_phone"))
        XCTAssertEqual(fall.service, .ambulance)
        XCTAssertTrue(fall.spokenBriefing.contains("A wearer fall is unconfirmed."))
        XCTAssertTrue(fall.spokenBriefing.contains("Current location is unavailable."))
        let requested = DemoDispatch(incident: threat, requestedService: .ambulance)
        XCTAssertEqual(requested.title, "Calling ambulance…")
        XCTAssertTrue(requested.spokenBriefing.hasPrefix("Ambulance dispatch, this is Ray Guardian."))
        XCTAssertEqual(requested.coordinates, police.coordinates)
        XCTAssertEqual(IncidentAnimation.update(previous: nil, incident: threat, now: 100,
                                               preferred: requested.service.animation)?.kind, .pulse)
    }

    func testScreenlessCheckInHasVoiceControlsAndSuppressesItsOwnInstructions() throws {
        let prompt = try XCTUnwrap(HandsFreePrompt.text(state:"check_in",voiceCommands:true))
        XCTAssertTrue(prompt.contains("Guardian cancel"))
        XCTAssertTrue(prompt.contains("Guardian SOS"))
        XCTAssertNil(KeywordDetector.intent(prompt,isFinal:true,confidence:0.9,isPlayingVoice:true))
        XCTAssertTrue(try XCTUnwrap(HandsFreePrompt.text(state:"check_in",voiceCommands:false)).contains("phone"))
        XCTAssertTrue(try XCTUnwrap(HandsFreePrompt.text(state:"call_unknown",voiceCommands:true)).contains("unknown"))
        XCTAssertNil(HandsFreePrompt.text(state:"future_unknown_state",voiceCommands:true))
    }
    func testQuietHaloUsesServerDeadlineAndDoesNotInventAlertSuccess() throws {
        let clock=try XCTUnwrap(QuietHalo.Countdown(startedAt:100000,deadline:115000))
        XCTAssertEqual(clock.reading(at:103001)?.seconds,12)
        XCTAssertEqual(clock.reading(at:114999)?.seconds,1)
        XCTAssertEqual(clock.reading(at:115000)?.seconds,0)
        XCTAssertEqual(clock.reading(at:125000)?.fraction,0)
        XCTAssertEqual(clock.reading(at:90000)?.fraction,1)
        XCTAssertNil(clock.reading(at:.nan))
        XCTAssertNil(QuietHalo.Countdown(startedAt:115000,deadline:100000))
        XCTAssertNil(QuietHalo.state(incidentState:nil))
        XCTAssertEqual(QuietHalo.state(incidentState:"check_in",capturing:true,processing:true)?.kind,.checkIn)
        XCTAssertEqual(QuietHalo.state(incidentState:"call_queued")?.title,"Preparing demo alert")
        XCTAssertEqual(QuietHalo.state(incidentState:"demo_call_active",transport:"playback")?.title,"Demo playback active")
        XCTAssertEqual(QuietHalo.state(incidentState:"call_unknown")?.title,"Check demo status")
        XCTAssertEqual(QuietHalo.state(incidentState:"cancelled")?.kind,.confirmation)
    }
    func testSpeechRegressionCorpus() throws {
        struct Example: Decodable { let text: String, expected: String?; let isFinal: Bool?, confidence: Float?, isPlayingVoice: Bool? }
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("../Fixtures/speech-intents.json")
        for example in try JSONDecoder().decode([Example].self,from:Data(contentsOf:url)) {
            let result = KeywordDetector.intent(example.text,isFinal:example.isFinal ?? true,confidence:example.confidence ?? 0.9,isPlayingVoice:example.isPlayingVoice ?? false)
            XCTAssertEqual(result.map { String(describing:$0) },example.expected,example.text)
        }
    }
    func testPhoneMotionConvertsGravityUnitsAndKeepsItsOwnCooldown() {
        var phone = FallCandidateDetector(), glasses = FallCandidateDetector()
        let rest = MotionPoint.phoneAcceleration(time:1,x:0,y:0,z:-1)
        XCTAssertEqual(rest.g,1,accuracy:0.00001)
        XCTAssertFalse(phone.consume(rest))
        XCTAssertFalse(phone.consume(.phoneAcceleration(time:1.1,x:0.1,y:0,z:0)))
        XCTAssertTrue(phone.consume(.phoneAcceleration(time:1.3,x:3,y:0,z:0)))
        XCTAssertFalse(phone.consume(.phoneAcceleration(time:1.4,x:0.1,y:0,z:0)))
        XCTAssertFalse(phone.consume(.phoneAcceleration(time:1.6,x:3,y:0,z:0)))
        XCTAssertFalse(glasses.consume(.phoneAcceleration(time:1.4,x:0.1,y:0,z:0)))
        XCTAssertTrue(glasses.consume(.phoneAcceleration(time:1.6,x:3,y:0,z:0)))
    }
    func testPhoneMotionOptInIsIncludedInSessionContract() throws {
        let normal = try JSONSerialization.jsonObject(with:JSONEncoder().encode(CreateSession(consent:Consent(),source:.meta_mock))) as! [String:Any]
        XCTAssertEqual(normal["phoneMotionTesting"] as? Bool,false)
        XCTAssertEqual(normal["automaticSceneChecks"] as? Bool,false)
        XCTAssertEqual(normal["speechMonitoring"] as? Bool,false)
        let optedIn = try JSONSerialization.jsonObject(with:JSONEncoder().encode(CreateSession(consent:Consent(),source:.meta_mock,phoneMotionTesting:true))) as! [String:Any]
        XCTAssertEqual(optedIn["phoneMotionTesting"] as? Bool,true)
        XCTAssertEqual(TriggerSignal.motion_phone.rawValue,"motion_phone")
    }
    #if canImport(Vision)
    func testShakaAcceptsEitherHandAndRejectsOtherPoses() {
        typealias Joint = VNHumanHandPoseObservation.JointName
        let shaka: [Joint: CGPoint] = [
            .wrist: CGPoint(x: 0, y: 0),
            .indexMCP: CGPoint(x: -0.3, y: 1), .indexTip: CGPoint(x: -0.3, y: 0.8),
            .middleMCP: CGPoint(x: 0, y: 1), .middleTip: CGPoint(x: 0, y: 0.75),
            .ringMCP: CGPoint(x: 0.25, y: 0.9), .ringTip: CGPoint(x: 0.2, y: 0.7),
            .littleMCP: CGPoint(x: 0.45, y: 0.7), .littlePIP: CGPoint(x: 0.75, y: 0.7),
            .littleDIP: CGPoint(x: 0.95, y: 0.7), .littleTip: CGPoint(x: 1.13, y: 0.7),
            .thumbMP: CGPoint(x: -0.45, y: 0.4), .thumbIP: CGPoint(x: -0.75, y: 0.45),
            .thumbTip: CGPoint(x: -1.05, y: 0.5)
        ]
        func matches(_ points: [Joint: CGPoint]) -> Bool {
            CameraHandPose.matches(.shaka) { joint, _ in points[joint] }
        }
        XCTAssertTrue(matches(shaka))
        XCTAssertTrue(matches(shaka.mapValues { CGPoint(x: -$0.x, y: $0.y) }))
        XCTAssertTrue(matches(shaka.mapValues { CGPoint(x: -$0.y, y: $0.x) }))

        var bentPinky = shaka
        bentPinky[.littleTip] = CGPoint(x: 0.86, y: 0.64)
        bentPinky.removeValue(forKey: .littleDIP)
        bentPinky.removeValue(forKey: .ringTip)
        XCTAssertTrue(matches(bentPinky))

        var angledShaka = shaka
        angledShaka[.littleTip] = CGPoint(x: 0.73, y: 0.67)
        XCTAssertTrue(matches(angledShaka))

        var horns = shaka
        horns[.indexTip] = CGPoint(x: -0.5, y: 1.9)
        XCTAssertFalse(matches(horns))

        var thumbsUp = shaka
        thumbsUp[.littleTip] = CGPoint(x: 0.4, y: 0.65)
        XCTAssertFalse(matches(thumbsUp))

        var peace = thumbsUp
        peace[.indexTip] = CGPoint(x: -0.55, y: 1.9)
        peace[.middleTip] = CGPoint(x: 0.15, y: 2)
        peace[.thumbTip] = CGPoint(x: -0.1, y: 0.7)
        XCTAssertFalse(matches(peace))

        var fist = thumbsUp
        fist[.thumbTip] = CGPoint(x: -0.1, y: 0.7)
        XCTAssertFalse(matches(fist))
        XCTAssertTrue(CameraHandPose.matches(.fist) { joint, _ in fist[joint] })
        XCTAssertFalse(CameraHandPose.matches(.fist) { joint, _ in shaka[joint] })
    }
    #endif

    func testGestureRequiresSustainedLiveFramesAndFiresOncePerHold() {
        var hold = HandGestureHold()
        XCTAssertFalse(hold.consume(matches: true, at: 0))
        XCTAssertFalse(hold.consume(matches: true, at: 0.3))
        XCTAssertFalse(hold.consume(matches: true, at: 1.1), "A dropped feed cannot complete a hold")
        XCTAssertFalse(hold.consume(matches: true, at: 1.4))
        XCTAssertFalse(hold.consume(matches: false, at: 1.7))
        XCTAssertFalse(hold.consume(matches: true, at: 2))
        XCTAssertFalse(hold.consume(matches: true, at: 2.3))
        XCTAssertFalse(hold.consume(matches: true, at: 2.6))
        XCTAssertTrue(hold.consume(matches: true, at: 2.9))
        XCTAssertFalse(hold.consume(matches: true, at: 3.2))
    }

    func testCancelHoldToleratesOneMissButRejectsAnInterruptedHold() {
        var hold = HandGestureHold()
        XCTAssertFalse(hold.consume(matches: true, at: 0, allowingOneMiss: true))
        XCTAssertFalse(hold.consume(matches: true, at: 0.28, allowingOneMiss: true))
        XCTAssertFalse(hold.consume(matches: false, at: 0.56, allowingOneMiss: true))
        XCTAssertTrue(hold.isHolding)
        XCTAssertTrue(hold.consume(matches: true, at: 0.9, allowingOneMiss: true))
        XCTAssertFalse(hold.consume(matches: true, at: 1.18, allowingOneMiss: true))

        hold = HandGestureHold()
        XCTAssertFalse(hold.consume(matches: true, at: 0, allowingOneMiss: true))
        XCTAssertFalse(hold.consume(matches: false, at: 0.28, allowingOneMiss: true))
        XCTAssertFalse(hold.consume(matches: false, at: 0.56, allowingOneMiss: true))
        XCTAssertFalse(hold.isHolding)
        XCTAssertFalse(hold.consume(matches: true, at: 0.9, allowingOneMiss: true))
    }

    func testSpeechClipSurvivesOldWindowBoundaryAndAnInternalPause() {
        var buffer = SpeechClipBuffer()
        XCTAssertTrue(buffer.consume(Array(repeating: 0, count: 61_000)).isEmpty)
        let first = Array(repeating: Int16(600), count: 4_600)
        let pause = Array(repeating: Int16(0), count: 4_800)
        let last = Array(repeating: Int16(-700), count: 7_200)
        let utterance = first + pause + last
        // Irregular audio callbacks should not affect where the clip starts or ends.
        for start in stride(from: 0, to: utterance.count, by: 541) {
            XCTAssertTrue(buffer.consume(Array(utterance[start..<min(start + 541, utterance.count)])).isEmpty)
        }
        let clips = buffer.consume(Array(repeating: 0, count: 12_000))
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.filter { $0 != 0 }, first + last)
    }

    func testSpeechClipLimitsLongRunsAndDoesNotResubmitTheOverlapAlone() {
        var buffer = SpeechClipBuffer()
        let initial = buffer.consume(Array(repeating: 900, count: 128_000))
        XCTAssertEqual(initial.first?.count, 128_000)
        XCTAssertTrue(buffer.consume(Array(repeating: 0, count: 16_000)).isEmpty)
        XCTAssertTrue(buffer.consume([Int16.max] + Array(repeating: 0, count: 16_000)).isEmpty)
        XCTAssertEqual(buffer.consume(Array(repeating: 900, count: 3_200) + Array(repeating: 0, count: 12_000)).count, 1)
    }

    func testVoiceCancelRecognizesCompletedCommandBeforeFinalTranscript() {
        XCTAssertTrue(KeywordDetector.isCancelCommand("I need help. Guardian, cancel.", isFinal: false, confidence: 0))
        XCTAssertTrue(KeywordDetector.isCancelCommand("Guardian, I’m okay.", isFinal: true, confidence: 0.9))
        XCTAssertFalse(KeywordDetector.isCancelCommand("Tap I'm okay on your phone to cancel.", isFinal: true, confidence: 0.9))
        XCTAssertFalse(KeywordDetector.isCancelCommand("Guardian", isFinal: false, confidence: 0))
        XCTAssertFalse(KeywordDetector.isCancelCommand("Guardian cancel", isFinal: true, confidence: 0.1))
    }

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
        XCTAssertEqual(KeywordDetector.intent("I’m in danger.",isFinal: true,confidence: -1),.distress)
        XCTAssertEqual(KeywordDetector.intent("I am not safe.",isFinal: false,confidence: 0),.distress)
        XCTAssertEqual(KeywordDetector.intent("Call an ambulance!",isFinal: true,confidence: 0.9),.distress)
        XCTAssertNil(KeywordDetector.intent("I’m not in danger.",isFinal: true,confidence: 0.9))
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
    func testLocalIncidentRecordingRequiresCameraConsentButNotCloudConsent() {
        var gate = PrivacyGate(), consent = Consent()
        gate.arm(consent: consent, now: 0)
        XCTAssertNil(gate.beginCapture(now: 1, localOnly: true))
        consent.capture = true
        gate.arm(consent: consent, now: 2)
        XCTAssertNil(gate.beginCapture(now: 3))
        let token = gate.beginCapture(now: 3, localOnly: true)
        XCTAssertNotNil(token)
        if let token { XCTAssertTrue(gate.accepts(token, now: 4)) }
        XCTAssertNil(gate.beginCapture(now: 4, localOnly: true))
    }
    func testWAVRoundTripBoundsAndMalformedFiles() throws {
        let samples: [Int16] = (0..<3200).map { Int16($0-1600) }; XCTAssertEqual(try PCM16WAV.decode(PCM16WAV.encode(samples)),samples)
        XCTAssertEqual(try PCM16WAV.decode(PCM16WAV.encode(Array(repeating:1,count:140000))).count,128000)
        let recording = Array(repeating: Int16(1), count: 160_000)
        let wav = PCM16WAV.encode(recording, maximumSamples: recording.count)
        XCTAssertEqual(wav.count, 44 + recording.count * MemoryLayout<Int16>.size)
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
    func testLateCaptureTimerDoesNotExtendMotionEvidence() throws {
        var recorder = MotionRecorder()
        for p in timeline(98,111,{ pose($0,0,g: $0 > 108 ? 10 : 1) }) { recorder.append(p) }
        let summary = try XCTUnwrap(recorder.summary(triggerAt:100,endAt:111))
        XCTAssertLessThanOrEqual(summary.coveredToMs,8000)
        XCTAssertEqual(summary.peakImpactG,1)
        XCTAssertLessThanOrEqual(summary.stillSecondsAtEnd,11)
        XCTAssertNil(recorder.summary(triggerAt:.nan,endAt:111))
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
