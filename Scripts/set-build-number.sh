#!/bin/sh
#
# Stamp the build number the app reports.
#
# The number is the number of commits, so it only ever increases and needs no
# state kept anywhere: a release built from a later commit always has a higher
# number than an earlier one. That is what the in-app update check compares,
# so it must never go backwards.
#
# DAIKONNECT_BUILD_NUMBER overrides it, which is how the release workflow uses
# its own run number instead — CI checks out a single commit, so the commit
# count would be the same for every run.
#
# Run as a build phase, after the Info.plist has been produced. Xcode signs the
# product after the build phases, so no re-signing is needed here.
#
# The number cannot live in the generated Info.plist alone. On an incremental
# build a later task rewrites that file, taking CFBundleVersion back from
# CURRENT_PROJECT_VERSION, so a stamp written here would not survive. The
# number also goes into a resource in the bundle, which nothing regenerates,
# and the app reads that in preference to the plist.

set -e

if [ -n "$DAIKONNECT_BUILD_NUMBER" ]; then
    BUILD="$DAIKONNECT_BUILD_NUMBER"
else
    # Read the commit count. Needs ENABLE_USER_SCRIPT_SANDBOXING off, since the
    # build sandbox blocks reading the repository.
    BUILD=$(git -C "$SRCROOT" rev-list --count HEAD) || {
        echo "set-build-number: git failed; leaving the build number alone" >&2
        exit 0
    }
fi

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if [ ! -f "$PLIST" ]; then
    echo "set-build-number: no Info.plist at $PLIST"
    exit 0
fi

if ! /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$PLIST" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUILD}" "$PLIST"
fi

echo "set-build-number: CFBundleVersion = ${BUILD} (read back: $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST"))"

# The plist above can be regenerated under us on an incremental build, so the
# number the app actually reports is kept here, in a file no other task writes.
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ -d "$RESOURCES" ]; then
    printf '%s\n' "$BUILD" > "$RESOURCES/BuildNumber"
    echo "set-build-number: wrote $RESOURCES/BuildNumber"
else
    echo "set-build-number: no resources folder at $RESOURCES" >&2
fi
