#!/bin/bash
# Builds build/Claudo.app (release, ad-hoc signed). `./build.sh --install` also copies it to /Applications
# and (re)launches it. `./build.sh --release` signs it with Developer ID, notarizes it and packs a .zip and a .dmg
# for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
APP=build/Claudo.app
MODE="${1:-}"
# Release signing: the Developer ID identity in the login keychain and a notarytool profile saved once with
# `xcrun notarytool store-credentials <profile> --key … --key-id … --issuer …`.
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: OCTAGONLAB LIMITED (6966J92GMC)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-van-dam}"

notarize() {
    local log
    log=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr)
    if ! grep -q "status: Accepted" <<<"$log"; then
        echo "notarization of $1 failed; details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
}

swift build -c release --product Claudo
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Claudo "$APP/Contents/MacOS/Claudo"
cp Info.plist "$APP/Contents/Info.plist"
# AppIcon.icns from Resources/AppIcon.png (regenerate the PNG with `tools/make-icon.sh`).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if [[ $MODE == --release ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
    ZIP="build/Claudo-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"
    spctl -a -vv -t exec "$APP"
    # Zip again so the download carries the stapled ticket.
    rm "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    # The same app in a drag-to-Applications disk image, notarized on its own.
    DMG="build/Claudo-$VERSION.dmg"
    STAGE=$(mktemp -d)
    ditto "$APP" "$STAGE/Claudo.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname Claudo -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DMG"
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl -a -vv -t open --context context:primary-signature "$DMG"
    echo "released $ZIP and $DMG"
    # The zip's SHA-256 goes into Casks/claudo.rb.
    shasum -a 256 "$ZIP" "$DMG"
    exit 0
fi

codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

if [[ $MODE == --install ]]; then
    LABEL=site.spasskiy.claudo
    AGENT=~/Library/LaunchAgents/$LABEL.plist
    # With Launch at Login on, launchd owns the process (and keeps it alive): stop it there instead of
    # racing KeepAlive with a second copy, and start it there again afterwards.
    if [[ -f $AGENT ]] && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$LABEL" || true
    fi
    pkill -x Claudo || true
    rm -rf /Applications/Claudo.app
    cp -R "$APP" /Applications/
    if [[ -f $AGENT ]]; then
        launchctl bootstrap "gui/$(id -u)" "$AGENT"
    else
        open /Applications/Claudo.app
    fi
    echo "installed /Applications/Claudo.app"
fi
