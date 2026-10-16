#!/bin/zsh
# Release DMG: universal app signed by build-app.sh, plus an Applications link.
set -eu
cd "${0:A:h:h}"
SAYVIA_UNIVERSAL=1 scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/Sayvia.app/Contents/Info.plist)
STAGE=$(mktemp -d -t sayvia-dmg)
trap 'rm -rf -- "$STAGE"' EXIT
cp -R dist/Sayvia.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Sayvia -srcfolder "$STAGE" -format UDZO -ov "dist/Sayvia-$VERSION.dmg"
print "DMG: dist/Sayvia-$VERSION.dmg"
