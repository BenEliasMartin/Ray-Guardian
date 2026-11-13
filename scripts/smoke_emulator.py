"""Exercise the debug-only demo on a disposable Android emulator.

Run after assembleDebug: python3 scripts/smoke_emulator.py --serial emulator-5554
"""

import argparse
import os
import re
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--serial', default='emulator-5554')
args = parser.parse_args()
if not re.fullmatch(r'emulator-\d+', args.serial):
    parser.error('This smoke test only runs on an emulator serial, not a physical device.')
sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
ADB = shutil.which('adb') or (str(Path(sdk) / 'platform-tools' / 'adb') if sdk else 'adb')
BASE = [ADB, '-s', args.serial]
ROOT = Path(__file__).resolve().parents[1]

def adb(*args):
    return subprocess.run(BASE + list(args), check=True, capture_output=True, text=True).stdout

def snapshot():
    adb('shell', 'uiautomator', 'dump', '/sdcard/window.xml')
    return ET.fromstring(adb('shell', 'cat', '/sdcard/window.xml'))

def nodes_with(root, text):
    return [node for node in root.iter('node') if text in node.attrib.get('text', '')]

def find(text, attempts=8, scroll=False):
    for _ in range(attempts):
        root = snapshot()
        matches = nodes_with(root, text)
        if matches:
            return matches[0]
        if scroll:
            adb('shell', 'input', 'swipe', '500', '2050', '500', '900', '300')
        else:
            time.sleep(.4)
    raise AssertionError(f'Could not find {text!r}')

def tap(text, scroll=False):
    node = find(text, scroll=scroll)
    a, b, c, d = map(int, re.findall(r'\d+', node.attrib['bounds']))
    adb('shell', 'input', 'tap', str((a + c) // 2), str((b + d) // 2))

adb('install', '-r', str(ROOT / 'app/build/outputs/apk/debug/app-debug.apk'))
adb('shell', 'am', 'force-stop', 'com.rayguardian.app')
adb('shell', 'am', 'start', '-n', 'com.rayguardian.app/.MainActivity')
header = find('RAY GUARDIAN')
top = int(re.findall(r'\d+', header.attrib['bounds'])[1])
assert top >= 100, f'Header overlaps status bar at y={top}'
find('DEMO ONLY')
tap('Try simulated glasses')
find('Simulated registration active')
find('Simulated Ray-Ban')
tap('Start device session')
find('Device session: Started')
print('Mock glasses session started.', flush=True)
tap('Start rehearsal', scroll=True)
find('Rehearsal active')
tap('Replay a possible incident', scroll=True)
find('Are you okay?')
tap("I'm okay", scroll=True)
find('Rehearsal active')
print('Check-in cancelled.', flush=True)
tap('Simulate SOS', scroll=True)
find('Simulated alert created')
find('Example location: Helsinki', scroll=True)
tap('Simulate acknowledgment', scroll=True)
find('Acknowledgment simulated')
print('SOS and acknowledgment simulated.', flush=True)
tap('Finish rehearsal', scroll=True)
find('Ready to practice')
tap('Start rehearsal', scroll=True)
find('Rehearsal active')
adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
adb('shell', 'am', 'start', '-n', 'com.rayguardian.app/.MainActivity')
find('Ready to practice', scroll=True)
print('Emulator smoke test passed: mock DAT connection and session, check-in cancellation, simulated SOS and acknowledgment, and foreground-only reset.')
