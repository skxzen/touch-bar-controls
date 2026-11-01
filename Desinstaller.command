#!/bin/bash
set -euo pipefail
SPICETIFY="$(command -v spicetify || true)"
if [[ -z "$SPICETIFY" && -x "$HOME/.spicetify/spicetify" ]]; then SPICETIFY="$HOME/.spicetify/spicetify"; fi
[[ -n "$SPICETIFY" ]] || { echo 'Spicetify introuvable'; exit 1; }
"$SPICETIFY" config extensions spotify-touchbar.js-
"$SPICETIFY" apply
printf 'Extension désactivée. Quitte Spotify Touch Bar via son menu ♪.\n'
