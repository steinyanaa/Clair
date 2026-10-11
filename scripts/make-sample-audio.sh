#!/bin/zsh
# Synthesises the public test lecture (Tests/french-sample.txt) with a French system
# voice. Optional: repeat it N times for long-running tests.
#   scripts/make-sample-audio.sh [repeat-count]
set -eu
root="${0:A:h:h}"
build="$root/.build"
mkdir -p "$build"
voice=$(say -v '?' | awk '/fr_FR/ { sub(/ +fr_FR.*/, ""); print; exit }')
[[ -n "$voice" ]] || { print -u2 "No French (fr_FR) voice installed. Add one in System Settings → Accessibility → Spoken Content."; exit 1; }
say -v "$voice" -f "$root/Tests/french-sample.txt" -o "$build/french-sample.aiff"
print -r -- "$build/french-sample.aiff (voice: $voice)"
if [[ -n "${1:-}" ]]; then
  xcrun swift -module-cache-path "$build/module-cache" "$root/Tools/RepeatAudio.swift" \
    "$build/french-sample.aiff" "$build/french-repeated.caf" "$1"
fi
