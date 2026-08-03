#!/bin/bash
# Standalone build of step-tessellate against Homebrew OpenCASCADE, for local
# testing independent of the Xcode project (the Xcode build phase that bundles
# this into the app will invoke clang++ the same way, see M5 task #33).
set -euo pipefail

OCCT_PREFIX="${OCCT_PREFIX:-$(brew --prefix opencascade)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$SCRIPT_DIR/step-tessellate}"

LIBS=(TKernel TKMath TKG2d TKG3d TKGeomBase TKBRep TKTopAlgo TKMesh TKDESTEP TKDE TKXSBase)
LDFLAGS=()
for lib in "${LIBS[@]}"; do
  LDFLAGS+=("-l${lib}")
done

clang++ -std=c++17 -O2 \
  -I"$OCCT_PREFIX/include/opencascade" \
  -L"$OCCT_PREFIX/lib" \
  "${LDFLAGS[@]}" \
  -Wl,-rpath,"$OCCT_PREFIX/lib" \
  -o "$OUT" \
  "$SCRIPT_DIR/main.cpp"

echo "built: $OUT"
