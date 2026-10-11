# Security Policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on the repository page) and include steps to
reproduce, the affected version and macOS version. You should get a reply within a week.

Areas of particular interest: the local model service (it must only listen on
`127.0.0.1`), model downloads and their SHA-256 verification, and handling of the
class data stored in `~/Library/Application Support/ClairClass/`.
