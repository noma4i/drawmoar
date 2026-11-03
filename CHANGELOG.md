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

- Editor controls sit on one aligned grid: icons only with 44 pt slots in groups with hairline dividers, a fixed Draw/Note pill, and the status in a small capsule at the end of the tool row (under New in the trailing rail).
- Top toolbar buttons have 44 pt touch targets with wider spacing. On a narrow phone, Settings, History, Crop, Window, and New move into a More menu. On a wide landscape screen the toolbar moves to a trailing rail and stays inside the safe area.
- The mark number on the note image is a blue circle with a white digit, sized to 3.5% of the image long side (at least 28 px), so it stays readable on large screens.
- Connecting to the Mac races Bonjour, Tailscale, and Remote address routes at once and picks the best one (local network wins when it is nearly as fast). When Wi-Fi or the network changes, DrawMoar picks a new route by itself. Settings shows the route in use.
- A voice session lasts until New: several recordings add to one note, marks keep counting, and each recording starts a new phrase.
- Switch between automatic drawing sends and voice notes in the editor.
- A voice note sends only light files: the annotated image is your crop, or the area around all marks, or the whole screen scaled to 1600 px. The full screenshot stays on the phone.

### Fixed

- Connecting through Tailscale or a Remote address also tries the default port 47823, so a pairing that stored a wrong port still connects.

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
