# Ray Guardian Demo Studio

A local, glasses-free presentation in an isolated subfolder. No npm dependencies, external fonts, analytics, or remote assets. It does not change the iOS app, Android app, or production backend.

## Open the studio

```sh
npm --prefix demo-studio start
```

Open **http://127.0.0.1:4174**. Node 22.13+ is required. Rehearsal works without a backend or provider keys and uses no camera/microphone. Keep the server running during the presentation. `DEMO_STUDIO_PORT` overrides the local port.

## Guided experience

The entry screen asks you to pick one of three guided moments or **Test it out yourself**. Each selection starts a paced, single-scene rehearsal: the cue, Guardian’s response, and the outcome. The main stage contains no technical timeline, dashboards, or logs. Turn Sound on for the locally rendered voice clips and spoken prompts; no microphone is accessed in rehearsal. Expand enters browser fullscreen when supported.

The phone response adapts the earlier cinematic companion to the current app: the dark surface and lavender/purple palette come from the iPhone app, with modest corners, a plain system-font title, and a clear full-width action. The earlier layout, prominent countdown, and restrained progress remain. Short labels keep the surrounding presentation simple. The selected car/pulse illustrations remain, with the phone panel kept separate from the screenless glasses POV.

- **A voice in the dark:** a spoken threat opens a check-in before scene assessment. The selected C1 car appears with the response countdown.
- **An unexpected fall:** motion requests a brief capture and assessment, followed by a qualifying scripted result and the selected M2 pulse.
- **A moment of doubt:** a refusal plea opens a precautionary check-in, then the wearer cancels it.

Tap **I’m okay** during a check-in to cancel. **Pause**, **Restart**, and **Skip** provide presenter control without filling the stage with controls. **Moments** and **Try another moment** return to the chooser. Space pauses/continues and Right Arrow skips when focus is outside an interactive control. Leaving the page pauses the experience. Reduced Motion uses static artwork.

**How it works** opens the optional explanation, event timeline, and route to the source-labeled session record. **Back to the experience** returns to the paused scene. Export is available in the record. The previous ruled-grid concept is preserved under `experiments/field-score/` as source; it is not served at runtime.

## First-person films

The three guided moments use actual local H.264 video. The ordinary story has been removed from the running experience; its licensed source asset is retained. The fall retains the approved screenless presentation, with the pulse/countdown in its separate **Phone app** panel. The glasses overlay experiment is archived under `experiments/lens-concept/` and is not served.

- **Threat:** a real-time night-walk edit: looking between buildings, then a rain-soaked street. An offscreen fictional threat starts the early check-in; the car and countdown appear in the phone companion. Footage: [Mixkit night walk](https://mixkit.co/free-stock-video/walking-between-buildings-looking-up-at-night-40736/) under its Stock Video Free License, and [Sergei Skrynnik / Pexels rain scene](https://www.pexels.com/video/people-walking-in-city-at-night-during-rainfall-11839648/) under the Pexels License. The cut between shots is cinematic, not a continuous signed recording.
- **Fall:** the approved staged EGOFALLS 1.1 neck-camera development clip ([dataset](https://doi.org/10.34894/HO5GE3), CC0-1.0), preserving impact and the floor view. The check-in/result are scripted. It is wearable research footage, not Meta footage.
- **Cancellation:** an ordinary EGOFALLS courtyard walk, with fictional added dialogue: “No, please don’t,” the precautionary check-in, then “Guardian cancel.” Narration distinguishes the wearer’s cancellation from Guardian’s confirmation. The button also cancels at any point; no pending assessment reopens the incident. The original walk contains no distress event.

The POV stays visible when Guardian responds. Captions distinguish scene narration, fictional dialogue, the wearer, and glasses audio. The richer response lives in a separate phone panel; the screenless glasses have no HUD. The presentation film is separate from the capture app’s short, triggered recording, whose status is indicated above it. Every result here is scripted, not live inference.

Pause, restart, and skips synchronize each film with its story. Short wearable clips hold the final frame instead of looping an impact or repeating a walk. Reduced Motion holds the first frame while captions continue. Leaving the moment, hiding the tab, opening an explanation, or selecting live mode stops playback. Sound uses locally rendered Kokoro voice clips for Guardian, narration, and fictional dialogue. Voices keep their natural pitch, with space between dialogue turns. Ordinary capture/assessment transitions are silent. Browser speech synthesis is a fallback for a missing clip or an unexpected runtime message. No microphone is accessed. All films play offline once the local server starts.

Source metadata, edits, license links, and SHA-256 hashes are in `public/assets/pov-films.provenance.json`. Earlier corridor/rain artwork is retained as design source. No replay or artwork receives a trusted-capture signature.

## A two-minute presentation

1. Enable Sound, expand the browser, and choose **A voice in the dark**. Watch the cue turn into the car/check-in. Tap **I’m okay**.
2. Return to Moments and choose **An unexpected fall**. Use Skip to advance through capture and assessment; the pulse appears at check-in.
3. Show **A moment of doubt** for a scripted cancellation, then choose **Test it out yourself** to use your own input.
4. Open How it works only when you want to explain the pipeline or inspect the session record.

## Test it out yourself

The fourth row enters a minimal real-input experience. Choose the camera or a local video, consent to sending up to six compressed scene frames, and press **Start**. A manual request stands in for the glasses trigger. No scenario label or expected assessment is supplied to the model.

Optionally expand **Try a phrase** and type a phrase such as “I’m in danger”, “no please don’t”, or “I’ll kill you”. The adapter uses the existing port of the capture app’s local phrase matcher to select a cue. This is explicitly **typed input**, not speech recognition; no microphone is accessed or enabled. An unmatched phrase opens no capture. A cancellation phrase disarms the session. Raw typed dialogue is not submitted as cloud audio/transcript evidence.

An accepted server capture window allows one brief camera/file capture: six frames over roughly three seconds, bounded by the backend’s eight-second deadline. The camera stops before upload. A timer, Stop, leaving the view, and tab visibility changes also stop local media; a camera stream arriving after cancellation or window expiry is immediately stopped. A single run never continuously monitors or restarts capture.

Real incident state controls the response, artwork, and countdown, using the backend deadline and clock offset. A speech cue may begin the check-in before scene analysis. Analysis/camera failures do not silently dismiss that check-in. Actual state is polled while the page is active; the wearer can cancel. Unanswered check-ins reach the backend’s calls-disabled state; no dispatch is simulated as a real call. Completed checks disarm automatically. Closing a view cancels pending incidents, and inactive adapter sessions are cleaned up. A test has a ninety-second ceiling.

Start the existing backend separately (`npm --prefix server start`). The studio reads `RAY_GUARDIAN_CLIENT_TOKEN` from the root ignored `.env` and connects to `http://127.0.0.1:8787`; set `DEMO_BACKEND_URL` to use a deployed API. `VERDA_INFERENCE_KEY` must be configured on that backend for real scene assessments. The page distinguishes offline, missing client token, connected AI, and connected-with-AI-unavailable states. Local phrase matching and backend check-ins can work when scene AI is unavailable; model errors remain visible. There is no fallback to a scripted assessment.

Session source is fixed to `phone` or `file_replay`, never Meta hardware. Audio, voice-provider generation, location, demo calls, automatic scene checks, and cloud speech monitoring are forced off. Local voice clips play only when Sound is enabled; no live voice-provider generation is requested. Credentials are never served to the browser. Replays/browser media never receive the capture-app seal. The optional session record/export contains actual backend events and source labels, not the source media or typed dialogue.

`free-api.mjs`, `public/free.js`, and the local phrase matcher are now integrated. `public/pcm-worklet.js` remains unserved preparation; microphone capture is not part of this version. The earlier `/api/live/*` adapter is retained for existing contract tests but has no running UI.

## Honest presentation

- Rehearsal is visibly labeled **Scripted demo · No calls**. Film provenance is labeled; results are scripted and are not live inference.
- Car/pulse artwork does not assert a crime, measured vital sign, or responder dispatch. The pulse is explicitly illustrative.
- The real app is a foreground MVP. With preview and gestures disabled, its camera is off in standby; selected local speech/motion may remain active while armed. This studio does not imply background or continuous emergency monitoring.
- **Signed by the capture app** means that a file matches the enrolled app’s signature. The browser never issues that seal. Compromised-phone footage injection before signing is outside its guarantee.

## Voice assets

Fixed dialogue is in `public/voice-lines.js`. The 15 PCM WAV clips and their generation settings, durations, and hashes are in `public/assets/voice/`, including `provenance.json`. They were generated locally with [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) (Apache-2.0) through `kokoro-onnx` 0.6.1; they are synthetic demo voices. Models and Python dependencies stay outside the repository and are not needed to run the studio. `scripts/render-voices.py` documents regeneration. No visitor input is sent to a voice service. Pause, Stop, navigation, and tab hiding cancel playback; late audio failures cannot revive a stopped prompt.

## Verify

```sh
npm --prefix demo-studio test
```

Tests cover story timing, early speech check-in, cancellation, ordinary backend results, bounded uploads, isolation of studio sessions, origin checks, and forced call/audio opt-out. Browser QA should cover desktop/projector, phone widths, reduced motion, playback controls, each view, and backend-offline behavior. Live provider success requires a configured backend and playable evidence; integration tests use an injected provider fixture and do not establish detector accuracy.
