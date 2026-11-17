#!/bin/zsh
# Publish the committed version: DMG, signed update feed (appcast.xml) and GitHub Release vX.Y.Z.
#   scripts/release.sh notes.md
# The notes (Markdown) show in the app's update window and on the Release page.
# Needs uv, gh (logged in), and the Sparkle signing key in this Mac's keychain (account "immich-viewer").
# DRY_RUN=1 builds the DMG and feed in build/updates and stops before publishing.
set -euo pipefail
cd "${0:A:h}/.."
notes=${1:?usage: scripts/release.sh notes.md}
repo=johnlin10/immich-viewer

if [[ -z ${DRY_RUN:-} ]]; then
  [[ -z $(git status --porcelain) ]] || { echo "Commit your changes first."; exit 1 }
  git fetch -q origin main
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "Push main first."; exit 1 }
fi

dmg=$(scripts/make-dmg.sh | tail -1)
version=${${dmg:t:r}#ImmichViewer-}
tag=v$version
if [[ -z ${DRY_RUN:-} ]] && gh release view $tag -R $repo >/dev/null 2>&1; then
  echo "$tag is already released; bump MARKETING_VERSION first."; exit 1
fi

# The feed keeps earlier entries: start from the one in the latest Release, if any.
updates=build/updates
rm -rf $updates
mkdir -p $updates
cp $dmg $updates/
cp $notes $updates/ImmichViewer-$version.md   # same name as the DMG = its release notes
gh release download -R $repo -p appcast.xml -D $updates 2>/dev/null || true
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --account immich-viewer \
  --download-url-prefix "https://github.com/$repo/releases/download/$tag/" --embed-release-notes $updates

if [[ -n ${DRY_RUN:-} ]]; then echo "Dry run: $updates/appcast.xml and $dmg are ready, nothing published."; exit; fi

# A draft first, so the feed (latest/download/appcast.xml) only switches once the DMG is there too.
gh release create $tag $dmg $updates/appcast.xml -R $repo --draft --target $(git rev-parse HEAD) \
  --title "Immich Viewer $version" --notes-file $notes
gh release edit $tag -R $repo --draft=false
echo "Released $tag"
