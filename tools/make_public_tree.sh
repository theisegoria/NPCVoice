#!/bin/zsh
# Builds the public repository locally from the committed main: the tree without the model
# weights (users run tools/fetch_models.sh) or internal working notes, as a fresh git repo
# with one commit. Nothing is pushed; review it, then add a remote and push yourself.
# Usage: tools/make_public_tree.sh <out-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?usage: tools/make_public_tree.sh <out-dir>}
[[ ! -e $out ]] || { print -u2 "$out already exists"; exit 1; }
[[ -z $(git status --porcelain) ]] || { print -u2 "commit or stash your changes first"; exit 1; }
[[ -f tools/models.lock ]] || print -u2 "note: no tools/models.lock yet (run tools/package_models.sh before the release)"

mkdir -p "$out"
git archive --format=tar HEAD | tar -x -C "$out"
rm -rf "${out:?}/third_party/models" "$out/docs/LOOP.md" "$out/docs/RESUME.md"
mkdir -p "$out/third_party/models"
print "Model weights go here: run tools/fetch_models.sh (see tools/models.lock)." > "$out/third_party/models/README.md"
print -- "\n# Model weights (tools/fetch_models.sh)\nthird_party/models/*\n!third_party/models/README.md" >> "$out/.gitignore"

# Checks: no Git LFS pointers, no weights, nothing from this machine.
if grep -rIl --exclude-dir=.git '^version https://git-lfs\.github\.com/spec/' "$out" | grep -q .; then print -u2 "LFS pointers left"; exit 1; fi
big=$(find "$out" -type f -size +10M -not -path "*/.git/*")
[[ -z $big ]] || { print -u2 "large files left:\n$big"; exit 1; }
if grep -rIl --exclude-dir=.git "$HOME" "$out" | grep -q .; then print -u2 "files mention $HOME"; exit 1; fi

git -C "$out" init -q -b main
git -C "$out" add -A
git -C "$out" commit -q -m "NPCVoice $(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)"
print "public tree: $out ($(du -sh "$out" | cut -f1), $(git -C "$out" ls-files | wc -l | tr -d ' ') files, 1 commit, no remote)"
