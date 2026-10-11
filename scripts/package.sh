#!/bin/zsh
# Packages dist/ClairClass.app into a versioned DMG with an Applications link and the
# user guide, verifies it and writes a SHA-256 file. Contains no user data or models.
set -eu
root="${0:A:h:h}"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$root/Resources/Info.plist")
dmg="$root/dist/ClairClass-$version-arm64.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
codesign --verify --strict "$root/dist/ClairClass.app"
ditto --noqtn "$root/dist/ClairClass.app" "$stage/ClairClass.app"
cp "$root/Resources/使用说明.txt" "$stage/安装与使用.txt"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "ClairClass $version" -srcfolder "$stage" -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
(cd "$root/dist" && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
print -r -- "$dmg"
