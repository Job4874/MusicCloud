#!/bin/bash
# Run on macOS with Xcode installed; this does not sign or install an app.
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_dir"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build requires macOS and Xcode. See README.md for Windows installation options." >&2
  exit 1
fi
xcodebuild -version
build_dir="$project_dir/build"
mkdir -p "$build_dir"
build_dir="$(cd -- "$build_dir" && pwd -P)"
xcodebuild -project MusicCloud.xcodeproj -scheme MusicCloud \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO build

app="$build_dir/Build/Products/Release-iphoneos/MusicCloud.app"
[[ -d "$app" ]] || { echo "Expected app was not produced." >&2; exit 1; }
# A unique staging directory keeps prior build outputs intact.
package_dir="$(mktemp -d "$build_dir/ipa-package.XXXXXX")"
package_dir="$(cd -- "$package_dir" && pwd -P)"
cleanup_package() {
  # Verify the resolved absolute target stays under the intended build root
  # immediately before recursively removing only this mktemp staging folder.
  if [[ "$package_dir" == "$build_dir"/ipa-package.* && -d "$package_dir" && ! -L "$package_dir" ]]; then
    rm -rf -- "$package_dir"
  fi
}
trap cleanup_package EXIT
mkdir -p "$package_dir/Payload"
ditto "$app" "$package_dir/Payload/MusicCloud.app"
ditto -c -k --keepParent "$package_dir/Payload" "$build_dir/MusicCloud-unsigned.ipa"
echo "Unsigned package: $build_dir/MusicCloud-unsigned.ipa"
echo "This IPA must be signed for your iPhone before it can run."

