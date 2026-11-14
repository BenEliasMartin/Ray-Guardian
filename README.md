# Ray Guardian

An iOS companion and authenticated demo backend for Meta glasses. Local indicators open a short capture window; real images and audio go through ElevenLabs transcription and Nemotron assessment. A possible incident starts a check-in, then genuine ElevenLabs demo dispatch audio or an allowlisted Twilio test call.

The implementation supports real DAT streams and actual MockDeviceKit video, motion and speech events. It is a foreground demonstration, with optional server continuation of an existing incident. Detection accuracy and emergency readiness have not been established. It does not call emergency services.

## Run the backend

Use Node 22.13+ (Node 24 recommended). No npm dependencies are required.

```sh
node scripts/bootstrap.mjs
# Fill VERDA_INFERENCE_KEY and ELEVENLABS_API_KEY in the ignored .env.
npm --prefix server start
```

Bootstrap generates the client token, encryption key and media signing secret without printing them. Existing configuration is preserved. Run `node scripts/doctor.mjs --require-ready` to check missing external settings. Provider keys remain on the server.

For a physical iPhone, use HTTPS or a reachable LAN host. Set `HOST=0.0.0.0` in `.env` and enter the host's LAN URL in the companion. `127.0.0.1` works for the iOS Simulator on the same Mac. Local HTTP is intended for development; HTTPS is required for remote endpoints.

### Host the full backend on Verda

Run the Node API, encrypted incident database, and HTTPS gateway on an always-on Verda CPU instance. Your phone connects directly to that instance over HTTPS. The API calls Verda Nemotron and optional voice and telephony providers from the server. [Verda instance setup](https://docs.verda.com/cpu-and-gpu-instances/set-up-a-gpu-instance/)

1. Provision an on-demand Verda CPU instance with a public IP, persistent disk, and SSH access. Point your API hostname at the public IP. Allow inbound TCP 80 and 443 for Caddy and restrict SSH access to administrators. Add the deployment public key in [deploy/verda/authorized_keys](deploy/verda/authorized_keys) as the instance's SSH key in the Verda console, or append it to `~/.ssh/authorized_keys` on the instance. Only the public key belongs in the repo; keep the private key with the administrator who deploys.
2. On the instance, install Docker with Compose v2.24.4 or later, clone this private repo, and run `node scripts/bootstrap.mjs` with Node 22.13+ to create the ignored `.env` and its secrets. Set `GUARDIAN_DOMAIN` in that file to the DNS hostname alone, for example `guardian.example.com`. The Compose override sets the matching HTTPS callback URL and exposes only the Caddy ports.
3. On the instance, run the following.

   ```sh
   docker compose -f compose.yml -f compose.verda.yml --profile https up --build -d
   ```

4. Confirm `https://guardian.example.com/health` from outside the instance, then enter the HTTPS base URL and `RAY_GUARDIAN_CLIENT_TOKEN` under **Settings → Advanced settings → Service connection**. Save and check the connection over cellular data to verify that it reaches the hosted API.
5. Add `VERDA_INFERENCE_KEY` to the instance's `.env` when the replacement key arrives. Keep the configured Nemotron model and URL unless Verda supplies different values. Add `ELEVENLABS_API_KEY` for transcription and voice. Re-run the Compose command to apply changes and run the credentialed smoke test below.

Keep the Docker volumes for SQLite and Caddy certificates on persistent storage and preserve `DATA_ENCRYPTION_KEY` across redeploys. The API can start before provider keys are available. If using server-hosted replay downloads, prepare or copy those media files onto the instance's replay directory.

## Run the iOS companion

The checked-in [Xcode project](ios/RayGuardian.xcodeproj) includes a shared RayGuardian scheme, native SwiftUI app, pinned Meta DAT **1.0.1**, and a standalone Swift core package. Requires **Xcode 26.4+, Swift 6.3+, iOS 17.2+** for the Meta binary SDK. The core alone builds with older supported Swift toolchains.

1. Open `ios/RayGuardian.xcodeproj`. Set the Apple development team in ignored `ios/Config/Local.xcconfig` (created by bootstrap). Configure Meta identifiers there when needed. The example shows all settings.
2. Select the **RayGuardian** scheme and **Debug**, resolve packages, and run on an iPhone or simulator. Debug includes the replay lab; real device connection needs supported paired glasses and Meta developer setup.
3. In **Settings → Advanced settings → Service connection**, enter the backend URL and client token. Grant camera, microphone, speech, or location permissions in **Settings → Pairing and permissions**. Use **Check glasses connection** before arming.
4. Debug starts in **Real glasses** with local iPhone speech, live preview, hand gestures, location sharing, and heart-rate detection enabled. Tap **Arm for 30 minutes**. Change the microphone and camera options in Settings.
5. In Debug, open **Settings → Advanced settings → Mock glasses** to rehearse. Choose the live iPhone rear camera or enable **Use video replay** and select prepared media. **Simulate spoken threat** and **Replay free-fall and impact samples** inject events through MockDeviceKit.
6. An accepted event or **Check scene now** opens a capture window of up to eight seconds when camera and cloud analysis are enabled. The Mock glasses screen reports the actual Nemotron result.
7. A qualifying result starts a check-in with at least 30 seconds to respond on real glasses and 15 seconds on Mock. Say ‘Guardian cancel’ or tap **I’m okay** to cancel. An unanswered check-in plays a repeating two-beep alert on the current audio output. **Activate SOS** starts that alert immediately. The iOS app creates sessions with telephone calls and background escalation disabled.

**Meta Ray-Ban Display:** Select the Display pair in **Settings → Glasses pair**. **Test glasses display** opens the status and controls screens without arming. When armed, pinch on the Meta Neural Band to open or return from controls, acknowledge a check-in, or silence an alert.

With `META_APP_ID=0`, the build omits all three Meta attestation keys for Developer Mode. Registered apps require the Meta app ID, client token and Apple team together; partial configuration fails the build.

For real glasses, select **Real glasses**, register through Meta AI, grant the permissions and enable the corresponding capabilities in your Meta project. Camera audio, motion and glasses speech are experimental capabilities. Selected **Glasses local speech** must actually reach its started state before arming succeeds; missing capability/permission or startup failure is shown explicitly. If unavailable, explicitly select **Phone local speech** with downloaded on-device English recognition. That choice uses the iPhone microphone, so test speech with the phone where you will carry it. There is no cloud standby recognition fallback.

Direct English distress reports such as **“I'm in danger,” “No, please don't,” “I'm not safe,” “I can't breathe,” “I've fallen,”** and requests for an ambulance start a check-in without a wake word. Straight/curly apostrophes and unpunctuated ASR forms are supported. A spoken request starts the check-in before optional capture; ordinary later images or an unavailable visual classifier do not erase it. Mock check-in prompts can play during capture; real-glasses cues wait for camera teardown and play before cloud inference finishes, with playback echo excluded from input. “Guardian cancel” and “Guardian SOS” still require final recognition; phone recognition finalizes settled utterances promptly. These English phrase rules are regression-tested cues, not a general natural-language understanding guarantee.

With **Phone local speech** selected, the microphone feeds on-device English recognition only during the explicitly armed foreground session. Standby audio is not saved or sent to cloud transcription. PCM conversion for cloud upload starts only inside an accepted event window. To keep the microphone off in standby, select **Manual and motion only**. Selecting Mock glasses speech uses injected events rather than the iPhone microphone. **Mock glasses → Simulate ‘No, please don’t’** exercises the same speech listener and check-in path without a live ASR dependency.

For physical phone-motion testing, enable **Use iPhone motion for Mock testing** before arming. This separate, explicit Mock-only source reads the iPhone accelerometer and starts a check-in on timed free-fall followed by impact. Its status and incident reason identify **phone motion**, not a confirmed wearer fall. It stops on disarm or leaving the foreground, and keeps a separate cooldown from glasses motion. The updated backend must be deployed to accept this new signal. The existing simulated free-fall/impact event remains available for repeatable testing without moving the phone.

### Screenless Meta glasses rehearsal

1. Pair the glasses with the iPhone and register Ray Guardian through Meta AI. Keep the glasses powered, unfolded, and worn.
2. In **Settings → Monitoring**, enable **Speak check-ins on glasses** and choose your local speech source. Select the glasses as the iPhone audio output. DAT pairing and Bluetooth audio routing are separate.
3. In **Settings → Advanced settings**, tap **Test spoken check-in** and **Test alert tone**. Verify that you hear both in the glasses.
4. Keep Ray Guardian foregrounded and the iPhone unlocked. Arm and say **“I’m in danger.”** After the cue, say **“Guardian cancel.”** Local speech uses Apple or the glasses speech service. ElevenLabs transcribes consented incident audio after capture.
5. Repeat after a triggered capture. When continuous preview is off, the app gives the camera up to two seconds to stop before starting the cue. Check that speech, cancellation, and disconnect behavior work on your pair.

The optional Bluetooth heart-rate setup connects to standard Heart Rate Service sensors. Three fresh elevated measurements spanning at least eight seconds can request an assessment; exercise and high heart rate alone never establish an incident. The threshold is configurable.

**Glasses hand gestures:** With **Recognize hand gestures** enabled, hold your whole hand in front of the camera for about one second. A **closed fist** requests a check-in and a **shaka** 🤙 (thumb and pinky extended) cancels an active incident and disarms Guardian. Apple Vision processes the live frames on the iPhone. Mock glasses can use the iPhone rear camera for the same gestures.

**Cloud capture is event-driven.** Local speech, a gesture, motion or heart rate, SOS, or **Check scene now** can open a consented capture window. With live preview and gesture recognition disabled, the real glasses camera stays off in standby. All event and manual captures share a 12-per-ten-minute budget. Battery impact and camera teardown require measurement on the target devices.

### Fall detection

The glasses IMU feeds a local candidate detector with three paths: free fall followed by an impact, a fast head-orientation change of about 55° or more together with an impact or fast rotation (gyroscope), and a large orientation change followed by 2.5 seconds of stillness (slow collapse). A candidate only requests a bounded assessment. After the server accepts an event window, the camera starts and frames are collected several times per second; up to six sharp frames within the eight-second window are sent. No pre-event camera buffer is retained. A privacy-safe motion summary (peak impact, minimum g, tilt, peak rotation, stillness, which path fired) accompanies the frames so Nemotron can recognize a fall from the change in viewpoint even when the impact itself happened between frames. Gyroscope units are assumed to be rad/s as reported by the Meta SDK; tune the thresholds in `ios/GuardianCore/Sources/GuardianCore/Motion.swift` after real-device trials.

## Prepare real replay media

Media stays local and is ignored by git. The committed index contains provenance and hashes only.

```sh
python3 -m venv validation/.venv
validation/.venv/bin/pip install -r validation/requirements.txt
# First checkout: download the existing 36-clip wearer-POV screening selection.
validation/.venv/bin/python scripts/prepare_pov_validation.py download
validation/.venv/bin/python scripts/prepare_demo_media.py
```

This produces twelve **development-only** EGOFALLS replays, six publisher fall labels and six ordinary-activity labels: HEVC MP4 video plus synchronized original mono 16 kHz PCM WAV. The middle eight seconds are kept at real-time speed; publisher full-clip labels need independent review after cropping. These are demonstrations, not held-out performance results.

Prepared files can be bundled by rebuilding the app, or served by the backend: **Fetch replay index → Download selected media**. The app can also import a compatible HEVC video and PCM WAV through Files. Raw phone/glasses incident captures are never written to this replay cache.

MockDeviceKit has a public video-feed API and speech/motion injection APIs, but no public deterministic PCM injection API. Replay WAV is therefore paced through the **same PCM processing and capture gate** as real incoming audio, with the source shown explicitly. It is not represented as SDK microphone output.

## Genuine demo phone calls

The default `DEMO_CALL_TRANSPORT=playback` plays actual ElevenLabs audio in the companion. It does not place a telephone call. For a real outbound demonstration call, configure these in `.env`:

```dotenv
DEMO_CALL_TRANSPORT=twilio
TWILIO_ACCOUNT_SID=AC...
TWILIO_AUTH_TOKEN=...
DEMO_CALL_FROM=+your_twilio_number
DEMO_CALL_TO=+your_test_phone
DEMO_CALL_ALLOWLIST=+your_test_phone
PUBLIC_BASE_URL=https://guardian.example.com
```

Use complete ordinary test-phone numbers; emergency/service short codes are rejected. The destination comes exclusively from server configuration and must match the allowlist. Trial-account verification and outbound country permissions must also be set in Twilio. Use a second phone for the destination if the companion is running on an iPhone.

Twilio plays genuine ElevenLabs audio via an expiring signed URL. Press **1** to acknowledge, **2** to repeat. Callback signatures and call identifiers are checked. Late callbacks cannot reverse cancellation or acknowledgment. If a dial response is lost, status becomes **unknown** and no automatic redial occurs. Cancellation is best effort once a phone has begun ringing, and the UI reports unconfirmed cancellation honestly.

For deployment, `docker compose up --build -d` starts the API with encrypted persistent metadata. For public HTTPS, set DNS and `GUARDIAN_DOMAIN`, then use `docker compose --profile https up --build -d`; set `PUBLIC_BASE_URL` to that exact root HTTPS address. Keep the encryption key across restarts. Only the configured private demonstration client is supported; this is not a public multi-user service.

## Privacy behavior

With live preview and hand gestures disabled, the real glasses camera is off in armed standby. Selected local speech and motion or heart-rate sensing can remain active while the app is foregrounded. Loudness alone does not trigger capture. An accepted event permits up to six compressed frames and eight seconds of optional cloud audio, with a ten-second interval and a maximum of twelve captures per ten minutes. Arming expires after thirty minutes.

Leaving the app, locking the iPhone, changing consent, device removal or disconnection, thermal or battery faults, or losing the backend heartbeat disarms capture. Epoch guards reject queued old callbacks. Cancellation aborts in-flight inference and prevents later results from recreating an incident. **Keep the camera preview live** retains up to three seconds of frames in memory for approved capture or incident evidence. With cloud analysis off, camera frames stay on the iPhone.

Raw submitted frames, audio and STT text are not persisted by the API. When a capture is associated with an incident, the iPhone saves a short clip in protected app storage. **Settings → Privacy → Record sound in incident clips** adds audio from the selected capture microphone when available. This setting is separate from audio sharing for cloud analysis. If too few frames arrive or encoding fails, it saves the clearest available photo. Open **Incidents** to review it on the phone that saved it. The verification badge confirms that the file matches an incident-specific signature created on that iPhone. Recordings and encrypted incident metadata are available for up to 24 hours. Deleting the incident also deletes its local recording. Temporary synthesized speech is cached in memory for up to ten minutes. The OS, SDKs and network stack can hold copies; in-memory clearing is best effort. Verda, ElevenLabs and Twilio process data under the configured accounts' retention settings. ElevenLabs zero-retention mode requires the account entitlement; setting a flag does not itself provide that entitlement. SDK analytics and SDK crash reporting are opted out in the iOS plist.

## Verification and live checks

```sh
node --test server/test/*.mjs
python3 -m unittest discover -s scripts -p 'test_*.py'
swift test --package-path ios/GuardianCore
# Works with Command Line Tools even when XCTest is unavailable:
swift run --package-path ios/GuardianCore GuardianCoreChecks
```

`GuardianCoreChecks --write-wav /tmp/guardian.wav` also exports a real Swift-encoded WAV for cross-language contract checks. CI builds the iOS Debug and Release targets, tests Swift/Node/Python and builds/lints the Android prototype. Regenerate the checked-in project after editing `ios/project.yml` using XcodeGen 2.46+: `xcodegen generate --spec ios/project.yml`.

The production detector can be evaluated against prepared replays without making calls:

```sh
# Pass --ffmpeg /path/to/ffmpeg if it is not on PATH. Default is a dry run.
node scripts/evaluate_guardian.mjs --audio
node --env-file=.env scripts/evaluate_guardian.mjs --live --audio
# Live full API path: authentic frames + original audio → STT → Nemotron → ElevenLabs.
node --env-file=.env scripts/smoke_guardian.mjs
# Also exercise the configured demo-call transport:
node --env-file=.env scripts/smoke_guardian.mjs --demo-call
```

A normal/uncertain result is reported faithfully; the smoke tool does not manufacture a positive incident. Live runs consume provider credits. Results and MP3 output are ignored under `validation/results/`. The original participant-separated 36-clip evaluation pipeline and its limitations remain in [validation](validation/README.md). The new replay evaluator is a component check, not proof of trigger recall, assault detection or emergency readiness.

See [implementation and API notes](docs/implementation.md) and [manual handoff](docs/manual-handoff.md). The Android companion under `app/` has bounded camera context and local trigger rehearsals. In a Debug build, select **Try simulated glasses** → **Open glasses POV feed** to replay a synthetic clip through Meta MockDeviceKit. You can select a local HEVC clip instead and freeze a frame for Nemotron analysis with separate consent. Previous research is preserved in the [research archive](docs/research-archive.md).

The Android synthetic video is also generated locally rather than committed. On macOS, run the following before building Debug; CI performs this step automatically and passes the generated asset to the Android build. Other build hosts can use a selected local HEVC video in the app.

```sh
swift scripts/generate_simulator_clip.swift app/src/debug/assets/simulator_path.mp4
./gradlew assembleDebug
```

## Existing browser demonstration

`npm --prefix web-simulator start` preserves the local browser rehearsal at `http://127.0.0.1:4173`. It uses the same root `.env` and the compatible summary API. `prepare_demo_media.py` also prepares its ignored `captures/browser-pov.mp4`; alternatively choose a local video in the page. Browser simulated-dispatch receipts remain a separate local rehearsal, not the iOS/Twilio incident workflow.

## Android capture signature preparation

The Android Keystore P-256 signer, one-time administrator key enrollment, server nonce, exact-byte verifier, encrypted original retention and incident-view status are prepared for the separately implemented MP4 recorder. The current recorder callback is **not connected yet** and no existing live flow generates seals. See [capture seal integration handoff](docs/capture-seal.md) for the three recorder-side calls, upload contract and acceptance tests. The UI/pitch claim is **“Signed by the capture app”**: the file matches what the enrolled app signed; compromised-phone footage injection before signing is outside this guarantee. SOS remains independent.
