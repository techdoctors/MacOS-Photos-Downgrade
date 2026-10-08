#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) build/Photos Downgrade.app that runs
# on macOS 12 Monterey and later, plus a universal build/pdowngrade CLI.
# No Xcode needed: each architecture is built separately and merged with lipo.
set -euo pipefail
cd "${0:A:h}/.."
MIN_OS=10.15
VERSION=${VERSION:-1.0}
for arch in arm64 x86_64; do
  for product in PhotosDowngradeApp pdowngrade; do
    swift build -c release --product $product --triple $arch-apple-macosx$MIN_OS --scratch-path .build/$arch
  done
done
APP="build/Photos Downgrade.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64/release/PhotosDowngradeApp .build/x86_64/release/PhotosDowngradeApp \
  -output "$APP/Contents/MacOS/PhotosDowngrade"
# App icon: render with scripts/make-icon.swift, then build every size into an .icns.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
[ -f Resources/AppIcon.png ] || swift scripts/make-icon.swift Resources/AppIcon.png
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
lipo -create .build/arm64/release/pdowngrade .build/x86_64/release/pdowngrade -output build/pdowngrade
codesign --force --sign - build/pdowngrade
# Target templates, one per macOS release (see Resources/Templates).
cp -R Resources/Templates "$APP/Contents/Resources/Templates"
rm -rf build/Templates && cp -R Resources/Templates build/Templates
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Photos Downgrade</string>
  <key>CFBundleDisplayName</key><string>Photos Downgrade</string>
  <key>CFBundleIdentifier</key><string>io.techdoctors.PhotosDowngrade</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>PhotosDowngrade</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
# Downloadable zip for a GitHub Release (ditto keeps the bundle and signature intact).
ZIP="build/Photos-Downgrade-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $APP"
echo "Built $ZIP"
