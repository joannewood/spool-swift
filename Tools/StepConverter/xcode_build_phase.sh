#!/bin/bash
# Xcode "Run Script" build phase (wired via project.yml's preBuildScripts): compiles
# step-tessellate and drops it straight into the app bundle's Resources folder, so
# Xcode's own later codesign phase picks it up and signs it along with everything else
# — no separate Copy Files phase needed. Deliberately does NOT invoke `brew` (a script
# phase's environment doesn't source the user's shell rc files, so `brew` may not be on
# PATH) — instead checks the same fixed Homebrew prefixes the rest of the app already
# uses for external tools (see ArchiveToolLocator).
#
# Missing OCCT is not a build failure: STEP files just fall back to
# render_status = 'unsupported', the same graceful degrade the app already gives .scad
# and 7z/rar without `unar` installed.
set -euo pipefail

OCCT_PREFIX=""
for prefix in /opt/homebrew/opt/opencascade /usr/local/opt/opencascade; do
  if [ -d "$prefix/lib" ]; then
    OCCT_PREFIX="$prefix"
    break
  fi
done

DEST_DIR="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST_DIR"

if [ -z "$OCCT_PREFIX" ]; then
  echo "warning: OpenCASCADE not found at /opt/homebrew/opt/opencascade or /usr/local/opt/opencascade (brew install opencascade) — STEP files will render as unsupported until it's installed and the app is rebuilt" >&2
  rm -f "$DEST_DIR/step-tessellate"
  exit 0
fi

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
  -o "$DEST_DIR/step-tessellate" \
  "$SRCROOT/Tools/StepConverter/main.cpp"

echo "built step-tessellate -> $DEST_DIR/step-tessellate"

# Xcode's own bundle-level codesign pass only signs the main executable plus recognized
# nested code (frameworks/plugins) — a loose executable dropped into Resources by a
# script phase like this one is invisible to it and keeps whatever (non-)signature
# clang++ left it with. Confirmed live: Apple's notary service rejected a real
# Developer ID release over exactly this ("The executable does not have the hardened
# runtime enabled"). Sign it explicitly here with whatever identity Xcode resolved for
# this build (falls back to ad-hoc "-" for a local Debug build with no team configured,
# which still accepts the hardened-runtime option).
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$DEST_DIR/step-tessellate"
echo "signed step-tessellate with identity: $SIGN_IDENTITY"
