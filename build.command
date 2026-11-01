#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/Spotify Touch Bar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build
export MACOSX_DEPLOYMENT_TARGET=12.0
clang -fobjc-arc -c src/TouchBarBridge.m -o .build/TouchBarBridge.o
clang -fobjc-arc -c src/BrightnessBridge.m -o .build/BrightnessBridge.o
swiftc -target "$(uname -m)-apple-macosx12.0" -swift-version 5 src/main.swift src/PlayerStrip.swift src/SpotifyAccount.swift .build/TouchBarBridge.o .build/BrightnessBridge.o -import-objc-header src/TouchBarBridge.h -framework AppKit -framework Network -framework IOKit -framework Security -framework CryptoKit -o "$APP/Contents/MacOS/SpotifyTouchBar"
cp assets/Spotify_icon.svg "$APP/Contents/Resources/Spotify_icon.svg"
cp THIRD-PARTY-LICENSES.txt "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SpotifyTouchBar</string>
<key>CFBundleIdentifier</key><string>local.spotifytouchbar.build</string>
<key>CFBundleName</key><string>Touch Bar Control</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Application compilée. Lance Installer.command pour associer Spicetify.\n'
