"""Exercise privacy defaults, synthetic trigger capture, deadline, and background cleanup.

Emulator-only. No real glasses, camera/microphone input, or AI request is used.
Run after assembleDebug with ANDROID_HOME set or adb on PATH.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', default='emulator-5554')
    parser.add_argument('--deadline-only', action='store_true', help='Run only the bounded-capture case')
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.serial):
        parser.error('Only disposable emulator serials are supported.')
    root = Path(__file__).resolve().parents[1]
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    executable = shutil.which('adb') or (str(Path(sdk)/'platform-tools/adb') if sdk else 'adb')
    base = [executable, '-s', args.serial]

    def adb(*values):
        return subprocess.run(base+list(values),capture_output=True,text=True,check=True).stdout

    width,height=map(int,re.findall(r'(\d+)x(\d+)',adb('shell','wm','size'))[-1])

    def snapshot():
        adb('shell','uiautomator','dump','/sdcard/trigger-window.xml')
        return ET.fromstring(adb('shell','cat','/sdcard/trigger-window.xml'))

    def swipe(up=True):
        # Small, slow steps do not fling past controls between hierarchy snapshots.
        a,b=(.7,.45) if up else (.25,.8)
        adb('shell','input','swipe',str(width//2),str(int(height*a)),str(width//2),str(int(height*b)),'500' if up else '150')

    def top():
        for _ in range(5):swipe(False)

    def find(text, scroll=True):
        for _ in range(12 if scroll else 4):
            matches=[n for n in snapshot().iter('node') if text in n.get('text','')]
            if matches:return matches[0]
            if scroll:swipe()
            else:time.sleep(.2)
        raise AssertionError(f'Missing UI text: {text}')

    def tap(text):
        node=find(text)
        left,y,right,bottom=map(int,re.findall(r'\d+',node.get('bounds')))
        adb('shell','input','tap',str((left+right)//2),str((y+bottom)//2))

    def launch():
        adb('shell','am','force-stop','com.rayguardian.app')
        adb('shell','am','start','-W','-n','com.rayguardian.app/.MainActivity','--ez','ray_guardian_simulator','true')
        find('Simulated registration active',scroll=False)

    adb('install','-r',str(root/'app/build/outputs/apk/debug/app-debug.apk'))
    if not args.deadline_only:
        launch()
        camera=find('Allow up to 8 seconds')
        assert camera.get('checked')=='false'
        cloud=find('I agree to automatically send')
        assert cloud.get('checked')=='false'
        assert cloud.get('enabled')=='false'
        top();tap('Start rehearsal');tap('Simulate SOS')
        find('Simulated alert created',scroll=False)
        find('Frames in capture buffer: 0')
        print('Defaults keep camera and cloud off, while SOS still works.',flush=True)

        launch()
        tap('Allow up to 8 seconds')
        tap('Enable simulated SOS phrase')
        tap('Enable simulated loud-voice hint')
        top();tap('Start rehearsal')
        tap('Replay loud voices')
        top();find('Rehearsal active')
        find('Loud-voice hint only; camera remains off')
        print('Loud voices alone do not trigger capture or an incident.',flush=True)

        tap('Replay SOS phrase')
        time.sleep(1.3)  # Allow a synthetic frame callback before foreground teardown.
        adb('shell','input','keyevent','KEYCODE_HOME')
        adb('shell','am','start','-W','-n','com.rayguardian.app/.MainActivity')
        top();find('Simulated alert created')
        find('DISARMED')
        find('Frames in capture buffer: 0')
        print('Voice replay follows SOS; leaving the foreground disarms and clears context.',flush=True)

    launch()
    tap('Allow up to 8 seconds')
    assert find('Allow up to 8 seconds').get('checked')=='true', 'Capture setting did not turn on'
    top();tap('Start rehearsal');tap('Simulate SOS')
    print('After SOS:',find('Context:').get('text'),flush=True)
    # Do not spend the short capture window scrolling to a transient status label.
    time.sleep(9)
    find('Camera off; frames discarded locally, no cloud submission')
    find('Frames in capture buffer: 0')
    print('Synthetic capture stops on its deadline and clears frames without cloud consent.',flush=True)
    print('Trigger privacy smoke test passed.',flush=True)


if __name__=='__main__':main()
