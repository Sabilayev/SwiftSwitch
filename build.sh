#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/SwiftSwitch.app"
ICON_PNG="$ROOT/Assets/AppIcon.png"
ICON_ICNS="$ROOT/Assets/AppIcon.icns"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

if [[ -f "$ICON_PNG" ]]; then
  if [[ ! -f "$ICON_ICNS" || "$ICON_PNG" -nt "$ICON_ICNS" ]]; then
    echo "=== Generating AppIcon.icns ==="
    python3 - "$ICON_PNG" "$ICON_ICNS" <<'PY'
import struct, subprocess, sys, tempfile, os
src, dst = sys.argv[1], sys.argv[2]
chunks = []
with tempfile.TemporaryDirectory() as td:
    for tag, sz in [(b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024)]:
        tmp = os.path.join(td, f"icon_{sz}.png")
        subprocess.check_call(["sips", "-s", "format", "png", "-z", str(sz), str(sz), src, "--out", tmp], stdout=subprocess.DEVNULL)
        data = open(tmp, "rb").read()
        chunks.append(tag + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
with open(dst, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
  fi
  cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "=== Compiling detector unit tests ==="
swiftc -swift-version 5 -O \
  "$ROOT/Sources/LayoutManager.swift" \
  "$ROOT/Sources/LanguageDetector.swift" \
  "$ROOT/test_detector.swift" \
  -framework Cocoa -framework Carbon \
  -o "$BUILD_DIR/test_detector"

echo "=== Building SwiftSwitch.app (native arm64) ==="
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  "$ROOT/Sources/LayoutManager.swift" \
  "$ROOT/Sources/LanguageDetector.swift" \
  "$ROOT/Sources/TypingEngine.swift" \
  "$ROOT/Sources/AppDelegate.swift" \
  "$ROOT/Sources/main.swift" \
  -framework Cocoa -framework Carbon -framework ApplicationServices \
  -o "$APP_BUNDLE/Contents/MacOS/SwiftSwitch"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SwiftSwitch</string>
    <key>CFBundleDisplayName</key>
    <string>SwiftSwitch</string>
    <key>CFBundleIdentifier</key>
    <string>com.swiftswitch.app</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>SwiftSwitch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"
file "$APP_BUNDLE/Contents/MacOS/SwiftSwitch"
du -sh "$APP_BUNDLE"
echo "Build complete: $APP_BUNDLE"
