#!/bin/zsh
# Asks the running Debug NPCVoice.app to render its visible windows to PNG (in-process,
# so it works with Stage Manager, other Spaces, a sleeping display, and no Screen
# Recording permission). Optionally switches the sidebar first.
# Usage: tools/snap.sh <out-dir> [screen]
#   screen: playground, voicelab, bake, world, facts, commands, pronunciations, or a character id
set -euo pipefail
setopt null_glob
out=${1:?usage: tools/snap.sh <out-dir> [screen]}; screen=${2:-}
mkdir -p "$out"; out=$(cd "$out" && pwd)
post() {
  osascript -l JavaScript -e "ObjC.import('Foundation');
    \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('$1', '$2', \$(), true)" >/dev/null
}
if [[ -n "$screen" ]]; then post dev.npcvoice.screen "$screen"; sleep "${SETTLE:-1.5}"; fi
old=("$out"/*.png); (( ${#old} )) && rm -f "${old[@]}"
post dev.npcvoice.snapshot "$out"
# The app writes on its main thread, which may still be busy with the screen switch.
for _ in {1..${SNAP_TRIES:-40}}; do
  pngs=("$out"/*.png)
  (( ${#pngs} )) && { sleep 0.3; printf '%s\n' "$out"/*.png; exit 0; }
  sleep 0.25
done
echo "no snapshot written after 10 s (is a Debug NPCVoice running?)" >&2; exit 1
