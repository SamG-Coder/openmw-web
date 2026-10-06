"""Fetch versioned upstream sources for a clean local wasm64 build.

Archives and SHA-256 records stay in the ignored deps directory. Existing source
trees are retained; this command never resets local dependency patches.
"""
from pathlib import Path
import hashlib
import json
import tarfile
import urllib.request
import shutil

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'deps' / 'src'
CACHE = ROOT / 'deps' / 'downloads'
SOURCES = [
    ('osg', 'https://codeload.github.com/openscenegraph/OpenSceneGraph/tar.gz/refs/tags/OpenSceneGraph-3.6.5'),
    ('bullet3', 'https://codeload.github.com/bulletphysics/bullet3/tar.gz/refs/tags/3.25'),
    ('recast', 'https://codeload.github.com/recastnavigation/recastnavigation/tar.gz/refs/tags/v1.6.0'),
    ('mygui', 'https://codeload.github.com/MyGUI/mygui/tar.gz/refs/tags/MyGUI3.4.3'),
    ('lua-5.4.7', 'https://www.lua.org/ftp/lua-5.4.7.tar.gz'),
    ('lz4-1.10.0', 'https://codeload.github.com/lz4/lz4/tar.gz/refs/tags/v1.10.0'),
    ('ffmpeg-6.1.2', 'https://ffmpeg.org/releases/ffmpeg-6.1.2.tar.gz'),
    ('boost_1_85_0', 'https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.gz'),
]
SRC.mkdir(parents=True, exist_ok=True)
CACHE.mkdir(parents=True, exist_ok=True)
for name, url in SOURCES:
    target = SRC / name
    if target.exists():
        print(f'{name}: retaining existing source tree', flush=True)
        continue
    archive = CACHE / f'{name}.tar.gz'
    if not archive.exists():
        print(f'{name}: downloading {url}', flush=True)
        partial = archive.with_suffix('.partial')
        with urllib.request.urlopen(url, timeout=120) as response, partial.open('wb') as output:
            shutil.copyfileobj(response, output)
        partial.replace(archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    unpack = CACHE / f'{name}-unpack'
    unpack.mkdir(exist_ok=True)
    with tarfile.open(archive) as package:
        package.extractall(unpack, filter='data')
    roots = list(unpack.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise RuntimeError(f'{name}: unexpected archive layout')
    roots[0].rename(target)
    (target / '.openmw-source.json').write_text(json.dumps({
        'url': url, 'sha256': digest,
        'note': 'Download digest for reproducibility; not an upstream signature.'
    }, indent=2) + '\n')
    print(f'{name}: extracted; sha256={digest}', flush=True)
