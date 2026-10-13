#!/bin/zsh
# Copies NPCVoiceKit.framework and the headers into the Unreal plugin's ThirdParty folder.
# Usage: Integrations/Unreal/setup.sh [NPCVoiceKit.xcframework]   (default: dist/NPCVoiceKit.xcframework)
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
xcf=${1:-$root/dist/NPCVoiceKit.xcframework}
fw="$xcf/macos-arm64/NPCVoiceKit.framework"
[[ -d $fw ]] || { print -u2 "no framework at $fw (run tools/build_xcframework.sh, or pass the release's xcframework)"; exit 1; }
tp="$root/Integrations/Unreal/NPCVoice/Source/ThirdParty"
rm -rf "${tp:?}/NPCVoiceKit.framework" "${tp:?}/include"
mkdir -p "$tp/include/npcvoice"
cp -R "$fw" "$tp/"
cp "$fw/Headers/npc_core.h" "$fw/Headers/npc_sdk.h" "$tp/include/"
cp "$root/Integrations/cpp/include/npcvoice/npcvoice.hpp" "$tp/include/npcvoice/"
print "ThirdParty ready: $tp"
print "Copy Integrations/Unreal/NPCVoice into your project's Plugins folder."
