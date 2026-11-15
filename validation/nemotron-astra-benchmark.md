# Nemotron and GPT-6 Astra comparison

Measured on 15 November 2026 using 16 synthetic speech cues. The set contains eight distress or threat cues and eight ordinary, quoted, or hypothetical cues. Each model received the same classification instructions and transcript. Labels were fixed before the benchmark. [Case-level results and prompts](nemotron-astra-results.json)

| Configuration | Median response | Correct | Distress cues caught | False check-ins |
| --- | ---: | ---: | ---: | ---: |
| Nemotron with reasoning disabled, Verda API | 106 ms | 14/16 | 7/8 | 0/8 |
| Nemotron with reasoning enabled, Verda API | 315 ms | 16/16 | 8/8 | 0/8 |
| GPT-6 Astra at low reasoning, Codex CLI | 3.09 s | 16/16 | 8/8 | 0/8 |

Reasoning-enabled Nemotron matched Astra on these speech cues and returned a response in about one-tenth the median time through the tested interfaces. Nemotron with reasoning disabled was faster and missed “Please don’t rob me.” It also abstained on a report of past distress. Ray Guardian's scene detector uses the model with reasoning disabled. Reasoning-enabled Nemotron was an experimental benchmark configuration.

Verda timing starts when the HTTP request is issued and ends when the full response is read. Astra timing starts when Codex reports that the turn has begun and ends when the answer is delivered. The Astra measurement includes the Codex request path and excludes CLI startup. With startup, its speech median was 3.50 s. These are observed response times for the two interfaces. Both measurements start with text already available and exclude transcription, audio playback, and app check-in time.

[NVIDIA Nemotron model documentation](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16) · [GPT-6 Astra model documentation](https://developers.openai.com/api/docs/models/gpt-6-astra)

## Visual fall screening

Both models received the same six chronological frames per clip, with audio, motion telemetry, and source labels omitted. The clips were the first three staged falls and the first three ordinary movements in the EGOFALLS test split. Latency starts with images available. The visual requests ran in separate blocks. [Dataset manifest](manifest.jsonl)

| Configuration | Median response | Correct | Falls caught | False alarms |
| --- | ---: | ---: | ---: | ---: |
| Nemotron with reasoning disabled, Verda API | 177 ms | 1/6 | 1/3 | 3/3 |
| Nemotron with reasoning enabled, Verda API | 1.71 s | 4/6 | 3/3 | 2/3 |
| GPT-6 Astra at low reasoning, Codex CLI | 4.81 s | 1/6 | 0/3 | 1/3 |

Reasoning-enabled Nemotron caught all three staged falls and incorrectly flagged two ordinary movements. Astra abstained on four clips. All six clips came from one participant and use publisher labels for the full clips. These samples measure decision behavior on the supplied frames and leave real-world detection accuracy outside the scope of the test.
