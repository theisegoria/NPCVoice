#!/bin/zsh
# Opens a project in the built NPCVoice.app with a forced appearance, for visual
# inspection. Capture windows with tools/snap.sh (the app renders itself to PNG), or with
# the computer-use app_screenshot tool on bundle id dev.npcvoice.NPCVoice when the
# window is the active stage (Stage Manager shows strip windows tilted and blurred).
# Usage: tools/launch_app.sh [light|dark] [screen] [project.npcproj]
#   AUTORUN=1 runs the screen's main action on appear (e.g. Voice Lab synthesizes; nothing plays).
#   ONBOARDING=1 shows the welcome sheet; SETTINGS=1 opens the Settings window (SETTINGS_TAB=models).
#   PORTRAIT=<id>=<image> imports a character picture at launch (DEBUG builds).
#   BACKEND=stub|apple|mlx picks the dialogue model for this launch (stub loads nothing on the GPU).
#   SNAP=<dir> writes PNGs of every window ~6 s after launch (SNAP_DELAY to change).
#   screen: world (default), playground, voicelab, bake, facts, commands, pronunciations, or a character id
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-light}; screen=${2:-world}; proj=${3:-build/screens/Harbor Town.npcproj}
app=build/DerivedData/Build/Products/Debug/NPCVoice.app
mkdir -p build/screens
[[ -d "$proj" ]] || swift run -q npcvoice init "$proj" >/dev/null
pkill -x NPCVoice 2>/dev/null || true; sleep 0.5
extra=(); [[ -n "${BACKEND:-}" ]] && extra+=(-NPCVoiceDefaultBackend "$BACKEND")
[[ -n "${PORTRAIT:-}" ]] && extra+=(-NPCVoicePortrait "$PORTRAIT")
open -a "$PWD/$app" "$proj" --args "${extra[@]}" -ApplePersistenceIgnoreState YES -NPCVoiceAppearance "$mode" -NPCVoiceScreen "$screen" -NPCVoiceAutoRun "${AUTORUN:-0}" -NPCVoiceShowOnboarding "${ONBOARDING:-0}" -NPCVoiceOpenSettings "${SETTINGS:-0}" -NPCVoiceSettingsTab "${SETTINGS_TAB:-general}" \
  -NPCVoiceSnapshot "${SNAP:-}" -NPCVoiceSnapshotDelay "${SNAP_DELAY:-6}"
