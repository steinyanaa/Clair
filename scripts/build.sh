#!/bin/zsh
# Builds dist/Clair.app: compiles the app, builds the icon, bundles the
# Ollama runtime from ./runtime and signs the bundle ad hoc.
#   scripts/build.sh                 full app bundle
#   scripts/build.sh --compile-only  type-check and compile the sources only (CI)
set -eu
root="${0:A:h:h}"
source "$root/scripts/trash.sh"
build="$root/.build"
app="$root/dist/Clair.app"
mkdir -p "$build"
if [[ "${1:-}" == "--compile-only" ]]; then
  xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
    -module-name Clair -module-cache-path "$build/module-cache" \
    "$root"/Sources/*.swift -o "$build/Clair"
  print -r -- "Compiled $build/Clair"
  exit 0
fi
if pgrep -x Clair > /dev/null; then
  print -u2 "Clair is running. Quit it before replacing or signing dist/Clair.app."
  exit 1
fi
if [[ ! -x "$root/runtime/ollama" ]]; then
  print -u2 "Missing Ollama runtime. Run scripts/fetch-runtime.sh first."
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -module-name Clair -module-cache-path "$build/module-cache" \
  "$root"/Sources/*.swift -o "$app/Contents/MacOS/Clair"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
# The app icon is built from the 1024 px master in Resources/AppIcon.png.
if [[ ! -f "$build/Clair.icns" || "$root/Resources/AppIcon.png" -nt "$build/Clair.icns" ]]; then
  iconset="$build/Clair.iconset"
  trash_artifact "$iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
  done
  iconutil -c icns "$iconset" -o "$build/Clair.icns"
fi
cp "$build/Clair.icns" "$app/Contents/Resources/Clair.icns"
cp "$root/Resources/使用说明.txt" "$app/Contents/Resources/使用说明.txt"
# Keep the runtime's symlinked dylibs and license files, but not extended attributes:
# detached signatures stored there do not match once the whole app is re-signed.
trash_artifact "$app/Contents/Resources/Ollama"
ditto --noextattr --noacl --noqtn "$root/runtime" "$app/Contents/Resources/Ollama"
while IFS= read -r -d '' archive; do
  trash_artifact "$archive"
done < <(find "$app/Contents/Resources/Ollama" -name '*.tgz' -print0)
codesign --force --sign - --options runtime --entitlements "$root/Resources/Clair.entitlements" "$app"
codesign --verify --strict "$app"
print -r -- "$app"
