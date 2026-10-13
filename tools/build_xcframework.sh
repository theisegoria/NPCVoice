#!/bin/zsh
# Builds dist/NPCVoiceKit.xcframework (macOS arm64) from the NPCVoiceKit framework target.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
jobs=(); [[ -n ${JOBS:-} ]] && jobs=(-jobs "$JOBS")     # JOBS=2 limits parallelism
rm -rf build/archive dist/NPCVoiceKit.xcframework
xcodebuild archive -project NPCVoice.xcodeproj -scheme NPCVoiceKit -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/archive/NPCVoiceKit.xcarchive \
  -derivedDataPath build/DerivedData SKIP_INSTALL=NO -quiet "${jobs[@]}"
mkdir -p dist
xcodebuild -create-xcframework \
  -framework build/archive/NPCVoiceKit.xcarchive/Products/Library/Frameworks/NPCVoiceKit.framework \
  -output dist/NPCVoiceKit.xcframework
cp cmake/NPCVoiceKitConfig.cmake cmake/NPCVoiceKitConfigVersion.cmake dist/   # find_package(NPCVoiceKit) for C/C++
echo "dist/NPCVoiceKit.xcframework ($(du -sh dist/NPCVoiceKit.xcframework | cut -f1)) + CMake package config"
