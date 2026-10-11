#!/bin/zsh
# Builds dist/ClairClass.app: compiles the app, generates the icon, bundles the
# Ollama runtime from ./runtime and signs the bundle ad hoc.
#   scripts/build.sh                 full app bundle
#   scripts/build.sh --compile-only  type-check and compile the sources only (CI)
set -eu
root="${0:A:h:h}"
build="$root/.build"
app="$root/dist/ClairClass.app"
mkdir -p "$build"
if [[ "${1:-}" == "--compile-only" ]]; then
  xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
    -module-name ClairClass -module-cache-path "$build/module-cache" \
    "$root"/Sources/*.swift -o "$build/ClairClass"
  print -r -- "Compiled $build/ClairClass"
  exit 0
fi
if [[ ! -x "$root/runtime/ollama" ]]; then
  print -u2 "Missing Ollama runtime. Run scripts/fetch-runtime.sh first."
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -module-name ClairClass -module-cache-path "$build/module-cache" \
  "$root"/Sources/*.swift -o "$app/Contents/MacOS/ClairClass"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
if [[ ! -f "$build/ClairClass.icns" || "$root/Tools/Icon.swift" -nt "$build/ClairClass.icns" ]]; then
  iconset="$build/ClairClass.iconset"
  mkdir -p "$iconset"
  xcrun swift -module-cache-path "$build/module-cache" "$root/Tools/Icon.swift" "$build/icon-1024.png"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$build/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$build/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
  done
  iconutil -c icns "$iconset" -o "$build/ClairClass.icns"
fi
cp "$build/ClairClass.icns" "$app/Contents/Resources/ClairClass.icns"
cp "$root/Resources/使用说明.txt" "$app/Contents/Resources/使用说明.txt"
# Keep the runtime's symlinked dylibs and license files, but not extended attributes:
# detached signatures stored there do not match once the whole app is re-signed.
rm -rf "$app/Contents/Resources/Ollama"
ditto --noextattr --noacl --noqtn "$root/runtime" "$app/Contents/Resources/Ollama"
find "$app/Contents/Resources/Ollama" -name '*.tgz' -delete
codesign --force --sign - --options runtime --entitlements "$root/Resources/ClairClass.entitlements" "$app"
codesign --verify --strict "$app"
print -r -- "$app"
