#!/bin/sh
# TEMPORARY diagnostic for the cp315 ios_arm64_iphonesimulator
# "Run-time dependency python found: NO" failure.
#
# Runs inside the cibuildwheel iOS build env (via `before-build`), where
# `python` is the cross venv python. Captures the environment/SDK/symlink
# state that the iOS compiler wrappers depend on, then re-runs the exact
# Meson has_header('Python.h') probe so we can compare a passing local run
# against the failing CI run.
set -u

echo "==================== DIAG: environment ===================="
echo "--- IPHONEOS / SDK related env ---"
env | grep -iE "IPHONEOS|IOS_SDK|SDKROOT|DEVELOPER_DIR" || echo "(none set)"
echo "--- xcode-select / xcrun ---"
xcode-select -p || true
xcrun --sdk iphonesimulator --show-sdk-version 2>&1 || true
xcrun --sdk iphonesimulator --show-sdk-path 2>&1 || true

echo "==================== DIAG: XCframework slice ===================="
D="$(python -c 'import sysconfig,os;print(os.path.dirname(sysconfig.get_config_var("INCLUDEPY")))' 2>/dev/null)"
echo "INCLUDEPY dir (from cross-venv sysconfig): $D"
INC="$(python -c 'import sysconfig;print(sysconfig.get_config_var("INCLUDEPY"))' 2>/dev/null)"
echo "INCLUDEPY: $INC"
echo "--- listing include dir ---"
ls -la "$D" 2>&1 || true
echo "--- symlink resolution + Python.h presence ---"
python - "$INC" <<'PY' 2>&1 || true
import os, sys
inc = sys.argv[1]
print("islink:", os.path.islink(inc))
print("realpath:", os.path.realpath(inc))
print("Python.h exists:", os.path.exists(os.path.join(inc, "Python.h")))
PY

echo "==================== DIAG: exact has_header probe ===================="
printf '%s\n' \
  '#ifdef __has_include' \
  ' #if !__has_include("Python.h")' \
  '  #error "Header (Python.h) could not be found"' \
  ' #endif' \
  '#else' \
  ' #include <Python.h>' \
  '#endif' > /tmp/diag_testfile.cpp

echo "--- clang version (active toolchain) ---"
arm64-apple-ios-simulator-clang++ --version 2>&1 | head -2 || true

echo "--- probe A: SIMULATOR wrapper (mirrors Meson command line; the failing case) ---"
arm64-apple-ios-simulator-clang++ -I"$INC" /tmp/diag_testfile.cpp \
  -E -P -P -O0 -U_FORTIFY_SOURCE -fpermissive -Werror=implicit-function-declaration
echo "probe A (simulator) exit=$?"

echo "--- probe B: explicit iphonesimulator SDK + arm64-simulator target ---"
xcrun --sdk iphonesimulator clang++ -target "arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-13.0}-simulator" \
  -I"$INC" /tmp/diag_testfile.cpp \
  -E -P -P -O0 -U_FORTIFY_SOURCE -fpermissive -Werror=implicit-function-declaration
echo "probe B (explicit simulator sdk) exit=$?"

echo "--- probe C: DEVICE SDK for contrast (this arch passes on device) ---"
xcrun --sdk iphoneos clang++ -target "arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-13.0}" \
  -I"$INC" /tmp/diag_testfile.cpp \
  -E -P -P -O0 -U_FORTIFY_SOURCE -fpermissive -Werror=implicit-function-declaration
echo "probe C (device sdk) exit=$?"

echo "--- probe D: simulator, but point -I straight at resolved framework Headers ---"
REAL="$(python -c 'import os,sysconfig;print(os.path.realpath(sysconfig.get_config_var("INCLUDEPY")))' 2>/dev/null)"
echo "resolved Headers dir: $REAL"
arm64-apple-ios-simulator-clang++ -I"$REAL" /tmp/diag_testfile.cpp \
  -E -P -P -O0 -U_FORTIFY_SOURCE -fpermissive -Werror=implicit-function-declaration
echo "probe D (simulator, resolved -I) exit=$?"

echo "--- verbose search paths for the SIMULATOR probe (why it does/doesn't resolve) ---"
arm64-apple-ios-simulator-clang++ -v -I"$INC" /tmp/diag_testfile.cpp -E -P 2>&1 \
  | grep -iE "sysroot|search starts|framework|ignoring|error|resource-dir|clang/[0-9]|#include" | head -50

echo "==================== DIAG: patch meson for [DIAG] lines ===================="
python "${BEFORE_BUILD_DIR:-.}/ci/diag_patch_meson.py" || true

echo "==================== DIAG: end before-build ===================="
