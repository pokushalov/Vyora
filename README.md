# Vyora

A fast, lightweight image and video viewer for macOS, built with SwiftUI and AppKit.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Image viewing** — JPEG, PNG, HEIC, WebP, TIFF, GIF, BMP, RAW, ICO
- **Video playback** — MP4, MOV, M4V, MKV, WebM, AVI with native AVKit controls
- **Folder browsing** — open a file and navigate all media in the same folder with arrow keys
- **Slideshow** — auto-advance with configurable interval (1–30 s); videos play to completion before advancing
- **Zoom & pan** — scroll wheel zoom, pinch-to-zoom, drag to pan, double-click to toggle fit/1:1
- **EXIF metadata** — camera, lens, aperture, shutter speed, ISO, focal length, GPS, date taken
- **Modern UI** — translucent material background, floating controls, hover navigation chevrons
- **Drag & drop** — drop images, videos, or folders onto the window
- **Open With** — register as a viewer in Finder's "Open With" menu
- **Recent files & folders** — quick access on the start screen, persisted with Security-Scoped Bookmarks
- **Context menu** — right-click to copy image, copy file, reveal in Finder, or move to Trash
- **Single-window** — one window, no tabs, no clutter
- **Keyboard driven** — arrows, space, F (fullscreen), I (info), P (play/pause), Esc

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `←` / `→` | Previous / Next |
| `Space` | Next |
| `P` | Toggle slideshow |
| `F` | Toggle fullscreen |
| `I` | Toggle info panel |
| `⌘O` | Open file or folder |
| `⌘⌫` | Move to Trash |
| `⌘,` | Settings |
| `⌘Q` | Quit |
| Double-click | Toggle fit / actual size |
| Scroll wheel | Zoom in/out |
| Drag | Pan (when zoomed) |

## Build

Requires macOS 14+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
# Development build (arm64, installs to /Applications)
./build.sh

# Release build (universal arm64+x86_64, signed, .pkg created)
./build.sh --release
```

The build script:
1. Compiles `main.swift` via `swiftc` (no Xcode project needed)
2. Generates the app icon programmatically (`make_icon.swift`)
3. Assembles the `.app` bundle with `Info.plist` and resources
4. Copies to `/Applications/Vyora.app`
5. Registers with Launch Services for "Open With" integration
6. (Release) Code-signs with Hardened Runtime + Sandbox entitlements, creates `.pkg`

## App Store Preparation

The project includes everything needed for App Store submission:

- `Vyora.entitlements` — App Sandbox + file access + Security-Scoped Bookmarks
- `AppStoreIcon.png` — 1024x1024 icon without alpha channel
- `privacy-policy.html` — Privacy Policy template
- `Info.plist` — category, copyright, encryption declaration
- Universal binary support (arm64 + x86_64)
- Hardened Runtime enabled in release builds

When you have an Apple Developer account:
```bash
export CODESIGN_IDENTITY='3rd Party Mac Developer Application: Your Name (TEAM_ID)'
./build.sh --release
# Upload build/Vyora.pkg via Transporter.app
```

## Project Structure

```
image_viewer/
├── main.swift           # Complete application (~1400 lines)
├── build.sh             # Build, sign, install, package
├── make_icon.swift      # Programmatic icon generator
├── Vyora.entitlements   # Sandbox entitlements for App Store
├── Vyora.icns           # Generated app icon
├── AppStoreIcon.png     # 1024x1024 icon for App Store Connect
├── privacy-policy.html  # Privacy policy template
└── build/
    ├── Vyora.app        # Built application bundle
    └── Vyora.pkg        # Installer package (release only)
```

## License

MIT
