# Touch Bar Control

Touch Bar Control is a native macOS companion for MacBook Pro models with a Touch Bar. It combines Spotify controls, Touch Bar brightness, and automatic display synchronization without BetterTouchTool.

## Features

- Automatic Touch Bar controls while Spotify is playing.
- Previous, play/pause, next, artwork, title, artist, and interactive progress.
- Like, shuffle, and repeat controls.
- Optional Spotify Connect support for playback started on a phone.
- OAuth Authorization Code with PKCE; tokens are stored in the macOS Keychain.
- Manual Touch Bar brightness and automatic synchronization with the main display.
- OLED perceptual correction: the Touch Bar defaults to 80% of the main display level.
- Menu bar companion that stays active while its window is closed.
- Built-in localization: French on French systems, English otherwise.

## Compatibility

- macOS 12 Monterey or later.
- MacBook Pro with a Touch Bar.
- Universal binary: Apple Silicon (arm64) and Intel (x86_64).
- Spotify is required for local playback control.

## Install a release

1. Download `Touch-Bar-Control-macos-universal.zip` from the [GitHub releases](https://github.com/lixteech/touch-bar-controls/releases).
2. Extract it and move **Touch Bar Control.app** to `/Applications`.
3. If macOS asks for confirmation, use Finder: right-click the app and choose **Open**.
4. Run `Installer.command` to install the Spicetify extension.

## Build from source

Requirements: Xcode Command Line Tools, macOS 12+, and Node.js for JavaScript tests.

```bash
git clone https://github.com/lixteech/touch-bar-controls.git
cd touch-bar-controls
./build.command
./Installer.command
```

`build.command` compiles both arm64 and x86_64 and creates a universal app bundle. Run `Desinstaller.command` to remove only the Spicetify extension.

## Spotify Connect

Account linking is optional. It allows the Mac to display and control playback started on a phone or another Spotify Connect device, even when Spotify is closed on the Mac. The local OAuth redirect URI is:

```text
http://127.0.0.1:43822/callback
```

Never publish access tokens, refresh tokens, or `pairing.txt`.

## Project layout

- `src/spotify-touchbar.js`: Spicetify extension and player commands.
- `src/main.swift` and `src/PlayerStrip.swift`: macOS companion and Touch Bar UI.
- `src/SpotifyAccount.swift`: Spotify OAuth PKCE and remote playback state.
- `src/Localization.swift`: system-language selection for the UI.
- `src/BrightnessBridge.m`: macOS brightness bridge.
- `src/TouchBarBridge.m`: system Touch Bar presentation.

## Tests

```bash
node tests/extension.test.cjs
swiftc tests/slider-render.swift -o /tmp/slider-render
/tmp/slider-render
```

## Troubleshooting

- If the Touch Bar is missing, make sure the companion is running and Spotify is playing.
- If Spotify is disconnected, open Spotify and re-run `Installer.command` after Spicetify updates.
- If the Touch Bar is too bright, disable synchronization or adjust the slider; the default OLED correction is 80%.
- Remote playback is refreshed about every five seconds.
- The release is locally signed but not notarized by Apple.

## Limitations and credits

The global Touch Bar presentation uses the private `presentSystemModalTouchBar:systemTrayItemIdentifier:` API and may change with macOS. Third-party components and licenses are listed in [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt). Spotify and its logo are trademarks of Spotify AB.
