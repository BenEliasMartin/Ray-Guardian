# Implemented flow

`GlassesAdapter` owns a DAT DeviceSession and separate standby/camera listener bags. Speech and motion attach only after `.started`; camera attaches only inside an accepted capture. `stopCapture()` invalidates its generation before clearing listeners and stopping the camera. Device-session generation separately rejects callbacks after disconnect/disarm. Mock feeds use the real SDK; model input contains neither fixture filenames nor reference labels.

`GuardianModel` enforces a monotonic local privacy epoch, finite arming and capture deadlines. It buffers at most six bounded JPEGs and 128,000 mono PCM samples, then stops capture before upload. Cloud STT/analysis is cancellable. Voice playback suppresses local ASR and microphone evidence to reduce self-triggering. Glasses stream audio and phone/replay PCM enter the same capture gate. Recorded demo files are fixtures, not a hidden pre-event recording buffer.

`server/guardian.mjs` controls sessions, observation idempotency, check-in deadlines, consent, cancellation and durable demo-call jobs. `detection.mjs` is the production Nemotron classifier; `nemotron.mjs` preserves the earlier advisory-summary API used by Android. Model output cannot select recipients or execute tools. Only medium/high wearer-involved fall/physical-struggle/distress results with observations start automatic check-in. Uncertain, low-confidence, ordinary and bystander-only results do not. Manual SOS is an independent deliberate action.

The SQLite store encrypts each metadata record with AES-256-GCM and record/owner-bound authenticated data. It does not store raw images, audio or STT transcripts. Stored model observations may quote reported speech. Session and incident records expire after 24 hours. A deterministic owner derives from the private client bearer token; all normal read/write routes are owner scoped. This is a private demo instance, not a tenant/user identity system.

Capture and incident budgets are persisted separately from session/history records, so rearming or deleting an incident cannot reset their ten-minute limits. Twilio demonstrations have a twenty-second ringing timeout and two-minute connected-call limit.

A ready outbox job is marked sending before the external dial. Restarted sending jobs become unknown, never automatically retried. Cancellation is recorded before provider cancellation. A dial that completes after cancellation is immediately cancelled using its returned SID. Deletion waits for an active dial task to settle before removing its metadata. Twilio callbacks use the configured public URL for signature verification, never an untrusted Host header. Signed media links expire in ten minutes. Callback order cannot undo terminal states.

## HTTP contract

All routes except health, signed Twilio callbacks and signed call audio require `Authorization: Bearer <client token>`. Native clients only; browser Origin requests are rejected. JSON bodies must be objects, at most 2 MiB. HTTP errors contain a stable `error` code and sanitized `message`; provider errors do not echo credentials or payloads.

| Method | Route | Behavior |
|---|---|---|
| GET | `/health` | Configuration flags, demo transport, readiness of keys; does not prove upstream availability |
| POST | `/v1/sessions` | Create demo session with independent consent booleans and input source |
| GET / DELETE | `/v1/sessions/:id` | Read or disarm/delete session |
| POST | `/v1/sessions/:id/arm` | Arm for fifteen minutes |
| POST | `/v1/sessions/:id/heartbeat` | Refresh foreground heartbeat; expires after thirty seconds |
| POST | `/v1/sessions/:id/disarm` | Stop observation; `cancelPending` defaults true |
| POST | `/v1/sessions/:id/triggers` | Submit signal; return permitted capture window and limits |
| POST | `/v1/sessions/:id/observations` | Submit bounded chronological frames, optional WAV/transcript; returns structured real detection |
| GET | `/v1/incidents` | Owner's retained incident metadata |
| GET / DELETE | `/v1/incidents/:id` | Read or cancel/delete incident |
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

Consent keys: `capture`, `cloud`, `audio`, `voice`, `demoCalls`, `location`, `backgroundEscalation`. All default false. Signals: `manual_sos`, `keyword_sos`, `keyword_distress`, `motion`, `heart_rate`, `loud_voice`. Loudness alone is rejected. The observation upload deadline is 28 seconds after the accepted trigger; the actual local capture deadline is eight seconds including startup. Up to two observations process concurrently. Capture windows are idempotent after completion; retry a lost upload response by polling the session before submitting again. Failed windows are not automatically resubmitted.

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

The host used for implementation has Apple Command Line Tools but no full Xcode/iOS SDK. Native app source can be parsed here; the standalone Swift core is compiled and run. Full native compile, simulator and hardware checks require Xcode 26.4+; the GitHub workflow provides those build jobs. A passing parse is not a native compile result.

No provider keys were present during development. Provider HTTP contracts and the complete workflow are exercised with mocked provider responses; live smoke/evaluation commands are supplied for the credentialed environment. Paid-provider success, real Bluetooth routing and hardware timing must be checked on that environment. No fixed detection outcome or readiness is asserted.

Glasses speech and camera audio are experimental in DAT 1.0.1 and require Meta capability availability; see [official speech documentation](https://github.com/meta/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/speech/SKILL.md) and [SDK repository](https://github.com/meta/meta-wearables-dat-ios/tree/1.0.1). Publishing to a production App Store channel depends on platform availability and approvals; a generated Release target does not grant those approvals.
