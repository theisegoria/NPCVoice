#!/bin/zsh
# Maintainers: packs third_party/models into release assets (one .tar per model, each under
# GitHub's 2 GiB asset limit) and writes tools/models.lock (name, file, bytes, SHA-256),
# which tools/fetch_models.sh verifies. Upload build/model-assets/*.tar to the GitHub
# release named in tools/models.lock ("release"), then commit the lock.
# Usage: tools/package_models.sh [model ...]   (default: every folder in third_party/models)
set -euo pipefail
cd "$(dirname "$0")/.."
release=${MODELS_RELEASE:-models-v1}
out=build/model-assets
mkdir -p "$out"
models=("$@")
(( ${#models} )) || models=($(cd third_party/models && ls -d */ | tr -d /))
lock=tools/models.lock
tmp=$(mktemp)
print -- "# NPCVoice model assets: name file bytes sha256 (written by tools/package_models.sh)" > "$tmp"
print -- "release $release" >> "$tmp"
for m in $models; do
  [[ -d "third_party/models/$m" ]] || { print -u2 "no such model folder: $m"; exit 1; }
  file="$m.tar"
  # Stable metadata: no owner names, no macOS extended attributes or .DS_Store.
  COPYFILE_DISABLE=1 tar -c --uid 0 --gid 0 --uname "" --gname "" --exclude .DS_Store \
    -f "$out/$file" -C third_party/models "$m"
  bytes=$(stat -f %z "$out/$file")
  (( bytes < 2147483648 )) || { print -u2 "$file is over 2 GiB"; exit 1; }
  sum=$(shasum -a 256 "$out/$file" | cut -d' ' -f1)
  print -- "$m $file $bytes $sum" >> "$tmp"
  print "$file  $(( bytes / 1048576 )) MB  $sum"
done
mv "$tmp" "$lock"
print "wrote $lock"
