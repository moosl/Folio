#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=13.0
vendor=.build/vendor
bundle=dist/Folio.app
extra=()
if [[ "${1:-}" == "--test" ]]; then
  bundle=.build/tests/Folio.app
  extra=(-D FOLIO_TEST tests/Integration.swift tests/SourceFiles.swift)
elif [[ "${1:-}" == "--store" ]]; then
  bundle=.build/app-store/Folio.app
  extra=(-D FOLIO_STORE)
elif [[ "${1:-}" == "--benchmark" ]]; then
  bundle=.build/benchmark/Folio.app
  extra=(-D FOLIO_BENCH tests/Performance.swift)
fi
app="$bundle/Contents"
mkdir -p "$vendor" "$app/MacOS" "$app/Resources" "$app/Helpers"
fetch() {
  local archive=$1 url=$2 digest=$3
  if ! test -s "$archive"; then
    curl -fL --retry 3 "$url" -o "$archive.part"
    mv "$archive.part" "$archive"
  fi
  echo "$digest  $archive" | shasum -a 256 -c -
}
sparkle_version=2.10.1
updater_flags=()
if [[ "${1:-}" != "--store" ]]; then
  sparkle="$vendor/sparkle-$sparkle_version"
  fetch "$sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
  if [[ ! -d "$sparkle/Sparkle.framework" ]]; then
    mkdir -p "$sparkle"
    tar -xf "$sparkle.tar.xz" -C "$sparkle"
  fi
  mkdir -p "$app/Frameworks"
  ditto "$sparkle/Sparkle.framework" "$app/Frameworks/Sparkle.framework"
  cp "$sparkle/LICENSE" "$app/Resources/Sparkle-LICENSE"
  updater_flags=(-F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
cmark="$vendor/swift-cmark-0.6.0"
fetch "$vendor/cmark.tar.gz" https://codeload.github.com/swiftlang/swift-cmark/tar.gz/refs/tags/0.6.0 6e2d1ecc9791bd7b2cfec22b5a2bc108c4f549c0b09def8953204467efabcb12
test -d "$cmark" || tar -xzf "$vendor/cmark.tar.gz" -C "$vendor"
case "$(uname -m)" in
  arm64) rgarch=aarch64; digest=378e973289176ca0c6054054ee7f631a065874a352bf43f0fa60ef079b6ba715 ;;
  x86_64) rgarch=x86_64; digest=64811cb24e77cac3057d6c40b63ac9becf9082eedd54ca411b475b755d334882 ;;
esac
rgname="ripgrep-15.1.0-$rgarch-apple-darwin"
fetch "$vendor/$rgname.tar.gz" "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/$rgname.tar.gz" "$digest"
test -d "$vendor/$rgname" || tar -xzf "$vendor/$rgname.tar.gz" -C "$vendor"
cp "$vendor/$rgname/rg" "$app/Helpers/rg"
cp "$vendor/$rgname/COPYING" "$app/Resources/ripgrep-COPYING"
cp "$vendor/$rgname/LICENSE-MIT" "$app/Resources/ripgrep-LICENSE-MIT"
cp "$cmark/COPYING" "$app/Resources/cmark-COPYING"
objects=".build/$(uname -m)"
mkdir -p "$objects"
if ! test -f "$objects/cmark.a"; then
  for source in "$cmark"/src/*.c "$cmark"/extensions/*.c; do
    clang -O2 -DCMARK_THREADING -I"$cmark/src/include" -I"$cmark/extensions/include" -c "$source" -o "$objects/$(basename "$source" .c).o"
  done
  libtool -static -o "$objects/cmark.a" "$objects"/*.o
fi
yaml="$vendor/yaml-0.2.5"
fetch "$vendor/yaml-0.2.5.tar.gz" https://pyyaml.org/download/libyaml/yaml-0.2.5.tar.gz c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4
test -d "$yaml" || tar -xzf "$vendor/yaml-0.2.5.tar.gz" -C "$vendor"
yaml_objects="$objects/libyaml-0.2.5"
if ! test -f "$yaml_objects/libyaml.a"; then
  mkdir -p "$yaml_objects"
  for source in "$yaml"/src/*.c; do
    clang -O2 -DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2 -DYAML_VERSION_PATCH=5 '-DYAML_VERSION_STRING="0.2.5"' -I"$yaml/include" -c "$source" -o "$yaml_objects/$(basename "$source" .c).o"
  done
  libtool -static -o "$yaml_objects/libyaml.a" "$yaml_objects"/*.o
fi
cp "$yaml/License" "$app/Resources/libyaml-License"
# Some mixed CLT installs expose two module maps for SwiftBridging.
swift_flags=()
swift_include="$(dirname "$(xcrun -f swiftc)")/../include/swift"
if [[ -f "$swift_include/module.modulemap" && -f "$swift_include/bridging.modulemap" ]] && grep -q "module SwiftBridging" "$swift_include/module.modulemap"; then
  : > .build/empty.modulemap
  printf '{"version":0,"roots":[{"type":"file","name":"%s/module.modulemap","external-contents":"%s/.build/empty.modulemap"}]}' "$(cd "$swift_include" && pwd -P)" "$PWD" > .build/swift-overlay.json
  swift_flags+=(-vfsoverlay "$PWD/.build/swift-overlay.json" -module-cache-path "$PWD/.build/cltcached" -Xcc -ivfsoverlay -Xcc "$PWD/.build/swift-overlay.json")
fi
swiftc "${swift_flags[@]}" -O -whole-module-optimization "${updater_flags[@]}" -Xlinker -dead_strip -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -I "$cmark/src/include" -I "$cmark/extensions/include" -I app/CYaml -Xcc "-I$PWD/$yaml/include" app/*.swift "${extra[@]}" "$objects/cmark.a" "$yaml_objects/libyaml.a" -o "$app/MacOS/Folio"
iconset=.build/FolioAppIcon.iconset
icon_source=app/Resources/FolioAppIcon.icon/Assets/Folder.png
icon_digest=$(shasum -a 256 "$icon_source" | cut -d ' ' -f 1)
icon_cache=".build/FolioAppIcon-$icon_digest.icns"
if [[ ! -f "$icon_cache" ]]; then
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size*2))" "$((size*2))" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$icon_cache"
fi
cp "$icon_cache" "$app/Resources/FolioAppIcon.icns"
cp app/Resources/Assets.car "$app/Resources/"
for localization in app/Resources/*.lproj; do
  ditto "$localization" "$app/Resources/$(basename "$localization")"
done
if [[ -f "$app/Resources/Folio.icns" ]]; then unlink "$app/Resources/Folio.icns"; fi
cp app/Resources/FolderBox{,Dark}.svg "$app/Resources/"
cp app/Info.plist "$app/Info.plist"
if [[ "${1:-}" == "--test" ]]; then
  cp tests/Fixtures/silence.mp3 "$app/Resources/test-silence.mp3"
  plutil -replace CFBundleIdentifier -string local.folio.integration "$app/Info.plist"
elif [[ "${1:-}" == "--benchmark" ]]; then
  plutil -replace CFBundleIdentifier -string local.folio.benchmark "$app/Info.plist"
fi
if [[ "${1:-}" == "--store" ]]; then
  cp store/PrivacyInfo.xcprivacy "$app/Resources/"
  for key in SUFeedURL SUPublicEDKey SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
    plutil -remove "$key" "$app/Info.plist"
  done
  plutil -replace CFBundleIdentifier -string "${FOLIO_STORE_BUNDLE_ID:-io.github.moosl.Folio}" "$app/Info.plist"
  plutil -insert LSApplicationCategoryType -string public.app-category.developer-tools "$app/Info.plist"
  plutil -insert CFBundleDocumentTypes.0.CFBundleTypeName -string "Text and project documents" "$app/Info.plist"
  plutil -insert CFBundleDocumentTypes.1.CFBundleTypeName -string "Images and audio" "$app/Info.plist"
  plutil -insert ITSAppUsesNonExemptEncryption -bool NO "$app/Info.plist"
  plutil -replace CFBundleVersion -string "${FOLIO_STORE_BUILD:-7}" "$app/Info.plist"
  signer=${FOLIO_STORE_APP_IDENTITY:--}
  codesign --force --sign "$signer" --entitlements store/Helper.entitlements "$app/Helpers/rg"
  codesign --force --sign "$signer" --entitlements store/Folio.entitlements "$bundle"
else
  codesign --force --sign - "$app/Helpers/rg"
  codesign --force --sign - "$bundle"
fi
touch "$bundle"
echo "Built $bundle"
