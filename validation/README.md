# Wearer-POV screening data

`manifest.jsonl` contains 36 original EGOFALLS 1.1 neck-camera clips: 18 staged falls and 18 ordinary non-fall activities. `protocol.json` defines deterministic sampling, participant-separated development/validation/test splits, preparation and limitations. `catalog.json`, source audits and `review.csv` preserve provenance and review status. Media and result files are ignored by git.

```sh
python3 -m venv validation/.venv
validation/.venv/bin/pip install -r validation/requirements.txt
validation/.venv/bin/python scripts/prepare_pov_validation.py download
validation/.venv/bin/python scripts/prepare_pov_validation.py prepare
validation/.venv/bin/python scripts/prepare_pov_validation.py audit
node scripts/evaluate_pov.mjs --split validation
# Add --live with VERDA_INFERENCE_KEY loaded to perform real inference.
```

The original evaluator uses chronological whole-clip image montages and an isolated fall/nonfall/uncertain research prompt. It preserves errors, missing results and abstentions in denominators and reports uncertainty intervals. It is distinct from the current production detector. See `scripts/evaluate_guardian.mjs` and the [main runbook](../README.md) for production detector replay checks using individual frames and original audio.

Publisher full-clip labels are not independent human adjudication of the sampled/cropped input. Neck-mount/environment labels have source anomalies. The data does not validate assault detection, medical diagnosis, actual emergency severity, real glasses mounting, local trigger recall or dispatch readiness. Use development clips for demonstration/tuning; keep validation/test participants separate. No live model evaluation has been claimed simply because media preparation succeeds.
