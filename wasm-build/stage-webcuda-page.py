"""Compatibility entry point: this branch stages the native WebGPU renderer."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).with_name("stage-webgpu-page.py")), run_name="__main__")
