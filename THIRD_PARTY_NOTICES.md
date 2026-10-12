# Third-Party Notices

Clair's own source code is MIT-licensed (see [LICENSE](LICENSE)). The repository
contains no third-party code or model weights. The components below are fetched at
build time or downloaded by the user, and keep their own licenses.

## Bundled in built apps: Ollama runtime

`scripts/fetch-runtime.sh` downloads the official macOS release of
[Ollama](https://github.com/ollama/ollama) (MIT License), which `scripts/build.sh`
copies into the app bundle together with the license files it ships:

| Component | License (file in the runtime) |
|---|---|
| Ollama | MIT |
| llama.cpp / ggml and vendored code | MIT (`LLAMA_CPP_LICENSE`, `LLAMA_CPP_VENDORS_LICENSE`) |
| MLX, MLX C | MIT (`MLX_LICENSE`, `MLX_C_LICENSE`) |
| cpp-httplib | MIT (`CPP_HTTPLIB_LICENSE`) |
| {fmt} | MIT-style (`FMT_LICENSE`) |
| Go dependencies | as listed in `GO_LICENSE` |
| PicoJSON | BSD 2-Clause (`PICOJSON_LICENSE`) |
| DLPack | Apache License 2.0 (`DLPACK_LICENSE`) |
| XGrammar | Apache License 2.0 (`XGRAMMAR_LICENSE`, `XGRAMMAR_NOTICE`) |

The license texts are inside the app at `Clair.app/Contents/Resources/Ollama/`.

## Downloaded on request: models

Models are downloaded from the official Ollama registry only when the user chooses
them in Settings. They are not distributed with Clair.

- **TranslateGemma** and **Gemma 3** are provided by Google under the
  [Gemma Terms of Use](https://ai.google.dev/gemma/terms) and the
  [Gemma Prohibited Use Policy](https://ai.google.dev/gemma/prohibited_use_policy).
  By downloading them you agree to those terms.

## Apple frameworks

Speech recognition (Speech), system translation fallback (Translation), audio capture
(AVFoundation, ScreenCaptureKit) and the interface (SwiftUI, AppKit) use frameworks
that are part of macOS.
