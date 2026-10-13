#!/bin/zsh
# Publishes main's current tree to the public repo (github.com/theisegoria/NPCVoice) as one new
# commit, with the same exclusions and checks as tools/make_public_tree.sh. Nothing is pushed:
# review build/public/NPCVoice, then push it yourself.
# Usage: tools/sync_public.sh "<commit message>"
set -euo pipefail
cd "$(dirname "$0")/.."
msg=${1:?usage: tools/sync_public.sh "<commit message>"}
pub=build/public/NPCVoice
[[ -d $pub/.git ]] || git clone https://github.com/theisegoria/NPCVoice.git "$pub"
git -C "$pub" pull --ff-only
tmp=$(mktemp -d)
tools/make_public_tree.sh "$tmp/tree" >/dev/null
rsync -a --delete --exclude .git "$tmp/tree/" "$pub/"
rm -rf "${tmp:?}"
git -C "$pub" add -A
if git -C "$pub" diff --cached --quiet; then print "nothing to publish"; exit 0; fi
git -C "$pub" commit -q -m "$msg"
git -C "$pub" log --oneline -1
print "review $pub, then: git -C $pub push"
