"""Render the fixed demo dialogue; models and Python packages stay outside the repo.

node --input-type=module -e "import {voiceLines} from './demo-studio/public/voice-lines.js'; process.stdout.write(JSON.stringify(voiceLines))" \
  | /path/to/venv/bin/python demo-studio/scripts/render-voices.py /path/to/models
Requires kokoro-onnx==0.6.1 and soundfile==0.13.1.
"""
import hashlib
import json
from pathlib import Path
import sys

import soundfile as sf
from kokoro_onnx import Kokoro

models = Path(sys.argv[1])
output = Path(__file__).resolve().parents[1] / 'public/assets/voice'
output.mkdir(parents=True, exist_ok=True)
kokoro = Kokoro(str(models / 'kokoro.onnx'), str(models / 'voices.bin'))
lines = json.load(sys.stdin)
for line in lines:
    samples, rate = kokoro.create(line['text'], voice=line['voice'], speed=line['speed'], lang='en-us')
    target = output / (line['id'] + '.wav')
    sf.write(target, samples, rate, subtype='PCM_16')
    line['durationSeconds'] = round(len(samples) / rate, 3)
    line['sha256'] = hashlib.sha256(target.read_bytes()).hexdigest()
    print(line['id'], line['durationSeconds'], flush=True)
provenance = {
    'generator': 'kokoro-onnx 0.6.1',
    'model': 'Kokoro-82M v1.0',
    'modelSource': 'https://huggingface.co/hexgrad/Kokoro-82M',
    'runtimeSource': 'https://github.com/thewh1teagle/kokoro-onnx',
    'modelLicense': 'Apache-2.0',
    'purpose': 'Synthetic fictional demo dialogue and app prompts. No real speaker impersonation.',
    'lines': lines,
}
(output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
