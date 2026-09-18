#!/bin/sh
#
# Package a built app into a disk image for release.
#
#   Scripts/make-dmg.sh /path/to/daiKonnect.app [out.dmg]
#
# The image contains the app and a symlink to /Applications, which is the
# layout people expect: drag the app across to install it.
#
# The app is not notarised, so macOS on another machine will warn about it
# the first time it is opened. That needs an Apple Developer ID and a
# notarisation step, neither of which a self-signed certificate can stand in
# for. Locally built copies are unaffected.

set -e

APP="${1:?usage: make-dmg.sh <app> [out.dmg]}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

if [ ! -d "$APP" ]; then
    echo "make-dmg: no app at $APP" >&2
    exit 1
fi

NAME="$(basename "$APP" .app)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
OUT="${2:-$PWD/$NAME-$VERSION-$BUILD.dmg}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "make-dmg: staging $NAME $VERSION ($BUILD)"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
echo "make-dmg: writing $OUT"
hdiutil create \
    -volname "$NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$OUT" >/dev/null

hdiutil verify "$OUT" >/dev/null
echo "make-dmg: $OUT ($(du -h "$OUT" | cut -f1))"
