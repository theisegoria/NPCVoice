#!/bin/zsh
# Downloads the model weights NPCVoice needs (~2 GB) into third_party/models, verifying each
# asset's size and SHA-256 against tools/models.lock. Safe to re-run: finished models are
# skipped and interrupted downloads resume.
#
# Assets come from this repository's GitHub release named in the lock ("release"). Override:
#   NPCVOICE_MODELS_URL=<base URL (https:// or file://)>   where the .tar assets live
#   NPCVOICE_MODELS_DIR=<folder>                            install somewhere else
set -euo pipefail
cd "$(dirname "$0")/.."
lock=tools/models.lock
[[ -f $lock ]] || { print -u2 "missing $lock"; exit 1; }
dest=${NPCVOICE_MODELS_DIR:-third_party/models}
release=$(awk '$1 == "release" { print $2 }' "$lock")

base=${NPCVOICE_MODELS_URL:-}
if [[ -z $base ]]; then
  origin=$(git remote get-url origin 2>/dev/null || true)
  if [[ $origin =~ 'github\.com[:/]([^/]+)/([^/.]+)' ]]; then
    base="https://github.com/${match[1]}/${match[2]}/releases/download/$release"
  else
    print -u2 "Can't tell where to download from: no GitHub 'origin' remote. Set NPCVOICE_MODELS_URL."
    exit 1
  fi
fi

downloads=build/model-downloads
mkdir -p "$downloads" "$dest"
grep -v '^#' "$lock" | grep -v '^release ' | while read -r name file bytes sum; do
  stamp="$dest/$name/.npcvoice-asset"
  if [[ -f $stamp && $(<"$stamp") == "$sum" ]]; then print "$name: up to date"; continue; fi
  part="$downloads/$file"
  if [[ ! -f $part || $(stat -f %z "$part") -ne $bytes ]]; then
    print "$name: downloading $(( bytes / 1048576 )) MB"
    curl -fL --retry 3 -C - -o "$part" "$base/$file"
  fi
  [[ $(stat -f %z "$part") -eq $bytes ]] || { print -u2 "$file: wrong size"; exit 1; }
  [[ $(shasum -a 256 "$part" | cut -d' ' -f1) == "$sum" ]] || { print -u2 "$file: checksum mismatch (deleted; re-run to download again)"; rm -f "$part"; exit 1; }
  rm -rf "${dest:?}/${name:?}"
  tar -xf "$part" -C "$dest"
  print -- "$sum" > "$stamp"
  rm -f "$part"
  print "$name: installed"
done
print "models ready in $dest"
