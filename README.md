# Docling Mac

[![macOS CI](https://github.com/superjackche/docling-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/superjackche/docling-mac/actions/workflows/ci.yml)

一个极简、原生的 macOS 文档转换工具。拖入文件或文件夹，在本机解析，预览并批量导出 Markdown、HTML、Docling JSON。

基于 [Docling](https://github.com/docling-project/docling)，独立非官方客户端。SwiftUI / AppKit 界面，无第三方 Swift 包。客户端采用 [MIT](LICENSE) 协议。

## 使用

需要 **Apple Silicon Mac（M 系列）和 macOS 14+**。当前锁定引擎不支持 Intel Mac。

从 [GitHub Releases](https://github.com/superjackche/docling-mac/releases/latest) 下载 DMG，将应用拖到 Applications；也可解压 ZIP。安装包仅含约 3 MB 的客户端，解析环境与模型首次使用时单独下载。

当前公开包采用 ad-hoc 签名，尚未做 Developer ID 公证。macOS 可能阻止首次打开；确认来源后可按 [Apple 的说明](https://support.apple.com/102445) 在「系统设置 → 隐私与安全性」中允许打开。

1. 安装 [uv](https://docs.astral.sh/uv/getting-started/installation/)：`brew install uv`。
2. 打开 `Docling Mac.app`，点击「准备本地引擎」。应用安装锁定的 Python 3.12 与依赖。
3. 拖入多个文件或文件夹，也可按 `⌘O` 选择。放下或选择后自动开始转换。
4. 核对预览，复制 Markdown、单独另存，或用工具栏「批量导出」保存全部已完成结果。同名文件自动编号。

整个窗口内容区（列表、预览及空白处）均接受文件拖入；拖入时显示整窗高亮和「松开以添加文档」。

支持 PDF、DOCX、PPTX、XLSX、HTML、Markdown、CSV，以及 PNG、JPEG、TIFF、BMP、WebP。扫描件使用 Apple OCR 识别中英文。图片嵌入导出文件；部分成功与失败均明确显示，可手动重试。

首次处理 PDF / 图片需要联网准备排版与表格模型，也可提前在「引擎与模型」中准备。准备后实际验证离线加载；转换一律使用 Hugging Face 离线模式。应用从 `~/.local/bin/uv`、`/opt/homebrew/bin/uv` 或 `/usr/local/bin/uv` 查找 uv。环境与模型约占 1.6 GB，首次安装另需下载缓存空间。

## 批量处理与占用

- 同批只启动一个转换进程、加载一次转换器。文件串行处理，CPU 推理并行度为 2，PDF 解析器线程为 2，流水线批大小为 2、队列为 4。Docling 流水线和 Apple OCR 还可能创建内部线程，这不是系统总线程数上限。
- 批次结束即释放 Python 与模型；没有常驻引擎、监听端口或定时轮询。导入、预览、导出在后台执行，主线程负责界面。运行期间可以继续加入文件，下一批处理。
- 同一路径、大小和修改时间未变时不重复入队，而是把原记录移到顶部并选中。“已复用”提示保留 4 秒，随后恢复完成状态。不同路径的相同内容按流式 SHA-256 复用转换结果；内容、扩展名、OCR 开关、引擎锁、后端代码、配置或模型身份变化会使缓存失效。
- 默认结果缓存上限 512 MiB、14 天。当前队列引用的结果暂时保留，可能超过上限；清空队列或退出后清理到上限。缓存不是历史库或备份，队列不会在退出后恢复，请及时导出。
- 预览最多读取每种格式 512 KiB，超大 HTML 切换为有限文本预览；复制和导出保留完整内容。导出流式复制，每次处理 1 MiB；相同内容的 JSON 导出会恢复各自的来源文件名。
- 导入后自动转换；只有手动停止后的队列显示「继续处理」。停止期间新增的文件等待用户继续，重试会自动运行。关闭窗口继续当前任务；退出应用会等待转换进程组停止，并取消导入和导出。失败不自动重试，不完整结果不进入复用缓存。

运行参数集中在 [Backend/runtime.json](Backend/runtime.json)，修改后重新构建。实际性能数据与测量条件见 [docs/PERFORMANCE.md](docs/PERFORMANCE.md)。

## 引擎与上游更新

使用随客户端测试的完整依赖锁，不在后台升级。设置中可手动检查 PyPI 上游版本、打开上游发布说明、修复锁定环境或重新验证现有模型。检查更新仅查询版本，不会安装新版本。已验证模型的重新验证保持离线。

维护者升级时更新 `Backend/pyproject.toml` 与 `Backend/uv.lock`，运行格式与批量回归，重新准备及验证模型，再发布客户端。锁变化后应用要求重新准备引擎；旧结果缓存不会混入新引擎输出。

## 隐私与数据

- 文档在本地 Python 子进程处理，无账号、云解析 API 或应用遥测。
- 安装连接 Python / PyPI 下载源；模型准备连接 Hugging Face。手动更新检查访问 PyPI。
- 禁用 Docling 远端服务与外部插件；仅接收本地文件。HTML / Markdown 外部图片不主动下载。
- 应用内预览禁用 JavaScript，并用 CSP 阻止网络资源；导出 HTML 也带 CSP。
- 原文件不修改。禁止导出覆盖队列中的输入及其符号链接。
- 环境与模型：`~/Library/Application Support/Docling Mac/`。
- 结果缓存：`~/Library/Caches/Docling Mac/Results/`，含转换后的文档内容。会话临时结果在正常退出时清理。日志可能包含文件路径，分享前请检查。

识别质量取决于 Docling 与 Apple OCR，复杂公式、跨页表格和扫描件请核对。当前实现标准文档解析，未加入 VLM、音视频或云服务。

## 构建与测试

仅需 Apple Command Line Tools（`xcode-select --install`），无需完整 Xcode。

```sh
./scripts/build.sh
open 'dist/Docling Mac.app'
```

运行 `./scripts/package.sh` 可本地编译并生成 DMG、ZIP 和 SHA-256 校验文件。DMG 内含 Applications 快捷方式。仓库不包含签名凭据。

通过应用准备引擎后运行：

```sh
./scripts/test.sh
"$HOME/Library/Application Support/Docling Mac/runtime/bin/python3" scripts/verify-engine.py
```

无界面环境可先运行 `./scripts/prepare-engine.sh`。GitHub Actions 在 macOS 15 ARM64 / Xcode 16.4 上准备锁定环境，运行 Swift 与 Python 检查，下载并离线验证模型，执行六种真实格式转换，再构建并校验安装包。`main` 推送、pull request、版本 tag 和手动触发均运行；结果与安装包保留为 CI artifacts。

测试涵盖队列、进程取消、缓存失效、并发互斥、模型验证和真实格式。范围与结果见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)。AI 绘制图标原图与提示词见 [Assets/README.md](Assets/README.md)。第三方包与模型保留各自许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Docling 名称属于上游项目，本应用不代表上游官方产品。
