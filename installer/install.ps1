# 书房 一键安装器
# 用法：双击 install.bat（它会用管理员权限跑这个脚本）

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# 全程留日志：闪退/报错时让用户把这个文件发回来即可远程诊断
try { Start-Transcript -Path (Join-Path $env:TEMP "shufang-install.log") -Force | Out-Null } catch {}
# 任何未捕获错误：显示人话 + 停住窗口，绝不闪退
trap {
  Write-Host ""
  Write-Host "[X] 安装中途出错了: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "    日志在 $env:TEMP\shufang-install.log，可以把它发给帮你装的人。" -ForegroundColor Yellow
  try { Stop-Transcript | Out-Null } catch {}
  Read-Host "按回车关闭"
  exit 1
}

# 支持两种跑法：解压后双击 install.bat（$PSScriptRoot 有值，附带离线文件），
# 或者终端一行 irm ... | iex（$PSScriptRoot 为空，纯在线安装）。
$PkgRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { $null }
$RepoUrl  = "https://github.com/URaux/shufang.git"
$Vault    = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "书房"
$AppDir   = Join-Path $env:USERPROFILE ".shufang"
$AppRepo  = Join-Path $AppDir "app"            # git clone，启动时自动 git pull 更新
$ConfigPath = Join-Path $AppDir "config.json"

function Step($msg) { Write-Host ""; Write-Host ">> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "   OK: $msg" -ForegroundColor Green }

Write-Host "==============================================" -ForegroundColor Yellow
Write-Host "  书房 · 本地啃书翻译器 安装程序" -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor Yellow

# ---------------------------------------------------------------- 依赖
Step "检查基础组件（Node / Pandoc / Obsidian）"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Host "这台电脑缺少 winget（微软应用安装器），一般 Win10 21H2+ / Win11 都自带。" -ForegroundColor Red
  Write-Host "请先从 Microsoft Store 安装「应用安装程序」，再重跑本安装器。" -ForegroundColor Red
  Read-Host "按回车退出"
  exit 1
}

$deps = @(
  @{ id = "OpenJS.NodeJS.LTS";      probe = "node" },
  @{ id = "Git.Git";                probe = "git" },
  @{ id = "JohnMacFarlane.Pandoc";  probe = "pandoc" },
  @{ id = "Obsidian.Obsidian";      probe = $null }
)
foreach ($d in $deps) {
  $have = $false
  if ($d.probe) { $have = [bool](Get-Command $d.probe -ErrorAction SilentlyContinue) }
  else { $have = Test-Path (Join-Path $env:LOCALAPPDATA "Obsidian\Obsidian.exe") }
  if ($have) { Ok "$($d.id) 已装" }
  else {
    Write-Host "   安装 $($d.id)（可能要一两分钟）..."
    winget install --id $d.id -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
    Ok "$($d.id) 装好了"
  }
}

# 让本次会话立刻能用刚装的命令
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

Step "安装 Claude Code（翻译助手的大脑）"
if (Get-Command claude -ErrorAction SilentlyContinue) { Ok "已装" }
else {
  npm install -g @anthropic-ai/claude-code
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
  Ok "装好了"
}

$pdf = Read-Host "要支持 PDF 格式的书吗？会多装一个 Python 组件 (y/N)"
if ($pdf -match "^[Yy]") {
  Step "安装 PDF 支持"
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
  }
  python -m pip install --quiet pymupdf4llm
  Ok "PDF 支持装好了"
}

# ---------------------------------------------------------------- API key
Step "配置 DeepSeek"
Write-Host "   需要一个 DeepSeek API key（在 platform.deepseek.com 注册后创建，sk- 开头）。"
$key = ""
while (-not ($key -match "^sk-")) {
  $key = (Read-Host "   粘贴你的 DeepSeek API key").Trim()
  if (-not ($key -match "^sk-")) { Write-Host "   看起来不太对，应该是 sk- 开头的一串。再试一次。" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------- 落盘
Step "获取书房程序（从 GitHub，之后每次启动自动更新）"
New-Item -ItemType Directory -Force $AppDir | Out-Null

$cloned = $false
if (-not (Test-Path (Join-Path $AppRepo ".git"))) {
  if (Test-Path $AppRepo) { Remove-Item -Recurse -Force $AppRepo }
  git clone --depth 1 $RepoUrl $AppRepo 2>$null
  if ($LASTEXITCODE -eq 0) { $cloned = $true; Ok "已从 GitHub 获取最新版" }
} else {
  Push-Location $AppRepo; git pull --ff-only 2>$null | Out-Null; Pop-Location
  $cloned = $true; Ok "已有安装，拉取了最新版"
}
if (-not $cloned) {
  if ($PkgRoot -and (Test-Path (Join-Path $PkgRoot "webapp"))) {
    # 离线兜底：用安装包里自带的文件（以后联网了启动器会自动接管更新）
    Copy-Item -Recurse $PkgRoot $AppRepo
    Ok "网络不通，先用安装包内置版本（联网后会自动更新）"
  } else {
    Write-Host "连不上 GitHub，而且当前是在线安装模式没有本地文件可用。" -ForegroundColor Red
    Write-Host "检查一下网络（或者网络代理），然后重跑这条安装命令。" -ForegroundColor Red
    Read-Host "按回车关闭"
    exit 1
  }
}

$VaultSrc = Join-Path $AppRepo "vault-template"
$WebDst   = Join-Path $AppRepo "webapp"

if (Test-Path $Vault) { Ok "书库已存在（$Vault），保留原样" }
else {
  Copy-Item -Recurse $VaultSrc $Vault
  Ok "书库建在 $Vault"
}

Push-Location $WebDst
npm install --omit=dev --silent
Pop-Location
Ok "网页程序就绪"

$token = -join ((48..57) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
$config = @{
  vaultPath = $Vault
  port      = 7787
  token     = $token
  env       = @{
    ANTHROPIC_BASE_URL              = "https://api.deepseek.com/anthropic"
    ANTHROPIC_AUTH_TOKEN            = $key
    ANTHROPIC_MODEL                 = "deepseek-v4-pro"
    ANTHROPIC_DEFAULT_OPUS_MODEL    = "deepseek-v4-pro"
    ANTHROPIC_DEFAULT_SONNET_MODEL  = "deepseek-v4-pro"
    ANTHROPIC_DEFAULT_HAIKU_MODEL   = "deepseek-v4-flash"
    CLAUDE_CODE_SUBAGENT_MODEL      = "deepseek-v4-flash"
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
  }
}
$config | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $ConfigPath
Ok "配置写好了"

# ---------------------------------------------------------------- 快捷方式
Step "创建桌面快捷方式"
$Desktop = [Environment]::GetFolderPath("Desktop")
$launcher = Join-Path $Desktop "启动书房.bat"
$launcherText = @"
@echo off
chcp 65001 >nul
title 书房
cd /d "$AppRepo"
echo 检查更新中...
git pull --ff-only >nul 2>&1
cd webapp
call npm install --omit=dev --silent >nul 2>&1
rem 更新书库里的系统文件（助手的说明书），你自己的书和笔记不会被动
xcopy /E /Y /I /Q "$AppRepo\vault-template\.claude" "$Vault\.claude" >nul 2>&1
copy /Y "$AppRepo\vault-template\CLAUDE.md" "$Vault\CLAUDE.md" >nul 2>&1
start "" "obsidian://open?path=$([uri]::EscapeDataString($Vault))"
start "" http://localhost:7787/
node server.js
pause
"@
# cmd 不认 BOM，必须写成无 BOM 的 UTF-8，否则第一行会报错
[System.IO.File]::WriteAllText($launcher, $launcherText, (New-Object System.Text.UTF8Encoding($false)))
Ok "桌面上有「启动书房」了"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "  双击桌面「启动书房」开始用。" -ForegroundColor Green
Write-Host "  第一次 Obsidian 打开时选「信任此仓库」即可。" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
Read-Host "按回车关闭本窗口"
