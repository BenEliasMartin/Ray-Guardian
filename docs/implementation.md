# Implemented flow

`GlassesAdapter` owns a DAT DeviceSession and separate standby/camera listener bags. Speech and motion attach only after `.started`; the camera starts only for a server-accepted event window. `stopCapture()` invalidates its generation before clearing listeners and stopping the camera. Device-session generation separately rejects callbacks after disconnect/disarm. Mock camera feeds are configured only on accepted capture. Model input contains neither fixture filenames nor reference labels.

`GuardianModel` enforces a monotonic local privacy epoch, finite arming and capture deadlines. It holds up to forty candidate JPEGs inside the accepted eight-second window, selects at most six sharp chronological JPEGs, and buffers at most 128,000 mono PCM samples. Capture stops before upload. Motion summary samples after the eight-second boundary are excluded even if a timer resumes late. Cloud STT/analysis is cancellable. Voice playback suppresses local ASR and microphone evidence to reduce self-triggering. Glasses stream audio and phone/replay PCM enter the same capture gate. Recorded demo files are fixtures, not a hidden pre-event recording buffer. Arming never starts the camera or configures its Mock feed. `GlassesAdapter.startCapture()` is called only from an accepted event window. `PhoneAudio.captureEnabled` prevents standby PCM conversion/export. Mock and real camera streams are stopped at the eight-second deadline; no pre-event frames are accepted by the API. The heartbeat refreshes liveness only. `automaticSceneChecks` and `speechMonitoring` requests are rejected, and the client sends both as false. Manual scene checks require an explicit button press and share the event capture budget.

`KeywordDetector` recognizes direct first-person danger/injury reports, urgent help requests and spoken threats without a wake word. Refusal pleas such as “No, please don’t” also request a check-in; shouting volume is not required. Standby recognition is local and exists only during an explicitly armed foreground session. There is no periodic cloud transcription path. Phone ASR finalizes a settled utterance after 1.2 seconds so final-only cancellation/SOS does not wait for the 50-second recognition-session rotation; finalization, restarts and callbacks have epoch/playback guards. A shared speech corpus under `ios/GuardianCore/Tests/Fixtures` runs in both XCTest and `GuardianCoreChecks`, including contractions, missing punctuation, negations, mundane help and low-confidence/echo inputs.

`phoneMotionTesting: true` enables `motion_phone` only for `meta_mock` sessions. `PhoneMotion` reads gravity-inclusive accelerometer samples on a serial operation queue at 60 Hz, converts g to m/s² and passes them through a separate `FallCandidateDetector`. It starts only on explicit opt-in, stops with the session and rejects queued callbacks after its generation changes. This event creates a check-in with `detectedBy: phone_motion` and an unconfirmed-wearer-fall description. Glasses motion retains the existing assessment path.

Speech-triggered check-ins have `detectedBy: speech_trigger`. Their original reason survives subsequent ordinary visual results, and both the UI and dispatch script retain it. Assessment failure does not cancel an existing check-in. A consented Mock check-in prompt can play during capture/processing; real-glasses cues wait for camera teardown but not inference. Input suppression excludes playback audio. This does not bypass cancellation, foreground escalation confirmation, incident limits or demo-call/voice consent.

`server/guardian.mjs` controls sessions, observation idempotency, check-in deadlines, consent, cancellation and durable demo-call jobs. `detection.mjs` is the production Nemotron classifier; `nemotron.mjs` preserves the earlier advisory-summary API used by Android. Model output cannot select recipients or execute tools. Medium/high fall, physical-struggle, immediate-danger, and distress results with observations can start a check-in according to `shouldCheckIn`. Uncertain, low-confidence, ordinary and bystander-only assessments do not. Local recognized distress or direct threats can independently request a check-in, and intentional SOS can request escalation. Their trigger/source is recorded separately from Nemotron assessment; subsequent ordinary evidence does not silently cancel a wearer-requested check-in.

The SQLite store encrypts each metadata record with AES-256-GCM and record/owner-bound authenticated data. It does not store submitted AI frames, audio or STT transcripts. The explicit capture-seal upload is an exception: accepted original MP4 bytes are retained as an immutable AES-256-GCM encrypted BLOB with the exact signed receipt/signature for 24 hours; untrusted/mismatched uploads are discarded. See [capture seal handoff](capture-seal.md). Stored model observations may quote reported speech. Session and incident records expire after 24 hours. A deterministic owner derives from the private client bearer token; all normal read/write routes are owner scoped. This is a private demo instance, not a tenant/user identity system.

Capture and incident budgets are persisted separately from session/history records, so rearming or deleting an incident cannot reset their ten-minute limits. Twilio demonstrations have a twenty-second ringing timeout and two-minute connected-call limit.

Without background-escalation consent, an automatic check-in requires a fresh challenge round trip after its deadline before a call can queue; an old heartbeat cannot authorize escalation while the phone is suspended. Standby Apple on-device ASR transcripts remain local; matched indicators send a signal rather than the raw transcript. Triggered evidence transcription receives only its bounded PCM window.

A ready outbox job is marked sending before the external dial. Restarted sending jobs become unknown, never automatically retried. Cancellation is recorded before provider cancellation. A dial that completes after cancellation is immediately cancelled using its returned SID. Deletion waits for an active dial task to settle before removing its metadata. Twilio callbacks use the configured public URL for signature verification, never an untrusted Host header. Signed media links expire in ten minutes. Callback order cannot undo terminal states.

## HTTP contract

All routes except health, signed Twilio callbacks and signed call audio require `Authorization: Bearer <client token>`. Native clients only; browser Origin requests are rejected. JSON bodies must be objects, at most 2 MiB. HTTP errors contain a stable `error` code and sanitized `message`; provider errors do not echo credentials or payloads.

| Method | Route | Behavior |
|---|---|---|
| GET | `/health` | Configuration flags, demo transport, readiness of keys; does not prove upstream availability |
| POST | `/v1/sessions` | Create demo session with independent consent booleans and input source |
| GET / DELETE | `/v1/sessions/:id` | Read or disarm/delete session |
| POST | `/v1/sessions/:id/arm` | Arm for thirty minutes |
| POST | `/v1/sessions/:id/heartbeat` | Refresh foreground heartbeat; expires after thirty seconds |
| POST | `/v1/sessions/:id/disarm` | Stop observation; `cancelPending` defaults true |
| POST | `/v1/sessions/:id/triggers` | Submit signal; return permitted capture window and limits |

| POST | `/v1/sessions/:id/observations` | Submit bounded chronological frames, optional WAV/transcript; returns structured real detection |
| POST | `/v1/sessions/:id/speech` | Legacy route rejected with `event_trigger_required`; cloud audio requires an accepted event window |
| GET | `/v1/incidents` | Owner's retained incident metadata |
| GET / DELETE | `/v1/incidents/:id` | Read or cancel/delete incident |
| POST | `/v1/incidents/:id/escalate` | Confirm post-deadline foreground challenge when background escalation is disabled |
| POST | `/v1/incidents/:id/cancel` | Persist cancellation, abort inference, cancel provider call if known |
| POST | `/v1/incidents/:id/acknowledge` | Demo operator acknowledgment |
| POST | `/v1/incidents/:id/location` | Fresh consented latitude/longitude/accuracy/timestamp |
| POST | `/v1/voice/prompts` | Real ElevenLabs MP3 for a fixed purpose; requires incident or session voice consent |
| GET | `/v1/demo-calls/:id/audio` | Real ElevenLabs demo script, owner authenticated or expiring HMAC link |
| POST | `/v1/twilio/status/:id` | Signed Twilio form callback |
| POST | `/v1/twilio/ack/:id` | Signed DTMF callback; 1 acknowledges, 2 repeats |
| GET | `/v1/replays` | Prepared fixture index and provenance |
| GET | `/v1/replays/:id/video` or `/audio` | Authenticated local replay download; no arbitrary filesystem paths |
| POST | `/v1/analyze` | Backward-compatible advisory summary route |

Consent keys: `capture`, `cloud`, `audio`, `voice`, `demoCalls`, `location`, `backgroundEscalation`. All default false. Signals: `manual_sos`, `keyword_sos`, `keyword_distress`, `spoken_threat`, `motion`, `motion_phone`, `heart_rate`, `loud_voice`, `manual_check`. Loudness alone is rejected. The observation upload deadline is 28 seconds after the accepted trigger; the actual local capture deadline is eight seconds including startup. Up to two observations process concurrently. Capture windows are idempotent after completion; retry a lost upload response by polling the session before submitting again. Failed windows are not automatically resubmitted.

Observation JSON:

```json
{
  "windowId": "UUID from accepted trigger",
  "source": "meta_mock",
  "frames": [{"offsetMs": 1200, "imageDataUrl": "data:image/jpeg;base64,..."}],
  "audio": {"format": "wav_pcm_s16le_16000_mono", "base64": "...", "source": "Replay WAV"}
}
```

Audio must be complete RIFF PCM WAV, mono, 16 kHz, signed 16 bit, 100 ms–8 seconds. No media URLs are accepted for inference. The server verifies canonical base64, image signatures, frame ordering/count/size and WAV chunk layout. Scribe transcript replaces an optional supplied transcript when WAV is present. Nemotron sees chronological images, reported trigger, capture source and actual transcript; no scenario identifier or gold label.

## Known operational limits

The host used for implementation has Apple Command Line Tools but no full Xcode/iOS SDK. The standalone Swift core is compiled and run locally. The GitHub workflow uses full Xcode to build Debug for Simulator and Release for iPhone, then runs native UI tests against actual MockDeviceKit video, motion and speech. It downloads one checksum-verified development video at runtime; media is not embedded in git. The fixture server requires genuine camera JPEGs and WAV bytes, but labels its provider responses `test_fixture` and `test_fixture_stt`. This verifies media routing and cancellation, not live provider accuracy. Physical hardware checks remain necessary.

No provider keys were present during development. Provider HTTP contracts and the complete workflow are exercised with mocked provider responses; live smoke/evaluation commands are supplied for the credentialed environment. Paid-provider success, real Bluetooth routing and hardware timing must be checked on that environment. No fixed detection outcome or readiness is asserted.

Glasses speech and camera audio are experimental in DAT 1.0.1 and require Meta capability availability; see [official speech documentation](https://github.com/meta/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/speech/SKILL.md) and [SDK repository](https://github.com/meta/meta-wearables-dat-ios/tree/1.0.1). Publishing to a production App Store channel depends on platform availability and approvals; a generated Release target does not grant those approvals.

## Screenless audio behavior

Real-glasses arming requires voice consent and an active Bluetooth output, independently of DAT registration. `GuardianAudioRoute` enables A2DP without forcing the phone speaker. Explicit Phone local speech preserves the built-in microphone while allowing A2DP output. Setup exposes the system route picker, current output and an audible test; the route check cannot prove the intended glasses are audible.

Selected DAT speech must reach `.started` within five seconds. Missing permissions, unsupported speech, startup failures and runtime errors are surfaced; no silent phone/cloud fallback changes the selected input. Display and Neural Band setup remain optional and depend on `supportsDisplay()`.

For real glasses, spoken check-ins wait until bounded capture ends and Camera reports `.stopped` (up to a two-second teardown wait). They play before cloud inference completes. This avoids knowingly playing over a camera stream, which can silence Bluetooth audio ([Meta SDK issue #312](https://github.com/meta/meta-wearables-dat-ios/issues/312)); physical audibility remains unverified. The server uses at least thirty seconds for `meta_glasses` check-ins, preserving the eight-second evidence limit. The local `HandsFreePrompt` supplies spoken command instructions and honest queued, connected, failed, unknown, cancellation and acknowledgment cues. Unrecognized states do not invent success. Remote ElevenLabs prompts also explain spoken cancel/SOS.

`VoicePlayer.inputSuppressed` gates both recognizers and evidence input during AVAudioPlayer/system speech playback, plus a 350 ms tail. Completion callbacks verify the active player/utterance before releasing suppression. Real native builds, Bluetooth routing, camera teardown, command resumption and battery draw must be checked on the actual glasses/iPhone. Locking or leaving the app still stops local monitoring; the current integration is not a pocket-ready background safety monitor.
