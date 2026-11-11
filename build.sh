#!/bin/bash
# 编译并打包「键盘锁.app」。
# 注意：每次重新编译后，系统会把它当成一个新程序，
# 需要在 系统设置 → 隐私与安全性 → 辅助功能 里重新勾选一次。
set -euo pipefail
cd "$(dirname "$0")"

APP="键盘锁.app"
BUILD="build"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD/AppIcon.iconset" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. 编译
swiftc -O -target "$(uname -m)-apple-macos13.0" Sources/*.swift \
  -o "$APP/Contents/MacOS/KeyLock"

# 2. 图标
swiftc -O make_icon.swift -o "$BUILD/make_icon"
"$BUILD/make_icon" "$BUILD/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# 3. Info.plist
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>键盘锁</string>
  <key>CFBundleDisplayName</key><string>键盘锁</string>
  <key>CFBundleExecutable</key><string>KeyLock</string>
  <key>CFBundleIdentifier</key><string>local.keylock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 4. 本地签名（ad-hoc）
codesign --force --sign - --identifier local.keylock "$APP"

echo "完成：$(pwd)/$APP"
