# AGENTS.md

## Project Overview

**Vyora** is a native macOS image and video viewer built entirely in a single Swift file (`main.swift`) using SwiftUI + AppKit. It compiles via `swiftc` without an Xcode project.

## Architecture

### Single-file design
Everything lives in `main.swift` (~1400 lines), organized with `// MARK:` sections:
- **App entry** - `ImageViewerApp: App` (SwiftUI single-window scene)
- **App delegate** - `AppDelegate` handles file opens, dock icon, lifecycle
- **Model** - `ViewerModel: ObservableObject` (singleton via `.shared`) owns all state
- **Layout constants** - `Layout` enum with reserved areas
- **Window sizing** - `WindowSizer` resizes window to fit image/video
- **Views** - `ContentView`, `ImageCanvas`, `VideoCanvas`, `EmptyState`, `TopBar`, `BottomBar`, `InfoPanel`, `SettingsView`
- **Helpers** - `VisualEffectBackground`, `KeyHandlingView`, `ScrollWheelView`, `PlayerViewRepresentable`

### Key patterns
- `ViewerModel` is a singleton (`ViewerModel.shared`) so both SwiftUI and `AppDelegate` access the same state
- Image loading is async via `DispatchQueue` + `NSCache` (5 items) + neighbor prefetch using `ImageIO` for immediate bitmap decode
- Video uses `AVPlayerView` wrapped in `NSViewRepresentable` (not SwiftUI's `VideoPlayer`, which crashes on some macOS versions)
- Window resize is deferred via `DispatchQueue.main.async` to avoid crashes during SwiftUI layout passes
- Recent files use Security-Scoped Bookmarks for sandbox compatibility

### Build system
No Xcode project. `build.sh` calls `swiftc` directly, assembles `.app` bundle, generates `Info.plist`, copies to `/Applications`, registers with Launch Services.

## Coding Conventions

- All code in `main.swift` - do not split into multiple files
- Use `// MARK: -` comments to organize sections
- SwiftUI views are structs, state management via `@EnvironmentObject` pointing to `ViewerModel`
- Prefer `NSViewRepresentable` wrappers over SwiftUI-native controls when stability is needed (e.g., `AVPlayerView`, `NSVisualEffectView`)
- Keyboard shortcuts use `KeyCatcherView` (NSView subclass) with `keyCode` constants, not SwiftUI `.keyboardShortcut`

## Common Tasks

### Adding a new supported format
Add the extension to `ViewerModel.imageExts` or `ViewerModel.videoExts`.

### Adding a new keyboard shortcut
Add a `case` in the `KeyHandlingView` closure inside `ContentView.body` (search for `switch event.keyCode`).

### Adding a bottom toolbar button
Add a `ToolButton(systemName:)` call inside `BottomBar.body`.

### Adding an Info.plist key
Edit the heredoc in `build.sh` (search for `cat > "$APP_DIR/Contents/Info.plist"`).

### Rebuilding the icon
Delete `Vyora.icns` and `AppStoreIcon.png`, then run `./build.sh`. The icon is drawn programmatically in `make_icon.swift`.

## Testing

No unit tests. Manual testing:
1. `./build.sh` - should compile and install without errors
2. Open the app, drag-and-drop an image folder
3. Navigate with arrows, test zoom (scroll wheel, double-click, +/- buttons)
4. Open a video - verify playback and slideshow behavior
5. Press `I` - verify info panel with EXIF data
6. Press `⌘,` - verify Settings window
7. Right-click → Copy Image, paste elsewhere
8. Test "Open With → Vyora" from Finder
