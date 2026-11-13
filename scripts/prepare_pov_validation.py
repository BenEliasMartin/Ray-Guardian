#!/usr/bin/env python3
"""Collect a bounded, reproducible wearer-POV screening set from EGOFALLS.

No inference or paid requests. All media stays under ignored validation/data/.
Uses HTTP byte ranges to read individual members of large, single-volume ZIPs.
"""
import argparse
import binascii
from collections import Counter, defaultdict
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import urllib.request
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'validation'
API = 'https://dataverse.nl/api'
SUBJECTS = {'S_FI': 'development', 'S_HB': 'validation', 'S_L': 'test'}
DOI = 'doi:10.34894/HO5GE3'
SEED = 'ray-guardian-pov-v1'


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def load_manifest():
    return [json.loads(line) for line in (BASE / 'manifest.jsonl').read_text().splitlines() if line]


def write_manifest(rows):
    (BASE / 'manifest.jsonl').write_text(''.join(json.dumps(row, sort_keys=True) + '\n' for row in rows))


class RangeReader:
    def __init__(self, url, size):
        self.url, self.size = url, size
        self.transferred = 0

    def get(self, start, length):
        if start < 0 or length < 1 or start + length > self.size:
            raise ValueError('Invalid archive range')
        end = start + length - 1
        req = urllib.request.Request(self.url, headers={
            'User-Agent': 'RayGuardian-validation/0.1', 'Range': f'bytes={start}-{end}',
        })
        with urllib.request.urlopen(req, timeout=90) as response:
            # Never accidentally download a multi-GB archive if a host ignores Range.
            if response.status != 206 or response.headers.get('Content-Range') != f'bytes {start}-{end}/{self.size}':
                raise ValueError('Publisher did not honor the exact requested byte range')
            data = response.read(length + 1)
        if len(data) != length:
            raise ValueError('Truncated archive range')
        self.transferred += length
        return data


def parse_index(tail, archive_size):
    """Normalize the central directory for zipfile, retaining actual member offsets."""
    end = tail.rfind(b'PK\x05\x06')
    if end < 0:
        raise ValueError('ZIP end record missing')
    _, disk, cd_disk, _, count, cd_size, cd_offset, comment = struct.unpack_from('<4s4H2IH', tail, end)
    if disk or cd_disk:
        raise ValueError('Split ZIPs are deliberately unsupported; choose a single-volume subject')
    if count == 65535 or cd_size == 0xffffffff or cd_offset == 0xffffffff:
        locator = end - 20
        if tail[locator:locator + 4] != b'PK\x06\x07':
            raise ValueError('ZIP64 locator missing')
        _, disk64, offset64, disks = struct.unpack_from('<4sIQI', tail, locator)
        if disk64 or disks != 1:
            raise ValueError('Split ZIP64 archive unsupported')
        pos = offset64 - (archive_size - len(tail))
        record = struct.unpack_from('<4sQ2H2I4Q', tail, pos)
        count, cd_size, cd_offset = record[7:10]
    start = cd_offset - (archive_size - len(tail))
    if start < 0 or count >= 65535:
        raise ValueError('Central directory exceeds the bounded tail buffer')
    central = tail[start:start + cd_size]
    normalized = central + struct.pack('<4s4H2IH', b'PK\x05\x06', 0, 0, count, count, cd_size, 0, 0)
    with zipfile.ZipFile(io.BytesIO(normalized)) as archive:
        return [{'path': i.filename, 'size': i.file_size, 'compressed_size': i.compress_size,
                 'header_offset': i.header_offset, 'crc': i.CRC, 'method': i.compress_type,
                 'flags': i.flag_bits} for i in archive.infolist()]


def index_sources():
    metadata_path = BASE / 'sources/egofalls.json'
    if not metadata_path.exists():
        with urllib.request.urlopen(f'{API}/datasets/:persistentId/?persistentId={DOI}', timeout=45) as r:
            save(metadata_path, json.load(r))
    metadata = json.loads(metadata_path.read_text())['data']['latestVersion']
    if metadata['license']['name'] != 'CC0-1.0':
        raise ValueError('Dataset license changed; review before collection')
    for subject in SUBJECTS:
        destination = BASE / f'sources/{subject}-index.json'
        if destination.exists():
            continue
        file = next(f['dataFile'] for f in metadata['files'] if f['dataFile']['filename'] == subject + '.zip')
        reader = RangeReader(f"{API}/access/datafile/{file['id']}", file['filesize'])
        length = min(file['filesize'], 2 * 1024 * 1024)
        entries = parse_index(reader.get(file['filesize'] - length, length), file['filesize'])
        save(destination, {'subject': subject, 'file_id': file['id'], 'archive_size': file['filesize'],
                           'publisher_checksum': file['checksum'], 'entries': entries})
        print(f'Indexed {subject}: {len(entries)} entries', flush=True)


def ranked(items):
    return sorted(items, key=lambda x: hashlib.sha256((SEED + x['path']).encode()).hexdigest())


def stratified(items, count):
    groups = defaultdict(list)
    for item in ranked(items):
        groups[item['scenario']].append(item)
    chosen = []
    while groups and len(chosen) < count:
        for key in sorted(list(groups)):
            if len(chosen) == count:
                break
            chosen.append(groups[key].pop(0))
            if not groups[key]:
                del groups[key]
    if len(chosen) != count:
        raise ValueError(f'Insufficient unique clips: wanted {count}, found {len(chosen)}')
    return chosen


def plan(per_class):
    if (BASE / 'manifest.jsonl').exists():
        raise ValueError('Manifest already frozen. Use a new copy of the validation directory to revise sampling.')
    rows, seen = [], set()
    anomalies = []
    for subject, split in SUBJECTS.items():
        source = json.loads((BASE / f'sources/{subject}-index.json').read_text())
        duplicates = defaultdict(list)
        for entry in source['entries']:
            if entry['size']:
                duplicates[(entry['size'], entry['crc'])].append(entry['path'])
        anomalies.extend({'subject': subject, 'paths': paths, 'basis': 'same ZIP CRC32 and byte length; candidate duplicates'}
                         for paths in duplicates.values() if len(paths) > 1)
        candidates = defaultdict(list)
        for entry in source['entries']:
            parts = entry['path'].split('/')
            # Use the same reported environment and mount; publisher labels still need review.
            if len(parts) < 6 or parts[1] != 'Indoor' or parts[-2] != 'Neck' or Path(parts[-1]).suffix.lower() not in {'.mov', '.mp4', '.avi'}:
                continue
            fingerprint = (entry['size'], entry['crc'])
            if fingerprint in seen:
                continue
            seen.add(fingerprint)
            label = {'falls': 'fall', 'nonfalls': 'nonfall'}.get(parts[2])
            if label is None:
                raise ValueError(f'Unexpected class directory: {parts[2]}')
            candidates[label].append({**entry, 'scenario': parts[3]})
        for label in ('fall', 'nonfall'):
            for entry in stratified(candidates[label], per_class):
                sample_id = hashlib.sha256(entry['path'].encode()).hexdigest()[:16]
                rows.append({'id': sample_id, 'dataset': 'EGOFALLS', 'dataset_doi': DOI,
                             'dataset_version': '1.1', 'split': split, 'subject': subject,
                             'label': label, 'scenario': entry['scenario'], 'source_path': entry['path'],
                             'source_url': f"{API}/access/datafile/{source['file_id']}",
                             'file_id': source['file_id'], 'archive_size': source['archive_size'],
                             'entry': entry, 'camera_mount_reported': 'neck', 'perspective': 'wearer',
                             'environment_reported': 'indoor', 'environment_verified': False, 'license': 'CC0-1.0',
                             'label_scope': 'staged activity, not diagnosis or emergency severity',
                             'review_status': 'publisher_label_unreviewed',
                             'raw_path': f'validation/data/raw/{sample_id}{Path(entry["path"]).suffix.lower()}'})
    write_manifest(rows)
    save(BASE / 'source-audit.json', {'candidate_duplicate_groups': anomalies,
                                     'note': 'Neck/waist copies may have inconsistent source labels. Mount is publisher-reported; verify before glasses claims.'})
    print(json.dumps({'samples': len(rows), 'raw_bytes': sum(r['entry']['size'] for r in rows),
                      'by_split_class': dict(Counter(f"{r['split']}/{r['label']}" for r in rows))}, indent=2))


def download(max_mib):
    rows = load_manifest()
    total = sum(r['entry']['size'] for r in rows)
    if total > max_mib * 1024 * 1024:
        raise ValueError(f'Planned media is {total / 1024**2:.1f} MiB; exceeds --max-mib {max_mib}')
    for index, row in enumerate(rows):
        path, entry = ROOT / row['raw_path'], row['entry']
        if path.exists():
            data = path.read_bytes()
        else:
            reader = RangeReader(row['source_url'], row['archive_size'])
            header = reader.get(entry['header_offset'], 30)
            fields = struct.unpack('<4s5H3I2H', header)
            if fields[0] != b'PK\x03\x04' or fields[2] & 1 or fields[3] not in (0, 8):
                raise ValueError('Unsupported or encrypted member')
            offset = entry['header_offset'] + 30 + fields[-2] + fields[-1]
            compressed = reader.get(offset, entry['compressed_size'])
            data = compressed if fields[3] == 0 else zlib.decompress(compressed, -15)
        if len(data) != entry['size'] or binascii.crc32(data) != entry['crc']:
            raise ValueError(f'Publisher ZIP checksum mismatch for {row["id"]}')
        digest = hashlib.sha256(data).hexdigest()
        if row.get('raw_sha256') and row['raw_sha256'] != digest:
            raise ValueError('Frozen media hash changed')
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            temp = path.with_suffix('.part')
            temp.write_bytes(data)
            temp.replace(path)
        row['raw_sha256'] = digest
        write_manifest(rows)
        print(f'{index + 1}/{len(rows)} verified {row["id"]} ({len(data)/1024**2:.1f} MiB)', flush=True)


def prepare():
    from PIL import Image, ImageDraw, ImageOps
    import imageio_ffmpeg
    executable = imageio_ffmpeg.get_ffmpeg_exe()
    rows = load_manifest()
    for row in rows:
        raw = ROOT / row['raw_path']
        if hashlib.sha256(raw.read_bytes()).hexdigest() != row.get('raw_sha256'):
            raise ValueError('Run download/verification first')
        probe = subprocess.run([executable, '-hide_banner', '-i', str(raw)], capture_output=True, text=True)
        match = re.search(r'Duration: (\d+):(\d+):(\d+\.\d+)', probe.stderr)
        if not match:
            raise ValueError(f'Cannot read video duration: {row["id"]}')
        h, m, s = map(float, match.groups())
        duration = h * 3600 + m * 60 + s
        times = [duration * f for f in (0.05, 0.23, 0.41, 0.59, 0.77, 0.95)]
        image = Image.new('RGB', (768, 464), '#151515')
        draw = ImageDraw.Draw(image)
        frame_hashes = []
        for i, timestamp in enumerate(times):
            result = subprocess.run([executable, '-loglevel', 'error', '-ss', str(timestamp), '-i', str(raw),
                                     '-frames:v', '1', '-vf', 'scale=256:-2', '-f', 'image2pipe', '-vcodec', 'png', '-'],
                                    capture_output=True, check=True)
            frame = Image.open(io.BytesIO(result.stdout)).convert('RGB')
            frame_hashes.append(hashlib.sha256(frame.tobytes()).hexdigest())
            tile = ImageOps.contain(frame, (256, 208))
            x, y = (i % 3) * 256, (i // 3) * 232
            image.paste(tile, (x + (256-tile.width)//2, y + (208-tile.height)//2))
            draw.text((x + 8, y + 212), f'{i+1}  {timestamp:.2f}s', fill='white')
        relative = f'validation/data/prepared/{row["id"]}.jpg'
        target = ROOT / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target, quality=85, exif=b'')
        row.update({'image_path': relative, 'image_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                    'duration_seconds': duration, 'frame_timestamps_seconds': times,
                    'decoded_frame_sha256': frame_hashes, 'preparation': 'six uniform-time frames; ordered montage; visual-only',
                    'ffmpeg_version': imageio_ffmpeg.get_ffmpeg_version()})
        write_manifest(rows)
        print(f'Prepared {row["id"]}: {duration:.2f}s', flush=True)


def audit(prepared_only=False):
    rows = load_manifest()
    by_hash, by_subject = defaultdict(set), defaultdict(set)
    missing, duplicates, counts = [], [], Counter()
    for row in rows:
        counts[f'{row["split"]}/{row["label"]}'] += 1
        by_subject[row['subject']].add(row['split'])
        digest = row.get('raw_sha256')
        if digest:
            by_hash[digest].add(row['split'])
        for field in (('image_path',) if prepared_only else ('raw_path', 'image_path')):
            file = ROOT / row[field] if row.get(field) else None
            hash_field = 'raw_sha256' if field == 'raw_path' else 'image_sha256'
            if file is None or not file.exists() or hashlib.sha256(file.read_bytes()).hexdigest() != row.get(hash_field):
                missing.append({'id': row['id'], 'field': field})
    digests = [r.get('raw_sha256') for r in rows if r.get('raw_sha256')]
    duplicates = [digest for digest, n in Counter(digests).items() if n > 1]
    result = {'samples': len(rows), 'counts': dict(counts), 'missing_or_changed': missing,
              'verification_scope': 'prepared_images_only' if prepared_only else 'original_videos_and_prepared_images',
              'original_videos_verified_locally': not prepared_only,
              'duplicate_raw_hashes': duplicates,
              'cross_split_hash_leakage': [k for k, v in by_hash.items() if len(v)>1],
              'cross_split_subject_leakage': [k for k, v in by_subject.items() if len(v)>1],
              'reviewed_samples': sum(r['review_status'] != 'publisher_label_unreviewed' for r in rows),
              'total_source_clip_seconds': sum(r.get('duration_seconds', 0) for r in rows),
              'readiness': 'not_established',
              'limitations': ['Body-worn neck view, not glasses/head-mounted.',
                              'Staged falls are not clinically confirmed collapse.',
                              'No assault data included.', 'No model inference has been run by this data audit.',
                              'Sparse montage can miss an event; source video labels are not frame labels.',
                              'Public pretraining contamination cannot be excluded.',
                              'Participant separation does not establish environment/session separation.',
                              'Publisher Indoor directories include visually outdoor-looking clips; environment labels are unverified.']}
    destination = BASE / ('results/prepared-data-audit.json' if prepared_only else 'data-audit.json')
    save(destination, result)
    print(json.dumps(result, indent=2))
    if missing or duplicates or result['cross_split_hash_leakage'] or result['cross_split_subject_leakage']:
        raise ValueError('Data integrity audit failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['index', 'plan', 'download', 'prepare', 'audit'])
    parser.add_argument('--per-class', type=int, default=6)
    parser.add_argument('--max-mib', type=int, default=1200)
    parser.add_argument('--prepared-only', action='store_true', help='Audit locally prepared images without checking original videos')
    args = parser.parse_args()
    if args.per_class < 1:
        parser.error('--per-class must be positive')
    {'index': index_sources, 'plan': lambda: plan(args.per_class),
     'download': lambda: download(args.max_mib), 'prepare': prepare,
     'audit': lambda: audit(prepared_only=args.prepared_only)}[args.command]()


if __name__ == '__main__':
    main()
