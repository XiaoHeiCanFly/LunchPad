#!/bin/bash
# Build a self-contained, certificate-free distribution from a compiled app.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: bash scripts/package-dmg.sh /path/to/LunchPad.app /path/to/output" >&2
  exit 1
fi

app_path="$1"
output_path="$2"
repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -d "$app_path" && -f "$app_path/Contents/Info.plist" ]] || {
  echo "Missing app bundle: $app_path" >&2; exit 1;
}
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
  echo "Invalid bundle version: $version" >&2; exit 1;
}
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
architectures=" $(lipo -archs "$app_path/Contents/MacOS/$executable") "
[[ "$architectures" == *' arm64 '* && "$architectures" == *' x86_64 '* ]] || {
  echo "Expected a universal app; found:$architectures" >&2; exit 1;
}

mkdir -p "$output_path"
output_path="$(cd "$output_path" && pwd)"
artifact_name="LunchPad-${version}-universal"
for file in "$artifact_name.dmg" "$artifact_name-source.tar.gz" SHA256SUMS.txt; do
  [[ ! -e "$output_path/$file" ]] || { echo "Refusing to overwrite $output_path/$file" >&2; exit 1; }
done

# A runner's temporary directory is cleaned up by Actions after the job.
# Keep local staging directories too, making packaging failures inspectable.
staging_path="$(mktemp -d "${TMPDIR:-/tmp}/LunchPad-dmg.XXXXXX")"
ditto "$app_path" "$staging_path/LunchPad.app"
ln -s /Applications "$staging_path/Applications"
cp "$repo_path/LICENSE" "$repo_path/NOTICE.md" "$staging_path/"
cp "$repo_path/docs/UNSIGNED-BUILD.md" "$staging_path/安装说明.md"

# ARM binaries need a valid code signature. Ad-hoc signing requires no secret
# and does NOT provide Developer ID trust or Apple notarization.
codesign --force --sign - --timestamp=none "$staging_path/LunchPad.app"
codesign --verify --strict --verbose=2 "$staging_path/LunchPad.app"

git -C "$repo_path" archive --format=tar.gz --prefix="LunchPad-${version}/" \
  --output="$output_path/$artifact_name-source.tar.gz" HEAD
hdiutil create -volname "LunchPad $version" -srcfolder "$staging_path" \
  -format UDZO -fs HFS+ "$output_path/$artifact_name.dmg"
hdiutil verify "$output_path/$artifact_name.dmg"
(
  cd "$output_path"
  shasum -a 256 "$artifact_name.dmg" "$artifact_name-source.tar.gz" > SHA256SUMS.txt
)
echo "Packages: $output_path"
echo "Staging: $staging_path"
