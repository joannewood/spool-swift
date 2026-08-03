#!/bin/bash
# Builds, signs, notarizes, and packages Spool for distribution outside the Mac App
# Store (a "Developer ID" release — see ExportOptions.plist). Produces a signed,
# notarized Spool.dmg, ready to upload wherever you're hosting it.
#
# One-time setup before this will work: store your notarization credentials once —
#   xcrun notarytool store-credentials "notarytool-password" \
#     --apple-id "<your apple id email>" --team-id "U8NA3U6GZF"
# (prompts for an app-specific password from appleid.apple.com — never stored in this repo).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Spool"
SCHEME="Spool"
KEYCHAIN_PROFILE="notarytool-password"
# Deliberately *outside* the repo, in plain /tmp — this repo lives under an iCloud
# Drive-synced Documents folder, and its File Provider sync daemon re-tags anything
# written under it with a `com.apple.FinderInfo` extended attribute within seconds,
# even after it's stripped (confirmed live: stripped it, checked again 2s later, it
# was back). `codesign --verify`/Apple's notary service both reject that attribute
# outright ("resource fork, Finder information... not allowed"), and since it's
# actively reapplied by a running daemon rather than a one-time taint, stripping it
# in place is a losing race — building somewhere never touched by iCloud sync sidesteps
# the problem entirely instead of fighting it.
BUILD_DIR="/tmp/spool-release-build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate

echo "==> Archiving (Release configuration)"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH"

echo "==> Exporting a Developer ID–signed build"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist Tools/Release/ExportOptions.plist

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: expected $APP_PATH to exist after export" >&2
  exit 1
fi

echo "==> Re-signing bundled helper tools with hardened runtime"
# `xcodebuild -exportArchive` re-signs every Mach-O it finds in the exported bundle for
# distribution — including loose helper executables dropped in by a script phase, like
# step-tessellate — but confirmed live it does *not* carry hardened runtime through for
# those (they came out of export signed correctly with the Developer ID identity, but
# with `flags=0x0(none)` instead of the runtime flag). `codesign --verify` doesn't catch
# this at all — it only checks signature integrity, not notarization requirements — so
# this class of bug is invisible until an actual notarization submission rejects it
# ("The executable does not have the hardened runtime enabled"), which is exactly what
# happened on the first real run of this script. Re-sign as the very last step before
# packaging, so nothing after this can strip it again.
if [ -f "$APP_PATH/Contents/Resources/step-tessellate" ]; then
  codesign --force --sign "Developer ID Application: Joanne Wood (U8NA3U6GZF)" \
    --options runtime --timestamp "$APP_PATH/Contents/Resources/step-tessellate"
  # Captured to a variable rather than piped straight into `grep -q`: with
  # `pipefail` on, `grep -q` closing the pipe as soon as it finds its match can
  # SIGPIPE the still-writing `codesign` process, making the pipeline's exit
  # status nonzero even though the match succeeded (confirmed live — this
  # exact check failed once, then passed on an immediate manual replay).
  SIGN_INFO="$(codesign -dvv "$APP_PATH/Contents/Resources/step-tessellate" 2>&1)"
  if echo "$SIGN_INFO" | grep -q "flags=0x10000(runtime)"; then
    echo "step-tessellate: hardened runtime confirmed"
  else
    echo "error: step-tessellate still missing hardened runtime after re-sign" >&2
    echo "$SIGN_INFO" >&2
    exit 1
  fi

  # Re-signing step-tessellate above invalidates the outer Spool.app seal —
  # `xcodebuild -exportArchive` already recorded a hash of every nested
  # resource (including this loose helper executable) in the app's own
  # CodeResources manifest, so changing step-tessellate's signature after the
  # fact makes the enclosing app's own signature reference a stale hash
  # (confirmed live: `codesign --verify` then fails with "a sealed resource is
  # missing or invalid"). Re-sign the enclosing app bundle to reseal it,
  # preserving its existing entitlements exactly rather than re-deriving them.
  echo "==> Resealing Spool.app after helper re-sign"
  ENTITLEMENTS_PATH="$BUILD_DIR/Spool.entitlements"
  codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PATH"
  codesign --force --sign "Developer ID Application: Joanne Wood (U8NA3U6GZF)" \
    --options runtime --timestamp --entitlements "$ENTITLEMENTS_PATH" "$APP_PATH"
fi

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Building a disk image"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

# `hdiutil create` produces an unsigned disk image — notarizing/stapling the
# app inside doesn't sign the DMG container itself, but the standard
# post-staple Gatekeeper check (`spctl -a -t open --context
# context:primary-signature`) validates the DMG's *own* signature, not just
# its stapled ticket (confirmed live: that check failed with "no usable
# signature" / "code object is not signed at all" until this was added).
echo "==> Signing the disk image"
codesign --force --sign "Developer ID Application: Joanne Wood (U8NA3U6GZF)" \
  --timestamp "$DMG_PATH"

echo "==> Submitting for notarization (this can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Final Gatekeeper check"
spctl -a -t open --context context:primary-signature -v "$DMG_PATH"

echo ""
echo "Done: $DMG_PATH"
echo "(Deliberately left outside the repo/iCloud sync — see the note at the top of this"
echo " script. Upload it directly from there; copying it back into Documents risks the"
echo " same FinderInfo re-tagging happening to the finished file.)"
