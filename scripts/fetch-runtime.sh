#!/bin/zsh
# Downloads the official Ollama macOS runtime that Clair bundles for local
# inference, verifies Ollama's code signature and unpacks it into ./runtime.
#   scripts/fetch-runtime.sh                     download the pinned release
#   CLAIRCLASS_RUNTIME_ARCHIVE=path/to.tgz ...   use an archive you already have
set -eu
root="${0:A:h:h}"
version="0.40.3"
url="https://github.com/ollama/ollama/releases/download/v$version/ollama-darwin.tgz"
team="3MU9H2V9Y9"   # Ollama's Developer ID team
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archive="${CLAIRCLASS_RUNTIME_ARCHIVE:-}"
if [[ -z "$archive" ]]; then
  print -r -- "Downloading Ollama v$version (~170 MB) from GitHub…"
  curl --fail --location --progress-bar "$url" -o "$work/ollama-darwin.tgz"
  archive="$work/ollama-darwin.tgz"
fi
mkdir "$work/runtime"
tar -xzf "$archive" -C "$work/runtime"
binary="$work/runtime/ollama"
[[ -x "$binary" ]] || { print -u2 "Archive does not contain an ollama executable."; exit 1; }
codesign --verify --strict "$binary"
signer=$(codesign -dv "$binary" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$signer" == "$team" ]] || { print -u2 "Unexpected signer '$signer' (expected Ollama, $team)."; exit 1; }
rm -rf "$root/runtime"
mv "$work/runtime" "$root/runtime"
print -r -- "Ollama v$version runtime ready in $root/runtime"
