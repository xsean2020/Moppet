#!/bin/bash
# Package Moppet as a real .app bundle (with the Moppet app icon).
# The bare-SPM-binary workflow (`swift run Moppet`) still works unchanged.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ building release…"
swift build -c release --disable-sandbox

APP="$ROOT/dist/Moppet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ bundling binary + resources…"
cp "$ROOT/.build/release/Moppet" "$APP/Contents/MacOS/Moppet"
# SPM resource bundle (stickers + vrma) must sit in Contents/Resources.
if [ -d "$ROOT/.build/release/Moppet_Moppet.bundle" ]; then
  cp -R "$ROOT/.build/release/Moppet_Moppet.bundle" "$APP/Contents/Resources/"
fi

# App icon: assets/Moppet.iconset → Moppet.icns (CFBundleIconFile).
iconutil -c icns "$ROOT/assets/Moppet.iconset" \
  -o "$APP/Contents/Resources/Moppet.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Moppet</string>
  <key>CFBundleDisplayName</key><string>Moppet</string>
  <key>CFBundleIdentifier</key><string>com.moppet.app</string>
  <key>CFBundleExecutable</key><string>Moppet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Moppet.icns</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "→ ad-hoc signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ built: $APP"
echo "  run it with:  open \"$APP\""
