# Clair · 法语听课助手

**macOS 上完全本机运行的法语 → 简体中文课堂实时字幕。**

[English](README.md)

Clair（原名 ClairClass）用麦克风（现场课堂）或系统声音（网课、视频）听课，用 Apple 本机语音识别转写法语，再用本地 TranslateGemma 模型逐句翻译成简体中文。课后可用本地 Gemma 模型整理笔记、生成纪要、提取术语表或回答问题，回答中的时间点可以跳回原句。所有内容都不上传云端。

![转录（浅色）](docs/images/transcript-light.png)

## 功能

- **双语实时字幕**：法语原文与中文译文同窗显示；音源可选麦克风、系统声音或导入音频（直接拖进窗口）。
- **整句翻译**：讲者句中停顿切开的半句会先合并再翻译；「euh」等语气词和口吃重复不送去翻译。
- **如实标注**：使用系统翻译回退的句子会标注来源，并在暂停或下课后自动改用 Gemma 重译；识别把握低的实词以橙色虚线标出，方便对照原声核对。
- **课堂助手**：基于转录整理笔记、生成纪要、术语表（以表格显示）和问答，并标注时间来源；可导出 Markdown。
- **资料库**：项目文件夹、多选与批量移动/删除、「最近删除」可恢复或经确认后彻底删除。
- **macOS 26 原生设计**：侧栏 / 列表 / 详情三栏、Liquid Glass 采集控制条、⌘K 命令面板、完整菜单与快捷键、浅色与深色外观。
- **本地模型在设置中管理**：从官方 Ollama 仓库下载 TranslateGemma 4B/12B 与 Gemma 3 4B/12B，校验 SHA-256；内置模型服务意外退出时自动重启。

| 课堂助手（深色） | 最近删除中的批量选择 |
|---|---|
| ![课堂助手](docs/images/assistant-dark.png) | ![批量选择](docs/images/batch-recently-deleted.png) |

## 环境要求

- Apple 芯片 Mac，**macOS 26（Tahoe）**或更新；使用 4B 模型建议 16 GB 以上内存。
- 构建需要 **Xcode 26** 或更新（命令行工具即可）。
- 两个 4B 模型约需 7 GB 磁盘空间。

## 构建与运行

```sh
git clone https://github.com/steinyanaa/ClairClass.git
cd ClairClass
scripts/fetch-runtime.sh      # 下载官方 Ollama 运行时（约 170 MB）并校验签名
scripts/build.sh              # 生成 dist/Clair.app
open dist/Clair.app
```

首次打开后，在 **设置 → 本地模型** 中下载翻译模型和课堂助手模型。第一次使用麦克风或系统声音时，macOS 会请求相应权限。

`scripts/package.sh` 会在 `dist/` 中生成 DMG。构建产物为临时签名、未经公证；如需分发给其他 Mac，请使用自己的 Developer ID 签名。

## 测试

```sh
scripts/test.sh                          # 单元测试（不需要模型）
scripts/make-sample-audio.sh             # 合成公开的法语测试讲课音频
scripts/test.sh --pipeline .build/french-sample.aiff --realtime   # 端到端测试，需要 App 的模型服务在运行
scripts/test.sh --study                  # 课堂助手测试，需要课堂助手模型
```

实测数据与已知限制见 [docs/TESTING.zh-CN.md](docs/TESTING.zh-CN.md)。

## 隐私

- 语音识别、翻译和课堂助手都在本机运行；模型服务只监听 `127.0.0.1`，并关闭 Ollama 云端功能。
- 实时音频和屏幕画面不保存。转录、译文和助手内容以 JSON 保存在 `~/Library/Application Support/ClairClass/`。
- 只有下载 Apple 语言资源和你选择的模型时才联网。

## 参与贡献

欢迎提交 Issue 和 Pull Request，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

Clair 以 [MIT 许可证](LICENSE) 发布。内置的 Ollama 运行时和可下载的 Gemma 模型各有其许可条款，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。模型输出可能出错，请始终对照转录核对译文和笔记。
