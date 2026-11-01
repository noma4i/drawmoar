<p align="center">
  <img src="assets/header.png" alt="DrawMoar" width="400">
</p>

# DrawMoar

iPhone/iPad companion for [ClipMoar](https://github.com/noma4i/clipmoar): grabs the current Mac screen, lets you draw and crop on it, and copies the result to the Mac clipboard.

<p align="center">
  <img src="screenshots/editor.png" alt="DrawMoar editor" width="300">
</p>

## How it works

1. On the Mac: ClipMoar -> Settings -> Companion -> Pair device, then scan the QR code with the iPhone/iPad camera or DrawMoar.
2. Draw and crop the screenshot. Your edits are sent to the Mac clipboard automatically.
3. Press New to capture another screenshot. Browse screenshot history to return to earlier captures.

The gear icon opens settings: paired Mac (pair another, forget) and screen (Auto = screen under the cursor, or a fixed display).

Both devices must be on the same local network. Traffic uses TLS with a pre-shared key.

## Build

Requires Xcode, xcodegen and a clipmoar checkout next to this repo (`../clipmoar`, or set `CLIPMOAR_DIR`).

```bash
scripts/gen.sh
open DrawMoar.xcodeproj
```

Select your device and Run.
