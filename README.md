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

1. Provision an on-demand Verda CPU instance with a public IP, persistent disk, and SSH access. Point your API hostname at the public IP. Allow inbound TCP 80 and 443 for Caddy and restrict SSH access to administrators.
2. On the instance, install Docker with Compose v2.24.4 or later, clone this private repo, and run `node scripts/bootstrap.mjs` with Node 22.13+ to create the ignored `.env` and its secrets. Set `GUARDIAN_DOMAIN` in that file to the DNS hostname alone, for example `guardian.example.com`. The Compose override sets the matching HTTPS callback URL and exposes only the Caddy ports.
3. On the instance, run the following.

   ```sh
   docker compose -f compose.yml -f compose.verda.yml --profile https up --build -d
   ```

4. Confirm `https://guardian.example.com/health` from outside the instance, then enter the HTTPS base URL and `RAY_GUARDIAN_CLIENT_TOKEN` in the iPhone app's **Setup**. Open **Setup** on a phone using cellular data to verify that it reaches the hosted API.
5. Add `VERDA_INFERENCE_KEY` to the instance's `.env` when the replacement key arrives. Keep the configured Nemotron model and URL unless Verda supplies different values. Add `ELEVENLABS_API_KEY` for transcription and voice. Re-run the Compose command to apply changes and run the credentialed smoke test below.

Keep the Docker volumes for SQLite and Caddy certificates on persistent storage and preserve `DATA_ENCRYPTION_KEY` across redeploys. The API can start before provider keys are available. If using server-hosted replay downloads, prepare or copy those media files onto the instance's replay directory.

## Run the iOS companion

The checked-in [Xcode project](ios/RayGuardian.xcodeproj) includes a shared RayGuardian scheme, native SwiftUI app, pinned Meta DAT **1.0.1**, and a standalone Swift core package. Requires **Xcode 26.4+, Swift 6.3+, iOS 17.2+** for the Meta binary SDK. The core alone builds with older supported Swift toolchains.

1. Open `ios/RayGuardian.xcodeproj`. Set the Apple development team in ignored `ios/Config/Local.xcconfig` (created by bootstrap). Configure Meta identifiers there when needed. The example shows all settings.
2. Select the **RayGuardian** scheme and **Debug**, resolve packages, and run on an iPhone or simulator. Debug includes the replay lab; real device connection needs supported paired glasses and Meta developer setup.
3. In **Setup**, enter/check the backend URL and client token. Provider keys do not belong here. Grant glasses permissions through the explicit setup buttons; grant location before arming if using it.
4. Choose Mock glasses or Real glasses, local keyword source, and capture audio source. Every capture/cloud/audio/voice/demo-call consent starts off. Enable the choices needed for the rehearsal.
5. For MockDeviceKit, prepare/download replay media as below. Select a clip before arming. Choose **Replay WAV** for its original audio. Choose **Glasses local speech** to exercise injected Mock speech events.
6. Arm for 15 minutes. In **Replay lab**, inject ‘Guardian help me’ or replay the motion sequence. The SDK delivers those events to the same listeners as real glasses. The accepted indicator opens a maximum eight-second window. The monitoring screen reports the actual Nemotron result.
7. A qualifying result starts a 15-second check-in. ‘Guardian cancel’ or **I'm okay** cancels it. If demo escalation is enabled, an unanswered check-in advances to the configured demo transport. **SOS** is a deliberate request and can escalate before visual assessment; it is labeled separately from Nemotron detection.

With `META_APP_ID=0`, the build omits all three Meta attestation keys for Developer Mode. Registered apps require the Meta app ID, client token and Apple team together; partial configuration fails the build.

For real glasses, select **Real glasses**, register through Meta AI, grant the permissions and enable the required capabilities in your Meta project. Camera audio and glasses speech are experimental capabilities; Meta currently limits their publishing availability. If local glasses ASR is unavailable, explicitly select **Phone local speech**, which requires on-device English recognition. There is no cloud standby recognition fallback. Phone microphone selection explicitly uses the built-in mic.

The optional Bluetooth heart-rate setup connects to standard Heart Rate Service sensors. Three fresh elevated measurements spanning at least eight seconds can request an assessment; exercise and high heart rate alone never establish an incident. The threshold is configurable.

For hands-free visual assessment, enable **Automatically check the scene while armed** along with camera capture and cloud sharing. The iPhone requests its first check after a successful heartbeat and can request another after 65 seconds. Scene checks share the three-captures-per-ten-minutes budget with other signals. Nemotron can assess visible physical struggle and immediate threats to the wearer. Immediate danger requires high confidence and concrete observations before the server opens a check-in. Events between captures can be missed.

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

The camera is off in armed standby. Selected local speech recognition and motion/heart-rate sensing can remain active while the app is foregrounded. Loudness alone does not trigger capture. A successful trigger permits at most six compressed frames and eight seconds of optional audio, with a 60-second capture cooldown and three bursts per ten minutes. Arming expires after fifteen minutes.

Leaving the app, changing consent, device removal/disconnection, thermal/battery faults, or losing the backend heartbeat disarms capture. Epoch guards reject queued old callbacks. Cancellation aborts in-flight inference and prevents later results from recreating an incident. No pre-event video is retained. iOS background transitions do not provide continuous monitoring; optional background escalation only permits the server to continue an already-created demo incident.

Raw submitted frames, audio and STT text are not persisted by the API. Encrypted incident metadata expires after 24 hours and can be deleted in the app. Temporary synthesized speech is cached in memory for up to ten minutes. The OS, SDKs and network stack can hold copies; in-memory clearing is best effort. Verda, ElevenLabs and Twilio process data under the configured accounts' retention settings. ElevenLabs zero-retention mode requires the account entitlement; setting a flag does not itself provide that entitlement. SDK analytics and SDK crash reporting are opted out in the iOS plist.

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

See [implementation and API notes](docs/implementation.md) and [manual handoff](docs/manual-handoff.md). The earlier Android prototype remains buildable under `app/`; it has bounded camera context and local trigger rehearsals, but does not have iOS feature parity. Previous research is preserved in the [research archive](docs/research-archive.md).

## Existing browser demonstration

`npm --prefix web-simulator start` preserves the local browser rehearsal at `http://127.0.0.1:4173`. It uses the same root `.env` and the compatible summary API. `prepare_demo_media.py` also prepares its ignored `captures/browser-pov.mp4`; alternatively choose a local video in the page. A video is no longer stored in the repository. Browser simulated-dispatch receipts remain a separate local rehearsal, not the new iOS/Twilio incident workflow.
