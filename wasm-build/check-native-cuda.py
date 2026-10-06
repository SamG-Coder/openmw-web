"""Compile OpenMW's CUDA using ChromiumRTXCuda's bundled NVRTC.

This is a local compiler check, not browser automation or proof of gameplay.
It uses the same options as alpha.6 and emits device-specific CUBIN. No
filesystem headers, compiler option overrides, or generated WGSL are used.
"""
import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import re
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser-root", type=Path, required=True)
    parser.add_argument("--entry", help="One runtime entry; default is all runtime entries")
    parser.add_argument("--paged", action="store_true", help="Compile the full renderer's paged native storage ABI")
    parser.add_argument("--arch", help="sm_XX; default is the first CUDA device's architecture")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    generated = Path(__file__).resolve().parents[1] / "render/webcuda/generated"
    manifest = json.loads((generated / "native-manifest.json").read_text(encoding="utf-8"))
    entries = [item for item in manifest if item["runtime"] and (not args.entry or item["entry"] == args.entry)]
    if not entries:
        parser.error("Unknown runtime kernel")
    # Start with the kernel whose WebGPU compilation is currently expensive.
    entries.sort(key=lambda item: item["entry"] != "raster_material")
    if args.paged:
        entries = [{**item, "artifact": f"{item['entry']}.native-paged.json"} for item in entries]
        if not args.entry:
            entries += [{"entry": entry, "artifact": f"{entry}.native.json"} for entry in ("omw_set_page", "omw_copy_pages")]
    dll_dir = (args.browser_root / "rtx_cuda").resolve(strict=True)
    dlls = list(dll_dir.glob("nvrtc64_*.dll"))
    if len(dlls) != 1:
        parser.error("Expected exactly one bundled nvrtc64 DLL under browser-root/rtx_cuda")
    directory_handle = os.add_dll_directory(str(dll_dir))
    nv = c.CDLL(str(dlls[0]))
    pointer, string, integer, size = c.c_void_p, c.c_char_p, c.c_int, c.c_size_t

    def api(name, arguments):
        function = getattr(nv, name)
        function.argtypes = arguments
        function.restype = integer
        return function

    create = api("nvrtcCreateProgram", [c.POINTER(pointer), string, string, integer, pointer, pointer])
    add_name = api("nvrtcAddNameExpression", [pointer, string])
    compile_program = api("nvrtcCompileProgram", [pointer, integer, c.POINTER(string)])
    log_size = api("nvrtcGetProgramLogSize", [pointer, c.POINTER(size)])
    get_log = api("nvrtcGetProgramLog", [pointer, pointer])
    cubin_size = api("nvrtcGetCUBINSize", [pointer, c.POINTER(size)])
    get_cubin = api("nvrtcGetCUBIN", [pointer, pointer])
    destroy = api("nvrtcDestroyProgram", [c.POINTER(pointer)])
    version = api("nvrtcVersion", [c.POINTER(integer), c.POINTER(integer)])

    def check(result):
        if result:
            raise RuntimeError(f"NVRTC returned {result}")

    major, minor = integer(), integer()
    check(version(c.byref(major), c.byref(minor)))
    arch = args.arch
    device_name = None
    if not arch:
        driver = c.WinDLL("nvcuda.dll")
        for name, arguments in [
            ("cuInit", [c.c_uint]),
            ("cuDeviceGet", [c.POINTER(integer), integer]),
            ("cuDeviceComputeCapability", [c.POINTER(integer), c.POINTER(integer), integer]),
            ("cuDeviceGetName", [pointer, integer, integer]),
        ]:
            getattr(driver, name).argtypes = arguments
            getattr(driver, name).restype = integer
        device, device_major, device_minor = integer(), integer(), integer()
        for result in [driver.cuInit(0), driver.cuDeviceGet(c.byref(device), 0),
                       driver.cuDeviceComputeCapability(c.byref(device_major), c.byref(device_minor), device)]:
            if result:
                raise RuntimeError(f"CUDA device query returned {result}; pass --arch for cross-compilation")
        name = c.create_string_buffer(256)
        if driver.cuDeviceGetName(name, 256, device):
            raise RuntimeError("CUDA device name query failed")
        device_name = name.value.decode()
        arch = f"sm_{device_major.value}{device_minor.value}"
    if not re.fullmatch(r"sm_[0-9]{2,3}", arch):
        parser.error("--arch must be sm_XX or sm_XXX")
    options = [f"--gpu-architecture={arch}", "--std=c++17", "--no-source-include",
               "--use_fast_math", "--dopt=on", "--Ofast-compile=0",
               "--extra-device-vectorization", "--ptxas-options=--opt-level=3"]
    encoded_options = (string * len(options))(*(value.encode() for value in options))
    report = {"schema": 1, "kind": "local NVRTC compilation", "status": "running",
              "compilerVersion": f"{major.value}.{minor.value}", "architecture": arch,
              "device": device_name, "options": options, "kernels": [],
              "executed": False, "browserTested": False, "pagedStorage": args.paged,
              "limits": "Compilation only; no GPU dispatch, browser permission, frame-rate or gameplay validation."}
    started = time.perf_counter()
    try:
        for item in entries:
            artifact = json.loads((generated / item["artifact"]).read_text(encoding="utf-8"))
            native = artifact["native"]
            source = native["source"].encode("utf-8")
            if native["entry"] != item["entry"] or native["version"] != 1:
                raise ValueError("Native artifact entry/version mismatch")
            if not 0 < len(source) <= 262144 or any(token in source for token in (b"#", b"%:", b"??", b"\\", b"__has_include", b"\0")):
                raise ValueError("Source does not meet the native browser's self-contained source contract")
            program = pointer()
            began = time.perf_counter()
            check(create(c.byref(program), source, b"browser.cu", 0, None, None))
            record = {"entry": item["entry"], "sourceBytes": len(source), "sourceSha256": hashlib.sha256(source).hexdigest()}
            try:
                check(add_name(program, item["entry"].encode()))
                result = compile_program(program, len(options), encoded_options)
                length = size()
                check(log_size(program, c.byref(length)))
                log = c.create_string_buffer(length.value)
                check(get_log(program, log))
                record["log"] = log.value.decode("utf-8", errors="replace")
                if result:
                    raise RuntimeError(f"{item['entry']}: NVRTC {result}\n{record['log']}")
                check(cubin_size(program, c.byref(length)))
                cubin = c.create_string_buffer(length.value)
                check(get_cubin(program, cubin))
                if not cubin.raw.startswith(b"\x7fELF"):
                    raise RuntimeError("NVRTC did not return a CUBIN ELF image")
                record.update(compiled=True, cubinBytes=length.value,
                              cubinSha256=hashlib.sha256(cubin.raw).hexdigest(),
                              compileMs=(time.perf_counter()-began)*1000)
                print(f"{item['entry']}: CUBIN {length.value} bytes, {record['compileMs']/1000:.3f} s", flush=True)
            finally:
                report["kernels"].append(record)
                check(destroy(c.byref(program)))
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        report["elapsedSeconds"] = time.perf_counter()-started
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
        directory_handle.close()
        print(f"{report['status']}: {len(report['kernels'])} kernels; report: {args.report}", flush=True)


if __name__ == "__main__":
    main()
