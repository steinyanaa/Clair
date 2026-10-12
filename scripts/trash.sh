# Sourced by build/package: keep replaced artifacts recoverable, including staging files.
trash_artifact() {
  if [[ -e "$1" || -L "$1" ]]; then
    mkdir -p "$HOME/.Trash"
    mv "$1" "$HOME/.Trash/Clair-${1:t}-$(uuidgen)"
  fi
}
