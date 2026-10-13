# Docling Mac

一个极简、原生的 macOS 文档转换工具。拖入文档，在本机解析，预览并导出 Markdown、HTML 或 Docling JSON。

基于 [Docling](https://github.com/docling-project/docling)，独立非官方客户端。客户端采用 [MIT](LICENSE) 协议。

## 能做什么

- 拖入多个文件，或按 `⌘O` 添加；`⌘↩` 开始串行转换。
- 支持 PDF、DOCX、PPTX、XLSX、HTML、Markdown、CSV，以及 PNG、JPEG、TIFF、BMP、WebP 图片。
- 识别标题、段落、列表与表格；使用 Apple OCR 识别中英文扫描件。
- 切换排版预览与 Markdown 源文，一键复制、另存为文件。
- 图片嵌入导出文件；支持取消转换、查看错误、手动重试。部分成功有明确提示。

## 运行

需要 macOS 14 或更高版本。当前在 Apple Silicon Mac 上验收，Intel 未实机验证。

1. 安装 [uv](https://docs.astral.sh/uv/getting-started/installation/)：`brew install uv`。
2. 打开 `Docling Mac.app`，点击「准备本地引擎」。应用会安装锁定的 Python 3.12 和依赖，无需手动管理 Python。
3. 添加文档，点击工具栏播放按钮。首次处理 PDF / 图片会下载模型，保持联网。
4. 核对预览后点击「导出」。队列与未导出结果仅在本次会话中保留，退出前请导出。

应用从 `~/.local/bin/uv`、`/opt/homebrew/bin/uv` 或 `/usr/local/bin/uv` 查找 uv。解析环境与模型约需 1.6 GB，首次安装另需下载缓存空间。

## 从源码构建

仅需 Apple Command Line Tools（`xcode-select --install`），无需完整 Xcode，也没有第三方 Swift 包依赖。

```sh
./scripts/build.sh
open 'dist/Docling Mac.app'
```

可把生成的 `.app` 拖到「应用程序」。本地构建采用 ad-hoc 签名；公开分发给其他用户前，应使用自己的 Developer ID 签名并公证。本仓库不包含签名凭据。

## 隐私与数据

- 文档在本地 Python 子进程中转换，无账号、无云解析 API、无应用遥测。
- 首次安装连接 Python / PyPI 下载源；PDF 模型从 Hugging Face 下载。模型缓存后可离线转换。
- 禁用 Docling 远端服务与外部插件，输入仅接收本地文件；HTML / Markdown 的外部图片不主动下载。
- 应用内预览禁用 JavaScript，并通过 CSP 阻止网络资源加载。导出 HTML 也带 CSP。
- 原文件不修改。输入队列中的文件禁止作为导出覆盖目标。
- 环境：`~/Library/Application Support/Docling Mac/runtime/`；模型：同目录下 `models/`。
- 本次会话的转换结果与日志位于系统临时目录；正常退出清理本次会话结果。日志可能包含本地文件路径，分享前请检查。

扫描件、复杂公式、跨页表格的识别质量取决于 Docling 与 Apple OCR；导出前请核对。当前仅实现标准文档解析，未加入 VLM、音视频、云端服务或历史库。

## 验证

先通过应用准备引擎，再运行：

```sh
./scripts/test.sh
"$HOME/Library/Application Support/Docling Mac/runtime/bin/python3" scripts/verify-engine.py
```

第一组验证 Swift 进程管理 / 取消 / 队列和 Python 集成；第二组生成真实 Office、扫描图片和 PDF 样本并验证输出，首次会下载模型。验收范围与结果见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)。

## 结构

`Sources/DoclingMac/` 为 SwiftUI / AppKit 界面与子进程管理；`Backend/worker.py` 调用 Docling，输出 JSON 行事件；`Backend/uv.lock` 固定引擎完整依赖图。没有常驻服务或监听端口。

第三方 Python 包及模型保留各自许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Docling 名称属于上游项目，本应用不代表上游官方产品。
