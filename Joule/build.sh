#!/bin/zsh
# Builds Joule.app next to this script. Needs only the Xcode command line tools.
# VERSION and BUILD set the numbers shown in Finder.
set -e
VERSION=${VERSION:-0.0.0}
BUILD=${BUILD:-1}
cd "${0:a:h}"
A=Joule.app/Contents
rm -rf Joule.app; mkdir -p $A/MacOS $A/Resources
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 Sources/*.swift -o $A/MacOS/Joule
cat > $A/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Joule</string>
<key>CFBundleExecutable</key><string>Joule</string>
<key>CFBundleIdentifier</key><string>local.joule.battery</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>CFBundleIconFile</key><string>Joule</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
T=$(mktemp -d); mkdir $T/J.iconset
$A/MacOS/Joule --icon $T/i.png
for s in 16 32 128 256 512; do
  sips -z $s $s $T/i.png --out $T/J.iconset/icon_${s}x$s.png >/dev/null
  sips -z $((s*2)) $((s*2)) $T/i.png --out $T/J.iconset/icon_${s}x$s@2x.png >/dev/null
done
iconutil -c icns $T/J.iconset -o $A/Resources/Joule.icns; rm -rf $T
codesign --force -s - Joule.app
echo "Built Joule.app $VERSION ($BUILD)"
