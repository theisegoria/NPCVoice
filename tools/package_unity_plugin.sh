#!/bin/zsh
# Builds NPCVoiceKit.bundle for Unity (macOS plugin bundle) from the xcframework, into the
# Unity package's Plugins/macOS. The metallib goes in Contents/Resources (code signing allows
# only code in Contents/MacOS); NPCVoice points MLX at it when loaded from a bundle.
# Usage: tools/package_unity_plugin.sh [NPCVoiceKit.xcframework]   (default: dist/NPCVoiceKit.xcframework)
#   SIGN_IDENTITY=<codesign identity>   default: ad hoc
set -euo pipefail
cd "$(dirname "$0")/.."
xcf=${1:-dist/NPCVoiceKit.xcframework}
fw="$xcf/macos-arm64/NPCVoiceKit.framework"
[[ -d $fw ]] || { print -u2 "no framework at $fw"; exit 1; }
version=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
out=Integrations/Unity/com.npcvoice.runtime/Plugins/macOS/NPCVoiceKit.bundle
rm -rf "${out:?}"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$fw/Versions/A/NPCVoiceKit" "$out/Contents/MacOS/NPCVoiceKit"
cp "$fw/Versions/A/Resources/mlx.metallib" "$out/Contents/Resources/mlx.metallib"
cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>NPCVoiceKit</string>
  <key>CFBundleIdentifier</key><string>dev.npcvoice.NPCVoiceKit.unity</string>
  <key>CFBundleName</key><string>NPCVoiceKit</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict>
</plist>
PLIST
if [[ -n ${SIGN_IDENTITY:-} ]]; then codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$out"
else codesign --force --sign - "$out"; fi
codesign --verify --strict "$out" && print "$out ($(du -sh "$out" | cut -f1)), signed ${SIGN_IDENTITY:-ad hoc}"
