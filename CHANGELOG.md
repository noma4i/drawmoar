# Changelog

## [1.3.0] - 2026-11-03

### Added

- Voice notes with on-device Parakeet Ultra transcription, numbered marks, and dictation.
- Download progress for the voice model.
- Built-in drawing tools: pen, marker, eraser, six colors, shown as icons.
- The voice model loads in the background at app start, so transcription starts without a delay. The editor shows "Loading model" while it loads. Transcription times out after 180 seconds.

### Changed

- A voice session lasts until New: several recordings add to one note, marks keep counting, and each recording starts a new phrase.
- Switch between automatic drawing sends and voice notes in the editor.
- A voice note sends only light files: the annotated image is your crop, or the area around all marks, or the whole screen scaled to 1600 px. The full screenshot stays on the phone.

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
