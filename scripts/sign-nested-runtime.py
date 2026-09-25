#!/usr/bin/env python3
"""Sign every copied native runtime object before sealing the outer app."""
import pathlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
identity = sys.argv[2]
magic = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
resources = app / 'Contents' / 'Resources'
signed = 0
for candidate in sorted(resources.rglob('*'), key=lambda p: len(p.parts), reverse=True):
    if candidate.is_symlink() or not candidate.is_file():
        continue
    with candidate.open('rb') as stream:
        native = stream.read(4) in magic
    if not native:
        continue
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp',
                    '--sign', identity, str(candidate)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(candidate)], check=True)
    signed += 1
print('Signed and verified %d nested native runtime objects.' % signed)
