#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# Full Xcode supplies SwiftUI compiler plugins missing from recent Command Line Tools SDKs.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# SAYVIA_UNIVERSAL=1 builds one binary for Apple silicon and Intel (release DMGs).
ARCHS=()
[[ "${SAYVIA_UNIVERSAL:-}" == 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BUILD_DIR=$(swift build -c release "${ARCHS[@]}" --show-bin-path)
APP="${SAYVIA_APP_PATH:-$PWD/dist/Sayvia.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/Sayvia" "$APP/Contents/MacOS/Sayvia"
# SwiftPM may change a resource bundle from flat files to Contents/Resources.
# Preserve the previous generated bundle locally, then copy a fresh one; merging
# can retain stale rules and invalidate the resource seal of a signed app.
if [[ -d "$APP/Contents/Resources/Sayvia_Sayvia.bundle" ]]; then
    RESOURCE_BACKUP=$(mktemp -d -t sayvia-build-resources)
    mv "$APP/Contents/Resources/Sayvia_Sayvia.bundle" "$RESOURCE_BACKUP/Sayvia_Sayvia.bundle"
fi
cp -R "$BUILD_DIR/Sayvia_Sayvia.bundle" "$APP/Contents/Resources/"
# UI translations, keyed by the Chinese source text.
cp -R Localization/*.lproj "$APP/Contents/Resources/"
# The app icon is drawn from the same SwiftUI geometry as the in-app logo.
ICON_TEMP=$(mktemp -d -t sayvia-icon)
"$BUILD_DIR/Sayvia" --render-icon "$ICON_TEMP/AppIcon.iconset"
iconutil -c icns "$ICON_TEMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf -- "$ICON_TEMP"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Sayvia</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleDisplayName</key><string>Sayvia</string>
<key>CFBundleIdentifier</key><string>io.github.rowanhfinch.sayvia</string>
<key>CFBundleExecutable</key><string>Sayvia</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Sayvia 录制你主动发起的语音输入，保存到本机并发送到你选择的语音识别服务。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${SAYVIA_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --sign "$SAYVIA_SIGNING_IDENTITY" "$APP"
else
    # A persistent, certificate-bound identity keeps this local app recognizable across updates.
    # Developer ID distribution can use SAYVIA_SIGNING_IDENTITY; this local certificate isn't notarization.
    IDENTITY_NAME="Sayvia Release Signing"
    CERTIFICATE=$(security find-certificate -c "$IDENTITY_NAME" -Z 2>/dev/null || true)
    FINGERPRINT=$(print -r -- "$CERTIFICATE" | sed -n 's/^SHA-1 hash: //p' | head -n 1)
    if [[ -z "$FINGERPRINT" ]]; then
        SIGNING_TEMP=$(mktemp -d -t sayvia-signing)
        chmod 700 "$SIGNING_TEMP"
        trap 'rm -rf -- "$SIGNING_TEMP"' EXIT
        cat > "$SIGNING_TEMP/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Sayvia Release Signing
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
        (umask 077; /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$SIGNING_TEMP/openssl.cnf" -keyout "$SIGNING_TEMP/key.pem" -out "$SIGNING_TEMP/cert.pem" 2>/dev/null)
        SIGNING_PASSWORD=$(/usr/bin/openssl rand -hex 32)
        (umask 077; print -r -- "$SIGNING_PASSWORD" > "$SIGNING_TEMP/password")
        /usr/bin/openssl pkcs12 -export -inkey "$SIGNING_TEMP/key.pem" -in "$SIGNING_TEMP/cert.pem" -out "$SIGNING_TEMP/identity.p12" -passout "file:$SIGNING_TEMP/password" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES
        LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
        security import "$SIGNING_TEMP/identity.p12" -k "$LOGIN_KEYCHAIN" -P "$SIGNING_PASSWORD" -T /usr/bin/codesign
        FINGERPRINT=$(/usr/bin/openssl x509 -in "$SIGNING_TEMP/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
        rm -rf -- "$SIGNING_TEMP"
        trap - EXIT
    fi
    [[ "$FINGERPRINT" =~ '^[A-Fa-f0-9]{40}$' ]] || { print -u2 "Invalid Sayvia signing certificate fingerprint"; exit 1; }
    codesign --force --sign "$FINGERPRINT" --requirements "=designated => identifier \"io.github.rowanhfinch.sayvia\" and certificate leaf = H\"$FINGERPRINT\"" "$APP"
fi
codesign --verify --strict "$APP"
print "Built: $APP"
