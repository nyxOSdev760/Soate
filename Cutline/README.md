# Cutline

An on-device video editor for iPhone (iPad supported). Swift, SwiftUI, AVFoundation, Core Image on Metal, Speech and Vision. iOS 17+.
No accounts, no ads, no watermark, and no network access: all processing happens on the device.

## What's in it

- **Home:** projects grid with thumbnails, sorted by last edit, with search. Long-press a project to rename, duplicate or delete it. Quick-start formats: TikTok/Reels/Shorts (9:16), Square (1:1), Instagram (4:5) and YouTube (16:9). **+** opens the photo picker and the editor starts with your clips already laid out.
- **Editor:**
  - **Preview:** tap to play or pause. Toggleable safe-area guides for each platform.
  - **Timeline:** fixed center playhead, pinch to zoom. Video, overlay, text, caption and audio lanes with thumbnails, waveforms, beat markers and keyframe diamonds.
  - **Gestures:** drag the yellow handles to trim, long-press and drag to reorder or move, double-tap to split at the playhead. Snapping to the playhead, clip edges and beats, with haptics. Magnetic timeline toggle.
  - **Context toolbar:** changes with the selection (icon and label on every tool).
- **Editing:** trim, split, delete, duplicate, reorder, freeze frame, reverse.
  - **Speed:** 0.1×–8× plus smooth speed ramps (Montage, Hero, Bullet, Flash In, Flash Out).
  - **Framing:** crop, rotate, flip, zoom and pan, fit or fill, and a blurred, black or white background.
  - **Keyframes:** position, scale, rotation and opacity, with Linear, Ease In, Ease Out, Smooth and Bounce easing.
  - **Audio:** volume up to 200%, fade in/out, mute, detach, voiceover recording, music from Files, beat detection, and noise reduction (high-pass filter + noise gate).
  - **Text:** 18 system fonts with a live-preview picker, size, color, outline, shadow, background box and alignment. In/out animations: fade, pop, slide, typewriter.
  - **Auto captions:** on-device `SFSpeechRecognizer` with word timing. Captions are editable, with Bold Center, Karaoke and Minimal styles.
  - **Overlays:** photos, emoji stickers and shapes, with size, color, opacity and keyframes.
  - **Filters:** 15 looks plus brightness, contrast, saturation, warmth, tint, sharpen, vignette, grain and blur. Apply per clip, to all clips, or to the whole video.
  - **Transitions:** cut, fade, dissolve, slide, zoom, spin and glitch, with adjustable duration.
  - **Advanced:** person background removal (Vision), stabilization (Vision image registration), green screen with adjustable color, tolerance and softness, and copy/paste of effects between clips.
- **Export:** 720p, 1080p or 4K at 24/30/60 fps, MP4 with H.264 or HEVC, a quality slider and a live size estimate. A progress screen with cancel, and background time while iOS allows it. Save to Photos or use the share sheet. Also audio-only (M4A) export and saving the current frame to Photos.
- **Safety:**
  - **Undo:** unlimited undo/redo; nothing is destructive (reverse, clean audio and freeze frame create new media files).
  - **Autosave:** at most about 0.9 s after an edit, and immediately when the app goes to the background. The playhead, zoom and selection are restored when you reopen.
  - **Recovery:** a damaged `project.json` is restored from `project.json.bak`.
  - **Clear messages:** for unsupported formats, low storage, missing media and denied permissions.

## Architecture

```
Cutline/
  App/CutlineApp.swift
  Models/       Project (+ clips, text, overlays, captions), Effects (filters, crop, speed, transitions), Basics (colors, fonts, keyframes)
  Services/     ProjectStore, AutosaveService, ProjectUndoManager, MediaImportService (+ proxies), ThumbnailCache,
                WaveformGenerator (+ beat detection), CaptionService, ExportService, ClipProcessing
                (ReverseService, StabilizationService, NoiseReductionService), VoiceoverRecorder, Haptics
  Rendering/    CompositionBuilder (AVMutableComposition, A/B tracks, speed segments, audio mix, BlankVideo),
                CutlineCompositor (custom AVVideoCompositing), FrameRenderer (per-frame pipeline),
                FilterLibrary (looks, adjustments, chroma key, transitions), TextRenderer (titles, captions, stickers, shapes)
  ViewModels/   EditorViewModel (+Processing), PlaybackController, ExportViewModel, HomeViewModel
  Views/        Home, Editor (preview, transport, timeline, context toolbar), Sheets, Components
```

- **MVVM:** `EditorViewModel` is the single source of truth. Every edit goes through `mutate`, which records an undo snapshot, re-lays out the main track, autosaves and rebuilds the preview off the main thread.
- **Playback:** the preview only replaces the `AVPlayerItem` when timing changes. Effect, text and overlay edits just swap the video composition, so there's no flicker.
- **Transitions:** main clips alternate between two video tracks, so a transition overlaps the outgoing clip with a pre-roll of the next. It uses the clip's real handles when available, otherwise a held first frame.
- **Proxies:** videos larger than 1920 px get a 720p proxy that's used for editing. Export always renders the originals.

## Build and run

1. Use Xcode 16 or later on a Mac.
2. Open `Cutline/Cutline.xcodeproj`.
3. Select the **Cutline** target ▸ **Signing & Capabilities**. Choose your Team (a free Apple ID works) and change the bundle ID from `com.example.cutline` to something unique.
4. Pick an iPhone and press **⌘R**. Speech recognition and person segmentation need a real device for best results.

After adding or removing source files, regenerate the project with `cd Cutline && python3 scripts/generate_xcodeproj.py`.

Unsigned command-line build, which is what CI does:

```sh
xcodebuild -project Cutline/Cutline.xcodeproj -scheme Cutline -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
mkdir Payload && cp -R build/Build/Products/Release-iphoneos/Cutline.app Payload/ && zip -qry Cutline-unsigned.ipa Payload
```

## Install on your iPhone

1. Connect the iPhone, unlock it and trust the computer.
2. Turn on **Settings ▸ Privacy & Security ▸ Developer Mode** and restart.
3. In Xcode, set your Team and a unique bundle ID, choose your iPhone as the destination and press **⌘R**.
4. The first time, trust your developer profile in **Settings ▸ General ▸ VPN & Device Management**.

Free-account installs expire after 7 days; run from Xcode again to refresh. The unsigned `Cutline/dist/Cutline-unsigned.ipa` must be re-signed with your own certificate before it can be installed.

## Known limits

- Reversed clips have no audio. Detach the audio first if you need it.
- Detach Audio and Clean Audio on a video clip need the clip at 1× speed.
- Stabilization corrects translation (up/down/left/right shake), not rotation.
- Background removal and green screen are applied per frame, so playback with them on can drop frames on older devices. Export is unaffected.
- Background export only continues for the time iOS grants (typically under a minute). Keep Cutline open for long exports.
