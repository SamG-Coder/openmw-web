"""Stage native WebGPU shaders and the game page beside an existing engine.

Usage: python wasm-build/stage-webgpu-page.py ENGINE_VERSION
The default destination is .local-runtime; --destination selects another web root.
No CUDA compiler, SDK mount, or engine rebuild is needed for a renderer-only edit.
"""
import argparse
import hashlib
from pathlib import Path
import re
import shutil


def stage(engine_version, destination):
    root = Path(__file__).resolve().parent.parent
    destination = Path(destination).resolve()
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", engine_version):
        raise ValueError("engine_version must be a single directory name")
    for name in ("openmw.js", "openmw.wasm", "openmw.data"):
        if not (destination / "e" / engine_version / name).is_file():
            raise FileNotFoundError(f"Missing staged engine artifact: {name}")
    renderer = root / "render" / "webgpu"
    sources = sorted(path for path in renderer.rglob("*")
                     if path.is_file() and path.suffix in (".js", ".wgsl"))
    if not sources or not (renderer / "game-host.js").is_file():
        raise FileNotFoundError("The native WebGPU renderer sources are missing")
    digest = hashlib.sha256()
    for path in sources:
        digest.update(path.relative_to(renderer).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    renderer_version = digest.hexdigest()[:16]
    renderer_directory = destination / "webgpu" / renderer_version
    for path in sources:
        target = renderer_directory / path.relative_to(renderer)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)

    page = (root / "play" / "index.html").read_text(encoding="utf-8")
    marker = "const rendererDirectory = './' + __ENGINE_DIR + 'webgpu/';"
    if "__ENGINE_VERSION__" not in page or marker not in page:
        raise ValueError("Page is missing an engine or renderer version placeholder")
    page = page.replace("__ENGINE_VERSION__", engine_version).replace(
        marker, f"const rendererDirectory = './webgpu/{renderer_version}/';")
    for name in ("frame-pump.js", "streamfs.js"):
        shutil.copyfile(root / "play" / name, destination / name)
    # Install the page after every dependency is present.
    temporary = destination / "index.html.tmp"
    temporary.write_text(page, encoding="utf-8")
    temporary.replace(destination / "index.html")
    return renderer_version


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine_version")
    parser.add_argument("--destination", type=Path,
                        default=Path(__file__).resolve().parent.parent / ".local-runtime")
    args = parser.parse_args()
    try:
        version = stage(args.engine_version, args.destination)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(f"Staged native WebGPU renderer {version} for engine {args.engine_version}")
