#!/bin/zsh
# Hidden fixture window: no microphone, model or real classroom library.
set -eu
root="${0:A:h:h}"
build="$root/.build/caption-tests"
mkdir -p "$build"
sed '/^@main$/d' "$root/Sources/App.swift" > "$build/App.swift"
sources=("$root"/Sources/*.swift)
sources=("${(@)sources:#$root/Sources/App.swift}")
xcrun swiftc -swift-version 5 -parse-as-library -Onone -g -target arm64-apple-macos26.0 \
  -module-name ClairCaptionTests -module-cache-path "$root/.build/module-cache" \
  "${sources[@]}" "$build/App.swift" "$root/Tests/CaptionLayoutTests.swift" -o "$build/ClairCaptionTests"
source "$root/scripts/trash.sh"
fixture=$(mktemp -d /private/tmp/ClairCaptions.XXXXXX)
trap 'trash_artifact "$fixture"' EXIT
"$build/ClairCaptionTests" -ClairClassDataRoot "$fixture"
