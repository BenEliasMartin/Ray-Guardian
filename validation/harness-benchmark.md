# Ray Guardian harness benchmark

Measured on 15 November 2026 using Nemotron 3.5 Super VL on Verda. The comparison uses the same model and endpoint for all cloud requests. A plain Nemotron request uses a short task prompt and returns one decision. This run has no measurements for GPT-6 Astra or Google Project Astra.

## Speech cues

Both paths received the same 16 synthetic English transcripts, eight labeled as warranting a check-in and eight labeled as ordinary, quoted, or hypothetical speech. Labels were set before inference. Guardian ran the actual Swift `KeywordDetector` in a release build. The baseline sent each transcript as one text request to Nemotron.

| Metric | Guardian local cue | Direct Nemotron |
| --- | ---: | ---: |
| Median time from transcript to decision | 0.045 ms | 130 ms |
| Correct decisions | 11/16 | 15/16 |
| Distress cues caught | 5/8 | 7/8 |
| False check-ins on negative examples | 2/8 | 0/8 |

Across the five genuine cues both paths caught, the median was **0.028 ms** locally and **121 ms** for direct Nemotron. For each transcript, the local measurement is the median of 100 timed calls after warm-up. The cloud time includes the network request and completed response. These timings start with an available transcript and exclude speech recognition, audio playback, backend incident creation, and the time to show the check-in.

The local matcher missed “Please don’t rob me,” a report of being locked in, and an indirect report of chest distress. It also triggered on a quoted threat and a hypothetical ambulance request. Direct Nemotron missed “Please don’t rob me.”

## Visual assessment

We used the first three fall and first three non-fall videos from the frozen EGOFALLS test split in the repository manifest. Both paths received the same six chronological JPEGs per clip. Guardian used the production prompt, timestamps, replay source, a manual trigger, and the app's check-in gate. The baseline received the frames in order and a short fall-classification prompt. The benchmark omitted audio and motion telemetry. Timing starts with frames already extracted.

| Metric | Guardian assessment | Direct Nemotron |
| --- | ---: | ---: |
| Median request to result | 629 ms | 171 ms |
| Correct decisions | 2/6 | 1/6 |
| Staged falls caught | 0/3 | 1/3 |
| False alarms on ordinary clips | 1/3 | 3/3 |
| Uncertain results | 2/6 | 2/6 |

Guardian produced fewer false alarms and missed all three staged falls. The paths made different tradeoffs on this set. The six clips came from one test participant, and the reference labels describe the full clips. The sampled frames can contain limited evidence of the event. Uncertain results stay in the denominator. This comparison does not establish real-world detection accuracy, assault detection, or end-to-end response time. [Dataset and protocol](README.md)

## Reproduce

Use Node 22.13+, Swift, and FFmpeg. Download the checksum-verified replay sources using the [dataset instructions](README.md). The runner selects only six clips and checks their hashes against the repository manifest. Set `VERDA_INFERENCE_KEY` in the ignored root `.env`.

```sh
node --env-file=.env scripts/benchmark_harness.mjs
```

Pass `--ffmpeg /path/to/ffmpeg` for an executable outside `PATH` or `--clips-dir /path/to/clips` for a separate replay directory. The runner writes case-level decisions, latencies, model responses, and aggregate counts to `validation/results/harness-benchmark.json`. Reruns use inference credits. [Benchmark runner](../scripts/benchmark_harness.mjs) · [Swift timing code](../scripts/benchmark_speech.swift)
