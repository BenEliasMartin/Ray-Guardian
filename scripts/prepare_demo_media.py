#!/usr/bin/env python3
"""Prepare ignored, actual wearer-POV HEVC video and synchronized PCM audio for iOS.
Uses DEVELOPMENT clips only. Never downloads or sends anything to an AI provider.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg')
    parser.add_argument('--limit', type=int, default=12)
    parser.add_argument('--output', type=Path, default=ROOT/'ios/RayGuardian/Resources/ReplayMedia')
    args = parser.parse_args()
    ffmpeg = args.ffmpeg or shutil.which('ffmpeg')
    if not ffmpeg:
        try:
            import imageio_ffmpeg
            ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
        except ImportError:
            parser.error('Install validation requirements or pass --ffmpeg /path/to/ffmpeg')
    rows = [json.loads(line) for line in (ROOT/'validation/manifest.jsonl').read_text().splitlines() if line]
    rows = [r for r in rows if r['split']=='development'][:args.limit]
    clips = []
    args.output.mkdir(parents=True, exist_ok=True)
    for index, row in enumerate(rows):
        raw = ROOT/row['raw_path']
        if not raw.is_file():
            parser.error('Raw clips missing: run scripts/prepare_pov_validation.py download first.')
        if hashlib.sha256(raw.read_bytes()).hexdigest() != row['raw_sha256']:
            parser.error(f'Raw clip checksum mismatch: {row["id"]}')
        # Preserve real-time playback; crop the middle 8s rather than speeding up the event.
        start = max(0, (row['duration_seconds']-8)/2)
        ident = 'replay-'+row['id']; video = ident+'.mp4'; audio = ident+'.wav'
        common = [ffmpeg,'-hide_banner','-loglevel','error','-y','-ss',str(start),'-i',str(raw),'-t','8']
        subprocess.run(common+['-map','0:v:0','-an','-vf','scale=640:-2,fps=15','-c:v','libx265','-preset','fast','-crf','27','-x265-params','log-level=error:pools=2:keyint=15:min-keyint=15:scenecut=0','-tag:v','hvc1','-pix_fmt','yuv420p','-movflags','+faststart',str(args.output/video)],check=True)
        probe = subprocess.run([ffmpeg,'-hide_banner','-i',str(raw)],capture_output=True,text=True)
        has_audio = 'Audio:' in probe.stderr
        if has_audio:
            subprocess.run(common+['-map','0:a:0','-vn','-ac','1','-ar','16000','-c:a','pcm_s16le',str(args.output/audio)],check=True)
        clips.append({'id':ident,'title':f'Wearer replay {index+1:02d}','video':video,'audio':audio if has_audio else None,
                      'expected':row['label'],'attribution':'EGOFALLS 1.1 · CC0-1.0 · doi:10.34894/HO5GE3',
                      'sourceId':row['id'],'sourceSplit':'development','startSeconds':start,'durationSeconds':min(8,row['duration_seconds']),
                      'labelScope':'Publisher full-clip activity label, unreviewed after cropping; demonstration only.',
                      'videoSHA256':hashlib.sha256((args.output/video).read_bytes()).hexdigest(),
                      'audioSHA256':hashlib.sha256((args.output/audio).read_bytes()).hexdigest() if has_audio else None})
        print(f'Prepared wearer replay {index+1:02d} (video + {"source audio" if has_audio else "no audio track"})')
    (args.output/'manifest.json').write_text(json.dumps({'version':1,'clips':clips},indent=2)+'\n')
    if rows:
        browser = ROOT/'captures/browser-pov.mp4'
        browser.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-y','-i',str(args.output/clips[0]['video']),'-an','-c:v','libx264','-preset','fast','-crf','26','-movflags','+faststart',str(browser)],check=True)
    print(f'{len(clips)} local replays ready. Media remains ignored by git.')
if __name__=='__main__': main()
