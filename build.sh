#!/bin/zsh
# Builds "Hierarchy Size.app" into ./build
set -e
cd "$(dirname "$0")"
SDK=""
for s in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk "$(xcrun --show-sdk-path)"; do
  [ -d "$s" ] && SDK="$s" && break
done
APP="build/Hierarchy Size.app"
rm -rf "$APP" build/icon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Compiling…"
for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$ARCH-apple-macos14.0" -sdk "$SDK" Sources/HierarchySize/*.swift -o "build/HierarchySize-$ARCH"
done
lipo -create build/HierarchySize-arm64 build/HierarchySize-x86_64 -output "$APP/Contents/MacOS/HierarchySize"
echo "Making icon…"
swiftc -sdk "$SDK" scripts/make_icon.swift -o build/make_icon
build/make_icon build/icon.iconset
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hierarchy Size</string>
  <key>CFBundleDisplayName</key><string>Hierarchy Size</string>
  <key>CFBundleIdentifier</key><string>local.hierarchysize.app</string>
  <key>CFBundleExecutable</key><string>HierarchySize</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Hierarchy Size asks Finder to empty the Trash when you click Empty.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Done: $APP"
