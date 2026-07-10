"""Diagnostic: patch mesonbuild PythonSystemDependency to print how the Python
system dependency is resolved (branch taken + has_header result).

Run with the SAME interpreter that runs meson (i.e. inside the build env, via
cibuildwheel `before-build`). Idempotent.

This is a TEMPORARY debugging aid for investigating the cp315
ios_arm64_iphonesimulator "Run-time dependency python found: NO" failure.
"""
import importlib.util
import pathlib
import sys

spec = importlib.util.find_spec("mesonbuild.dependencies.python")
if spec is None or not spec.origin:
    print("[patch_meson] mesonbuild not importable in this interpreter; skipping",
          file=sys.stderr)
    sys.exit(0)

path = pathlib.Path(spec.origin)
src = path.read_text()

MARKER = "# __DIAG_PATCH__"
if MARKER in src:
    print(f"[patch_meson] already patched: {path}", file=sys.stderr)
    sys.exit(0)

anchor = (
    "        SystemDependency.__init__(self, name, environment, kwargs)\n"
    "        _PythonDependencyBase.__init__(self, installation, kwargs.get('embed', False))\n"
)
if anchor not in src:
    print("[patch_meson] top anchor not found; meson layout changed", file=sys.stderr)
    sys.exit(0)

inject_top = anchor + (
    "        import sys as _sys  " + MARKER + "\n"
    "        try:\n"
    "            _new = environment.need_exe_wrapper(self.for_machine)\n"
    "        except Exception as _e:\n"
    "            _new = f'ERR:{_e!r}'\n"
    "        print(f'[DIAG] platform={self.platform!r} link_libpython={self.link_libpython} "
    "is_freethreaded={self.is_freethreaded} for_machine={self.for_machine}', file=_sys.stderr)\n"
    "        print(f'[DIAG] need_exe_wrapper={_new}', file=_sys.stderr)\n"
    "        print(f'[DIAG] clib_compiler={self.clib_compiler!r}', file=_sys.stderr)\n"
    "        print(f'[DIAG] startswith_ios={self.platform.startswith(\"ios-\")}', file=_sys.stderr)\n"
)
src = src.replace(anchor, inject_top, 1)

hdr_anchor = (
    "        if not self.clib_compiler.has_header('Python.h', '', extra_args=self.compile_args)[0]:\n"
    "            self.is_found = False\n"
)
if hdr_anchor not in src:
    print("[patch_meson] has_header anchor not found; meson layout changed", file=sys.stderr)
    # Still write the top diagnostics we already injected.
    path.write_text(src)
    print(f"[patch_meson] partially patched: {path}", file=sys.stderr)
    sys.exit(0)

hdr_new = (
    "        import sys as _sys2  " + MARKER + "\n"
    "        print(f'[DIAG] compile_args={self.compile_args}', file=_sys2.stderr)\n"
    "        _hdr = self.clib_compiler.has_header('Python.h', '', extra_args=self.compile_args)[0]\n"
    "        print(f'[DIAG] has_header(Python.h)={_hdr} is_found_before={self.is_found}', file=_sys2.stderr)\n"
    "        if not _hdr:\n"
    "            self.is_found = False\n"
)
src = src.replace(hdr_anchor, hdr_new, 1)

path.write_text(src)
print(f"[patch_meson] patched: {path}", file=sys.stderr)
