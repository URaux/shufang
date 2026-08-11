# 书房 📚 — 在自己电脑上啃外文书

把一本外文书丢给它，它帮你：整理**全书梗概**和**逐章摘要** → 你想读哪章，它翻哪章 → 翻好的书在漂亮的阅读界面里看，手机也能看。所有东西都存在你自己电脑上。

## 安装（只做一次，约 10 分钟）

先去 [platform.deepseek.com](https://platform.deepseek.com) 注册，充几块钱，创建一个 API key（`sk-` 开头的一串，复制好）。

### Windows

按 `Win` 键，输入 `powershell`，打开「Windows PowerShell」，把下面这行整个粘进去回车：

```powershell
irm https://raw.githubusercontent.com/URaux/shufang/master/installer/install.ps1 | iex
```

按提示走：中途会问要不要 PDF 支持（要读 PDF 书就输 y），然后粘贴 API key。装完桌面上出现「启动书房」。

> ⚠️ 不要在 GitHub 网页上单独下载 install.bat——它一个人干不了活。要么用上面这行命令，要么下载**完整压缩包**解压后再双击 installer 里的 install.bat（离线安装用）。

### Mac

按 `Cmd+空格`，输入「终端」打开 Terminal，把下面这行整个粘进去回车：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/URaux/shufang/master/installer/install-mac.sh)"
```

中途会要你输一次开机密码（装 Homebrew 用，输入时屏幕不显示是正常的）。装完桌面上出现「启动书房.command」，第一次运行若被系统拦，右键它选「打开」一次即可。

## 日常使用

1. 双击「启动书房」→ 会弹出一个黑色小窗口（**别关它，最小化就行**）+ 浏览器页面 + Obsidian。
2. 在网页右边的聊天框里告诉助手你要读的书，比如：
   - 把书的文件（epub / txt / docx / pdf）放到 `文档\书房` 文件夹里，然后说「我放了一本书进来，帮我整理一下」
   - 或者直接说文件在哪：「桌面上有本 The Stranger.epub，我想读」
3. 等它整理完（几分钟），左边书架上就有这本书了：先看**全书梗概**和**逐章摘要**，决定读什么。
4. 想读哪章就说：「翻第 3 章」「把 5 到 8 章都翻了」「全部翻了」。翻好的章节出现在「译文」里。
5. 读到哪聊到哪：随时问它「第 3 章里那个人为什么这么做」，聊出来的想法它会帮你存进笔记。

## 手机上用

电脑开着「书房」时：手机连**同一个 Wi-Fi**，用浏览器打开黑色小窗口里显示的那个网址（或者扫窗口里的二维码）。看书、聊天都可以。

想在外面（不在家的 Wi-Fi）也能用？装 [Tailscale](https://tailscale.com)：电脑和手机各装一个，登同一个账号，打开开关就行。之后在哪都能连回家里的书房。这步可选，不装完全不影响在家用。

## 更新

不用管。每次双击「启动书房」它都会先悄悄从 GitHub 拉最新版（几十 KB 的增量），拉不到（断网）就用当前版本照常启动。你的书、译文、笔记都在 `文档\书房` 里，更新永远不会碰它们。

## 常见问题

- **双击 install.bat 窗口一闪就没了** — 你多半只下载了 bat 这一个文件，或者还在压缩包里没解压。用安装章节里的「粘一行命令」方式最省事。
- **黑窗口关了网页就打不开了** — 正常，重新双击「启动书房」。
- **助手说额度不够** — DeepSeek 余额用完了，去 platform.deepseek.com 充值。翻一整本书一般也就几块钱。
- **书是扫描版 PDF（每页是图片）** — 暂时啃不动，需要先用别的工具 OCR 成文字。
- **Obsidian 第一次打开问「是否信任」** — 点信任。它只是个看笔记的软件，书库就是普通文件夹。
- **想换电脑** — 把 `文档\书房` 文件夹整个拷走就行，书和译文都在里面。

## 这东西怎么工作的（技术人员看）

- 翻译大脑：Claude Code CLI 跑在 DeepSeek 官方 Anthropic 兼容端点上（`api.deepseek.com/anthropic`），按 [官方文档](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/) 配置
- 工作流：vault 内的 `book-translator` skill（入库/摘要/翻译/译名表/讨论）
- 前端：`~\.shufang\webapp` 里的 Node 服务（端口 7787），聊天走 SSE 包 `claude -p --continue`，阅读器直接渲染 vault markdown
- 格式转换：pandoc（epub/docx），可选 pymupdf4llm（PDF）
- 配置：`~\.shufang\config.json`（key、模型、端口、局域网访问口令都在这）
