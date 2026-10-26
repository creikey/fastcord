#!/bin/sh
# Re-signs build/pkg/Fastcord.app with a Developer ID, notarizes and staples it,
# and rewrites dist/fastcord-macos.zip. Used by CI when the Apple secrets exist:
#   MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD, MACOS_SIGN_IDENTITY ("Developer ID Application: Name (TEAMID)"),
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64 (App Store Connect API key for notarytool).
set -e
cd "$(dirname "$0")/.."
APP=build/pkg/Fastcord.app
KC="$RUNNER_TEMP/sign.keychain-db"
KCPASS="$(uuidgen)"

echo "$MACOS_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$RUNNER_TEMP/cert.p12" -k "$KC" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')

cat > "$RUNNER_TEMP/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --timestamp --entitlements "$RUNNER_TEMP/entitlements.plist" \
	--sign "$MACOS_SIGN_IDENTITY" --keychain "$KC" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "$ASC_KEY_P8_BASE64" | base64 --decode > "$RUNNER_TEMP/key.p8"
ditto -c -k --keepParent "$APP" "$RUNNER_TEMP/notarize.zip"
xcrun notarytool submit "$RUNNER_TEMP/notarize.zip" --key "$RUNNER_TEMP/key.p8" \
	--key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

rm -f dist/fastcord-macos.zip
ditto -c -k --keepParent "$APP" dist/fastcord-macos.zip
echo "notarized dist/fastcord-macos.zip"
