# DrawMoar

iPhone/iPad companion for [ClipMoar](https://github.com/noma4i/clipmoar): grabs the current Mac screen, lets you draw and crop on it, and copies the result to the Mac clipboard.

## How it works

1. On the Mac: ClipMoar -> Settings -> Companion -> enable, grant Screen Recording, press Pair device.
2. On the iPhone/iPad: open DrawMoar, pick the Mac, enter the 6-digit PIN.
3. Every launch opens straight into a fresh screenshot. Draw with PencilKit, crop, press Copy to Mac, then paste on the Mac.

The gear icon opens settings: paired Mac (pair another, forget) and screen (Auto = screen under the cursor, or a fixed display).

Both devices must be on the same local network. Traffic uses TLS with a pre-shared key.

## Build

Requires Xcode, xcodegen and a clipmoar checkout next to this repo (`../clipmoar`, or set `CLIPMOAR_DIR`).

```bash
scripts/gen.sh
open DrawMoar.xcodeproj
```

Select your device and Run.
