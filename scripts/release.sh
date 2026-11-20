#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

identity=${FOLIO_SIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  identities=$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ {print $2}')
  if [[ -z "$identities" || "$identities" == *$'\n'* ]]; then
    echo "需要一个可用的 Developer ID Application 签名身份。有多个时用 FOLIO_SIGN_IDENTITY 指定。" >&2
    exit 1
  fi
  identity=$identities
fi

bash scripts/build.sh
stage=$(mktemp -d "${TMPDIR:-/tmp}/Folio-release.XXXXXXXX")
bundle="$stage/Folio.app"
ditto dist/Folio.app "$bundle"
# Public application payload, even when the local signing job uses a private umask.
chmod -R a+rX "$bundle"
if [[ -n "${FOLIO_RELEASE_VERSION:-}" || -n "${FOLIO_RELEASE_BUILD:-}" ]]; then
  [[ "${FOLIO_RELEASE_VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "${FOLIO_RELEASE_BUILD:-}" =~ ^[1-9][0-9]*$ ]] || exit 2
  plutil -replace CFBundleShortVersionString -string "$FOLIO_RELEASE_VERSION" "$bundle/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$FOLIO_RELEASE_BUILD" "$bundle/Contents/Info.plist"
fi
framework="$bundle/Contents/Frameworks/Sparkle.framework"
sparkle="$framework/Versions/B"
for helper in "$sparkle"/XPCServices/*.xpc "$sparkle/Autoupdate" "$sparkle/Updater.app"; do
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$helper"
done
for target in "$framework" "$bundle/Contents/Helpers/rg" "$bundle"; do
  codesign --force --options runtime --timestamp --sign "$identity" "$target"
done
codesign --verify --deep --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$bundle"

ditto -c -k --norsrc --noextattr --noacl --keepParent "$bundle" "$stage/submit.zip"
for attempt in 1 2 3; do
  if asc notarization submit --file "$stage/submit.zip" --wait --timeout 72h --output table 2>"$stage/notary.err"; then
    break
  fi
  if [[ "$attempt" == 3 ]] || ! grep -qi 'upload failed' "$stage/notary.err"; then
    echo "公证提交失败，详见本地日志 $stage/notary.err" >&2
    exit 1
  fi
  echo "上传中断，重试相同的已签名 ZIP。" >&2
  sleep 3
done
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
spctl --assess --type execute --verbose=2 "$bundle"

version=$(plutil -extract CFBundleShortVersionString raw "$bundle/Contents/Info.plist")
archive="Folio-$version-macOS-$(uname -m).zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$bundle" "$stage/$archive"
bash scripts/verify-release-zip.sh "$stage/$archive"
if [[ -n "${FOLIO_NOTARIZED_ARCHIVE:-}" ]]; then
  cp "$stage/$archive" "$FOLIO_NOTARIZED_ARCHIVE.partial"
  mv -f "$FOLIO_NOTARIZED_ARCHIVE.partial" "$FOLIO_NOTARIZED_ARCHIVE"
fi
updates="$stage/updates"
mkdir "$updates"
mv "$stage/$archive" "$updates/$archive"
tools=.build/vendor/sparkle-2.10.1/bin
account=moosl.Folio.updates
if [[ "$("$tools/generate_keys" --account "$account" -p)" != "$(plutil -extract SUPublicEDKey raw "$bundle/Contents/Info.plist")" ]]; then
  echo "Sparkle 更新签名公钥与应用不一致。" >&2
  exit 1
fi
"$tools/generate_appcast" --account "$account" --download-url-prefix "https://github.com/moosl/Folio/releases/download/v$version/" "$updates"
mv "$updates/$archive" "dist/$archive"
mv "$updates/appcast.xml" dist/appcast.xml
echo "公证发行包和更新清单：dist/$archive、dist/appcast.xml"
