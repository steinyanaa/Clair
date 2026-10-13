#!/bin/zsh
# Compiles the non-UI sources with the test driver and runs it. Without arguments it
# runs the unit tests; other modes need audio or the local models, e.g.
#   scripts/test.sh --pipeline .build/french-sample.aiff --realtime   (needs a running model service)
#   scripts/test.sh --study                                          (needs the assistant model)
#   scripts/test.sh --lookup -ClairClassDataRoot /tmp/ClairLookup  (service on 11449; --baseline / --marked compare prompts)
#   scripts/test.sh --bench                                          (library read/write timings)
#   scripts/test.sh --recognize <audio-file> --realtime -ClairClassDataRoot <temporary-directory>
# Add -ClairClassSpeechDiagnostics to write timing-only JSONL into the test root (audio, recognition,
# main-thread lag, translation queue). It also works with --pipeline <audio-file> --realtime.
# The same flag works in a dev app with -ClairClassDataRoot; never use a real class library.
set -eu
root="${0:A:h:h}"
build="$root/.build"
mkdir -p "$build"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -module-name ClairTests -module-cache-path "$build/module-cache" \
  "$root/Sources/Audio.swift" "$root/Sources/Session.swift" "$root/Sources/Translation.swift" \
  "$root/Sources/Library.swift" "$root/Sources/Study.swift" "$root/Sources/Models.swift" "$root/Sources/Preset.swift" "$root/Sources/WordLookup.swift" \
  "$root/Tests/LookupEvaluation.swift" "$root/Tests/TestMain.swift" -o "$build/ClairTests"
codesign --force --sign - --options runtime "$build/ClairTests"
exec "$build/ClairTests" "$@"
