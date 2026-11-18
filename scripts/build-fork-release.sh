#!/bin/bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo 'Usage: scripts/build-fork-release.sh VERSION BUILD_NUMBER' >&2
  exit 2
fi
version="$1"
build_number="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${FORK_DERIVED_DATA:-$root/build}"
release_output="${FORK_RELEASE_OUTPUT:-$root/dist}"
account="${SPARKLE_KEYCHAIN_ACCOUNT:-Offbrand-Window.boring-notch}"
mkdir -p "$derived" "$release_output"
xcodebuild -project "$root/boringNotch.xcodeproj" -scheme boringNotch -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" CODE_SIGNING_ALLOWED=NO build
stage="$(mktemp -d "$derived/fork-release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Boring Notch.app"
ditto "$derived/Build/Products/Release/Boring Notch.app" "$app"
python3 - "$root/boringNotch/boringNotch.entitlements" "$app/Contents/Info.plist" "$stage/app.entitlements" <<'PY'
import plistlib,sys
source,info,out=sys.argv[1:]
bundle=plistlib.load(open(info,'rb'))['CFBundleIdentifier']
def expand(value):
    if isinstance(value,str):return value.replace('$(PRODUCT_BUNDLE_IDENTIFIER)',bundle)
    if isinstance(value,list):return [expand(x) for x in value]
    if isinstance(value,dict):return {k:expand(v) for k,v in value.items()}
    return value
plistlib.dump(expand(plistlib.load(open(source,'rb'))),open(out,'wb'))
PY
codesign --force --deep --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$app"
codesign --force --sign - --entitlements "$root/BoringNotchXPCHelper/BoringNotchXPCHelper.entitlements" \
  "$app/Contents/XPCServices/BoringNotchXPCHelper.xpc"
codesign --force --sign - --entitlements "$stage/app.entitlements" "$app"
codesign --verify --deep --strict "$app"
sparkle_bin="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
actual_key="$("$sparkle_bin/generate_keys" --account "$account" -p)"
expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
if [[ "$actual_key" != "$expected_key" ]]; then
  echo 'Signing key does not match the app public key; release stopped.' >&2
  exit 1
fi
archive="$release_output/Boring-Notch-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
signature="$("$sparkle_bin/sign_update" --account "$account" -p "$archive")"
"$sparkle_bin/sign_update" --account "$account" --verify "$archive" "$signature"
python3 "$root/scripts/create-fork-appcast.py" --version "$version" --build "$build_number" \
  --archive "$archive" --signature "$signature" --output "$root/updater/appcast.xml"
(cd "$release_output" && shasum -a 256 "$(basename "$archive")") > "$archive.sha256"
echo "Signed release archive: $archive"
