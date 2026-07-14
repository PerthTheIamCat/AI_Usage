#!/bin/zsh
# Build AIUsageBar.app bundle from the Swift package.
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-0.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
swift build -c release
APP=AIUsageBar.app
rm -rf "$APP"
SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework not found. Run: swift package resolve" >&2
  exit 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/release/AIUsageBar "$APP/Contents/MacOS/AIUsageBar"
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
SPARKLE_APP_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

# This app is not sandboxed, so Sparkle's optional XPC services are unnecessary.
# Removing them lets us use Sparkle's documented explicit signing order instead
# of --deep, which can apply unsuitable entitlements to the Downloader service.
rm -rf "$SPARKLE_APP_FRAMEWORK/Versions/B/XPCServices"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.perth.aiusagebar</string>
    <key>CFBundleName</key><string>AI Usage Bar</string>
    <key>CFBundleExecutable</key><string>AIUsageBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>SUFeedURL</key><string>https://perththeiamcat.github.io/AI_Usage/appcast.xml</string>
    <key>SUPublicEDKey</key><string>GZz3+3QtNsOQQuZ0OdbFyFuua1WkN3uWj11cx/WGkSc=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$SPARKLE_APP_FRAMEWORK/Versions/B/Autoupdate"
codesign --force --sign - "$SPARKLE_APP_FRAMEWORK/Versions/B/Updater.app"
codesign --force --sign - "$SPARKLE_APP_FRAMEWORK"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
