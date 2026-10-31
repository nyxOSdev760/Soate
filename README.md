# Slate

A simple, solo whiteboard app for iPhone and iPad. Swift, SwiftUI, iOS 17+.
No accounts, no networking. Everything is stored locally.

## Features

- **Home:** a grid of board thumbnails sorted by last edit. Tap **+** to create a board. Touch and hold a board to rename, duplicate or delete it.
- **Infinite canvas:** pan with two fingers and pinch to zoom. The exact viewport is restored when you reopen a board.
- **Objects:**
  - **Text:** tap to add, double-tap to edit. You can set the font, size, bold, italic, alignment and color.
  - **Images:** add from the photo library or camera. They're downscaled to 2048 px and compressed on import. You can move, resize, rotate and set opacity.
  - **Sticky notes:** use the theme's palette and hold editable text.
  - **Freehand:** pen, highlighter and stroke eraser, with Apple Pencil pressure. Double-tap the Pencil to toggle the eraser.
- **Interaction:**
  - Select, lasso, and two-finger tap to add or remove objects from the selection.
  - Move, resize with corner handles, rotate (snaps every 45°), duplicate and delete.
  - Bring forward, send backward, lock and unlock.
  - Unlimited undo and redo for the session.
- **Themes:** Dark (default), Light, Blackboard, Blueprint, Paper, Midnight and Graphite. Each board has its own theme and a background pattern (none, dots, grid or lines). Colors set to the theme default ("A" swatch) and sticky colors adapt when the theme changes.
- **Export:** export a board or the current selection as PNG, JPEG or PDF through the share sheet.
- **Autosave:** saves are debounced to at most about 0.9 s after a change and are written immediately when the app goes to the background. There is no save button.

## Storage

Everything lives in `Documents/Slate/`:

| Path | Contents |
| --- | --- |
| `Boards/<id>.json` | one JSON document per board |
| `Boards/<id>.json.bak` | the last copy that opened cleanly, used for corrupted-file recovery |
| `Images/<id>.jpg` / `.png` | imported images, referenced from boards by ID |
| `Thumbnails/<id>.jpg` | home screen previews |
| `Recovered/` | damaged files moved aside instead of deleted |

Damaged boards are restored from their backup, and damaged objects inside an otherwise valid board are skipped. When storage is low, saving pauses and a banner appears; your changes stay in memory and save once space is free.

**iCloud:** true iCloud Drive sync needs an iCloud container entitlement, which requires a paid developer team and signing setup, so it is not enabled. Instead, the Documents folder is exposed in the **Files** app (On My iPhone ▸ Slate), and it is included in normal iCloud device backups.

## Project layout

```
Slate.xcodeproj/                 generated Xcode project + shared scheme
Slate/
  App/SlateApp.swift
  Models/        Board, BoardObject (+Geometry), Theme, Viewport, FontFamily, ColorModels
  Services/      BoardStore, ImageStore, AutosaveService, BoardUndoManager,
                 ThemeManager, ExportService, Haptics
  Rendering/     CanvasRenderer (Core Graphics, shared by canvas/export/thumbnails)
  ViewModels/    BoardViewModel, HomeViewModel
  Views/Home/    HomeView, BoardCardView
  Views/Board/   BoardView, CanvasView (UIKit canvas), MainToolbarView,
                 InspectorView, TextEditingPanel, ThemePickerView, FontPickerView
  Views/Components/ ColorSwatchRow, SystemPickers (share sheet, camera)
  Utilities/Geometry.swift
  Info.plist, Assets.xcassets
scripts/generate_xcodeproj.py    regenerates the .xcodeproj after adding files
scripts/make_icon.py             regenerates the app icon
.github/workflows/build-ipa.yml  CI build of the unsigned IPA
dist/Slate-unsigned.ipa          unsigned build produced by CI
```

## Build and run

1. Install Xcode 16 or later on a Mac.
2. Open `Slate.xcodeproj`.
3. Select the **Slate** target ▸ **Signing & Capabilities**. Choose your **Team** (a free Apple ID personal team works) and change the bundle identifier from `com.example.slate` to something unique, for example `com.yourname.slate`.
4. Pick an iPhone simulator and press **⌘R**.

Command-line unsigned build, which is what CI runs:

```sh
xcodebuild -project Slate.xcodeproj -scheme Slate -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO clean build
mkdir Payload && cp -R build/Build/Products/Release-iphoneos/Slate.app Payload/
zip -qry Slate-unsigned.ipa Payload
```

## Install on your own iPhone with Xcode

1. Connect the iPhone with a cable, unlock it and tap **Trust This Computer**.
2. On the iPhone, turn on **Settings ▸ Privacy & Security ▸ Developer Mode**, then restart when prompted.
3. In Xcode, complete step 3 of *Build and run* (Team and a unique bundle ID).
4. Choose your iPhone as the run destination in the toolbar and press **⌘R**.
5. The first time you install with a free personal team, open **Settings ▸ General ▸ VPN & Device Management** on the iPhone, tap your developer profile and tap **Trust**. Then launch Slate.

Apps signed with a free personal team expire after 7 days; run again from Xcode to refresh. The unsigned `.ipa` in `dist/` can't be installed as-is. You must re-sign it, for example with Xcode or a signing tool, using your own certificate.
