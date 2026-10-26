#!/bin/sh
# Builds dist/fastcord-macos.zip: a universal (arm64 + x86_64) Fastcord.app.
#   scripts/package_macos.sh [version]      e.g. v0.1.0 (default: dev)
set -e
cd "$(dirname "$0")/.."
VERSION="${1:-dev}"
PLAIN="${VERSION#v}"
FLAGS="-collection:fc=src -o:speed -define:FASTCORD_VERSION=$VERSION"
rm -rf dist build/pkg && mkdir -p dist build/pkg
./build.sh c

odin build src/app -out:build/pkg/fastcord-arm64 -target:darwin_arm64 $FLAGS -extra-linker-flags:"-mmacosx-version-min=13.0"
odin build src/app -out:build/pkg/fastcord-x86_64 -target:darwin_amd64 $FLAGS -extra-linker-flags:"-mmacosx-version-min=13.0"
lipo -create build/pkg/fastcord-arm64 build/pkg/fastcord-x86_64 -output build/pkg/fastcord

APP=build/pkg/Fastcord.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/pkg/fastcord "$APP/Contents/MacOS/Fastcord"

odin build tools/appicon -collection:fc=src -out:build/pkg/appicon
build/pkg/appicon build/pkg/Fastcord.iconset
iconutil -c icns build/pkg/Fastcord.iconset -o "$APP/Contents/Resources/Fastcord.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Fastcord</string>
	<key>CFBundleDisplayName</key><string>Fastcord</string>
	<key>CFBundleIdentifier</key><string>com.creikey.fastcord</string>
	<key>CFBundleExecutable</key><string>Fastcord</string>
	<key>CFBundleIconFile</key><string>Fastcord</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$PLAIN</string>
	<key>CFBundleVersion</key><string>$PLAIN</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Fastcord uses the microphone for voice chat.</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (required to launch on Apple silicon). Not notarized.
codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" dist/fastcord-macos.zip
echo "dist/fastcord-macos.zip ($VERSION)"
