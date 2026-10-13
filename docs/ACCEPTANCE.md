# 0.1.0 验收记录

验收日期：2026-10-13（Asia/Singapore）。环境：Apple Silicon、macOS 27.2、Swift 6.4、Python 3.12.13、Docling 2.138.0。这里只记录本次实际检查范围，不代表任意文档都能无损识别。

## 自动检查

`./scripts/test.sh`：10 组 Swift 检查、7 项 Python 集成测试通过。

- 参数按原样传给子进程，中文、空格、shell 特殊字符不会被执行；保留非零退出码。
- 取消终止子进程；可执行文件缺失正确报错。
- 解析部分成功与不完整事件；40,000 字符警告不被界面日志上限截断。
- 队列输入校验、去重、重试与移除；导出拒绝覆盖输入及其符号链接。
- macOS Foundation 启动的 Python 进程正确进入事件协议。
- 实际 Docling 子进程取消后队列标记为已取消，运行状态释放；手动重试成功，并加载真实中英文预览。
- 中文 HTML 标题、段落、列表、表格与三种导出；含空格的文件路径。
- 损坏 Office 文件报错；已有结果目录拒绝覆盖；URL 输入拒绝。
- HTML 外部图片没有产生 HTTP 请求；文档内的字面 HTML 代码保持文本。
- 部分成功保留警告，图片子节点中的 OCR 文字在三种输出中均保留。

## 真实格式

每项使用脚本现场生成的文档，核对 Markdown 中确有指定中英文内容，三个导出文件非空，JSON schema 为 DoclingDocument。结果与导出哈希见 [acceptance-engine.json](acceptance-engine.json)。

| 输入 | 条件 | 结果 |
| --- | --- | --- |
| DOCX | 标题、正文、表格 | 通过 |
| PPTX | 中英文幻灯片 | 通过 |
| XLSX | 中英文表格 | 通过 |
| PNG | 中英文 Apple OCR | 通过 |
| 扫描 PDF | 图像页面，开启 OCR | 通过 |
| 扫描 PDF | 模型缓存后，HF_HUB_OFFLINE=1 | 通过，约 6.2 秒 |
| 原生 PDF | 两页中英文，关闭 OCR，HF_HUB_OFFLINE=1 | 通过，约 4.6 秒，页数为 2 |

离线模式验收通过 Hugging Face 的离线开关完成，没有更改本机网络。原始样本、日志和逐轮回执保留在本机 `.build/acceptance-fixtures/`，可由 `scripts/verify-engine.py` 再生。首次扫描测试发现缺少 OpenCV，补入上游官方 extra 后通过。

## 应用窗口

已实际打开构建的 `.app`，验证首次准备引擎、更新后就绪、系统文件选择、中文 HTML 转换、排版预览、Markdown 源文、复制与原生保存。通过保存面板实际导出 `.build/ui-export.md`，重新读取确认中文、列表、表格内容一致。扫描 PDF 在应用中完成，显示 1 页、约 7.2 秒，预览包含中英文 OCR 文本。

## 构建与分发边界

Release 构建成功；Info.plist 校验与 ad-hoc 代码签名校验通过。应用不捆绑 Python 环境或模型；首次使用由 uv 安装锁定依赖。本机已准备好运行环境与模型。

未在 Intel Mac 或更早 macOS 实机验收；未做 Developer ID 公证、App Store 提交或公开 GitHub 发布。复杂文档的识别质量仍须用户核对。
