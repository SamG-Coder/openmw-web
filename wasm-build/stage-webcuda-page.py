"""Stage the local WebCuda page and its required scripts without changing game data.

The engine files must already exist in .local-runtime/e/<version>/ and the
webcuda/webcuda-sdk mounts must already be configured for this machine.
"""
import argparse
import re
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument("engine_version")
args = parser.parse_args()
if not re.fullmatch(r"[a-zA-Z0-9_-]+", args.engine_version):
    parser.error("engine_version must be a single directory name")
root = Path(__file__).resolve().parent.parent
destination = root / ".local-runtime"
for name in ("openmw.js", "openmw.wasm", "openmw.data"):
    if not (destination / "e" / args.engine_version / name).is_file():
        parser.error(f"Missing staged engine artifact: {name}")
for name in ("webcuda/game-host.js", "webcuda-sdk/src/runtime/runtime.js"):
    if not (destination / name).is_file():
        parser.error(f"Missing local renderer mount: {name}")
page = (root / "play/index.html").read_text(encoding="utf-8")
if "__ENGINE_VERSION__" not in page:
    parser.error("Page has no engine version placeholder")
# Install dependencies before the page that references them.
for name in ("frame-pump.js", "streamfs.js"):
    shutil.copyfile(root / "play" / name, destination / name)
(destination / "index.html").write_text(
    page.replace("__ENGINE_VERSION__", args.engine_version), encoding="utf-8"
)
print(f"Staged WebCuda page and startup scripts for {args.engine_version}")
