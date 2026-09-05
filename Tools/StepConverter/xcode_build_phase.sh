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
#
# Written for macOS's system /bin/bash (3.2) — no associative arrays, no `${arr[-1]}`
# negative indexing, both bash 4+ only.
set -euo pipefail

OCCT_PREFIX=""
for prefix in /opt/homebrew/opt/opencascade /usr/local/opt/opencascade; do
  if [ -d "$prefix/lib" ]; then
    OCCT_PREFIX="$prefix"
    break
  fi
done

DEST_DIR="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
FRAMEWORKS_DIR="$BUILT_PRODUCTS_DIR/$(dirname "$UNLOCALIZED_RESOURCES_FOLDER_PATH")/Frameworks"
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

# @executable_path/../Frameworks (not the Homebrew lib dir) — the whole point of
# bundling below is that this binary must not depend on Homebrew being installed
# on the machine actually running the built app.
clang++ -std=c++17 -O2 \
  -I"$OCCT_PREFIX/include/opencascade" \
  -L"$OCCT_PREFIX/lib" \
  "${LDFLAGS[@]}" \
  -Wl,-rpath,@executable_path/../Frameworks \
  -o "$DEST_DIR/step-tessellate" \
  "$SRCROOT/Tools/StepConverter/main.cpp"

echo "built step-tessellate -> $DEST_DIR/step-tessellate"

# --- Bundle OpenCASCADE's own runtime dependencies --------------------------
#
# Confirmed live: every render_step job failed at runtime with
# "Library not loaded: /opt/homebrew/opt/opencascade/lib/libTKernel.7.9.dylib
#  ... file system sandbox blocked open()" — the App Sandbox blocks dyld from
# reading anything under /opt/homebrew at runtime, even though step-tessellate
# itself (a same-signature bundled helper) is allowed to *execute*. The linked
# libraries have to physically live inside the signed app bundle instead, with
# every reference to them (the binary's own, and each library's references to
# its siblings) rewritten from the Homebrew absolute path to @rpath.
#
# Walks the actual transitive dependency closure via `otool -L` to a fixed
# point rather than hardcoding a library list — confirmed live to currently be
# a closed set of 27 dylibs / ~32MB (11 OpenCASCADE libs directly linked, plus
# more OpenCASCADE libs, Intel TBB, FreeType, and libpng pulled in
# transitively) — so a future OCCT version bump that changes the graph doesn't
# silently leave something un-bundled.
#
# Two distinct reference styles show up and both need resolving: some deps
# (FreeType, libpng, TBB, and each top-level OCCT lib's own identity) use an
# absolute Homebrew path; but OpenCASCADE's own dylibs reference *each other*
# via `@rpath/libX.dylib`, resolved against their shared `@loader_path/../lib`
# rpath — i.e. the same $OCCT_PREFIX/lib directory. Confirmed live: missing
# this second style silently produced an incomplete bundle that built and
# launched fine but crashed on the first real STEP conversion with "Library
# not loaded: @rpath/libTKShHealing.7.9.dylib" — a dependency invisible to a
# plain `grep` for absolute Homebrew paths.
mkdir -p "$FRAMEWORKS_DIR"

homebrew_deps_of() {
  otool -L "$1" | tail -n +2 | awk '{print $1}' | while IFS= read -r dep; do
    case "$dep" in
      @rpath/*)
        name="${dep#@rpath/}"
        [ -f "$OCCT_PREFIX/lib/$name" ] && echo "$OCCT_PREFIX/lib/$name"
        ;;
      /opt/homebrew/opt/*|/usr/local/opt/*)
        echo "$dep"
        ;;
    esac
  done || true
}

DEPS_FILE="$(mktemp)"
trap 'rm -f "$DEPS_FILE" "$DEPS_FILE.scan"' EXIT

homebrew_deps_of "$DEST_DIR/step-tessellate" | sort -u > "$DEPS_FILE"

prev_count=-1
while true; do
  cur_count=$(wc -l < "$DEPS_FILE" | tr -d ' ')
  [ "$cur_count" = "$prev_count" ] && break
  prev_count=$cur_count
  : > "$DEPS_FILE.scan"
  while IFS= read -r dep; do
    [ -f "$dep" ] && homebrew_deps_of "$dep" >> "$DEPS_FILE.scan"
  done < "$DEPS_FILE"
  cat "$DEPS_FILE.scan" >> "$DEPS_FILE"
  sort -u -o "$DEPS_FILE" "$DEPS_FILE"
done

dep_count=$(wc -l < "$DEPS_FILE" | tr -d ' ')
echo "bundling $dep_count runtime dependencies into Frameworks/"

while IFS= read -r dep; do
  name="$(basename "$dep")"
  cp -f "$dep" "$FRAMEWORKS_DIR/$name"
  chmod u+w "$FRAMEWORKS_DIR/$name"
  install_name_tool -id "@rpath/$name" "$FRAMEWORKS_DIR/$name"
done < "$DEPS_FILE"

# Rewrite cross-references between the now-bundled dylibs, and from
# step-tessellate itself, from the Homebrew absolute path to @rpath.
retarget() {
  local target="$1"
  while IFS= read -r dep; do
    local name
    name="$(basename "$dep")"
    install_name_tool -change "$dep" "@rpath/$name" "$target" 2>/dev/null || true
  done < "$DEPS_FILE"
}
while IFS= read -r dep; do
  retarget "$FRAMEWORKS_DIR/$(basename "$dep")"
done < "$DEPS_FILE"
retarget "$DEST_DIR/step-tessellate"

# Xcode's own bundle-level codesign pass only signs the main executable plus recognized
# nested code (frameworks/plugins) — a loose executable/library dropped into the bundle
# by a script phase like this one is invisible to it and keeps whatever (non-)signature
# it was left with. Confirmed live: Apple's notary service rejected a real Developer ID
# release over exactly this ("The executable does not have the hardened runtime
# enabled"). Sign everything explicitly here with whatever identity Xcode resolved for
# this build (falls back to ad-hoc "-" for a local Debug build with no team configured,
# which still accepts the hardened-runtime option) — the bundled dylibs first, since
# step-tessellate's own signature seals a reference to them.
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
while IFS= read -r dep; do
  codesign --force --sign "$SIGN_IDENTITY" --options runtime "$FRAMEWORKS_DIR/$(basename "$dep")"
done < "$DEPS_FILE"

codesign --force --sign "$SIGN_IDENTITY" --options runtime "$DEST_DIR/step-tessellate"
echo "signed step-tessellate and $dep_count bundled dependencies with identity: $SIGN_IDENTITY"
