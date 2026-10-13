#!/bin/zsh
# Builds every release asset into dist/release/:
#   NPCVoice-<v>.dmg                  the app (models included) + the CLI, signed
#   npcvoice-cli-<v>-macos-arm64.zip  the CLI with mlx.metallib (models: the app's, or Models/ beside it)
#   NPCVoiceKit-<v>.xcframework.zip   SwiftPM binaryTarget (+ dist/Package.swift)
#   NPCVoiceKit-<v>-sdk.zip           xcframework + CMake package config
#   NPCVoiceKit-<v>-unity-plugin.zip  NPCVoiceKit.bundle for the Unity package
#   <model>.tar + tools/models.lock   weights for tools/fetch_models.sh
#
# SIGN_IDENTITY   codesign identity (default: the first "Developer ID Application" in the keychain)
# NOTARY_PROFILE  notarytool keychain profile; when set, the DMG is notarized and stapled
# RELEASE_URL     base URL of the release's assets (for dist/Package.swift)
# JOBS            limit build parallelism (e.g. 2 while other heavy work runs)
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
[[ -n $identity ]] || { print -u2 "no Developer ID Application identity; set SIGN_IDENTITY"; exit 1; }
out=dist/release
rm -rf "${out:?}"; mkdir -p "$out"
sign() { codesign --force --options runtime --timestamp --sign "$identity" "$@"; }
xjobs=(); sjobs=(); [[ -n ${JOBS:-} ]] && { xjobs=(-jobs "$JOBS"); sjobs=(-j "$JOBS"); }

print "== app"
xcodegen generate -q
rm -rf build/DerivedData/Build/Products/Release/NPCVoiceKit.framework   # stale SDK headers would shadow the package's
xcodebuild -project NPCVoice.xcodeproj -scheme NPCVoice -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet "${xjobs[@]}" build
app=build/release/NPCVoice.app
rm -rf "${app:?}"; mkdir -p build/release
cp -R build/DerivedData/Build/Products/Release/NPCVoice.app "$app"
mkdir -p "$app/Contents/Resources/Models"
for m in qwen3.5-2b-4bit kokoro-82m-coreml misaki-en misaki-ja; do
  rsync -a --exclude .DS_Store --exclude fixtures --exclude .npcvoice-asset "third_party/models/$m" "$app/Contents/Resources/Models/"
done
sign "$app"
codesign --verify --deep --strict "$app"

print "== cli"
swift build -c release --product npcvoice "${sjobs[@]}"
cli=build/release/npcvoice-cli
rm -rf "${cli:?}"; mkdir -p "$cli"
cp .build/release/npcvoice "$cli/"
cp "$app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$cli/mlx.metallib"
sign "$cli/npcvoice"
cat > "$cli/README.txt" <<TXT
npcvoice $version — NPCVoice command-line tool (macOS 27, Apple silicon)

Keep mlx.metallib next to npcvoice. Models are found in, in order: \$NPCVOICE_MODELS, a Models
folder next to npcvoice, then /Applications/NPCVoice.app/Contents/Resources/Models.

  ./npcvoice init "Harbor Town.npcproj"
  ./npcvoice say "Harbor Town.npcproj" --npc marta --player "Got a room?" --backend mlx
TXT
(cd build/release && ditto -c -k --keepParent npcvoice-cli "$OLDPWD/$out/npcvoice-cli-$version-macos-arm64.zip")

print "== dmg"
stage=build/release/dmg
rm -rf "${stage:?}"; mkdir -p "$stage"
cp -R "$app" "$stage/"
cp -R "$cli" "$stage/Command Line Tool"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "NPCVoice $version" -srcfolder "$stage" -format UDZO -fs APFS "$out/NPCVoice-$version.dmg"
sign "$out/NPCVoice-$version.dmg"
if [[ -n ${NOTARY_PROFILE:-} ]]; then
  xcrun notarytool submit "$out/NPCVoice-$version.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$out/NPCVoice-$version.dmg"
fi

print "== sdk"
tools/build_xcframework.sh
sign dist/NPCVoiceKit.xcframework/macos-arm64/NPCVoiceKit.framework
NPCVOICE_RELEASE_URL=${RELEASE_URL:-} tools/package_sdk.sh
mv dist/NPCVoiceKit-$version.xcframework.zip dist/NPCVoiceKit-$version-sdk.zip "$out/"
SIGN_IDENTITY="$identity" tools/package_unity_plugin.sh
(cd Integrations/Unity/com.npcvoice.runtime/Plugins/macOS && ditto -c -k --keepParent NPCVoiceKit.bundle "$OLDPWD/$out/NPCVoiceKit-$version-unity-plugin.zip")

print "== models"
MODELS_RELEASE=v$version tools/package_models.sh
mv build/model-assets/*.tar "$out/"

print "== done"
ls -lh "$out"
for f in "$out"/*; do (( $(stat -f %z "$f") < 2147483648 )) || print -u2 "WARNING: $f is over GitHub's 2 GiB asset limit"; done
