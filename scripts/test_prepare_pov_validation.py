import importlib.util
import io
from pathlib import Path
import struct
import unittest
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pov', Path(__file__).with_name('prepare_pov_validation.py'))
pov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pov)


class PreparationTests(unittest.TestCase):
    def test_zip_directory_preserves_offsets_without_downloading_payload(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('subject/Indoor/falls/Neck/one.mov', b'x'*100000)
            archive.writestr('subject/Indoor/nonfalls/Neck/two.mov', b'y'*100000)
        data = buffer.getvalue()
        entries = pov.parse_index(data[-65536:], len(data))
        self.assertEqual(len(entries),2)
        for entry in entries:
            self.assertEqual(data[entry['header_offset']:entry['header_offset']+4],b'PK\x03\x04')

    def test_real_zip64_directory_and_split_archive_rejection(self):
        # Synthetic ZIP64 ending with a member offset above 4 GiB.
        filename=b'one.mov'
        header=struct.pack('<4s6H3I5H2I', b'PK\x01\x02',45,45,0,0,0,0,123,100,100,len(filename),0,0,0,0,0,42)
        central=header+filename
        cd_offset=2**32+100
        offset64=cd_offset+len(central)
        tail=central+struct.pack('<4sQ2H2I4Q',b'PK\x06\x06',44,45,45,0,0,1,1,len(central),cd_offset)
        tail+=struct.pack('<4sIQI',b'PK\x06\x07',0,offset64,1)
        tail+=struct.pack('<4s4H2IH',b'PK\x05\x06',0,0,1,1,len(central),0xffffffff,0)
        entries=pov.parse_index(tail,cd_offset+len(tail))
        self.assertEqual(entries[0]['header_offset'],42)
        changed=bytearray(tail)
        struct.pack_into('<H',changed,len(changed)-18,1)
        with self.assertRaisesRegex(ValueError,'Split'):
            pov.parse_index(changed,cd_offset+len(changed))

    def test_server_ignoring_ranges_is_rejected_before_read(self):
        class FullResponse:
            status=200
            headers={}
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,*args):raise AssertionError('Should not download full archive')
        with patch.object(pov.urllib.request,'urlopen',return_value=FullResponse()):
            with self.assertRaisesRegex(ValueError,'exact requested'):
                pov.RangeReader('https://example.com/archive.zip',10**10).get(0,100)

    def test_stratified_selection_is_stable_and_covers_each_category(self):
        rows=[{'path':f'{category}/{i}','scenario':category} for category in ('a','b','c') for i in range(4)]
        first=pov.stratified(rows,6)
        self.assertEqual(first,pov.stratified(list(reversed(rows)),6))
        self.assertEqual({r['scenario'] for r in first},{'a','b','c'})


if __name__=='__main__':unittest.main()
