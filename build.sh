#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# ── Configuration ──────────────────────────────────────────────────────
APP_NAME="Vyora"
DISPLAY_NAME="Vyora"
BUNDLE_ID="com.local.vyora"
VERSION="1.0"
BUILD_NUMBER="1"
COPYRIGHT="© 2026 Vyora. All rights reserved."
MIN_OS="14.0"

BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

RELEASE=false
if [[ "${1:-}" == "--release" ]]; then
    RELEASE=true
    echo "=== RELEASE BUILD ==="
fi

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# ── Icon ───────────────────────────────────────────────────────────────
if [[ ! -f Vyora.icns ]] || [[ ! -f AppStoreIcon.png ]]; then
    echo "Generating icons…"
    swift make_icon.swift
    iconutil -c icns Vyora.iconset -o Vyora.icns
fi
cp Vyora.icns "$RES_DIR/AppIcon.icns"
cp AppStoreIcon.png "$RES_DIR/AppStoreIcon.png"

# ── Compile ────────────────────────────────────────────────────────────
FRAMEWORKS=(
    -framework AppKit
    -framework SwiftUI
    -framework AVKit
    -framework AVFoundation
    -framework CoreMedia
    -framework ImageIO
    -framework UniformTypeIdentifiers
)

echo "Compiling Swift sources…"

if $RELEASE; then
    # Universal binary (arm64 + x86_64) for App Store distribution.
    swiftc -O -target arm64-apple-macos${MIN_OS}  "${FRAMEWORKS[@]}" -parse-as-library main.swift -o "$MACOS_DIR/${APP_NAME}_arm64"
    swiftc -O -target x86_64-apple-macos${MIN_OS} "${FRAMEWORKS[@]}" -parse-as-library main.swift -o "$MACOS_DIR/${APP_NAME}_x86_64"
    lipo -create "$MACOS_DIR/${APP_NAME}_arm64" "$MACOS_DIR/${APP_NAME}_x86_64" -output "$MACOS_DIR/$APP_NAME"
    rm "$MACOS_DIR/${APP_NAME}_arm64" "$MACOS_DIR/${APP_NAME}_x86_64"
    echo "  → Universal binary (arm64 + x86_64)"
else
    swiftc -O -target arm64-apple-macos${MIN_OS} "${FRAMEWORKS[@]}" -parse-as-library main.swift -o "$MACOS_DIR/$APP_NAME"
fi

# ── Info.plist ─────────────────────────────────────────────────────────
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
    <key>NSAppleEventsUsageDescription</key><string>Vyora needs access to open image and video files.</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Movie</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ── Code signing ───────────────────────────────────────────────────────
if $RELEASE; then
    # Ad-hoc sign with hardened runtime + sandbox entitlements.
    # Replace "-" with your Developer ID or "3rd Party Mac Developer Application"
    # identity when you have an Apple Developer account.
    SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
    echo "Code signing (identity: $SIGN_IDENTITY)…"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
             --entitlements Vyora.entitlements \
             --options runtime \
             "$APP_DIR"
    echo "Verifying signature…"
    codesign --verify --deep --strict "$APP_DIR"
    echo "  → Signature OK"

    # Show entitlements for verification.
    echo "Entitlements:"
    codesign -d --entitlements - "$APP_DIR" 2>/dev/null | head -20
fi

# ── Refresh Finder ─────────────────────────────────────────────────────
touch "$APP_DIR"

# Install into /Applications.
INSTALL_DIR="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"

"$LSREGISTER" -u "$APP_DIR"      >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALL_DIR"  >/dev/null 2>&1 || true

echo ""
echo "Built:     $APP_DIR"
echo "Installed: $INSTALL_DIR"

# ── App Store package ──────────────────────────────────────────────────
if $RELEASE; then
    PKG_PATH="$BUILD_DIR/$APP_NAME.pkg"
    echo "Creating installer package…"
    productbuild --component "$APP_DIR" /Applications "$PKG_PATH"
    echo "Package:   $PKG_PATH"
    echo ""
    echo "To upload to App Store Connect:"
    echo "  1. Sign with your Developer ID:  export CODESIGN_IDENTITY='3rd Party Mac Developer Application: Your Name (TEAM_ID)'"
    echo "  2. Re-run:  ./build.sh --release"
    echo "  3. Upload:  xcrun altool --upload-app -f $PKG_PATH -t macos -u YOUR_APPLE_ID -p @keychain:AC_PASSWORD"
    echo "     Or use Transporter.app to drag-and-drop the .pkg"
fi

echo ""
echo "Run with:  open $INSTALL_DIR"
