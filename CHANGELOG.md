# Changelog

## [1.3.0] - 2026-11-03

### Added

- Voice notes with on-device Parakeet Ultra transcription, numbered marks, and dictation.
- Download progress for the voice model.
- Voice engine choice in Settings: Apple Speech, Parakeet Ultra, or Whisper Small (quantized 216 MB). DrawMoar now requires iOS 26.
- Every voice recording is stored on the phone as AAC with a timeline of the session, so a past session keeps its audio, words, and stroke timing. Selecting a history entry continues its voice session. Audio is never sent to the Mac.
- Replay of a past voice session: strokes are drawn again in time with the audio, marks appear when they were made, and the transcript shows time pills you can tap to seek. Pauses longer than 3 seconds are shortened to 1 second. Open it from History (swipe or long-press) or the editor toolbar.
- Built-in drawing tools: pen, marker, eraser, six colors, shown as icons.
- The voice model loads in the background at app start, so transcription starts without a delay. The first launch after an install or update prepares the model for about a minute, later launches are instant. The microphone shows a small spinner while the model prepares, and Settings shows "Preparing...". Recording works meanwhile. Transcription times out after 180 seconds.
- Redo next to Undo: one ordered history covers strokes and crop changes, and Redo appears after an Undo.

### Changed

- The editor controls live in the system toolbar of a navigation stack: on a phone they sit in the top bar with Draw/Note as text and titles on New, Crop, Window, and Replay. On an unfolded foldable iPhone in landscape the system places them vertically beside the status items, as icons. Crop, Window, and History move to the overflow menu first. The status capsule has its own slot at the end of the tool row and no longer overlaps the width dots.
- The mark number on the note image is a blue circle with a white digit, sized to 3.5% of the image long side (at least 28 px), so it stays readable on large screens.
- Connecting to the Mac races Bonjour, Tailscale, and Remote address routes at once and picks the best one (local network wins when it is nearly as fast). When Wi-Fi or the network changes, DrawMoar picks a new route by itself. Settings shows the route in use.
- A voice session lasts until New: several recordings add to one note, marks keep counting, and each recording starts a new phrase.
- Switch between automatic drawing sends and voice notes in the editor.
- A voice note sends only light files: the annotated image is your crop, or the area around all marks, or the whole screen scaled to 1600 px. The full screenshot stays on the phone.

### Fixed

- The tool row stays on one line down to 588 pt wide (for example the unfolded Duo in portrait) with the buttons shrinking evenly, and the Draw/Note switch stays visible there with Undo, Redo, and New: between 588 and 858 pt it sits next to History and Replay moves to the overflow menu; no empty toolbar placeholder is drawn.
- The editor toolbar never changes its items or their positions: Mic, Replay, and Redo are always there and only turn on or off, the mic shows a small spinner in its own slot instead of a large one, and Crop and Window show Cancel and Done in a pill over the canvas instead of replacing the toolbar.
- The Draw/Note switch is larger (two side-by-side segments, each at least 44 pt high and 72 pt wide, always horizontal and centered on the tool row), and when the screen is wide enough it sits on one line with the tools, colors, widths, and status.
- The transcript on the phone shows only the time and the phrase, without mark numbers.
- The tool row fits narrow screens: it splits into two rows (tools and colors, then widths and the status capsule) when one row does not fit, and the status capsule never covers a color or width button. Draw/Note shows the words "Draw" and "Note" in every layout.
- Folding, unfolding, and rotating the device no longer flashes the two-row tool layout, no longer opens or closes the History sheet by itself, and keeps the drawing, tool, mode, crop, and Replay state.
- Sending to the Mac no longer stops after Replay, Settings, History, an alert, or leaving the app: a pen stroke whose touch was cancelled is always ended, so auto-send in Draw mode and voice notes in Note mode resume and the status goes back to "Sending…" and "On Mac ✓".
- Replay starts playing from the beginning as soon as it opens, and closing it stops the audio and releases the audio session so the next recording works.
- Connecting through Tailscale or a Remote address also tries the default port 47823, so a pairing that stored a wrong port still connects.
- Voice notes no longer contain engine markers such as [BLANK_AUDIO] or [MUSIC]; empty phrases are not created.
- A recording with no sound shows "No audio recorded. Check the microphone." instead of sending an empty note. Each recording starts a fresh audio engine after the audio session is activated in normal input mode.

## [1.2.0] - 2026-11-02

### Added
- Tailscale connections and a Remote address setting

### Fixed
- Connection errors show the cause for each route
- Mac not found immediately after launch or return
- Connection attempts no longer hang

## [1.1.0] - 2026-11-02

### Added
- Share images to DrawMoar and send them to the Mac immediately

## [1.0.0] - 2026-11-01

### Added
- QR pairing with ClipMoar 1.8.0 or newer
- Mac screen capture with Auto or fixed display selection
- PencilKit drawing with line widths and image cropping
- Window selection with tap, repeated tap for deeper parts, and double tap to confirm
- Automatic sending to the Mac clipboard 2.5 seconds after the last edit
- Screenshot history with thumbnails and swipe to delete
- Storage size, delete all, and Day, Week, Month, or Forever retention settings
- System, Light, and Dark appearance settings
