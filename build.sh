#!/bin/bash
# Builds build/Claudo.app (release, ad-hoc signed). `./build.sh --install` also copies it to /Applications
# and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Claudo.app
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
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
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
