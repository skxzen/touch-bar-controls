#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SPICETIFY="$(command -v spicetify || true)"
if [[ -z "$SPICETIFY" && -x "$HOME/.spicetify/spicetify" ]]; then SPICETIFY="$HOME/.spicetify/spicetify"; fi
if [[ -z "$SPICETIFY" ]]; then echo 'Spicetify est requis : https://spicetify.app'; exit 1; fi
APP="$PWD/Spotify Touch Bar.app"
[[ -x "$APP/Contents/MacOS/SpotifyTouchBar" ]] || ./build.command
CONFIG_DIR="$("$SPICETIFY" path userdata)"
mkdir -p "$CONFIG_DIR/Extensions" "$PWD/backup"
if [[ -f "$CONFIG_DIR/config-xpui.ini" ]]; then cp "$CONFIG_DIR/config-xpui.ini" "$PWD/backup/config-$(date +%Y%m%d-%H%M%S).ini"; fi
TOKEN_FILE="$APP/Contents/Resources/pairing.txt"
umask 077
if [[ ! -s "$TOKEN_FILE" ]]; then openssl rand -hex 32 > "$TOKEN_FILE"; fi
TOKEN="$(cat "$TOKEN_FILE")"
sed "s/__PAIRING_TOKEN__/$TOKEN/g" src/spotify-touchbar.js > "$CONFIG_DIR/Extensions/spotify-touchbar.js"
codesign --force --sign - "$APP"
"$SPICETIFY" config extensions spotify-touchbar.js
printf 'Application de l’extension (Spotify peut redémarrer)…\n'
"$SPICETIFY" apply
INSTALL_DEST="/Applications/Touch Bar Control.app"
ditto "$APP" "$INSTALL_DEST"
"/usr/libexec/PlistBuddy" -c "Set :CFBundleIdentifier local.spotifytouchbar" "$INSTALL_DEST/Contents/Info.plist"
codesign --force --sign - "$INSTALL_DEST"
open "$INSTALL_DEST"
printf 'Installation terminée. Le menu ♪ permet de réafficher la Touch Bar.\n'
