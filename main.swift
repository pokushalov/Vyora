import SwiftUI
import AppKit
import AVKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - App entry

@main
struct ImageViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ViewerModel.shared

    var body: some Scene {
        Window("Vyora", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 480)
                .onAppear { NSWindow.allowsAutomaticWindowTabbing = false }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            // Drop "New Window" entirely — Vyora is single-window.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openPanel() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .sidebar) {
                Button("Next") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Previous") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @EnvironmentObject var model: ViewerModel
    private let privacyURL = "https://example.com/vyora/privacy"

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environmentObject(model)
                .tabItem { Label("General", systemImage: "gear") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420, height: 280)
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var model: ViewerModel
    private let presets: [TimeInterval] = [1, 2, 3, 5, 8, 15, 30]

    var body: some View {
        Form {
            Picker("Slideshow interval", selection: $model.slideshowInterval) {
                ForEach(presets, id: \.self) { value in
                    Text(value < 60 ? "\(Int(value)) seconds" : "\(Int(value / 60)) min")
                        .tag(value)
                }
            }
            .pickerStyle(.menu)

            Divider()

            HStack {
                Text("Recent files: \(model.recentFiles.count), folders: \(model.recentFolders.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Recents") {
                    model.clearRecents()
                }
            }
        }
        .padding(20)
    }
}

struct AboutSettingsTab: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    private let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    private let privacyURL = "https://example.com/vyora/privacy"

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("Vyora")
                .font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("A lightweight image & video viewer for macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Link("Privacy Policy", destination: URL(string: privacyURL)!)
                .font(.callout)

            Text("© 2026 Vyora. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Don't quit the process when the window is closed — it stays in the
    /// background so subsequent Finder "Open With" calls reuse the same
    /// instance instead of spawning a new one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// When the dock icon is clicked while the window is hidden, bring it
    /// back instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    /// Files dropped on the dock icon or sent via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let model = ViewerModel.shared

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           isDir.boolValue {
            model.loadFolder(url)
        } else {
            model.load(url: url)
        }

        // Bring the existing window to the front instead of opening a new one.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Model

final class ViewerModel: ObservableObject {
    static let shared = ViewerModel()

    @Published var files: [URL] = []
    @Published var index: Int = 0
    @Published var image: NSImage? = nil
    @Published var videoURL: URL? = nil
    @Published var recentFiles: [URL] = []
    @Published var recentFolders: [URL] = []
    @Published var isPlaying: Bool = false
    @Published var zoomScale: CGFloat = 1.0
    @Published var slideshowInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(slideshowInterval, forKey: "slideshowInterval")
            if isPlaying { restartSlideshow() }
        }
    }

    static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif",
        "heic", "heif", "webp", "ico", "icns", "raw"
    ]
    static let videoExts: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "mpg", "mpeg"
    ]
    static func isVideo(_ url: URL) -> Bool {
        videoExts.contains(url.pathExtension.lowercased())
    }
    static func isImage(_ url: URL) -> Bool {
        imageExts.contains(url.pathExtension.lowercased())
    }

    private let maxRecents = 5
    private let recentFilesKey = "recentFiles"
    private let recentFoldersKey = "recentFolders"

    // Async load + cache
    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 5
        return c
    }()
    private let loadQueue = DispatchQueue(label: "imageviewer.load",
                                          qos: .userInitiated,
                                          attributes: .concurrent)
    private var loadToken: URL?
    private var slideshowTimer: Timer?

    // Video playback owned by the model so it can observe end-of-video
    // and advance the slideshow only after the video has actually finished.
    let player = AVPlayer()
    private var videoEndObserver: NSObjectProtocol?

    init() {
        let stored = UserDefaults.standard.double(forKey: "slideshowInterval")
        self.slideshowInterval = stored > 0 ? stored : 4.0
        loadRecents()
    }

    var currentURL: URL? {
        guard files.indices.contains(index) else { return nil }
        return files[index]
    }

    var displayName: String { currentURL?.lastPathComponent ?? "No image" }
    var counterText: String {
        files.isEmpty ? "" : "\(index + 1) / \(files.count)"
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose an image or video, or a folder to browse all its media."
        panel.prompt = "Open"
        if #available(macOS 11, *) {
            panel.allowedContentTypes = [.image, .movie, .folder]
        } else {
            panel.allowedFileTypes = Array(Self.imageExts) + Array(Self.videoExts)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           isDir.boolValue {
            loadFolder(url)
        } else {
            load(url: url)
        }
    }

    func load(url: URL) {
        let folder = url.deletingLastPathComponent()
        let images = Self.images(in: folder)

        files = images
        index = images.firstIndex(of: url) ?? 0
        loadCurrent()
        pushRecent(file: url)
        pushRecent(folder: folder)
    }

    func loadFolder(_ folder: URL) {
        let images = Self.images(in: folder)
        guard let first = images.first else { return }
        files = images
        index = 0
        loadCurrent()
        pushRecent(file: first)
        pushRecent(folder: folder)
    }

    static func images(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: folder,
                                                    includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { isImage($0) || isVideo($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Recents

    private func pushRecent(file url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > maxRecents { recentFiles = Array(recentFiles.prefix(maxRecents)) }
        saveRecents()
    }

    private func pushRecent(folder url: URL) {
        recentFolders.removeAll { $0 == url }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > maxRecents { recentFolders = Array(recentFolders.prefix(maxRecents)) }
        saveRecents()
    }

    func clearRecents() {
        recentFiles.removeAll()
        recentFolders.removeAll()
        saveRecents()
    }

    /// Load recents from Security-Scoped Bookmarks stored in UserDefaults.
    /// Falls back to plain paths for backwards compat with pre-sandbox data.
    private func loadRecents() {
        let d = UserDefaults.standard
        recentFiles  = Self.resolveBookmarks(d.array(forKey: recentFilesKey)  as? [Data] ?? [])
        recentFolders = Self.resolveBookmarks(d.array(forKey: recentFoldersKey) as? [Data] ?? [])
    }

    /// Save recents as Security-Scoped Bookmark Data so they survive sandbox
    /// restarts — plain file paths lose their access token after relaunch.
    private func saveRecents() {
        let d = UserDefaults.standard
        d.set(Self.makeBookmarks(recentFiles),  forKey: recentFilesKey)
        d.set(Self.makeBookmarks(recentFolders), forKey: recentFoldersKey)
    }

    private static func makeBookmarks(_ urls: [URL]) -> [Data] {
        urls.compactMap { url in
            try? url.bookmarkData(options: .withSecurityScope,
                                  includingResourceValuesForKeys: nil,
                                  relativeTo: nil)
        }
    }

    private static func resolveBookmarks(_ datas: [Data]) -> [URL] {
        datas.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { return nil }
            guard url.startAccessingSecurityScopedResource() else { return nil }
            // Re-bookmark if stale (the old data still resolves but should be refreshed).
            // We don't stop accessing here — the resource stays accessible for the app lifetime.
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func next() {
        guard !files.isEmpty else { return }
        index = (index + 1) % files.count
        loadCurrent()
        if isPlaying { restartSlideshow() }
    }

    func previous() {
        guard !files.isEmpty else { return }
        index = (index - 1 + files.count) % files.count
        loadCurrent()
        if isPlaying { restartSlideshow() }
    }

    // MARK: Slideshow

    func toggleSlideshow() {
        if isPlaying { stopSlideshow() } else { startSlideshow() }
    }

    func startSlideshow() {
        guard files.count > 1 else { return }
        isPlaying = true
        restartSlideshow()
    }

    func stopSlideshow() {
        isPlaying = false
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    private func restartSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        // Don't run a timer while a video is playing — its end-of-play
        // observer will advance the slideshow when the clip actually finishes.
        guard isPlaying,
              let url = currentURL,
              !Self.isVideo(url)
        else { return }

        slideshowTimer = Timer.scheduledTimer(withTimeInterval: slideshowInterval,
                                              repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard !self.files.isEmpty else { return }
            self.index = (self.index + 1) % self.files.count
            self.loadCurrent()
        }
    }

    func zoomIn()  { zoomScale = min(zoomScale * 1.25, 8.0) }
    func zoomOut() { zoomScale = max(zoomScale / 1.25, 1.0) }
    func resetZoom() { zoomScale = 1.0 }

    private func loadCurrent() {
        guard let url = currentURL else {
            image = nil; videoURL = nil; loadToken = nil
            tearDownPlayback()
            return
        }
        loadToken = url
        zoomScale = 1.0

        if Self.isVideo(url) {
            image = nil
            videoURL = url

            // Replace player item and start playback.
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            player.seek(to: .zero)
            player.play()

            // Observe end-of-playback so the slideshow advances only after
            // the video has fully played, not on the still-image interval.
            removeVideoEndObserver()
            videoEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                if self.isPlaying {
                    self.next()
                }
            }

            // Pause the slideshow timer while a video is playing — it will
            // be restarted by the next() call once the video ends and we
            // land on an image again.
            slideshowTimer?.invalidate()
            slideshowTimer = nil

            // Resize window to video natural size — defer past the current
            // SwiftUI update so the AVPlayerView is built before we animate.
            let asset = AVURLAsset(url: url)
            if let track = asset.tracks(withMediaType: .video).first {
                let s = track.naturalSize.applying(track.preferredTransform)
                let size = NSSize(width: abs(s.width), height: abs(s.height))
                DispatchQueue.main.async { WindowSizer.fit(to: size) }
            }
            prefetchNeighbors()
            return
        }

        // Leaving video → tear down player so audio doesn't bleed through.
        videoURL = nil
        tearDownPlayback()

        // Show cached image immediately if available — zero-latency navigation.
        if let cached = cache.object(forKey: url as NSURL) {
            image = cached
            DispatchQueue.main.async { WindowSizer.fit(to: cached.size) }
            prefetchNeighbors()
            return
        }

        loadQueue.async { [weak self] in
            guard let self = self else { return }
            let img = Self.fastLoad(url: url)
            DispatchQueue.main.async {
                guard self.loadToken == url else { return } // user moved on
                if let img = img {
                    self.cache.setObject(img, forKey: url as NSURL)
                    self.image = img
                    DispatchQueue.main.async { WindowSizer.fit(to: img.size) }
                }
                self.prefetchNeighbors()
            }
        }
    }

    private func prefetchNeighbors() {
        guard files.count > 1 else { return }
        let next = files[(index + 1) % files.count]
        let prev = files[(index - 1 + files.count) % files.count]
        for url in [next, prev]
            where Self.isImage(url) && cache.object(forKey: url as NSURL) == nil {
            loadQueue.async { [weak self] in
                guard let self = self else { return }
                if self.cache.object(forKey: url as NSURL) != nil { return }
                if let img = Self.fastLoad(url: url) {
                    DispatchQueue.main.async {
                        self.cache.setObject(img, forKey: url as NSURL)
                    }
                }
            }
        }
    }

    private func tearDownPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeVideoEndObserver()
    }

    private func removeVideoEndObserver() {
        if let obs = videoEndObserver {
            NotificationCenter.default.removeObserver(obs)
            videoEndObserver = nil
        }
    }

    /// Decode using ImageIO so the bitmap is materialised on the loader thread,
    /// not lazily on the main thread the first time it is drawn.
    static func fastLoad(url: URL) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
            return NSImage(contentsOf: url) // fallback
        }
        let size = NSSize(width: cg.width, height: cg.height)
        return NSImage(cgImage: cg, size: size)
    }

    // MARK: Clipboard / Finder

    func copyCurrentImage() {
        guard let url = currentURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Write both the file URL (for pasting into Finder/Mail) and the
        // image bitmap (for pasting into image editors / chats) in one go.
        var items: [NSPasteboardWriting] = [url as NSURL]
        if let img = NSImage(contentsOf: url) {
            items.append(img)
        }
        pb.writeObjects(items)
    }

    func copyCurrentFileURL() {
        guard let url = currentURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    func revealCurrentInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Trash

    func moveCurrentToTrash() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self, error == nil else { return }
                self.cache.removeObject(forKey: url as NSURL)
                let removedIndex = self.index
                self.files.removeAll { $0 == url }
                if self.files.isEmpty {
                    self.index = 0
                    self.image = nil
                    self.loadToken = nil
                    self.stopSlideshow()
                    return
                }
                self.index = min(removedIndex, self.files.count - 1)
                self.loadCurrent()
            }
        }
    }

    // MARK: Info

    func currentInfo() -> ImageInfo? {
        guard let url = currentURL else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int ?? 0
        let date = attrs?[.modificationDate] as? Date

        var pixelW = 0
        var pixelH = 0
        var exif = ExifInfo()
        var duration: Double? = nil

        if Self.isVideo(url) {
            let asset = AVURLAsset(url: url)
            if let track = asset.tracks(withMediaType: .video).first {
                let s = track.naturalSize.applying(track.preferredTransform)
                pixelW = Int(abs(s.width))
                pixelH = Int(abs(s.height))
            }
            duration = CMTimeGetSeconds(asset.duration)
        } else if let image = image {
            pixelW = Int(image.representations.first?.pixelsWide ?? Int(image.size.width))
            pixelH = Int(image.representations.first?.pixelsHigh ?? Int(image.size.height))
            exif = Self.readExif(url: url)
        } else {
            return nil
        }

        return ImageInfo(
            name: url.lastPathComponent,
            path: url.path,
            pixelWidth: pixelW,
            pixelHeight: pixelH,
            byteSize: size,
            modified: date,
            ext: url.pathExtension.uppercased(),
            duration: duration,
            exif: exif
        )
    }

    static func readExif(url: URL) -> ExifInfo {
        var info = ExifInfo()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return info }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux  = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps  = props[kCGImagePropertyGPSDictionary]    as? [CFString: Any] ?? [:]

        let make  = (tiff[kCGImagePropertyTIFFMake]  as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model = model, !model.isEmpty {
            if let make = make, !make.isEmpty, !model.localizedCaseInsensitiveContains(make) {
                info.camera = "\(make) \(model)"
            } else {
                info.camera = model
            }
        }

        info.lens = (exif[kCGImagePropertyExifLensModel] as? String)
            ?? (aux[kCGImagePropertyExifAuxLensModel]    as? String)

        if let f = exif[kCGImagePropertyExifFNumber] as? Double, f > 0 {
            info.aperture = String(format: "f/%.1f", f)
        }

        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            if t >= 1 {
                info.shutter = String(format: "%.1f s", t)
            } else {
                info.shutter = "1/\(Int(round(1 / t))) s"
            }
        }

        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso0 = isos.first {
            info.iso = "ISO \(iso0)"
        }

        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double, fl > 0 {
            info.focalLength = "\(Int(round(fl))) mm"
        }

        if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = parser.date(from: dt) {
                let out = DateFormatter()
                out.dateStyle = .medium
                out.timeStyle = .short
                info.dateTaken = out.string(from: d)
            } else {
                info.dateTaken = dt
            }
        }

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef]  as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            info.gps = String(format: "%.4f° %@, %.4f° %@", lat, latRef, lon, lonRef)
        }

        return info
    }
}

struct ExifInfo {
    var camera: String?
    var lens: String?
    var aperture: String?
    var shutter: String?
    var iso: String?
    var focalLength: String?
    var dateTaken: String?
    var gps: String?

    var hasAny: Bool {
        camera != nil || lens != nil || aperture != nil || shutter != nil ||
        iso != nil || focalLength != nil || dateTaken != nil || gps != nil
    }
}

struct ImageInfo {
    let name: String
    let path: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteSize: Int
    let modified: Date?
    let ext: String
    let duration: Double?
    let exif: ExifInfo

    var durationString: String? {
        guard let d = duration, d.isFinite, d > 0 else { return nil }
        let total = Int(d.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }
    var dateString: String {
        guard let modified = modified else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: modified)
    }
    var dimensionsString: String { "\(pixelWidth) × \(pixelHeight)" }

    /// Compact one-liner combining shutter / aperture / ISO / focal.
    var exposureLine: String? {
        let parts = [exif.shutter, exif.aperture, exif.iso, exif.focalLength].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

// MARK: - Layout constants

enum Layout {
    static let topReserve: CGFloat = 56     // space for the title pill
    static let bottomReserve: CGFloat = 76  // space for the bottom toolbar
    static let sideReserve: CGFloat = 52    // breathing room + nav chevrons
    static let navButtonSize: CGFloat = 32
}

// MARK: - Window sizing

enum WindowSizer {
    /// Resize the key window so its content area fits the image while staying
    /// on-screen. Preserves aspect ratio and centers around the current frame.
    static func fit(to imageSize: NSSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        let visible = screen.visibleFrame
        // Leave a comfortable margin around the window.
        let maxW = visible.width  - 80
        let maxH = visible.height - 80

        // Account for the chrome around the content view (title bar etc.)
        // and the space we reserve for the floating top/bottom bars.
        let chromeH = window.frame.height - window.contentLayoutRect.height
        let reservedH = Layout.topReserve + Layout.bottomReserve
        let reservedW = Layout.sideReserve * 2

        // Available area for the actual image, on this screen.
        let availW = maxW - reservedW
        let availH = maxH - chromeH - reservedH

        // Fit image into available area, preserving aspect ratio.
        let scale = min(availW / imageSize.width,
                        availH / imageSize.height,
                        1.0) // never upscale beyond native size
        let drawW = imageSize.width  * scale
        let drawH = imageSize.height * scale

        var contentW = max(drawW + reservedW, 480)
        var contentH = max(drawH + reservedH, 360)

        // If we hit the minimums, re-cap to the available area.
        contentW = min(contentW, maxW)
        contentH = min(contentH, maxH - chromeH)

        let newWindowW = contentW
        let newWindowH = contentH + chromeH

        // Center new frame around the current center.
        let oldFrame = window.frame
        let centerX = oldFrame.midX
        let centerY = oldFrame.midY
        var newFrame = NSRect(
            x: centerX - newWindowW / 2,
            y: centerY - newWindowH / 2,
            width: newWindowW,
            height: newWindowH
        )

        // Constrain to the visible frame of the screen.
        if newFrame.maxX > visible.maxX { newFrame.origin.x = visible.maxX - newFrame.width }
        if newFrame.minX < visible.minX { newFrame.origin.x = visible.minX }
        if newFrame.maxY > visible.maxY { newFrame.origin.y = visible.maxY - newFrame.height }
        if newFrame.minY < visible.minY { newFrame.origin.y = visible.minY }

        window.setFrame(newFrame, display: true, animate: true)
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var model: ViewerModel
    @State private var hovering = false
    @State private var showInfo = false

    var body: some View {
        ZStack {
            // Translucent background like modern macOS apps
            VisualEffectBackground()
                .ignoresSafeArea()

            if let videoURL = model.videoURL {
                VideoCanvas(url: videoURL)
                    .id(videoURL)
                    .padding(.top, Layout.topReserve)
                    .padding(.bottom, Layout.bottomReserve)
                    .padding(.horizontal, Layout.sideReserve)
                    .transition(.opacity)
            } else if let image = model.image {
                ImageCanvas(image: image)
                    .id(model.currentURL)
                    .padding(.top, Layout.topReserve)
                    .padding(.bottom, Layout.bottomReserve)
                    .padding(.horizontal, Layout.sideReserve)
                    .transition(.opacity)
            } else {
                EmptyState()
            }

            VStack {
                TopBar()
                Spacer()
                BottomBar(showInfo: $showInfo)
            }

            if showInfo, let info = model.currentInfo() {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        InfoPanel(info: info)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, Layout.sideReserve + 8)
                    .padding(.trailing, Layout.sideReserve + 8)
                    .padding(.bottom, Layout.bottomReserve + 8)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Hover navigation chevrons — sit inside the side reserve, not over the image.
            HStack {
                NavButton(systemName: "chevron.left") { model.previous() }
                    .opacity(model.files.count > 1 && hovering ? 1 : 0)
                Spacer()
                NavButton(systemName: "chevron.right") { model.next() }
                    .opacity(model.files.count > 1 && hovering ? 1 : 0)
            }
            .padding(.horizontal, (Layout.sideReserve - Layout.navButtonSize) / 2)
            .animation(.easeInOut(duration: 0.18), value: hovering)
        }
        .onHover { hovering = $0 }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                       isDir.boolValue {
                        model.loadFolder(url)
                    } else {
                        model.load(url: url)
                    }
                }
            }
            return true
        }
        .background(KeyHandlingView { event in
            switch event.keyCode {
            case 123: model.previous(); return true   // left
            case 124: model.next(); return true       // right
            case 49:  model.next(); return true       // space
            case 51:                                  // delete
                if event.modifierFlags.contains(.command) {
                    model.moveCurrentToTrash()
                    return true
                }
                return false
            case 3:                                   // f
                NSApp.keyWindow?.toggleFullScreen(nil)
                return true
            case 34:                                  // i
                withAnimation(.easeInOut(duration: 0.18)) { showInfo.toggle() }
                return true
            case 35:                                  // p
                model.toggleSlideshow()
                return true
            case 53:                                  // esc
                if showInfo { withAnimation { showInfo = false }; return true }
                return false
            default: return false
            }
        })
        .animation(.easeInOut(duration: 0.18), value: model.currentURL)
        .animation(.easeInOut(duration: 0.18), value: showInfo)
    }
}

struct ImageCanvas: View {
    let image: NSImage
    @EnvironmentObject var model: ViewerModel

    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let availW = max(geo.size.width,  1)
            let availH = max(geo.size.height, 1)
            let imgAspect = image.size.width / max(image.size.height, 1)
            let boxAspect = availW / availH
            let fitW = imgAspect > boxAspect ? availW : availH * imgAspect
            let fitH = imgAspect > boxAspect ? availW / imgAspect : availH
            let nativeScale = max(image.size.width / max(fitW, 1), 1.0)

            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: fitW, height: fitH)
                    .scaleEffect(model.zoomScale)
                    .offset(offset)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard model.zoomScale > 1 else { return }
                                offset = CGSize(
                                    width:  lastOffset.width  + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                offset = clampedOffset(of: offset, scale: model.zoomScale, fitW: fitW, fitH: fitH, geo: geo.size)
                                lastOffset = offset
                            }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newScale = max(1.0, min(lastScale * value, 8.0))
                                model.zoomScale = newScale
                                offset = clampedOffset(of: offset, scale: newScale, fitW: fitW, fitH: fitH, geo: geo.size)
                            }
                            .onEnded { _ in
                                lastScale = model.zoomScale
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            if model.zoomScale > 1.01 {
                                model.zoomScale = 1
                                lastScale = 1
                                offset = .zero; lastOffset = .zero
                            } else {
                                model.zoomScale = nativeScale
                                lastScale = nativeScale
                                offset = .zero; lastOffset = .zero
                            }
                        }
                    }
                    .background(
                        ScrollWheelView(
                            onScroll: { dx, dy, _ in
                                // Scroll wheel always zooms.
                                let factor = 1.0 + dy * 0.01
                                let newScale = max(1.0, min(model.zoomScale * factor, 8.0))
                                model.zoomScale = newScale
                                lastScale = newScale
                                offset = clampedOffset(of: offset, scale: newScale, fitW: fitW, fitH: fitH, geo: geo.size)
                                lastOffset = offset
                            }
                        )
                    )
                    .contextMenu {
                        Button {
                            model.copyCurrentImage()
                        } label: {
                            Label("Copy Image", systemImage: "doc.on.doc")
                        }
                        Button {
                            model.copyCurrentFileURL()
                        } label: {
                            Label("Copy File", systemImage: "doc")
                        }
                        Divider()
                        Button {
                            model.revealCurrentInFinder()
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        Divider()
                        Button(role: .destructive) {
                            model.moveCurrentToTrash()
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onChange(of: model.currentURL) { _ in
                lastScale = 1
                offset = .zero; lastOffset = .zero
            }
            .onChange(of: model.zoomScale) { newValue in
                // Detect external (toolbar) zoom changes — sync local state
                // and reset pan, since panning makes no sense after a hard
                // zoom reset and the user can re-pan immediately.
                if abs(newValue - lastScale) > 0.001 {
                    lastScale = newValue
                    offset = .zero
                    lastOffset = .zero
                }
            }
        }
    }

    private func clampedOffset(of o: CGSize, scale: CGFloat, fitW: CGFloat, fitH: CGFloat, geo: CGSize) -> CGSize {
        let maxX = max((fitW * scale - geo.width)  / 2, 0)
        let maxY = max((fitH * scale - geo.height) / 2, 0)
        return CGSize(
            width:  min(maxX,  max(-maxX, o.width)),
            height: min(maxY,  max(-maxY, o.height))
        )
    }
}

// Captures NSScrollWheel events for trackpad pan + ⌘-scroll zoom.
struct ScrollWheelView: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat, Bool) -> Void
    func makeNSView(context: Context) -> ScrollCatcherView {
        let v = ScrollCatcherView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ v: ScrollCatcherView, context: Context) {
        v.onScroll = onScroll
    }
}

final class ScrollCatcherView: NSView {
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, command)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // pass clicks through
}

struct EmptyState: View {
    @EnvironmentObject var model: ViewerModel
    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: "sun.max")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(LinearGradient(
                        colors: [Color(red: 0.46, green: 0.62, blue: 1.0),
                                 Color(red: 0.74, green: 0.50, blue: 1.0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                Text("Vyora")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .tracking(0.5)
                Text("Drop an image here, or open one to begin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(action: { model.openPanel() }) {
                    Label("Open Image…", systemImage: "folder")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: [.command])
                .padding(.top, 4)
            }

            if !model.recentFiles.isEmpty || !model.recentFolders.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    RecentColumn(
                        title: "Recent Files",
                        items: model.recentFiles,
                        icon: "photo"
                    ) { url in
                        model.load(url: url)
                    }
                    RecentColumn(
                        title: "Recent Folders",
                        items: model.recentFolders,
                        icon: "folder"
                    ) { url in
                        model.loadFolder(url)
                    }
                }
                .frame(maxWidth: 560)
            }
        }
        .padding(40)
    }
}

struct RecentColumn: View {
    let title: String
    let items: [URL]
    let icon: String
    let onTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)

            VStack(spacing: 2) {
                if items.isEmpty {
                    Text("Empty")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                } else {
                    ForEach(items, id: \.self) { url in
                        RecentRow(url: url, icon: icon) { onTap(url) }
                    }
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecentRow: View {
    let url: URL
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(url.path)
        .onHover { hover = $0 }
    }
}

struct TopBar: View {
    @EnvironmentObject var model: ViewerModel
    var body: some View {
        GeometryReader { geo in
            HStack {
                Spacer(minLength: 0)
                if model.image != nil || model.videoURL != nil {
                    Text(model.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                        .frame(maxWidth: max(geo.size.width - 140, 80), alignment: .center)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(model.currentURL?.path ?? "")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .frame(width: geo.size.width)
        }
        .frame(height: 44)
    }
}

struct BottomBar: View {
    @EnvironmentObject var model: ViewerModel
    @Binding var showInfo: Bool

    var body: some View {
        HStack(spacing: 10) {
            ToolButton(systemName: "folder") { model.openPanel() }
            if model.files.count > 1 {
                ToolButton(systemName: "chevron.left") { model.previous() }
                Text(model.counterText)
                    .font(.system(.callout, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56)
                ToolButton(systemName: "chevron.right") { model.next() }
            }
            if model.image != nil {
                Divider().frame(height: 18).padding(.horizontal, 2)
                ToolButton(systemName: "minus.magnifyingglass") { model.zoomOut() }
                ToolButton(systemName: "plus.magnifyingglass") { model.zoomIn() }
            }
            if model.image != nil || model.videoURL != nil {
                Divider().frame(height: 18).padding(.horizontal, 2)
                if model.files.count > 1 {
                    ToolButton(systemName: model.isPlaying ? "pause.fill" : "play.fill") {
                        model.toggleSlideshow()
                    }
                    SlideshowMenu()
                }
                ToolButton(systemName: showInfo ? "info.circle.fill" : "info.circle") {
                    withAnimation(.easeInOut(duration: 0.18)) { showInfo.toggle() }
                }
                ToolButton(systemName: "arrow.up.left.and.arrow.down.right") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                ToolButton(systemName: "trash") { model.moveCurrentToTrash() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
        .padding(.bottom, 18)
    }
}

struct InfoPanel: View {
    let info: ImageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(info.name)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.bottom, 2)
            row("Dimensions", info.dimensionsString)
            if let dur = info.durationString { row("Duration", dur) }
            row("Size",       info.sizeString)
            row("Format",     info.ext)
            row("Modified",   info.dateString)

            if info.exif.hasAny {
                Divider().padding(.vertical, 3)
                if let v = info.exif.camera     { row("Camera",   v) }
                if let v = info.exif.lens       { row("Lens",     v) }
                if let v = info.exposureLine    { row("Exposure", v) }
                if let v = info.exif.dateTaken  { row("Taken",    v) }
                if let v = info.exif.gps        { row("GPS",      v) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SlideshowMenu: View {
    @EnvironmentObject var model: ViewerModel
    private let presets: [TimeInterval] = [1, 2, 3, 5, 8, 15, 30]

    var body: some View {
        Menu {
            Section("Slideshow Interval") {
                ForEach(presets, id: \.self) { value in
                    Button {
                        model.slideshowInterval = value
                    } label: {
                        HStack {
                            Text(label(for: value))
                            if abs(model.slideshowInterval - value) < 0.01 {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("Slideshow settings")
    }

    private func label(for v: TimeInterval) -> String {
        v < 60 ? "\(Int(v)) seconds" : "\(Int(v / 60)) min"
    }
}

struct ToolButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(hover ? Color.primary.opacity(0.12) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct NavButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Layout.navButtonSize, height: Layout.navButtonSize)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .scaleEffect(hover ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Video

struct VideoCanvas: View {
    let url: URL
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        PlayerViewRepresentable(player: model.player)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
            .contextMenu {
                Button {
                    model.copyCurrentFileURL()
                } label: {
                    Label("Copy File", systemImage: "doc")
                }
                Button {
                    model.revealCurrentInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    model.moveCurrentToTrash()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
    }
}

/// Wraps the native AppKit AVPlayerView. We use this instead of the SwiftUI
/// VideoPlayer because the latter has historically been crashy when its
/// generic metadata gets instantiated during a layout pass triggered by a
/// concurrent window resize.
struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = false
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - NSViewRepresentable helpers

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct KeyHandlingView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onKeyDown = onKeyDown
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

final class KeyCatcherView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
