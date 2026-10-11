# Contributing to ClairClass

Thanks for helping. Bug reports, translations of the docs, and pull requests are all welcome.

## Before you start

- Search existing issues first. For larger changes, open an issue to discuss the approach before writing code.
- Keep the app local-first: no telemetry, no cloud services, no storing of live audio.

## Development setup

```sh
scripts/fetch-runtime.sh   # once
scripts/build.sh           # app bundle in dist/
scripts/test.sh            # unit tests
```

There is no Xcode project; the scripts call `swiftc` directly. Requirements: Apple silicon, macOS 26, Xcode 26 or later.

For interface checks, run the app against throw-away data instead of your own library:

```sh
open dist/ClairClass.app --args -ClairClassDataRoot /tmp/clairclass-fixture -ClairClassUITestPane assistant
```

## Code style

- Match the surrounding code: naming, density of comments (explain *why*, not *what*), and idioms.
- Use the tokens in `Sources/DesignSystem.swift` for spacing, radii, type and motion instead of literal numbers.
- Prefer native SwiftUI/AppKit controls. Liquid Glass belongs on controls that float over content, not on content.
- Motion only where it explains a change of state; never on keyboard-driven or high-frequency updates, and honour Reduce Motion.
- The code must compile without warnings with `-strict-concurrency=complete`.

## Tests

- Add or update tests in `Tests/TestMain.swift` for behaviour changes; `scripts/test.sh` must pass.
- Changes to recognition or translation quality should come with numbers (see `docs/TESTING.md` for the measurement approach). Changes that do not measurably help are better left out.

## Pull requests

- One focused change per pull request, with a clear description of what and why.
- Include screenshots in light and dark appearance for visible changes.
- Update `CHANGELOG.md` under an "Unreleased" heading and the user guide (`Resources/使用说明.txt`) when behaviour changes.

By contributing you agree that your contributions are licensed under the MIT License.
