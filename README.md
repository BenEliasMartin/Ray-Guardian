<h1 align="center">Ray Guardian</h1>

<p align="center"><strong>When you can’t ask for help, your glasses can check on you.</strong></p>
<p align="center">A hands-free safety prototype for Meta Ray-Ban glasses and iPhone, built at Junction.</p>

<p align="center">
  <a href="https://86.38.182.91.compute.verda.run/demo/"><strong>▶ Open the web demo</strong></a>
  &nbsp;·&nbsp;
  <a href="docs/setup.md#run-the-ios-companion">Run on iPhone</a>
  &nbsp;·&nbsp;
  <a href="validation/nemotron-astra-benchmark.md">Read the benchmark</a>
</p>

<p align="center">
  <a href="#try-it">Try it</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#side-challenges">Side challenges</a> ·
  <a href="#benchmarks">Benchmarks</a> ·
  <a href="#local-development">Local development</a> ·
  <a href="#repository-guide">Repository guide</a>
</p>

---

## Try it

- **Watch a guided moment.** Open the web demo and choose a threat, a fall, or a check-in the wearer cancels. The guided scenes use rehearsal footage and scripted outcomes.
- **Test your own input.** Choose **Test it out yourself** for a one-shot camera or video assessment with live Nemotron. The browser asks for consent before sharing frames. It uses typed phrases for optional speech cues.
- **Try the iPhone app.** Run the SwiftUI companion in Xcode. Pair supported Meta glasses, use **This iPhone** mode, or rehearse with MockDeviceKit in Debug. [iPhone setup](docs/setup.md#run-the-ios-companion)

Ray Guardian is a foreground prototype. The browser demo never places calls. The native app can play a simulated dispatch, and the optional backend telephone test uses an allowlisted ordinary number. Emergency services are outside the prototype's scope.

## How it works

1. **Notice a cue.** On-device speech, motion, or another enabled signal can request a check. A recognized plea or threat can start the check-in before cloud assessment finishes.
2. **Capture context.** With consent, an accepted cue opens an event window of up to eight seconds. The companion can send up to six chronological frames, available motion context, and optional incident audio.
3. **Assess the scene.** The backend combines the frames and any available transcript. A qualifying assessment can start a check-in. Ambiguous evidence can produce an uncertain result.
4. **Ask and respond.** The wearer can cancel with **I’m okay** or an available voice or glasses control. An unanswered check-in can advance to the simulated response. The iPhone can save a short incident clip and check its integrity against a signature created on the phone.

With live preview and camera gestures off, the glasses camera stays off while waiting for a cue. The backend does not persist raw inference frames, audio, or transcripts. [Privacy and retention](docs/setup.md#privacy-behavior)

## Side challenges

| Challenge | What we used it for | Where to see it |
| --- | --- | --- |
| [NVIDIA Nemotron](#nvidia-nemotron) | Read the scene from a short sequence of frames, motion, and speech | Web demo → **Test it out yourself** |
| [ElevenLabs](#elevenlabs) | Transcribe what happened and speak the response | iPhone check-in and simulated dispatch |
| [OpenAI Codex](#openai-codex) | Drive work through Goal mode, test the app with browser and computer use, and run the model comparison | Demo Studio and the benchmark |

### NVIDIA Nemotron

We chose **Nemotron 3.5 Super VL on Verda** for a specific job. An incident can look ordinary in one frame, and a motion spike can happen during everyday activity. Nemotron can assess up to six chronological frames alongside the trigger, motion measurements, and the ElevenLabs transcript in one request. A text-only model could assess the transcript, while the vision-language model can also use changes in viewpoint to inform its assessment. Guardian applies its own check-in rules to the model’s structured result. [Assessment and check-in rules](server/detection.mjs)

**What stood out** was the combination of response time, selectable reasoning, and deployment options. Our Verda endpoint gave us a fast path with reasoning disabled and an experimental reasoning mode we could evaluate on ambiguous inputs. Compared with GPT-6 Astra through Codex CLI, reasoning-enabled Nemotron matched the speech score with a lower observed response time and caught more staged falls in our small visual screening. NVIDIA also publishes the model weights, giving us a path to serve it on our own GPU infrastructure if needed. [Benchmark](#benchmarks) · [NVIDIA model documentation](https://catalog.ngc.nvidia.com/orgs/nim/nvidia/models/nemotron-3.5-super-vl-120b-a12b/-?_lr=1)

### ElevenLabs

We used **Scribe v2** to transcribe short, consented incident audio so Nemotron can consider what was said alongside what the camera saw. We used **Eleven Multilingual v2** to turn check-ins and simulated dispatch briefings into spoken audio, including the incident summary and coordinates when available. The native app can also speak prompts on-device. The guided browser scenes use pre-rendered Kokoro clips so they can run without provider keys.

[ElevenLabs client](server/elevenlabs.mjs) · [Incident voice flow](server/guardian.mjs) · [Browser voice credits](demo-studio/README.md#voice-assets)

### OpenAI Codex

We used Codex across the SwiftUI companion, the Meta glasses integration, and the hosted demo. It helped us iterate on the incident flow from detection to check-in, cancellation, and simulated dispatch, and create the countdown and heartbeat animations for the pitch. [Alert animations](ios/RayGuardian/Views/IncidentAnimationView.swift)

- **Goal mode.** One teammate used Goal mode for work that spanned multiple steps, setting the outcome up front so Codex could carry the task through implementation and checks.
- **Browser and computer use.** We used computer use to work through setup and browser use to test the hosted demo as a judge would. We checked that it opened on Moments, played the scene, accepted a cancellation during the countdown, and returned a live Nemotron assessment from our own input. [Demo Studio](demo-studio/README.md) · [Browser tests](demo-studio/test/)
- **Codex CLI.** We ran GPT-6 Astra on the same labeled inputs as Nemotron and saved the prompts and case-level decisions so the comparison could be inspected. [Case-level results](validation/nemotron-astra-results.json)

## Benchmarks

On 16 synthetic speech cues, reasoning-enabled Nemotron and GPT-6 Astra each got **16/16**. Median response time was **315 ms** for Nemotron on Verda and **3.09 s** for Astra through Codex CLI, measured with the transcript already available. In the six-clip visual screening, reasoning-enabled Nemotron caught **3/3 staged falls** and flagged **2/3 ordinary movements**. Astra caught **0/3 staged falls** and abstained on four clips. Reasoning mode was experimental. Guardian’s scene detector uses reasoning disabled. [Model results and methodology](validation/nemotron-astra-benchmark.md)

A separate harness test compared Guardian’s own decision path with direct requests to the same Nemotron endpoint. Local speech cue matching was faster once text was available. In the six-clip visual test, the harness produced fewer false alarms and caught fewer falls. [Harness results and reproduction steps](validation/harness-benchmark.md)

## Local development

**Browser demo** · Node 22.13+ with no external npm dependencies.

```sh
npm --prefix demo-studio start
```

Open [localhost:4174](http://127.0.0.1:4174). The guided moments run without provider keys. The live test needs the backend and a configured Nemotron endpoint.

**Backend** · Generate local secrets, add provider keys to the ignored `.env`, and start the API.

```sh
node scripts/bootstrap.mjs
npm --prefix server start
```

Use `VERDA_INFERENCE_KEY` for scene assessment and `ELEVENLABS_API_KEY` for transcription and generated voice. A physical iPhone needs a reachable LAN address or remote HTTPS. [Backend setup and Verda deployment](docs/setup.md#run-the-backend) · [Configuration example](.env.example)

**Checks** · Run the browser and API suites locally.

```sh
npm --prefix demo-studio test
npm --prefix server test
```

See [native checks and live smoke tests](docs/setup.md#verification-and-live-checks) and the [evaluation protocol](validation/README.md) for replay preparation, provider checks, and known limits.

## Repository guide

| Path | What’s there |
| --- | --- |
| [`ios/`](ios/) | SwiftUI companion, Meta device integration, and shared Swift core |
| [`server/`](server/) | Node API, incident state, encrypted storage, and provider integrations |
| [`demo-studio/`](demo-studio/) | Guided browser demo, live camera and video test, and media provenance |
| [`app/`](app/) | Android prototype and MockDeviceKit rehearsal |
| [`web-simulator/`](web-simulator/) | Earlier local browser hazard rehearsal |
| [`validation/`](validation/) | Replay datasets, evaluation protocol, and limitations |

[Setup and testing](docs/setup.md) · [Implementation and API](docs/implementation.md) · [Device handoff](docs/manual-handoff.md) · [Android capture-seal handoff](docs/capture-seal.md)
