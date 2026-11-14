#!/usr/bin/env python3
"""Fetch ONE checksum-verified CC0 development clip for native MockDeviceKit CI.
No provider calls; does not change the frozen validation manifest.
"""
import json
from pathlib import Path
import sys
import prepare_pov_validation as source
import prepare_demo_media as media
root = Path(__file__).resolve().parents[1]
row = next(json.loads(line) for line in (root/'validation/manifest.jsonl').read_text().splitlines() if json.loads(line)['split']=='development')
source.load_manifest = lambda: [row]
source.write_manifest = lambda rows: None
source.download(32)
sys.argv = ['prepare_demo_media.py','--limit','1']
media.main()
