"""Live, synthetic-text AI smoke test. Requires the local backend and a configured debug APK.

This performs one real provider request and may incur inference charges.
Run: python3 scripts/smoke_ai_emulator.py --serial emulator-5554 --live
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--serial', default='emulator-5554')
parser.add_argument('--live', action='store_true', help='Permit one real synthetic-text inference request.')
args = parser.parse_args()
if not args.live:
    parser.error('--live is required; this test makes a real inference request.')
if not re.fullmatch(r'emulator-\d+', args.serial):
    parser.error('Only emulator serials are supported.')
sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
adb_path = shutil.which('adb') or (str(Path(sdk) / 'platform-tools/adb') if sdk else 'adb')
base = [adb_path, '-s', args.serial]
root = Path(__file__).resolve().parents[1]

def adb(*arguments):
    return subprocess.run(base + list(arguments), check=True, capture_output=True, text=True, timeout=30).stdout

def find(text, scroll=False, attempts=10):
    for _ in range(attempts):
        adb('shell', 'uiautomator', 'dump', '/sdcard/ray-ai-window.xml')
        tree = ET.fromstring(adb('shell', 'cat', '/sdcard/ray-ai-window.xml'))
        for node in tree.iter('node'):
            if text in node.attrib.get('text', ''):
                return node
        if scroll:
            adb('shell', 'input', 'swipe', '500', '2000', '500', '800', '300')
        else:
            time.sleep(.3)
    raise AssertionError(f'Missing UI text: {text}')

def tap(text, scroll=True):
    node = find(text, scroll)
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.attrib['bounds']))
    adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))

adb('install', '-r', str(root / 'app/build/outputs/apk/debug/app-debug.apk'))
adb('shell', 'am', 'force-stop', 'com.rayguardian.app')
adb('shell', 'am', 'start', '-n', 'com.rayguardian.app/.MainActivity')
tap('Open Nemotron context')
find('NEMOTRON  /  AI CONTEXT')
tap('Analyze with Nemotron')
find('Confirm consent', scroll=True)
for _ in range(2):
    adb('shell', 'input', 'swipe', '500', '600', '500', '2000', '300')
tap('I agree to send')
tap('Analyze with Nemotron')
find('AI-GENERATED CONTEXT', scroll=True, attempts=16)
find('UNCERTAINTIES', scroll=True)
print('Live Android AI smoke test passed: consent enforced, Nemotron result displayed, uncertainties present.', flush=True)
